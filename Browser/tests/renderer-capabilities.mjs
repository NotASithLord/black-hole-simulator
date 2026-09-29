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
const flush=async()=>{for(let index=0;index<16;index++)await Promise.resolve();};

function makeHost(timestamp,format,limitOverrides={}) {
  const events=[],buffers=[],textures=[],computePipelines=[],renderPipelines=[],passes=[];
  let request,queryCount=0,resolveCount=0,timestampScale=1,timestampValues=null;
  let clock=0,timestampOrigin=1_000_000_000n;
  install('performance',{now:()=>clock});
  const limits={maxStorageBufferBindingSize:128*MiB,maxBufferSize:256*MiB,maxTextureDimension2D:8192,
    maxComputeWorkgroupsPerDimension:65535,maxStorageBuffersPerShaderStage:8,maxStorageTexturesPerShaderStage:4,...limitOverrides};
  const device={
    limits:{...limits},lost:new Promise(()=>{}),addEventListener(){},
    queue:{
      writeBuffer(buffer,offset,data){
        const bytes=data instanceof ArrayBuffer?new Uint8Array(data):new Uint8Array(data.buffer,data.byteOffset,data.byteLength);
        new Uint8Array(buffer.bytes).set(bytes,offset);
      },
      submit(commands){
        timestampOrigin+=1_000_000_000n;
        for(const command of commands)for(const execute of command)execute();
        // Deterministic host wall span must contain the simulated GPU span.
        // Advancing the epoch makes each real query fresh, not repeated bytes.
        clock+=Math.max(1,3*timestampScale)+1;
      },
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
          commands.push(()=>{
            querySet.values[begin]=timestampValues?.[begin]??timestampOrigin+BigInt((begin+1)*timestampScale)*1_000_000n;
            querySet.values[end]=timestampValues?.[end]??timestampOrigin+BigInt((end+1)*timestampScale)*1_000_000n;
          });
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
    get now(){return clock;},advance(ms){clock+=ms;},
    set timestampValues(value){timestampValues=value;},
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
    const host=makeHost(timestamp,'bgra8unorm'),renderer=new KerrRenderer(host.canvas);
    const promptCompletion=host.device.queue.onSubmittedWorkDone;
    host.device.queue.onSubmittedWorkDone=async()=>{await promptCompletion();host.advance(100);};
    await renderer.init();
    check(`Coarse completion delivery (${timestamp?'with':'without'} timestamps) selects bounded eight-frame scheduling from measurements`,
      renderer.completionDelivery.latenciesMS.every(value=>value===104)&&
      renderer.completionDelivery.medianMS===104&&renderer.completionDelivery.coarseCompletion&&
      renderer.frameWindow.maxPending===8&&typeof renderer.tracePace==='function');
    check(`Coarse completion probe (${timestamp?'with':'without'} timestamps) releases both small diagnostic buffers`,
      host.buffers.filter(buffer=>buffer.label?.startsWith('Completion delivery probe')).length===2&&
      host.buffers.filter(buffer=>buffer.label?.startsWith('Completion delivery probe')).every(buffer=>buffer.size===4&&buffer.destroyed));
    // Inject a deterministic pacer to verify the selected trace path is actually
    // used, without making this fake-host test wait on real wall-clock timers.
    let paces=0;renderer.tracePace=async()=>{paces++;};
    await renderer.rebuild(16,40,1);
    check(`Coarse completion (${timestamp?'with':'without'} timestamps) actually uses paced trace submissions`,
      paces>0&&renderer.traceCount===1&&renderer.raysPerMS>0);
    const done=deferred();host.device.queue.onSubmittedWorkDone=()=>done.promise;
    for(let frame=0;frame<8;frame++)assert.notEqual(await renderer.render(0,{wait:false}),null);
    const ninth=await renderer.render(0,{wait:false});
    check(`Coarse completion (${timestamp?'with':'without'} timestamps) admits eight real frames but never a ninth pending frame`,
      renderer.pendingFrames===8&&renderer.frameWindow.pending===8&&ninth===null);
    done.resolve();await flush();
    check(`Coarse completion (${timestamp?'with':'without'} timestamps) releases the entire window only after real completions`,
      renderer.pendingFrames===0&&renderer.frameWindow.pending===0&&renderer.frameCompletions.size===0&&!renderer.queryBusy);
    renderer.camera.destroy();for(const buffer of host.buffers)buffer.destroy();
  }
  for(const timestamp of [false,true]) {
    const label=timestamp?'optional timestamps':'no timestamp feature';
    const host=makeHost(timestamp,timestamp?'bgra8unorm':'rgba8unorm');
    const renderer=new KerrRenderer(host.canvas);
    await renderer.init();
    check(`${label}: initializes on 128 MiB storage / 8192 texture limits`,
      host.request.requiredLimits.maxStorageBufferBindingSize===128*MiB&&host.request.requiredLimits.maxBufferSize===128*MiB);
    check(`${label}: prompt completion delivery retains two-frame scheduling`,
      renderer.completionDelivery.latenciesMS.length===3&&!renderer.completionDelivery.coarseCompletion&&
      renderer.tracePace===null&&renderer.frameWindow.maxPending===2);
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
      // Optional instrumentation failures do not abort otherwise successful GPU
      // rendering. Fault injection exercises host ownership, not real drivers.
      const reportedErrors=[];renderer.onError=error=>reportedErrors.push(error);
      const faults=[
        ['mapAsync rejects',renderer.queryRead,'mapAsync'],
        ['getMappedRange throws after mapping',renderer.queryRead,'getMappedRange'],
      ];
      for(const [name,object,method] of faults) {
        await renderer.render(0,{wait:true,measure:true});
        assert.ok(renderer.gpuTiming);
        const original=object[method];
        const failure=Error(`Injected failure: ${name}`);
        object[method]=()=>{throw failure;};
        if(method==='mapAsync')object[method]=async()=>{throw failure;};
        try {await renderer.render(0,{wait:true,measure:true});}
        finally {object[method]=original;}
        check(`${name}: frame and query ownership retire`,renderer.pendingFrames===0&&renderer.queryBusy===false);
        check(`${name}: readback buffer is not left mapped`,renderer.queryRead.mapState==='unmapped');
        check(`${name}: only optional timing is discarded, without onError`,
          renderer.gpuTiming===null&&renderer.gpuMS===0&&renderer.emissionMS===0&&renderer.presentationMS===0&&reportedErrors.length===0);
        await renderer.render(0,{wait:true,measure:true});
        check(`${name}: a following measured frame succeeds`,renderer.pendingFrames===0&&!renderer.queryBusy&&renderer.gpuMS===3);
      }
      {
        const original=renderer.queryRead.mapAsync;
        renderer.queryRead.mapAsync=async()=>{throw Error('Optional nonblocking readback failure');};
        await renderer.render(0,{wait:false,measure:true});await flush();renderer.queryRead.mapAsync=original;
        check('Nonblocking optional readback failure does not invoke the rendering error handler',
          reportedErrors.length===0&&renderer.gpuTiming===null&&renderer.pendingFrames===0&&!renderer.queryBusy&&renderer.queryRead.mapState==='unmapped');
        await renderer.render(0,{wait:true,measure:true});
      }
      {
        const original=renderer.camera.encode,failure=Error('Injected fatal camera encoding failure');
        const frame=renderer.frame;
        renderer.camera.encode=()=>{throw failure;};
        try {await assert.rejects(renderer.render(0,{wait:true,measure:true}),error=>error===failure);}
        finally {renderer.camera.encode=original;}
        check('A genuine camera encoding failure is not swallowed as optional timing',
          renderer.frame===frame&&renderer.pendingFrames===0&&!renderer.queryBusy&&renderer.queryRead.mapState==='unmapped');
        await renderer.render(0,{wait:true,measure:true});
        check('Camera encoding failure leaves query ownership available for the next frame',renderer.gpuMS===3);
      }
      for(const [name,values,reason] of [
        ['end before start',[10_000_000n,1_000_000n,11_000_000n,12_000_000n],'unordered-counters'],
        ['cross-pass reversal',[1_000_000n,3_000_000n,2_000_000n,4_000_000n],'unordered-counters'],
        ['huge positive span',[1n,2n,3n,1_000_000_000_000_000n],'implausible-span'],
      ]) {
        host.timestampValues=values;await renderer.render(0,{wait:true,measure:true});
        check(`${name}: never publishes negative, stale or implausible GPU headroom`,
          renderer.gpuMS===0&&renderer.gpuTiming===null&&renderer.emissionMS===0&&renderer.presentationMS===0&&renderer.timingHealth.status.lastFailure===reason);
        host.timestampValues=null;await renderer.render(0,{wait:true,measure:true});
        check(`${name}: a transient counter failure recovers on the next valid frame`,renderer.gpuMS===3);
      }
      {
        host.timestampValues=[9_000_000n,10_000_000n,11_000_000n,12_000_000n];
        await renderer.render(0,{wait:true,measure:true});assert.equal(renderer.gpuMS,3);
        await renderer.render(0,{wait:true,measure:true});
        check('Repeated query bytes do not masquerade as a new workload measurement',
          renderer.gpuTiming===null&&renderer.timingHealth.status.lastFailure==='stale-counters');
        host.timestampValues=[0n,1_000_000n,2_000_000n,3_000_000n];
        await renderer.render(0,{wait:true,measure:true});
        check('A valid lower counter epoch is accepted after an implementation reset',renderer.gpuMS===3);
        host.timestampValues=null;
      }
      {
        host.timestampValues=[4n,3n,2n,1n];
        for(let index=0;index<3;index++)await renderer.render(0,{wait:true,measure:true});
        check('Persistent bad timestamp writes suspend instrumentation, not the renderer',
          renderer.timingHealth.status.suspended&&renderer.pendingFrames===0&&!renderer.queryBusy&&renderer.gpuTiming===null&&reportedErrors.length===0);
        const resolves=host.resolveCount,frames=renderer.frame;
        renderer.resetTiming();await renderer.render(0,{wait:true,measure:true});
        check('Timing reset cannot defeat query cooldown; frames still render without queries',
          host.resolveCount===resolves&&renderer.frame===frames+1&&renderer.timingHealth.status.suspended);
        host.advance(renderer.timingHealth.status.retryAt-host.now);
        await renderer.render(0,{wait:true,measure:true});
        check('A failed recovery probe backs off query overhead',
          host.resolveCount===resolves+1&&renderer.timingHealth.status.cooldownMS===10_000);
        host.timestampValues=null;host.advance(renderer.timingHealth.status.retryAt-host.now);
        await renderer.render(0,{wait:true,measure:true});
        check('A valid scheduled recovery probe restores normal GPU timing',
          !renderer.timingHealth.status.suspended&&renderer.gpuMS===3&&renderer.gpuTiming!==null&&reportedErrors.length===0);
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
        renderer.gpuTiming===null&&renderer.completionTiming===null&&renderer.completionCadence.startAt===null&&renderer.queueMS===0);
      check(`${label}: stale completion still releases all ownership`,
        renderer.pendingFrames===0&&!renderer.queryBusy&&renderer.timingGeneration===generation);
    }
    if(timestamp) {
      {
        const original=host.device.queue.onSubmittedWorkDone,done=deferred();
        host.device.queue.onSubmittedWorkDone=()=>done.promise;
        const frame=renderer.render(0,{wait:true,measure:true});await flush();
        const mapsBeforeCompletion=renderer.queryRead.mapState==='mapped'&&renderer.queryBusy&&renderer.pendingFrames===1;
        done.resolve();await frame;host.device.queue.onSubmittedWorkDone=original;
        check('Timestamp map is requested before the queue-completion callback is delivered',mapsBeforeCompletion);
        check('An early completed timestamp map remains owned until normal frame completion',
          renderer.queryRead.mapState==='unmapped'&&!renderer.queryBusy&&renderer.pendingFrames===0&&renderer.gpuMS===3);
      }
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
          renderer.timingGeneration===generation+1&&renderer.gpuTiming===null&&renderer.completionTiming===null&&renderer.completionCadence.startAt===null);
        await frame;
      }
      {
        const originalQueue=host.device.queue.onSubmittedWorkDone,originalMap=renderer.queryRead.mapAsync;
        const entered=deferred(),done=deferred(),failure=Error('Injected fatal queue completion failure');
        let settled=false;
        renderer.queryRead.mapAsync=async function(){entered.resolve();await done.promise;await originalMap.call(this);};
        host.device.queue.onSubmittedWorkDone=async()=>{throw failure;};
        const frame=renderer.render(0,{wait:true,measure:true}).then(
          ()=>assert.fail('A genuine queue completion error must still reject'),
          error=>{settled=true;assert.equal(error,failure);});
        await entered.promise;await flush();
        const heldUntilMapRetires=!settled&&renderer.queryBusy&&renderer.pendingFrames===0;
        done.resolve();await frame;await flush();
        renderer.queryRead.mapAsync=originalMap;host.device.queue.onSubmittedWorkDone=originalQueue;
        check('Fatal queue failure drains the already-requested timestamp mapping before releasing ownership',heldUntilMapRetires);
        check('Fatal queue failure unmaps its eventual readback and preserves the original error',
          settled&&renderer.queryRead.mapState==='unmapped'&&!renderer.queryBusy&&renderer.pendingFrames===0);
        await renderer.render(0,{wait:true,measure:true});
        check('After a synthetic queue failure no mapped timestamp buffer contaminates later submissions',renderer.gpuMS===3);
      }
    } else {
      // Deterministic completion cadence, deliberately without GPU timestamps.
      // An initial completion anchors the window; only later intervals count.
      let now=0;install('performance',{now:()=>now});renderer.resetTiming();
      for(let i=0;i<64;i++){now=i*20;await renderer.render(0,{wait:true});}
      check('Completion window waits for 64 intervals even after one second',renderer.completionTiming===null&&renderer.completionCadence.intervals===63);
      now=1280;await renderer.render(0,{wait:true});
      check('Completion window publishes interval average with generation and time',
        renderer.completionTiming.ms===20&&renderer.completionTiming.samples===64&&renderer.completionTiming.at===1280&&renderer.completionTiming.generation===renderer.timingGeneration);
      renderer.resetTiming();
      for(let i=0;i<=64;i++){now=2000+i*5;await renderer.render(0,{wait:true});}
      check('Completion window also waits for one second when 64 intervals are too short',renderer.completionTiming===null&&renderer.completionCadence.intervals===64);
      for(let i=65;i<=200;i++){now=2000+i*5;await renderer.render(0,{wait:true});}
      check('A longer fast-completion window averages every completed interval',renderer.completionTiming.ms===5&&renderer.completionTiming.samples===200&&renderer.completionTiming.at===3000);
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
