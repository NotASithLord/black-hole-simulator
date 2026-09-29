import assert from 'node:assert/strict';
import {traceRows} from '../src/trace-queue.js';

// Host scheduling only. These deliberately deferred fences prove ownership and
// overlap; they do not simulate a GPU or measure rendering performance.
const flush=async()=>{for(let i=0;i<8;i++)await Promise.resolve();};
function host() {
  let clock=0,active=0,peak=0;
  const submissions=[];
  return {submissions,now:()=>clock,advance:ms=>{clock+=ms;},
    get active(){return active;},get peak(){return peak;},
    submit(row,count) {
      active++;peak=Math.max(peak,active);
      let resolve,reject;
      const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});
      submissions.push({row,count,finish(error){active--;error?reject(error):resolve();}});
      return promise;
    }};
}
let passed=0;
const check=(name,fn)=>{fn();passed++;console.log(`PASS ${name}`);};
{
  const h=host(),progress=[];let settled=false;
  const task=traceRows({...h,height:40,progress:f=>progress.push(f)}).then(value=>{settled=true;return value;});
  check('Two trace chunks submit before waiting for the first fence',()=>assert.equal(h.submissions.length,2));
  h.advance(8);h.submissions[0].finish();await flush();
  check('Retiring the oldest chunk immediately queues a successor',()=>assert.equal(h.submissions.length,3));
  check('Trace cannot publish while successor work remains outstanding',()=>assert.equal(settled,false));
  let index=1;
  while(!settled) {h.advance(8);h.submissions[index++].finish();await flush();}
  assert.equal(await task,true);
  check('In-flight trace backlog never exceeds two chunks',()=>assert.equal(h.peak,2));
  check('Completed chunks cover every row once with no overlap',()=>{
    let next=0;
    for(const {row,count} of h.submissions) {assert.equal(row,next);assert.ok(count>0&&count<=64);next+=count;}
    assert.equal(next,40);assert.equal(progress.at(-1),1);
  });
}
{
  const h=host();let cancelled=false,settled=false;
  const task=traceRows({...h,height:128,cancel:()=>cancelled}).then(value=>{settled=true;return value;});
  cancelled=true;h.submissions[0].finish();await flush();
  check('Hard cancellation stops replacement submissions',()=>assert.equal(h.submissions.length,2));
  check('Hard cancellation drains the queued successor before returning',()=>assert.equal(settled,false));
  h.submissions[1].finish();assert.equal(await task,false);assert.equal(h.active,0);
}
{
  const h=host();let settled=false;
  const failure=Error('Synthetic GPU queue failure');
  const task=traceRows({...h,height:128}).then(()=>assert.fail('Expected failure'),error=>{settled=true;assert.equal(error,failure);});
  h.submissions[0].finish(failure);await flush();
  check('Failed oldest fence waits for its already-submitted successor',()=>assert.equal(settled,false));
  h.submissions[1].finish();await task;
  check('Failure does not submit replacement work or retain pending chunks',()=>{assert.equal(h.submissions.length,2);assert.equal(h.active,0);});
}
{
  const h=host();let settled=false;
  const failure=Error('Synthetic successor failure');
  const task=traceRows({...h,height:128}).then(()=>assert.fail('Expected failure'),error=>{settled=true;assert.equal(error,failure);});
  h.submissions[1].finish(failure);await flush();
  assert.equal(settled,false);h.submissions[0].finish();await flush();
  // The oldest success may replenish one chunk before the failed successor is
  // observed. That bounded work must also retire before propagation.
  if(h.submissions[2])h.submissions[2].finish();await task;
  check('Successor rejection is handled immediately and all queued work drains',()=>assert.equal(h.active,0));
}
{
  const h=host();
  assert.equal(await traceRows({...h,height:8,cancel:()=>true}),false);
  check('Already-cancelled trace submits no work',()=>assert.equal(h.submissions.length,0));
}
{
  const submitted=[];let clock=0;
  assert.equal(await traceRows({height:520,initialRows:128,now:()=>clock,
    submit:async(row,count)=>{submitted.push({row,count});clock+=.5;}}),true);
  check('Fast completions and oversized predictions retain the 64-row watchdog cap',()=>{
    assert.ok(submitted.every(({count})=>count<=64));assert.equal(submitted[0].count,64);
    assert.equal(submitted.reduce((sum,item)=>sum+item.count,0),520);
  });
}
{
  const h=host();let cancelled=false,settled=false;
  const failure=Error('Synthetic successor failure during cancellation');
  const task=traceRows({...h,height:128,cancel:()=>cancelled}).then(
    ()=>assert.fail('A failed drain must not resolve as cancellation'),
    error=>{settled=true;assert.equal(error,failure);});
  cancelled=true;h.submissions[0].finish();await flush();
  assert.equal(settled,false);h.submissions[1].finish(failure);await task;
  check('Cancellation propagates a failed successor instead of hiding device failure',()=>{
    assert.equal(h.active,0);assert.equal(h.submissions.length,2);
  });
}
{
  const h=host(),primary=Error('Synthetic oldest fence failure'),secondary=Error('Synthetic successor fence failure');
  const task=traceRows({...h,height:128}).then(
    ()=>assert.fail('Expected primary failure'),error=>assert.equal(error,primary));
  h.submissions[0].finish(primary);h.submissions[1].finish(secondary);await task;
  check('Simultaneous fence failures preserve the primary error after draining',()=>assert.equal(h.active,0));
}
{
  const h=host(),primary=Error('Synthetic synchronous submit failure'),secondary=Error('Synthetic first fence failure');
  let settled=false;
  const task=traceRows({...h,height:128,submit:(row,count)=>{
    if(row>0)throw primary;return h.submit(row,count);
  }}).then(()=>assert.fail('Expected submit failure'),error=>{settled=true;assert.equal(error,primary);});
  await flush();assert.equal(settled,false);assert.equal(h.submissions.length,1);
  h.submissions[0].finish(secondary);await task;
  check('Synchronous submit failure drains prior work without replacing its primary error',()=>assert.equal(h.active,0));
}
{
  const h=host(),primary=Error('Synthetic progress failure'),secondary=Error('Synthetic successor fence failure');
  let settled=false;
  const task=traceRows({...h,height:128,progress:()=>{throw primary;}}).then(
    ()=>assert.fail('Expected progress failure'),error=>{settled=true;assert.equal(error,primary);});
  h.submissions[0].finish();await flush();assert.equal(settled,false);
  h.submissions[1].finish(secondary);await task;
  check('Progress callback failure drains the successor while preserving its primary error',()=>assert.equal(h.active,0));
}
console.log(`${passed}/${passed} bounded trace-queue host checks passed; no GPU execution performed.`);

