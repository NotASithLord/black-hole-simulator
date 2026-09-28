import assert from 'node:assert/strict';
import {KerrRenderer} from '../src/renderer.js';

// Pure host scheduling test: no browser, GPU API, or shader execution.
// Simulate a camera update while the last strip is still in flight.
for (const shouldCancel of [false,true]) {
  let waits=0,cancelled=false;
  const renderer=new KerrRenderer({});
  Object.assign(renderer,{width:8,height:8,samples:1,bindings:{},tracePipeline:{}});
  renderer.uniforms=()=>new ArrayBuffer(176);
  renderer.device={
    limits:{maxStorageBufferBindingSize:1024*1024},
    queue:{writeBuffer(){},submit(){},async onSubmittedWorkDone(){if(++waits===2) cancelled=shouldCancel;}},
    createCommandEncoder(){return {
      beginComputePass(){return {setPipeline(){},setBindGroup(){},dispatchWorkgroups(){},end(){}};},
      finish(){return {};},
    };},
  };
  const complete=await renderer.rebuild(8,8,1,()=>{},()=>cancelled);
  assert.equal(complete,!shouldCancel);
  assert.equal(renderer.traceCount,shouldCancel?0:1);
  console.log(`PASS ${shouldCancel?'Last-strip invalidation rejects stale geometry':'Unchanged camera publishes completed geometry'}`);
}

// A moving camera must not alter uniforms halfway through an in-flight map.
{
  const renderer=new KerrRenderer({}),writes=[];let waits=0,uniformCalls=0;
  Object.assign(renderer,{width:8,height:32,samples:1,bindings:{},tracePipeline:{}});
  renderer.settings.cameraYaw=.75;
  renderer.uniforms=()=>{uniformCalls++;const bytes=new ArrayBuffer(176);new DataView(bytes).setFloat32(20,renderer.settings.cameraYaw,true);return bytes;};
  renderer.device={limits:{maxStorageBufferBindingSize:1024*1024},queue:{
    writeBuffer(_buffer,_offset,bytes){writes.push(new DataView(bytes.slice(0)).getFloat32(20,true));},submit(){},
    async onSubmittedWorkDone(){if(++waits>1)renderer.settings.cameraYaw+=.1;},
  },createCommandEncoder(){return{beginComputePass(){return{setPipeline(){},setBindGroup(){},dispatchWorkgroups(){},end(){}};},finish(){return{};}};}};
  assert.equal(await renderer.rebuild(8,32),true);
  assert.equal(uniformCalls,1);assert.ok(writes.length>1);assert.ok(writes.every(yaw=>yaw===.75));
  console.log('PASS Every trace strip retains the same camera snapshot during input');
}

// Deferred fake GPU completions distinguish submission from actual completion.
function queuedRenderer() {
  const renderer=new KerrRenderer({}),releases=[];
  renderer.uniforms=()=>new ArrayBuffer(176);
  renderer.context={getCurrentTexture(){return{createView(){return{};}};}};
  renderer.camera={encode(){}};
  renderer.device={queue:{writeBuffer(){},submit(){},onSubmittedWorkDone(){return new Promise(resolve=>releases.push(resolve));}},
    createCommandEncoder(){return{beginComputePass(){return{setPipeline(){},setBindGroup(){},dispatchWorkgroups(){},end(){}};},finish(){return{};}};}};
  return{renderer,releases};
}
{
  const{renderer,releases}=queuedRenderer();
  assert.ok(Number.isFinite(await renderer.render(0,{wait:false})));
  assert.ok(Number.isFinite(await renderer.render(1,{wait:false})));
  assert.equal(renderer.pendingFrames,2);
  assert.equal(await renderer.render(2,{wait:false}),null);
  assert.equal(renderer.frame,2);assert.equal(releases.length,2);
  releases.shift()();await Promise.resolve();await Promise.resolve();
  assert.equal(renderer.pendingFrames,1);
  assert.ok(Number.isFinite(await renderer.render(3,{wait:false})));
  for(const release of releases)release();await Promise.resolve();await Promise.resolve();
  assert.equal(renderer.pendingFrames,0);assert.equal(renderer.timingSerial,3);
  console.log('PASS Interactive submission never waits per frame and caps backlog at two frames');
}
{
  const{renderer,releases}=queuedRenderer();let settled=false;
  const result=renderer.render(0).then(time=>{settled=true;return time;});
  await Promise.resolve();assert.equal(settled,false);
  releases.shift()();assert.ok(Number.isFinite(await result));assert.equal(renderer.pendingFrames,0);
  console.log('PASS Verification rendering still waits for actual completion');
}
{
  const renderer=new KerrRenderer({});let models=0,uploads=0;
  renderer.core={init_model(){models++;return 0;},memory:{buffer:new ArrayBuffer(128)},metadata_ptr(){return 0;},radial_ptr(){return 88;},radial_count(){return 1;}};
  renderer.device={queue:{writeBuffer(){uploads++;}}};
  assert.equal(renderer.updateModel(),true);assert.equal(renderer.updateModel(),false);
  renderer.settings.cameraYaw+=.2;assert.equal(renderer.updateModel(),false);
  renderer.settings.spin=.9;assert.equal(renderer.updateModel(),true);
  assert.equal(models,2);assert.equal(uploads,2);
  console.log('PASS Camera-only changes do not rebuild or upload physical tables');
}
{
  const renderer=new KerrRenderer({});renderer.meta=new Float64Array(11);
  let data=new DataView(renderer.uniforms());
  assert.equal(renderer.settings.quality,'interactive');assert.equal(renderer.settings.thickness,0);
  assert.equal(renderer.settings.glowStrength,0);assert.equal(renderer.settings.fluctuations,0);assert.equal(renderer.settings.playback,4000);
  assert.equal(data.getUint32(148,true),0);assert.equal(data.getUint32(172,true),1);
  renderer.settings.quality='auto';data=new DataView(renderer.uniforms());
  assert.equal(data.getUint32(148,true),1);
  console.log('PASS Motion-first defaults select lightweight source and one material sample');
}
{
  const renderer=new KerrRenderer({});renderer.meta=new Float64Array(11);
  const scratch=renderer.uniforms(100,8,{160:12,164:8}),snapshot=scratch.slice(0);
  const next=renderer.uniforms(200);
  assert.equal(scratch,next,'Uniform packing reuses one buffer');
  assert.equal(new DataView(snapshot).getFloat32(8,true),100);
  assert.equal(new DataView(next).getFloat32(8,true),200);
  assert.equal(new DataView(next).getUint32(160,true),0);
  assert.equal(new DataView(next).getUint32(164,true),0);
  assert.equal(new DataView(next).getFloat32(108,true),0);
  console.log('PASS Reused uniform bytes clear temporary overrides and preserve explicit snapshots');
}
{
  const renderer=new KerrRenderer({}),rows=[];
  Object.assign(renderer,{width:64,height:128,samples:1,bindings:{},tracePipeline:{},raysPerMS:1024});
  renderer.uniforms=()=>new ArrayBuffer(176);
  renderer.device={limits:{maxStorageBufferBindingSize:1024*1024},queue:{writeBuffer(){},submit(){},async onSubmittedWorkDone(){}},
    createCommandEncoder(){return{beginComputePass(){return{setPipeline(){},setBindGroup(){},dispatchWorkgroups(_x,y){rows.push(y*8);},end(){}};},finish(){return{};}};}};
  assert.equal(await renderer.rebuild(64,128),true);
  assert.deepEqual(rows,[64,64]);
  console.log('PASS Completed trace throughput seeds bounded chunks without redundant tiny warmup strips');
}

