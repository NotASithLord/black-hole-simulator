import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {KerrRenderer} from '../src/renderer.js';

// Exercise the actual initialization, rebuild and presentation host code with
// the real compiled WASM model and a fake WebGPU device. No browser, driver,
// shader compiler or GPU execution is involved in this portability check.
const originals=new Map(['fetch','navigator','isSecureContext','performance','GPUBufferUsage','GPUTextureUsage','GPUShaderStage','GPUMapMode'].map(name=>[name,Object.getOwnPropertyDescriptor(globalThis,name)]));
const install=(name,value)=>Object.defineProperty(globalThis,name,{value,writable:true,configurable:true});
const wasm=await readFile(new URL('../public/core.wasm',import.meta.url));
const source={
  'kerr.wgsl':await readFile(new URL('../src/kerr.wgsl',import.meta.url),'utf8'),
  'camera.wgsl':await readFile(new URL('../src/camera.wgsl',import.meta.url),'utf8'),
};
install('isSecureContext',true);
install('GPUBufferUsage',{MAP_READ:1,COPY_SRC:4,COPY_DST:8,UNIFORM:64,STORAGE:128,QUERY_RESOLVE:512});
install('GPUTextureUsage',{COPY_SRC:1,TEXTURE_BINDING:4,STORAGE_BINDING:8});
install('GPUShaderStage',{VERTEX:1,FRAGMENT:2,COMPUTE:4});
install('GPUMapMode',{READ:1});
const MiB=1024*1024;
let passed=0;
const check=(name,condition)=>{assert.ok(condition,name);passed++;console.log(`PASS ${name}`);};
const deferred=()=>{let resolve;const promise=new Promise(done=>{resolve=done;});return {promise,resolve};};

