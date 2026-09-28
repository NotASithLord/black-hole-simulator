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
