import assert from 'node:assert/strict';
import {CameraResponse} from '../src/camera.js';

// Host allocation and command scheduling only. These mocks neither compile
// WGSL nor execute GPU work; browser validation remains a separate check.
const originalFetch=globalThis.fetch;
const originalBufferUsage=globalThis.GPUBufferUsage;
const originalTextureUsage=globalThis.GPUTextureUsage;
globalThis.GPUBufferUsage={UNIFORM:1,COPY_DST:2};
globalThis.GPUTextureUsage={TEXTURE_BINDING:1,STORAGE_BINDING:2};
globalThis.fetch=async()=>({ok:true,text:async()=>''});

let passed=0;
const check=(name,test)=>{test();passed++;console.log(`PASS ${name}`);};
function texture(width,height,label='HDR source') {
  return {width,height,label,destroyed:false,views:0,
    createView(){assert.ok(!this.destroyed);this.views++;return {texture:this};},
    destroy(){this.destroyed=true;},
  };
}
const textures=[],groups=[],buffers=[],writes=[];
const device={
  queue:{writeBuffer(buffer,offset,data){writes.push(Array.from(data));}},
  createShaderModule(){return {async getCompilationInfo(){return {messages:[]};}};},
  async createComputePipelineAsync(){return {getBindGroupLayout(){return {bindings:[0,1,6]};}};},
  async createRenderPipelineAsync(){return {getBindGroupLayout(){return {bindings:[0,1,2,3,4,5]};}};},
  createSampler(){return {sampler:true};},
  createBuffer(descriptor){const buffer={...descriptor,destroyed:false,destroy(){this.destroyed=true;}};buffers.push(buffer);return buffer;},
  createTexture(descriptor){const t=texture(descriptor.size[0],descriptor.size[1],descriptor.label);textures.push(t);return t;},
  createBindGroup(descriptor){
    assert.deepEqual(descriptor.entries.map(entry=>entry.binding),descriptor.layout.bindings);
    for(const entry of descriptor.entries) assert.ok(!entry.resource.texture?.destroyed);
    groups.push(descriptor);return descriptor;
  },
};
function frame(camera,source,settings={},timestampWrites) {
  const calls={compute:[],render:[]};
  const encoder={
    beginComputePass(){
      const call={dispatches:[],pipelineSets:0};calls.compute.push(call);
      return {setPipeline(pipeline){call.pipeline=pipeline;call.pipelineSets++;},setBindGroup(index,group){call.group=group;},
        dispatchWorkgroups(...size){call.dispatches.push({size,group:call.group});},end(){}};
    },
    beginRenderPass(descriptor){
      const call={descriptor};calls.render.push(call);
      return {setPipeline(pipeline){call.pipeline=pipeline;},setBindGroup(index,group){call.group=group;},
        draw(count){call.vertices=count;},end(){}};
    },
  };
  camera.encode(encoder,source,{},settings,timestampWrites);
  for(const call of [...calls.compute.flatMap(pass=>pass.dispatches),...calls.render]) {
    for(const entry of call.group.entries) assert.ok(!entry.resource.texture?.destroyed,'Encoded bindings must not reference destroyed textures');
  }
  return calls;
}
const bound=(call,binding)=>call.group.entries.find(entry=>entry.binding===binding).resource;