function makeHost(timestamp,format,limitOverrides={}) {
  const events=[],buffers=[],textures=[],computePipelines=[],renderPipelines=[],passes=[];
  let request,queryCount=0,resolveCount=0,timestampScale=1;
  const limits={maxStorageBufferBindingSize:128*MiB,maxBufferSize:256*MiB,maxTextureDimension2D:8192,
    maxComputeWorkgroupsPerDimension:65535,maxStorageBuffersPerShaderStage:8,maxStorageTexturesPerShaderStage:4,...limitOverrides};
  const device={
    limits:{...limits},lost:new Promise(()=>{}),addEventListener(){},
    queue:{
      writeBuffer(buffer,offset,data){
        const bytes=data instanceof ArrayBuffer?new Uint8Array(data):new Uint8Array(data.buffer,data.byteOffset,data.byteLength);
        new Uint8Array(buffer.bytes).set(bytes,offset);
      },
      submit(commands){for(const command of commands)for(const execute of command)execute();},
      async onSubmittedWorkDone(){},
    },
    createBuffer(descriptor){
      assert.ok(descriptor.size<=this.limits.maxBufferSize);
      if(descriptor.usage&GPUBufferUsage.STORAGE)assert.ok(descriptor.size<=this.limits.maxStorageBufferBindingSize);
      const buffer={...descriptor,bytes:new ArrayBuffer(descriptor.size),destroyed:false,
        get mapState(){return this.mapped?'mapped':'unmapped';},
        async mapAsync(){this.mapped=true;},getMappedRange(){assert.equal(this.mapped,true);return this.bytes;},
        unmap(){this.mapped=false;},destroy(){this.destroyed=true;}};
      buffers.push(buffer);return buffer;
    },
    createTexture(descriptor){
      const [width,height]=descriptor.size;
      assert.ok(width>0&&height>0&&width<=limits.maxTextureDimension2D&&height<=limits.maxTextureDimension2D);
      assert.equal(descriptor.format,'rgba16float');
      const texture={width,height,destroyed:false,createView(){return {texture:this};},destroy(){this.destroyed=true;}};
      textures.push(texture);return texture;
    },
    createSampler(descriptor){assert.equal(descriptor.minFilter,'linear');return {descriptor};},
    createBindGroupLayout(descriptor){
      assert.ok(descriptor.entries.filter(entry=>entry.buffer?.type?.includes('storage')).length<=limits.maxStorageBuffersPerShaderStage);
      assert.ok(descriptor.entries.filter(entry=>entry.storageTexture).length<=limits.maxStorageTexturesPerShaderStage);
      return descriptor;
    },
    createPipelineLayout(descriptor){return descriptor;},
    createBindGroup(descriptor){return descriptor;},
    createShaderModule(descriptor){assert.ok(descriptor.code.length>100);return {async getCompilationInfo(){return {messages:[]};}};},
    async createComputePipelineAsync(descriptor){computePipelines.push(descriptor.compute.entryPoint);return {getBindGroupLayout(){return {};}};},
    async createRenderPipelineAsync(descriptor){
      assert.equal(descriptor.fragment.targets[0].format,format);renderPipelines.push(descriptor.fragment.entryPoint);
      return {getBindGroupLayout(){return {};}};
    },
    createQuerySet(descriptor){assert.equal(timestamp,true,'Timestamp resources need the optional feature');queryCount++;return {...descriptor,values:new BigUint64Array(descriptor.count)};},
    createCommandEncoder(){
      const commands=[];
      function begin(kind,descriptor={}) {
        passes.push({kind,...descriptor});
        if(descriptor.timestampWrites) {
          assert.equal(timestamp,true);
          const {querySet,beginningOfPassWriteIndex:begin,endOfPassWriteIndex:end}=descriptor.timestampWrites;
          commands.push(()=>{querySet.values[begin]=BigInt((begin+1)*timestampScale)*1_000_000n;querySet.values[end]=BigInt((end+1)*timestampScale)*1_000_000n;});
        }
        return {setPipeline(){},setBindGroup(){},draw(){},
          dispatchWorkgroups(x,y,z=1){assert.ok([x,y,z].every(n=>n<=limits.maxComputeWorkgroupsPerDimension));},end(){}};
      }
      return {
        beginComputePass:descriptor=>begin('compute',descriptor),beginRenderPass:descriptor=>begin('render',descriptor),
        resolveQuerySet(query,first,count,destination,offset){
          assert.equal(offset%256,0);resolveCount++;
          commands.push(()=>new BigUint64Array(destination.bytes,offset,count).set(query.values.subarray(first,first+count)));
        },
        copyBufferToBuffer(from,fromOffset,to,toOffset,size){commands.push(()=>{
          assert.ok(!from.mapped&&!to.mapped,'Submitted buffers must not remain mapped');
          new Uint8Array(to.bytes,toOffset,size).set(new Uint8Array(from.bytes,fromOffset,size));
        });},
        finish(){return commands;},
      };
    },
  };
  const adapter={
    features:new Set(timestamp?['timestamp-query']:[]),limits,
    // Intentionally omit adapter.info to exercise older/redacted hosts.
    async requestDevice(descriptor){
      request=descriptor;
      assert.deepEqual(descriptor.requiredFeatures,timestamp?['timestamp-query']:[]);
      for(const [name,value] of Object.entries(descriptor.requiredLimits))assert.ok(value<=limits[name]);
      Object.assign(device.limits,descriptor.requiredLimits);return device;
    },
  };
  install('navigator',{gpu:{async requestAdapter(){events.push('adapter');return adapter;},getPreferredCanvasFormat(){return format;}}});
  install('fetch',async url=>{
    const name=String(url).split('/').at(-1);events.push(name);
    if(name==='core.wasm')return {ok:true,arrayBuffer:async()=>wasm.buffer.slice(wasm.byteOffset,wasm.byteOffset+wasm.byteLength)};
    if(name in source)return {ok:true,text:async()=>source[name]};
    throw Error(`Unexpected fake-host request: ${url}`);
  });
  const canvas={width:320,height:216,getContext(kind){assert.equal(kind,'webgpu');return {
    configure(descriptor){assert.equal(descriptor.device,device);assert.equal(descriptor.format,format);},
    getCurrentTexture(){return {createView(){return {};}};},
  };}};
  return {canvas,device,events,buffers,textures,computePipelines,renderPipelines,passes,
    get request(){return request;},get queryCount(){return queryCount;},get resolveCount(){return resolveCount;},
    set timestampScale(value){timestampScale=value;}};
}

