import {CameraResponse} from './camera.js';
import {traceRows} from './trace-queue.js';

export const defaults = {
  spin:.82, mass:1e8, accretion:.1, outerRadius:30, thickness:0,
  cameraYaw:-.28, cameraPitch:.06, cameraDistance:80, fov:.48, lookYaw:0, lookPitch:0,
  quality:'max', appearance:'radiant', exposureEV:0, paletteTemperature:6800,
  materialStrength:.9, glowStrength:0, fluctuations:0, rotation:true,
  playback:4000, energy:false, diagnosticMode:false, passage:false,
};
export const modes = {
  interactive:{steps:2048,tolerance:2e-6,maxStep:.025,samples:1,fps:60,pixels:230_400,headroomPixels:2_073_600,traceBudget:100,movingBudget:24,minimumPixels:4096,maxDPR:1,materialSamples:1,lite:true},
  auto:{steps:4096,tolerance:2e-6,maxStep:.025,samples:1,fps:60,pixels:1_500_000,traceBudget:800},
  efficient:{steps:2048,tolerance:3e-6,maxStep:.025,samples:1,fps:30,pixels:600_000,traceBudget:400},
  cinematic:{steps:4096,tolerance:8e-7,maxStep:.018,samples:2,fps:30,pixels:2_500_000,traceBudget:1800},
  max:{steps:8192,tolerance:3e-7,maxStep:.012,samples:4,fps:60,pixels:8_294_400,traceBudget:5000,gpuBudgetFraction:.875,maxScale:3},
};

