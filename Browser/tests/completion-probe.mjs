import assert from 'node:assert/strict';
import {measureCompletionDelivery} from '../src/completion-probe.js';

globalThis.GPUBufferUsage={COPY_SRC:4,COPY_DST:8};
let passed=0;
async function check(name,run) {await run();passed++;console.log(`PASS ${name}`);}
function host({durations=[1,2,3],failure=null,failureAt=-1,createFailureAt=-1,submitFailureAt=-1}={}) {
  let clock=0,completionCalls=0,submitCalls=0;
  const buffers=[],commands=[],writes=[];
  const device={
    createBuffer(descriptor) {
      if(buffers.length===createFailureAt) throw failure;
      const buffer={...descriptor,destroyed:false,value:0,destroy(){this.destroyed=true;}};
      buffers.push(buffer);return buffer;
    },
    createCommandEncoder() {
      const copies=[];
      return {copyBufferToBuffer(source,sourceOffset,destination,destinationOffset,size) {
        copies.push({source,sourceOffset,destination,destinationOffset,size});
      },finish(){return {copies};}};
    },
    queue:{
      writeBuffer(buffer,offset,values) {writes.push({buffer,offset,values:[...values]});buffer.value=values[0];},
      submit(list) {
        if(submitCalls++===submitFailureAt) throw failure;
        commands.push(...list);
        for(const command of list) for(const copy of command.copies) copy.destination.value=copy.source.value;
      },
      async onSubmittedWorkDone() {
        const index=completionCalls++;
        if(index===failureAt) throw failure;
        clock+=durations[index%durations.length];
      },
    },
  };
  return {device,buffers,commands,writes,now:()=>clock,
    get completionCalls(){return completionCalls;},get submitCalls(){return submitCalls;}};
}

await check('Prompt completion delivery retains the low-backlog policy',async()=>{
  const h=host(),result=await measureCompletionDelivery(h.device,{now:h.now});
  assert.deepEqual(result,{latenciesMS:[1,2,3],medianMS:2,minMS:1,maxMS:3,coarseCompletion:false});
  assert.equal(h.completionCalls,3);
});
await check('Coarse completion delivery is detected without a browser identity',async()=>{
  const h=host({durations:[103,100,106]}),result=await measureCompletionDelivery(h.device,{now:h.now});
  assert.equal(result.medianMS,103);assert.equal(result.coarseCompletion,true);
  assert.deepEqual(result.latenciesMS,[103,100,106]);
});
await check('Every sample submits one initialized, nonempty four-byte GPU copy',async()=>{
  const h=host();await measureCompletionDelivery(h.device,{now:h.now});
  assert.equal(h.writes.length,1);assert.notEqual(h.writes[0].values[0],0);
  assert.equal(h.commands.length,3);assert.ok(h.buffers.every(buffer=>buffer.size===4));
  for(const command of h.commands) {
    assert.equal(command.copies.length,1);
    const copy=command.copies[0];assert.equal(copy.size,4);
    assert.equal(copy.sourceOffset,0);assert.equal(copy.destinationOffset,0);
    assert.equal(copy.destination.value,copy.source.value);
    assert.notEqual(copy.source,copy.destination);
  }
  assert.ok(h.buffers.every(buffer=>buffer.destroyed));
});
await check('Median resists one isolated long startup sample',async()=>{
  const h=host({durations:[120,2,3]}),result=await measureCompletionDelivery(h.device,{now:h.now});
  assert.equal(result.coarseCompletion,false);assert.equal(result.medianMS,3);assert.equal(result.maxMS,120);
});
await check('Even sample count uses the central pair and preserves raw observations',async()=>{
  const h=host({durations:[90,10,30,50]}),result=await measureCompletionDelivery(h.device,{now:h.now,samples:4});
  assert.equal(result.medianMS,40);assert.equal(result.coarseCompletion,true);
  assert.deepEqual(result.latenciesMS,[90,10,30,50]);
});
await check('Zero host latency is valid and does not fabricate a positive overhead',async()=>{
  const h=host({durations:[0,0,0]}),result=await measureCompletionDelivery(h.device,{now:h.now});
  assert.equal(result.medianMS,0);assert.equal(result.coarseCompletion,false);
});
await check('Rejected GPU completion propagates and destroys both buffers',async()=>{
  const failure=Error('Synthetic device failure'),h=host({failure,failureAt:1});
  await assert.rejects(measureCompletionDelivery(h.device,{now:h.now}),error=>error===failure);
  assert.equal(h.completionCalls,2);assert.ok(h.buffers.every(buffer=>buffer.destroyed));
});
await check('Synchronous submission failure propagates with deterministic cleanup',async()=>{
  const failure=Error('Synthetic submit failure'),h=host({failure,submitFailureAt:0});
  await assert.rejects(measureCompletionDelivery(h.device,{now:h.now}),error=>error===failure);
  assert.equal(h.completionCalls,0);assert.ok(h.buffers.every(buffer=>buffer.destroyed));
});
await check('Partial buffer allocation failure destroys the already-created source',async()=>{
  const failure=Error('Synthetic allocation failure'),h=host({failure,createFailureAt:1});
  await assert.rejects(measureCompletionDelivery(h.device,{now:h.now}),error=>error===failure);
  assert.equal(h.buffers.length,1);assert.equal(h.buffers[0].destroyed,true);
});
await check('Nonfinite and backwards host clocks reject instead of corrupting classification',async()=>{
  for(const readings of [[NaN],[Infinity],[-Infinity],[10,9],[0,Infinity],[10,11,0,1],[-1e308,1e308]]) {
    const h=host();let index=0;
    await assert.rejects(measureCompletionDelivery(h.device,{now:()=>readings[index++]}),RangeError);
    assert.ok(h.buffers.every(buffer=>buffer.destroyed));
  }
});
await check('Probe count and threshold are bounded before allocating GPU resources',async()=>{
  for(const options of [{samples:0},{samples:10},{samples:Infinity},{samples:1.5},
    {thresholdMS:0},{thresholdMS:NaN},{thresholdMS:Infinity},{now:null}]) {
    const h=host();await assert.rejects(measureCompletionDelivery(h.device,options),RangeError);
    assert.equal(h.buffers.length,0);assert.equal(h.submitCalls,0);
  }
});
console.log(`${passed}/${passed} completion-delivery probe host checks passed; no GPU execution performed.`);