try {
  for(const [name,limits,expected] of [
    ['Large-memory adapter', {maxStorageBufferBindingSize:1024*MiB,maxBufferSize:2048*MiB},589824000],
    ['Buffer-size-limited adapter', {maxStorageBufferBindingSize:1024*MiB,maxBufferSize:192*MiB},192*MiB],
  ]) {
    const host=makeHost(false,'bgra8unorm',limits),renderer=new KerrRenderer(host.canvas);
    await renderer.init();
    check(`${name} requests the supported useful ray-map limit instead of an arbitrary 256 MiB ceiling`,
      host.request.requiredLimits.maxStorageBufferBindingSize===expected&&host.request.requiredLimits.maxBufferSize===expected);
    check(`${name} does not allocate the requested memory ceiling at startup`,host.buffers.every(buffer=>buffer.size<MiB));
    renderer.camera.destroy();for(const buffer of host.buffers)buffer.destroy();
  }
  for(const timestamp of [false,true]) {
    const label=timestamp?'optional timestamps':'no timestamp feature';
    const host=makeHost(timestamp,timestamp?'bgra8unorm':'rgba8unorm');
    const renderer=new KerrRenderer(host.canvas);
    await renderer.init();
    check(`${label}: initializes on 128 MiB storage / 8192 texture limits`,
      host.request.requiredLimits.maxStorageBufferBindingSize===128*MiB&&host.request.requiredLimits.maxBufferSize===128*MiB);
    check(`${label}: initialization tolerates unavailable adapter identity`,renderer.adapter.info===undefined&&renderer.meta.every(Number.isFinite));
    check(`${label}: adapter discovery and both initial fetches start together`,
      host.events.slice(0,3).sort().join('|')===['adapter','core.wasm','kerr.wgsl'].sort().join('|'));
    check(`${label}: unused validation pipeline stays lazy`,
      host.computePipelines.length===3&&['traceGeometry','shadeGeometry','cameraDownsample'].every(entry=>host.computePipelines.includes(entry)));
    check(`${label}: camera formats need no optional float-filtering or arithmetic feature`,
      host.request.requiredFeatures.length===(timestamp?1:0)&&host.renderPipelines.length===1);
    await renderer.rebuild(16,16,1);
    await renderer.render(0,{wait:true,measure:true});
    check(`${label}: actual host render path completes and drains pending frames`,renderer.frame===1&&renderer.pendingFrames===0&&renderer.timingSerial===1);
    if(timestamp) {
      check('Timestamp writes use the actual emission and presentation passes',
        host.passes.filter(pass=>pass.timestampWrites).map(pass=>pass.kind).join('|')==='compute|render'&&host.queryCount===1&&host.resolveCount===1);
      check('Timestamp readback distinguishes emission, presentation and total span',renderer.emissionMS===1&&renderer.presentationMS===1&&renderer.gpuMS===3);
      host.timestampScale=2;await renderer.render(0,{wait:true,measure:true});
      check('Adaptation smooths same-workload GPU timestamps while preserving the raw HUD span',
        renderer.gpuMS===6&&Math.abs(renderer.gpuTiming.ms-4.05)<1e-12);
      renderer.resetTiming();await renderer.render(0,{wait:true,measure:true});
      check('Timing reset does not blend old resource costs into new workload evidence',renderer.gpuTiming.ms===6);
      host.timestampScale=0;await renderer.render(0,{wait:true,measure:true});
      check('Zero-quantized timestamps cannot manufacture fresh execution headroom',renderer.gpuMS===0&&renderer.gpuTiming===null);
      host.timestampScale=1;renderer.resetTiming();
      // Fault injection tests exception-path ownership, not browser failures.
      // Each rejected operation must retire its frame/query and permit the next
      // measurement, including when mapping succeeded before decoding failed.
      const faults=[
        ['mapAsync rejects',renderer.queryRead,'mapAsync'],
        ['getMappedRange throws after mapping',renderer.queryRead,'getMappedRange'],
        ['camera encoding throws before submission',renderer.camera,'encode'],
      ];
      for(const [name,object,method] of faults) {
        const original=object[method];
        const failure=Error(`Injected failure: ${name}`);
        object[method]=()=>{throw failure;};
        if(method==='mapAsync')object[method]=async()=>{throw failure;};
        try {await assert.rejects(renderer.render(0,{wait:true,measure:true}),error=>error===failure);}
        finally {object[method]=original;}
        check(`${name}: frame and query ownership retire`,renderer.pendingFrames===0&&renderer.queryBusy===false);
        check(`${name}: readback buffer is not left mapped`,renderer.queryRead.mapState==='unmapped');
        await renderer.render(0,{wait:true,measure:true});
        check(`${name}: a following measured frame succeeds`,renderer.pendingFrames===0&&!renderer.queryBusy&&renderer.gpuMS===3);
      }
    } else {
      check('No timestamp resources, writes or resolves when the feature is absent',
        host.queryCount===0&&host.resolveCount===0&&!host.passes.some(pass=>pass.timestampWrites));
    }
    // A completed submission can still have a pending timestamp map. Neither
    // that map nor an older queue completion may repopulate a reset generation.
    {
      const original=host.device.queue.onSubmittedWorkDone,done=deferred();
      host.device.queue.onSubmittedWorkDone=()=>done.promise;
      const frame=renderer.render(0,{wait:true,measure:true});
      renderer.resetTiming();const generation=renderer.timingGeneration;
      done.resolve();await frame;host.device.queue.onSubmittedWorkDone=original;
      check(`${label}: reset rejects a pending old-generation completion`,
        renderer.gpuTiming===null&&renderer.completionTiming===null&&renderer.completionWindowStart===null&&renderer.queueMS===0);
      check(`${label}: stale completion still releases all ownership`,
        renderer.pendingFrames===0&&!renderer.queryBusy&&renderer.timingGeneration===generation);
    }
    if(timestamp) {
      const original=renderer.queryRead.mapAsync,entered=deferred(),done=deferred();
      renderer.queryRead.mapAsync=async function(){entered.resolve();await done.promise;await original.call(this);};
      const frame=renderer.render(0,{wait:true,measure:true});await entered.promise;
      renderer.resetTiming();const generation=renderer.timingGeneration;
      check('Reset preserves ownership while an old timestamp mapping is pending',renderer.queryBusy&&renderer.pendingFrames===0);
      done.resolve();await frame;renderer.queryRead.mapAsync=original;
      check('A timestamp mapped after reset cannot publish stale timings',
        renderer.gpuTiming===null&&renderer.gpuMS===0&&renderer.emissionMS===0&&renderer.presentationMS===0&&renderer.timingGeneration===generation);
      check('A stale timestamp map still unmaps and releases its query',renderer.queryRead.mapState==='unmapped'&&!renderer.queryBusy);
      const changes=[
        ['glare activation',()=>{renderer.settings.glowStrength=.5;}],
        ['diagnostic response',()=>{renderer.settings.diagnosticMode=true;}],
        ['scientific response',()=>{renderer.settings.appearance='scientific';}],
        ['material branch',()=>{renderer.settings.materialStrength=0;}],
        ['temperature fluctuations',()=>{renderer.settings.fluctuations=.2;}],
        ['material quality',()=>{renderer.settings.quality='auto';}],
        ['energy cadence',()=>{renderer.settings.energy=true;}],
        ['source rotation state',()=>{renderer.settings.rotation=false;}],
        ['presentation width',()=>{host.canvas.width++;}],
        ['presentation height',()=>{host.canvas.height++;}],
      ];
      for(const [name,change] of changes) {
        await renderer.render(0,{wait:true,measure:true});
        assert.ok(renderer.gpuTiming);
        const generation=renderer.timingGeneration;change();
        const frame=renderer.render(0,{wait:true});
        check(`${name} invalidates the old workload sample before completion`,
          renderer.timingGeneration===generation+1&&renderer.gpuTiming===null&&renderer.completionTiming===null&&renderer.completionWindowStart===null);
        await frame;
      }
    } else {
      // Deterministic completion cadence, deliberately without GPU timestamps.
      // An initial completion anchors the window; only later intervals count.
      let now=0;install('performance',{now:()=>now});renderer.resetTiming();
      for(let i=0;i<8;i++){now=i*20;await renderer.render(0,{wait:true});}
      check('Completion window waits for eight intervals even after 100 ms',renderer.completionTiming===null&&renderer.completionWindowCount===7);
      now=160;await renderer.render(0,{wait:true});
      check('Completion window publishes interval average with generation and time',
        renderer.completionTiming.ms===20&&renderer.completionTiming.samples===8&&renderer.completionTiming.at===160&&renderer.completionTiming.generation===renderer.timingGeneration);
      renderer.resetTiming();
      for(let i=0;i<=8;i++){now=200+i*5;await renderer.render(0,{wait:true});}
      check('Completion window also waits for 100 ms when eight intervals are too short',renderer.completionTiming===null&&renderer.completionWindowCount===8);
      for(let i=9;i<=20;i++){now=200+i*5;await renderer.render(0,{wait:true});}
      check('A longer fast-completion window averages every completed interval',renderer.completionTiming.ms===5&&renderer.completionTiming.samples===20&&renderer.completionTiming.at===300);
      Object.defineProperty(globalThis,'performance',originals.get('performance'));
    }
    renderer.camera.destroy();for(const buffer of host.buffers)buffer.destroy();for(const texture of host.textures)texture.destroy();
  }
  console.log(`${passed}/${passed} renderer capability host checks passed with real CPU WASM; no GPU execution was performed.`);
} finally {
  for(const [name,descriptor] of originals) {
    if(descriptor)Object.defineProperty(globalThis,name,descriptor);else delete globalThis[name];
  }
}