// Deterministic completed-work model: GPU jobs execute quickly, but callbacks
// are delivered on a coarse 100 ms poll. The pacer advances independently every
// 16 ms. These are scheduling regressions, not browser/GPU benchmark claims.
function pacedHost({rowMS=.05,pollMS=100}={}) {
  let clock=0,nextGPU=0,nextPoll=pollMS,active=0,peak=0;
  const submissions=[],paces=[];
  return {submissions,now:()=>clock,
    get active(){return active;},get peak(){return peak;},
    pace:()=>new Promise(resolve=>paces.push({at:clock+16,resolve})),
    submit(row,count) {
      active++;peak=Math.max(peak,active);nextGPU=Math.max(clock,nextGPU)+count*rowMS;
      return new Promise(resolve=>submissions.push({row,count,at:clock,doneAt:nextGPU,retired:false,
        finish(){this.retired=true;active--;resolve();}}));
    },
    tick() {
      clock+=4;
      if(clock>=nextPoll) {
        for(const submission of submissions) if(!submission.retired&&submission.doneAt<=clock) submission.finish();
        nextPoll+=pollMS;
      }
      for(let index=paces.length-1;index>=0;index--) if(paces[index].at<=clock) paces.splice(index,1)[0].resolve();
    },
  };
}
async function drive(task,h) {
  let settled=false,result,failure;
  task.then(value=>{settled=true;result=value;},error=>{settled=true;failure=error;});
  for(let ticks=0;!settled&&ticks<20_000;ticks++) {h.tick();await flush();}
  assert.ok(settled,'The bounded scheduler must eventually settle when real completions arrive.');
  if(failure) throw failure;
  return result;
}
{
  const legacy=pacedHost(),paced=pacedHost(),progress=[];
  const oldResult=await drive(traceRows({...legacy,pace:null,height:1024}),legacy);
  const newResult=await drive(traceRows({...paced,height:1024,progress:value=>progress.push(value)}),paced);
  check('Paced useful submissions amortize coarse completion polling without empty commands',()=>{
    assert.equal(oldResult,true);assert.equal(newResult,true);
    assert.ok(paced.now()<legacy.now()*.4,`${paced.now()} ms vs ${legacy.now()} ms`);
    assert.ok(paced.submissions.every((chunk,index,list)=>index===0||chunk.at-list[index-1].at>=16));
  });
  check('Paced row growth consumes settled heads and grows beyond eight rows',()=>{
    assert.ok(paced.submissions.some(chunk=>chunk.count>=32));
    assert.ok(paced.submissions.every(chunk=>chunk.count<=64));
    assert.equal(progress.at(-1),1);assert.ok(progress.every((value,index)=>index===0||value>progress[index-1]));
  });
  check('Paced traces retain at most eight unretired chunks and cover each row once',()=>{
    assert.ok(paced.peak<=8);assert.equal(paced.active,0);
    let next=0;
    for(const {row,count} of paced.submissions) {assert.equal(row,next);assert.ok(count>0);next+=count;}
    assert.equal(next,1024);
  });
}
{
  const h=pacedHost();
  assert.equal(await drive(traceRows({...h,height:317,initialRows:128,maxRows:25}),h),true);
  check('Paced configurable dispatch cap rounds down to a safe workgroup tile',()=>{
    assert.ok(h.submissions.every(chunk=>chunk.count<=24));
    assert.equal(h.submissions.reduce((sum,chunk)=>sum+chunk.count,0),317);
  });
}
{
  const h=host();let cancelled=false,settled=false;
  const task=traceRows({...h,height:1024,pace:async()=>{},cancel:()=>cancelled})
    .then(value=>{settled=true;return value;});
  await flush();assert.equal(h.submissions.length,8);cancelled=true;
  h.submissions[0].finish();await flush();
  check('Paced cancellation stops replacement work and waits for every submitted chunk',()=>{
    assert.equal(h.submissions.length,8);assert.equal(settled,false);
  });
  for(const submission of h.submissions.slice(1)) submission.finish();
  assert.equal(await task,false);assert.equal(h.active,0);
}
{
  const h=host(),failure=Error('Synthetic paced successor failure');let settled=false;
  const task=traceRows({...h,height:1024,pace:async()=>{}}).then(
    ()=>assert.fail('Expected successor error'),error=>{settled=true;assert.equal(error,failure);});
  await flush();assert.equal(h.submissions.length,8);
  h.submissions[7].finish(failure);await flush();
  assert.equal(settled,false);
  for(const submission of h.submissions.slice(0,7)) submission.finish();
  await task;
  check('Paced successor failure is handled immediately and drains all earlier jobs',()=>{
    assert.equal(h.submissions.length,8);assert.equal(h.active,0);
  });
}
{
  const h=host(),primary=Error('Synthetic pacing failure'),secondary=Error('Synthetic drain failure');let settled=false;
  const task=traceRows({...h,height:64,pace:async()=>{throw primary;}}).then(
    ()=>assert.fail('Expected pacing error'),error=>{settled=true;assert.equal(error,primary);});
  await flush();assert.equal(h.submissions.length,1);assert.equal(settled,false);
  h.submissions[0].finish(secondary);await task;
  check('A failed pacing callback drains submitted work and preserves the primary error',()=>assert.equal(h.active,0));
}
{
  const h=host(),failure=Error('Synthetic paced cancellation drain failure');let cancelled=false;
  const task=traceRows({...h,height:1024,pace:async()=>{},cancel:()=>cancelled}).then(
    ()=>assert.fail('Expected drain error'),error=>assert.equal(error,failure));
  await flush();cancelled=true;h.submissions[0].finish();await flush();
  for(let index=1;index<h.submissions.length;index++) h.submissions[index].finish(index===7?failure:null);
  await task;
  check('Paced cancellation does not hide a later failed completion',()=>assert.equal(h.active,0));
}
{
  const h=host();
  assert.equal(await traceRows({...h,height:8,pace:async()=>{},cancel:()=>true}),false);
  check('Already-cancelled paced trace submits no work',()=>assert.equal(h.submissions.length,0));
}
{
  const h=host();let settled=false;
  const task=traceRows({...h,height:1024,pace:async()=>{}}).then(value=>{settled=true;return value;});
  await flush();assert.equal(h.submissions.length,8);h.advance(300);
  h.submissions[0].finish();await flush();
  check('Paced age watchdog waits for real old completions instead of replacing one freed slot',()=>{
    assert.equal(h.submissions.length,8);assert.equal(settled,false);
  });
  // Once every old token has really retired, useful work can resume normally.
  for(const submission of h.submissions.slice(1)) submission.finish();await flush();
  let finished=8;
  while(!settled) {
    const submitted=h.submissions.length;
    for(;finished<submitted;finished++)h.submissions[finished].finish();
    await flush();
  }
  assert.equal(await task,true);assert.equal(h.active,0);
}
{
  const h=host(),primary=Error('Synthetic paced submit failure'),secondary=Error('Synthetic preceding fence failure');
  let settled=false;
  const task=traceRows({...h,height:64,pace:async()=>{},submit:(row,count)=>{
    if(row>0)throw primary;return h.submit(row,count);
  }}).then(()=>assert.fail('Expected submit error'),error=>{settled=true;assert.equal(error,primary);});
  await flush();assert.equal(h.submissions.length,1);assert.equal(settled,false);
  h.submissions[0].finish(secondary);await task;
  check('A paced synchronous submit failure releases its reservation and drains prior work',()=>assert.equal(h.active,0));
}
{
  const h=host(),primary=Error('Synthetic paced progress failure');let settled=false;
  const task=traceRows({...h,height:1024,pace:async()=>{},progress:()=>{throw primary;}}).then(
    ()=>assert.fail('Expected progress error'),error=>{settled=true;assert.equal(error,primary);});
  await flush();h.submissions[0].finish();await flush();assert.equal(settled,false);
  for(const submission of h.submissions.slice(1)) submission.finish();await task;
  check('Paced progress failure drains every submitted successor before propagating',()=>assert.equal(h.active,0));
}
{
  const chunks=[];let clock=0;
  await traceRows({height:100,initialRows:64,maxRows:16,now:()=>clock,
    submit:async(row,count)=>{chunks.push({row,count});clock++;}});
  check('Prompt-delivery tracing also respects the caller ray-count row cap',()=>{
    assert.ok(chunks.every(chunk=>chunk.count<=16));
    assert.equal(chunks.reduce((sum,chunk)=>sum+chunk.count,0),100);
  });
}
console.log(`${passed}/${passed} trace-queue host checks passed, including paced coarse-poll simulations; no GPU execution performed.`);