/** WebAssembly owns f64 source physics; WebGPU owns transport and camera. */
export class KerrRenderer {
  constructor(canvas, status=()=>{}) {
    this.canvas=canvas; this.status=status; this.settings={...defaults};
    this.width=0;this.height=0;this.samples=1;this.frame=0;this.traceCount=0;
    this.gpuMS=0;this.queueMS=0;this.traceMS=0;this.raysPerMS=0;this.errors=[];
    this.pendingFrames=0;this.queryBusy=false;this.timingSerial=0;
    this.uniformBytes=new ArrayBuffer(176);this.uniformView=new DataView(this.uniformBytes);
    this.emissionMS=0;this.presentationMS=0;
    this.timingGeneration=0;this.gpuTiming=null;this.completionTiming=null;
    this.completionWindowStart=null;this.completionWindowCount=0;
  }
  resetTiming() {
    this.timingGeneration++;this.gpuTiming=null;this.completionTiming=null;
    this.completionWindowStart=null;this.completionWindowCount=0;
    this.gpuMS=0;this.queueMS=0;this.emissionMS=0;this.presentationMS=0;
  }
  async init() {
    if(!isSecureContext || !navigator.gpu) throw Error('WebGPU is unavailable. Open this in a WebGPU-enabled browser over localhost or HTTPS. There is intentionally no WebGL fallback.');
    const start=performance.now();
    this.status('Loading compiled double-precision disk physics…');
    // Independent network and adapter discovery do not need a serial waterfall.
    const [response,shaderResponse,adapter]=await Promise.all([
      fetch('./core.wasm'),fetch(new URL('./kerr.wgsl',import.meta.url)),
      navigator.gpu.requestAdapter({powerPreference:'high-performance'}),
    ]);
    if(!response.ok) throw Error('The compiled core.wasm file is missing. Build the browser target first.');
    if(!shaderResponse.ok) throw Error('Unable to load Kerr shader.');
    const [bytes,shaderSource]=await Promise.all([response.arrayBuffer(),shaderResponse.text()]);this.wasmBytes=bytes.byteLength;
    const {instance}=await WebAssembly.instantiate(bytes,{}); this.core=instance.exports;
    if(this.core.abi_version()!==1) throw Error('Unsupported physics core ABI.');
    this.core.init_spectrum();
    this.adapter=adapter;
    if(!this.adapter) throw Error('No WebGPU adapter is available. Check browser graphics acceleration.');
    const timestamp=this.adapter.features.has('timestamp-query');
    // Request enough supported storage for the highest useful ray-map size,
    // including chooseRenderSize's 10% reserve. Requesting a limit allocates
    // nothing; actual maps remain viewport-, calibration- and memory-bounded.
    const usefulStorage=Math.ceil(modes.max.pixels*modes.max.samples*16/.9);
    const maxStorage=Math.min(usefulStorage,this.adapter.limits.maxStorageBufferBindingSize,this.adapter.limits.maxBufferSize);
    this.device=await this.adapter.requestDevice({
      requiredFeatures:timestamp?['timestamp-query']:[],
      requiredLimits:{maxStorageBufferBindingSize:maxStorage,maxBufferSize:maxStorage},
    });
    this.device.addEventListener('uncapturederror',event=>{
      this.errors.push(event.error.message); this.onError?.(Error(event.error.message));
    });
    this.device.lost.then(info=>{if(info.reason!=='destroyed') this.onError?.(Error(`GPU connection lost: ${info.message}. Reload to recover.`));});
    this.context=this.canvas.getContext('webgpu');
    this.format=navigator.gpu.getPreferredCanvasFormat();
    this.context.configure({device:this.device,format:this.format,alphaMode:'opaque'});
    this.uniform=this.device.createBuffer({label:'Native-compatible 176-byte parameters',size:176,usage:GPUBufferUsage.UNIFORM|GPUBufferUsage.COPY_DST});
    const storage=(label,size)=>this.device.createBuffer({label,size,usage:GPUBufferUsage.STORAGE|GPUBufferUsage.COPY_DST});
    this.disk=storage('Page–Thorne radial f32 upload',4096*16);
    this.spectrum=storage('CIE spectral f32 upload',2048*16);
    this.device.queue.writeBuffer(this.spectrum,0,new Float32Array(this.core.memory.buffer,this.core.spectral_ptr(),this.core.spectral_count()*4));
    this.updateModel();
    this.status('Compiling Kerr transport and photographic response for this GPU…');
    const module=this.device.createShaderModule({label:'Kerr null geodesics',code:shaderSource});
    const info=await module.getCompilationInfo();
    const errors=info.messages.filter(m=>m.type==='error');
    if(errors.length) throw Error(errors.map(m=>`Kerr shader ${m.lineNum}:${m.linePos}: ${m.message}`).join('\n'));
    const entries=[
      {binding:0,visibility:GPUShaderStage.COMPUTE,buffer:{type:'uniform'}},
      {binding:1,visibility:GPUShaderStage.COMPUTE,buffer:{type:'storage'}},
      {binding:2,visibility:GPUShaderStage.COMPUTE,buffer:{type:'read-only-storage'}},
      {binding:3,visibility:GPUShaderStage.COMPUTE,buffer:{type:'read-only-storage'}},
      {binding:4,visibility:GPUShaderStage.COMPUTE,storageTexture:{access:'write-only',format:'rgba16float'}},
    ];
    this.layout=this.device.createBindGroupLayout({entries});
    this.validationLayout=this.device.createBindGroupLayout({entries:[...entries,
      {binding:5,visibility:GPUShaderStage.COMPUTE,buffer:{type:'read-only-storage'}},
      {binding:6,visibility:GPUShaderStage.COMPUTE,buffer:{type:'storage'}},
    ]});
    const layout=this.device.createPipelineLayout({bindGroupLayouts:[this.layout]});
    const validationLayout=this.device.createPipelineLayout({bindGroupLayouts:[this.validationLayout]});
    this.transportModule=module;this.validationPipelineLayout=validationLayout;
    this.camera=new CameraResponse(this.device,this.format);
    [this.tracePipeline,this.shadePipeline]=await Promise.all([
      this.device.createComputePipelineAsync({label:'Cached geodesic trace',layout,compute:{module,entryPoint:'traceGeometry'}}),
      this.device.createComputePipelineAsync({label:'Retarded source shading',layout,compute:{module,entryPoint:'shadeGeometry'}}),
      this.camera.init(),
    ]);
    if(timestamp) {
      this.queries=this.device.createQuerySet({type:'timestamp',count:4});
      this.queryResolve=this.device.createBuffer({size:32,usage:GPUBufferUsage.QUERY_RESOLVE|GPUBufferUsage.COPY_SRC});
      this.queryRead=this.device.createBuffer({size:32,usage:GPUBufferUsage.MAP_READ|GPUBufferUsage.COPY_DST});
    }
    this.startupMS=performance.now()-start;
  }
  updateModel() {
    const s=this.settings;
    const key=[s.spin,s.mass,s.accretion,s.outerRadius,s.thickness].join('|');
    if(key===this.modelKey) return false;
    if(this.core.init_model(s.spin,s.mass,s.accretion,s.outerRadius,s.thickness)) throw Error('Invalid disk model parameters.');
    this.meta=new Float64Array(this.core.memory.buffer,this.core.metadata_ptr(),11).slice();
    if(this.device) this.device.queue.writeBuffer(this.disk,0,new Float32Array(this.core.memory.buffer,this.core.radial_ptr(),this.core.radial_count()*4));
    this.modelKey=key;return true;
  }
  // Scratch bytes: queue.writeBuffer copies them during the call. A consumer
  // retaining a snapshot (e.g. a multi-strip trace) must explicitly slice it.
  uniforms(time=0,row=0,overrides=null) {
    const s=this.settings, m=modes[s.quality], a=this.uniformBytes,v=this.uniformView;
    const f=(i,n)=>v.setFloat32(i,n,true),u=(i,n)=>v.setUint32(i,n,true);
    u(0,this.width);u(4,this.height);f(8,time);f(12,s.spin);f(20,s.cameraYaw);f(24,s.cameraPitch);f(28,s.cameraDistance);
    u(32,m.steps);u(36,this.samples);u(40,0);f(44,s.cameraDistance);f(48,s.fov);f(52,m.tolerance);f(56,m.maxStep);
    f(60,this.meta[0]);f(64,this.meta[1]);f(68,.03);u(72,4096);f(76,this.meta[2]);f(80,this.meta[3]);f(84,this.meta[7]);
    f(88,s.appearance==='scientific'?0:s.fluctuations);u(92,2048);f(96,this.meta[5]);f(100,this.meta[6]);u(104,s.diagnosticMode?1:0);f(108,row);
    f(112,s.lookYaw);f(116,s.lookPitch);u(120,s.appearance==='scientific'?0:1);f(124,s.materialStrength);f(128,s.paletteTemperature);
    f(132,s.rotation?time:0);f(136,this.meta[2]);f(140,Math.log(s.outerRadius)-this.meta[2]);f(144,s.rotation?1:0);u(148,m.lite?0:1);
    f(152,s.appearance==='scientific'?0:this.meta[10]);f(156,0);
    u(16,0);u(160,0);u(164,0);
    f(168,s.rotation?.5*s.playback/(s.energy?20:m.fps):0);u(172,m.materialSamples??(s.quality==='max'?4:s.quality==='efficient'?1:2));
    for(const offset in overrides) {
      const value=overrides[offset];
      ([0,4,32,36,40,72,92,104,120,148,160,164,172].includes(Number(offset))?u:f)(Number(offset),value);
    }
    return a;
  }
  entries() {return [
    {binding:0,resource:{buffer:this.uniform}},{binding:1,resource:{buffer:this.geometry}},
    {binding:2,resource:{buffer:this.disk}},{binding:3,resource:{buffer:this.spectrum}},
    {binding:4,resource:this.hdr.createView()},
  ];}
  async rebuild(width,height,samples=1,progress=()=>{},cancel=()=>false) {
    width=Math.max(8,Math.floor(width));height=Math.max(8,Math.floor(height));
    const bytes=width*height*samples*16;
    if(bytes>this.device.limits.maxStorageBufferBindingSize) throw Error('Ray map exceeds this adapter’s buffer limit. Reduce quality.');
    await this.device.queue.onSubmittedWorkDone();
    this.resetTiming();
    if(width!==this.width||height!==this.height||samples!==this.samples) {
      this.geometry?.destroy();this.hdr?.destroy();
      this.width=width;this.height=height;this.samples=samples;
      this.geometry=this.device.createBuffer({label:'Cached (radius, azimuth, delay, redshift)',size:bytes,usage:GPUBufferUsage.STORAGE|GPUBufferUsage.COPY_SRC});
      this.hdr=this.device.createTexture({label:'Linear HDR emission',size:[width,height],format:'rgba16float',usage:GPUTextureUsage.STORAGE_BINDING|GPUTextureUsage.TEXTURE_BINDING|GPUTextureUsage.COPY_SRC});
      this.bindings=this.device.createBindGroup({layout:this.layout,entries:this.entries()});
    }
    // Freeze every strip to one camera/model snapshot. Input can keep moving
    // while this small map finishes, without mixing multiple poses in one map.
    const traceUniforms=this.uniforms(0,0).slice(0),traceView=new DataView(traceUniforms);
    const start=performance.now();
    // Use only completed traces to seed the next bounded chunk. The first map
    // still starts at one workgroup row; all chunks retain the watchdog cap.
    const predictedRows=Number.isFinite(this.raysPerMS)?this.raysPerMS*8/(width*samples):0;
    // Queue one successor so browser fence delivery does not leave the device
    // idle between strips. Both chunks remain capped and retire on cancellation.
    const complete=await traceRows({height,initialRows:predictedRows,cancel,progress,
      submit:(row,rows)=>{
        traceView.setFloat32(108,row,true);
        this.device.queue.writeBuffer(this.uniform,0,traceUniforms);
        const encoder=this.device.createCommandEncoder(),pass=encoder.beginComputePass();
        pass.setPipeline(this.tracePipeline);pass.setBindGroup(0,this.bindings);
        pass.dispatchWorkgroups(Math.ceil(width/8),Math.ceil(rows/8),samples);pass.end();
        this.device.queue.submit([encoder.finish()]);
        return this.device.queue.onSubmittedWorkDone();
      },
    });
    if(!complete) return false;
    // Input may change while the final strip is in flight, not just between
    // strips. Do not publish that stale map as a completed camera revision.
    if(cancel()) return false;
    this.geometryPose={distance:traceView.getFloat32(44,true),fov:traceView.getFloat32(48,true)};
    this.traceMS=performance.now()-start;this.traceCount++;
    this.raysPerMS=width*height*samples/this.traceMS;return true;
  }
  async render(timeSeconds=0,{wait=true,measure:forceMeasure=false}={}) {
    // Interactive callers submit without a CPU/GPU round-trip every frame.
    // Bound latency and memory: never queue an unbounded backlog of frames.
    if(!wait&&this.pendingFrames>=2) return null;
    // A timing belongs to its workload, not indefinitely to this device. Mode
    // switches and presentation resizes invalidate old samples without adding
    // per-frame objects or relying on a user-agent name.
    const s=this.settings,m=modes[s.quality];
    const variant=(m.lite?1:0)|(s.appearance==='scientific'?2:0)|(s.glowStrength>0?4:0)|
      (s.materialStrength>0?8:0)|(s.fluctuations>0?16:0)|(s.diagnosticMode?256:0)|(s.energy?512:0)|(s.rotation?1024:0)|
      ((m.materialSamples??(s.quality==='max'?4:s.quality==='efficient'?1:2))*32);
    if(variant!==this.timingVariant||this.canvas.width!==this.timingCanvasWidth||this.canvas.height!==this.timingCanvasHeight) {
      this.resetTiming();this.timingVariant=variant;this.timingCanvasWidth=this.canvas.width;this.timingCanvasHeight=this.canvas.height;
    }
    const generation=this.timingGeneration;
    const start=performance.now(),measure=!!this.queries&&!this.queryBusy&&(forceMeasure||this.frame%30===0);
    const pose=this.geometryPose;
    const uniforms=this.uniforms(timeSeconds);
    if(pose) {const view=this.uniformView;view.setFloat32(44,pose.distance,true);view.setFloat32(48,pose.fov,true);}
    this.device.queue.writeBuffer(this.uniform,0,uniforms);
    const encoder=this.device.createCommandEncoder();
    const pass=encoder.beginComputePass({label:'Emission',...(measure?{timestampWrites:{querySet:this.queries,beginningOfPassWriteIndex:0,endOfPassWriteIndex:1}}:{})});
    pass.setPipeline(this.shadePipeline);pass.setBindGroup(0,this.bindings);
    pass.dispatchWorkgroups(Math.ceil(this.width/8),Math.ceil(this.height/8));pass.end();
    this.camera.encode(encoder,this.hdr,this.context.getCurrentTexture().createView(),this.settings,
      measure?{querySet:this.queries,beginningOfPassWriteIndex:2,endOfPassWriteIndex:3}:undefined);
    if(measure) {
      encoder.resolveQuerySet(this.queries,0,4,this.queryResolve,0);encoder.copyBufferToBuffer(this.queryResolve,0,this.queryRead,0,32);
    }
    this.device.queue.submit([encoder.finish()]);this.pendingFrames++;this.frame++;
    // Encoding is synchronous; acquire only after a successful submission so
    // a rejected encoder cannot permanently reserve the timestamp buffer.
    if(measure)this.queryBusy=true;
    const submissionMS=performance.now()-start;
    const completion=this.device.queue.onSubmittedWorkDone().then(async()=>{
      this.pendingFrames--;const completedAt=performance.now(),elapsed=completedAt-start;this.timingSerial++;
      if(generation===this.timingGeneration) {
        this.queueMS=this.queueMS?this.queueMS*.8+elapsed*.2:elapsed;
        if(this.completionWindowStart===null)this.completionWindowStart=completedAt;
        else {
          this.completionWindowCount++;
          const duration=completedAt-this.completionWindowStart;
          if(duration>=100&&this.completionWindowCount>=8) {
            this.completionTiming={ms:duration/this.completionWindowCount,at:completedAt,generation,samples:this.completionWindowCount};
            this.completionWindowStart=completedAt;this.completionWindowCount=0;
          }
        }
      }
      if(measure) {
        try {
          await this.queryRead.mapAsync(GPUMapMode.READ);
          const stamps=new BigUint64Array(this.queryRead.getMappedRange());
          if(generation===this.timingGeneration) {
            this.emissionMS=Number(stamps[1]-stamps[0])/1e6;
            this.presentationMS=Number(stamps[3]-stamps[2])/1e6;
            this.gpuMS=Number(stamps[3]-stamps[0])/1e6;
            // Smooth timestamp jitter only within one unchanged workload.
            // The HUD keeps the raw span; adaptation avoids retracing a large
            // map in response to one noisy timestamp. resetTiming clears it.
            const previous=this.gpuTiming;
            const stableMS=previous?.generation===generation ? previous.ms*.65+this.gpuMS*.35 : this.gpuMS;
            this.gpuTiming=Number.isFinite(this.gpuMS)&&this.gpuMS>0
              ? {ms:stableMS,at:completedAt,generation} : null;
          }
        } finally {this.queryRead.unmap();this.queryBusy=false;}
      }
      return elapsed;
    },error=>{this.pendingFrames--;if(measure) this.queryBusy=false;throw error;});
    if(wait) return completion;
    completion.catch(error=>this.onError?.(error));
    return submissionMS;
  }
  async readHDR() {
    const stride=Math.ceil(this.width*8/256)*256;
    const out=this.device.createBuffer({size:stride*this.height,usage:GPUBufferUsage.COPY_DST|GPUBufferUsage.MAP_READ});
    const e=this.device.createCommandEncoder();e.copyTextureToBuffer({texture:this.hdr},{buffer:out,bytesPerRow:stride},[this.width,this.height]);this.device.queue.submit([e.finish()]);
    await out.mapAsync(GPUMapMode.READ);const half=new Uint16Array(out.getMappedRange()),pixels=new Float32Array(this.width*this.height*4);
    for(let y=0;y<this.height;y++) for(let x=0;x<this.width*4;x++) {
      const v=half[y*stride/2+x],sign=v&32768?-1:1,exp=(v>>10)&31,frac=v&1023;
      pixels[(y*this.width*4)+x]=sign*(exp===31?(frac?NaN:Infinity):exp===0?frac*2**-24:(1+frac/1024)*2**(exp-15));
    }
    out.unmap();out.destroy();return pixels;
  }
  async validateCases(cases) {
    if(!this.validationPipeline) this.validationPipeline=await this.device.createComputePipelineAsync({
      label:'Reference ray validation',layout:this.validationPipelineLayout,
      compute:{module:this.transportModule,entryPoint:'validateKerr'},
    });
    const pixels=this.device.createBuffer({size:16,usage:GPUBufferUsage.STORAGE|GPUBufferUsage.COPY_DST});
    const output=this.device.createBuffer({size:64,usage:GPUBufferUsage.STORAGE|GPUBufferUsage.COPY_SRC});
    const read=this.device.createBuffer({size:64,usage:GPUBufferUsage.COPY_DST|GPUBufferUsage.MAP_READ});
    const group=this.device.createBindGroup({layout:this.validationLayout,entries:[...this.entries(),{binding:5,resource:{buffer:pixels}},{binding:6,resource:{buffer:output}}]});
    const results=[];
    for(const c of cases) {
      const overrides={0:c.resolution[0],4:c.resolution[1],12:c.spin,20:c.cameraYaw??.17,24:c.cameraPitch??.28,44:c.cameraDistance??36,
        32:c.steps??4096,48:c.fov??Math.PI/4,52:c.tolerance??2e-6,56:c.maxStep??.02,60:this.core.isco(c.spin),64:c.diskOuter??30,
        112:c.lookYaw??0,116:c.lookPitch??0,152:0,156:0};
      this.device.queue.writeBuffer(this.uniform,0,this.uniforms(0,0,overrides));
      this.device.queue.writeBuffer(pixels,0,new Float32Array([...c.pixel,0,0]));
      const e=this.device.createCommandEncoder(),p=e.beginComputePass();p.setPipeline(this.validationPipeline);p.setBindGroup(0,group);p.dispatchWorkgroups(1);p.end();
      e.copyBufferToBuffer(output,0,read,0,64);this.device.queue.submit([e.finish()]);await read.mapAsync(GPUMapMode.READ);
      results.push({...c,result:Array.from(new Float32Array(read.getMappedRange()))});read.unmap();
    }
    pixels.destroy();output.destroy();read.destroy();return results;
  }
}