try {
  const camera=new CameraResponse(device,'bgra8unorm');
  await camera.init();
  const source=texture(1024,672);
  camera.resize(source.width,source.height);
  check('Init and resize allocate only one 1×1 inactive texture',()=>{
    assert.equal(textures.length,1);
    assert.deepEqual([textures[0].width,textures[0].height],[1,1]);
    assert.equal(camera.levels.length,0);
  });
  const direct=frame(camera,source);
  check('Default no-glow frame has one presentation and zero pyramid dispatches',()=>{
    assert.equal(direct.compute.length,0);assert.equal(direct.render.length,1);
    assert.equal(direct.render[0].vertices,3);assert.equal(textures.length,1);
    for(const binding of [2,3,4]) assert.equal(bound(direct.render[0],binding).texture,textures[0]);
  });
  const groupCount=groups.length,viewCount=source.views;
  frame(camera,source,{glowStrength:0,exposureEV:1});
  check('Stable direct frames reuse texture views and bind groups',()=>{
    assert.equal(groups.length,groupCount);assert.equal(source.views,viewCount);assert.equal(textures.length,1);
    assert.ok(Math.abs(writes.at(-1)[0]-.06)<1e-8);assert.equal(writes.at(-1)[4],1);
  });
  const scientific=frame(camera,source,{appearance:'scientific',glowStrength:.6});
  const scientificWrites=writes.length;
  frame(camera,source,{appearance:'scientific',glowStrength:.1});
  check('Scientific mode does not upload an ignored glow setting',()=>assert.equal(writes.length,scientificWrites));
  const diagnostic=frame(camera,source,{diagnosticMode:true,glowStrength:.6});
  check('Scientific and diagnostic modes bypass glare even at a positive slider value',()=>{
    assert.equal(scientific.compute.length,0);assert.equal(diagnostic.compute.length,0);
    assert.equal(textures.length,1);assert.equal(writes.at(-1)[2],0);assert.equal(writes.at(-1)[3],1);
  });
  const enabled=frame(camera,source,{glowStrength:.28});
  check('First enabled Radiant frame allocates and dispatches exactly seven levels',()=>{
    assert.equal(textures.length,8);assert.equal(enabled.compute.length,1);
    assert.equal(enabled.compute[0].dispatches.length,7);assert.equal(enabled.compute[0].pipelineSets,1);
    assert.deepEqual(camera.levels.map(t=>[t.width,t.height]),[[512,336],[256,168],[128,84],[64,42],[32,21],[16,10],[8,5]]);
    assert.deepEqual(enabled.compute[0].dispatches[0].size,[64,42]);
    assert.deepEqual(enabled.compute[0].dispatches[6].size,[1,1]);
    for(const [binding,index] of [[2,2],[3,4],[4,6]]) assert.equal(bound(enabled.render[0],binding).texture,camera.levels[index]);
  });
  check('Each pyramid dispatch reads only the completed preceding level',()=>{
    for(const [index,dispatch] of enabled.compute[0].dispatches.entries()) {
      const input=bound(dispatch,1).texture,output=bound(dispatch,6).texture;
      assert.equal(input,index===0?source:camera.levels[index-1]);
      assert.equal(output,camera.levels[index]);assert.notEqual(input,output);
    }
  });
  const warmGroups=groups.length,warmWrites=writes.length;
  const stillEnabled=frame(camera,source,{glowStrength:.28});
  check('Enabled steady frames reuse the pyramid and all bind groups',()=>{
    assert.equal(textures.length,8);assert.equal(groups.length,warmGroups);assert.equal(stillEnabled.compute.length,1);
    assert.equal(stillEnabled.compute[0].dispatches.length,7);
  });
  check('Unchanged settings require no repeated uniform upload',()=>assert.equal(writes.length,warmWrites));
  const disabled=frame(camera,source,{glowStrength:0});
  check('Disabling glow switches back to tiny bindings with no compute work',()=>{
    assert.equal(disabled.compute.length,0);assert.equal(groups.length,warmGroups);
    for(const binding of [2,3,4]) assert.equal(bound(disabled.render[0],binding).texture,textures[0]);
  });
  frame(camera,source,{glowStrength:.28});
  check('Repeated glow toggles do not reallocate warmed resources',()=>{
    assert.equal(textures.length,8);assert.equal(groups.length,warmGroups);
  });
  const secondSource=texture(1024,672);
  const beforeSecondSource=groups.length;
  frame(camera,secondSource,{glowStrength:0});
  const secondGlare=frame(camera,secondSource,{glowStrength:.28});
  check('Alternate HDR sources share the six source-independent pyramid groups',()=>{
    assert.equal(groups.length-beforeSecondSource,3);
    for(let index=1;index<7;index++)assert.equal(secondGlare.compute[0].dispatches[index].group,enabled.compute[0].dispatches[index].group);
  });
  const pingPongGroups=groups.length;
  frame(camera,source,{glowStrength:0});frame(camera,secondSource,{glowStrength:0});
  frame(camera,source,{glowStrength:.28});frame(camera,secondSource,{glowStrength:.28});
  check('Ping-pong HDR textures cache both direct and glare bindings',()=>{
    assert.equal(groups.length,pingPongGroups);assert.equal(textures.length,8);
    assert.equal(source.views,1);assert.equal(secondSource.views,1);
  });
  const oldLevels=[...camera.levels],large=texture(1920,1080);
  const resized=frame(camera,large,{glowStrength:0});
  check('Resizing while glow is off retires old levels without reallocating a pyramid',()=>{
    assert.equal(resized.compute.length,0);assert.equal(textures.length,8);
    assert.equal(camera.levels.length,0);assert.ok(oldLevels.every(t=>t.destroyed));
    for(const binding of [2,3,4]) assert.equal(bound(resized.render[0],binding).texture,textures[0]);
  });
  frame(camera,large,{glowStrength:.28});
  check('Enabling glow after resize uses only the new dimensions and live bindings',()=>{
    assert.equal(textures.length,15);assert.equal(camera.levels.length,7);
    assert.deepEqual([camera.levels[0].width,camera.levels[0].height],[960,540]);
    assert.ok(camera.levels.every(t=>!t.destroyed));
  });
  const beforeSameSize=textures.length;
  camera.resize(1920,1080);frame(camera,large,{glowStrength:.28});
  check('Same-size resize is a no-op for warmed glare resources',()=>assert.equal(textures.length,beforeSameSize));
  const timestampWrites={querySet:{},beginningOfPassWriteIndex:2,endOfPassWriteIndex:3};
  const timed=frame(camera,large,{glowStrength:.28},timestampWrites);
  const untimed=frame(camera,large,{glowStrength:.28});
  check('Optional timestamps attach to presentation and do not leak into later frames',()=>{
    assert.equal(timed.render[0].descriptor.timestampWrites,timestampWrites);
    assert.equal(untimed.render[0].descriptor.timestampWrites,undefined);
  });
  const beforeTiny=textures.length;
  const tiny=texture(8,8),tinyFrame=frame(camera,tiny,{glowStrength:.28});
  check('Repeated 1×1 pyramid levels alias one texture and omit redundant dispatches',()=>{
    assert.equal(textures.length-beforeTiny,3);assert.equal(camera.levels.length,3);
    assert.equal(tinyFrame.compute[0].dispatches.length,3);
    assert.deepEqual(camera.levels.map(t=>[t.width,t.height]),[[4,4],[2,2],[1,1]]);
    for(const binding of [2,3,4])assert.equal(bound(tinyFrame.render[0],binding).texture,camera.levels[2]);
  });
  const beforeNarrow=textures.length;
  const narrow=texture(128,1),narrowFrame=frame(camera,narrow,{glowStrength:.28});
  check('A 1-pixel short axis keeps filtering until the long axis also reaches one',()=>{
    assert.equal(textures.length-beforeNarrow,7);assert.equal(narrowFrame.compute[0].dispatches.length,7);
    assert.equal(camera.levels[0].width,64);assert.equal(camera.levels.at(-1).width,1);
  });
  camera.destroy();
  check('Destroy releases all camera-owned textures and buffers, preserving HDR inputs',()=>{
    assert.ok(textures.every(t=>t.destroyed));assert.ok(buffers.every(b=>b.destroyed));
    assert.ok(!source.destroyed&&!secondSource.destroyed&&!large.destroyed);
  });
  const previousUploads=writes.length;
  await camera.init();frame(camera,narrow,{glowStrength:.28});
  check('Reinitializing forces a fresh upload for the new uniform buffer',()=>assert.equal(writes.length,previousUploads+1));
  camera.destroy();
  console.log(`${passed}/${passed} camera host allocation/scheduling checks passed; no GPU execution was performed.`);
} finally {
  globalThis.fetch=originalFetch;
  if(originalBufferUsage===undefined) delete globalThis.GPUBufferUsage;else globalThis.GPUBufferUsage=originalBufferUsage;
  if(originalTextureUsage===undefined) delete globalThis.GPUTextureUsage;else globalThis.GPUTextureUsage=originalTextureUsage;
}