// Exercise the scheduler through actual rebuild(): row uploads must precede
// their individual submissions, share one camera snapshot, and retire safely.
for(const cancelDuringTrace of [false,true]) {
  const renderer=new KerrRenderer({}),submissions=[];let lastUpload,waits=0,cancelled=false,settled=false,active=0,peak=0;
  Object.assign(renderer,{width:8,height:40,samples:1,bindings:{},tracePipeline:{}});
  renderer.settings.cameraYaw=.75;
  renderer.uniforms=()=>{const bytes=new ArrayBuffer(176);new DataView(bytes).setFloat32(20,renderer.settings.cameraYaw,true);return bytes;};
  renderer.device={limits:{maxStorageBufferBindingSize:1024*1024},queue:{
    writeBuffer(_buffer,_offset,bytes){lastUpload=bytes.slice(0);},
    submit([command]){
      active++;peak=Math.max(peak,active);
      const view=new DataView(lastUpload);
      submissions.push({row:view.getFloat32(108,true),yaw:view.getFloat32(20,true),rows:command.rows});
    },
    onSubmittedWorkDone(){
      if(++waits===1)return Promise.resolve();
      return new Promise(resolve=>{submissions.at(-1).finish=()=>{active--;resolve();};});
    },
  },createCommandEncoder(){let rows;return{beginComputePass(){return{
    setPipeline(){},setBindGroup(){},dispatchWorkgroups(_x,y){rows=y*8;},end(){},
  };},finish(){return{rows};}};}};
  const flush=async()=>{for(let i=0;i<8;i++)await Promise.resolve();};
  const task=renderer.rebuild(8,40,1,()=>{},()=>cancelled).then(value=>{settled=true;return value;});
  await flush();assert.equal(submissions.length,2);assert.equal(peak,2);
  renderer.settings.cameraYaw=1.25;cancelled=cancelDuringTrace;
  submissions[0].finish();await flush();assert.equal(settled,false);
  if(cancelDuringTrace) {
    assert.equal(submissions.length,2);submissions[1].finish();
    assert.equal(await task,false);assert.equal(renderer.traceCount,0);assert.equal(active,0);
    console.log('PASS Pipelined renderer hard cancellation drains its successor before returning');
  } else {
    let index=1;
    while(!settled){submissions[index++].finish();await flush();}
    assert.equal(await task,true);assert.equal(renderer.traceCount,1);assert.equal(active,0);
    let next=0;
    for(const chunk of submissions){assert.equal(chunk.row,next);assert.equal(chunk.yaw,.75);next+=chunk.rows;}
    assert.equal(next,40);assert.equal(peak,2);
    console.log('PASS Pipelined renderer uploads complete nonoverlapping rows from one immutable camera pose');
  }
}
