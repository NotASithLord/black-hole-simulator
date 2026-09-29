import assert from 'node:assert/strict';
import {BoundedSubmissionWindow} from '../src/submission-window.js';

let passed=0;
const check=(name,fn)=>{fn();passed++;console.log(`PASS ${name}`);};

check('Unknown execution cost permits exactly eight useful outstanding jobs',()=>{
  const window=new BoundedSubmissionWindow(),tokens=[];
  for(let i=0;i<8;i++) tokens.push(window.tryAcquire({now:i*16}));
  assert.equal(tokens.length,8);assert.ok(tokens.every(Number.isInteger));
  assert.equal(new Set(tokens).size,8);assert.equal(window.pending,8);
  assert.equal(window.tryAcquire({now:128}),null);
});

check('The hard safety cap cannot be configured above eight notifications',()=>{
  const window=new BoundedSubmissionWindow({maxPending:100});
  assert.equal(window.capacity(),8);
});

check('Validated GPU cost narrows the backlog without claiming a completion',()=>{
  const window=new BoundedSubmissionWindow();
  assert.equal(window.capacity(1),8);assert.equal(window.capacity(10),8);
  assert.equal(window.capacity(16),5);assert.equal(window.capacity(40),2);
  assert.equal(window.capacity(81),1);assert.equal(window.capacity(1000),1);
  const first=window.tryAcquire({now:0,gpuMS:16});
  const second=window.tryAcquire({now:1,gpuMS:16});
  assert.equal(window.tryAcquire({now:2,gpuMS:81}),null);
  assert.equal(window.pending,2);
  window.release(first);assert.equal(window.tryAcquire({now:3,gpuMS:81}),null);
  window.release(second);assert.notEqual(window.tryAcquire({now:4,gpuMS:81}),null);
});

check('Invalid or unavailable GPU queries do not turn into false overload',()=>{
  const window=new BoundedSubmissionWindow();
  for(const cost of [0,-1,NaN,Infinity,-Infinity,undefined,null]) assert.equal(window.capacity(cost),8);
});

check('Age watchdog prevents new submissions even when count capacity remains',()=>{
  const window=new BoundedSubmissionWindow(),first=window.tryAcquire({now:0});
  assert.equal(window.oldestAge(249),249);
  const second=window.tryAcquire({now:249});assert.notEqual(second,null);
  assert.equal(window.tryAcquire({now:250}),null);assert.equal(window.pending,2);
  assert.equal(window.tryAcquire({now:10_000}),null);assert.equal(window.pending,2);
  window.release(first);
  assert.notEqual(window.tryAcquire({now:251}),null);
});

check('Elapsed time never retires work and a lost callback cannot create an unbounded queue',()=>{
  const window=new BoundedSubmissionWindow();let accepted=0;
  for(let time=0;time<60_000;time+=16) if(window.tryAcquire({now:time})!==null) accepted++;
  assert.equal(accepted,8);assert.equal(window.pending,8);
});

check('Release is idempotent and stale tokens never release a newer job',()=>{
  const window=new BoundedSubmissionWindow({maxPending:1});
  const first=window.tryAcquire({now:0});assert.equal(window.release(first),true);
  const second=window.tryAcquire({now:1});assert.notEqual(second,first);
  assert.equal(window.release(first),false);assert.equal(window.release(-1),false);
  assert.equal(window.pending,1);assert.equal(window.release(second),true);assert.equal(window.pending,0);
});

check('Out-of-order callback delivery retains the actual oldest pending job',()=>{
  const window=new BoundedSubmissionWindow();
  const first=window.tryAcquire({now:0}),second=window.tryAcquire({now:10}),third=window.tryAcquire({now:20});
  window.release(second);assert.equal(window.oldestAge(250),250);
  assert.equal(window.tryAcquire({now:250}),null);
  window.release(first);assert.equal(window.oldestAge(250),230);
  window.release(third);assert.equal(window.oldestAge(1000),0);
  assert.notEqual(window.tryAcquire({now:1000}),null);
});

check('Submit failures can release a reservation without retaining a phantom job',()=>{
  const window=new BoundedSubmissionWindow();
  const token=window.tryAcquire({now:0});
  try {throw Error('Synthetic encode failure');} catch {window.release(token);}
  assert.equal(window.pending,0);
});

check('Invalid policy values and nonfinite host clocks fail explicitly',()=>{
  for(const options of [{maxPending:0},{maxPending:1.5},{maxPending:Infinity},
    {maxAgeMS:0},{maxAgeMS:NaN},{maxQueuedGPUTimeMS:0},{maxQueuedGPUTimeMS:Infinity}]) {
    assert.throws(()=>new BoundedSubmissionWindow(options),RangeError);
  }
  const window=new BoundedSubmissionWindow();
  for(const now of [NaN,Infinity,-Infinity]) assert.throws(()=>window.tryAcquire({now}),RangeError);
});

// Model only notification delivery, not a real GPU. Jobs really finish after
// their execution cost; callbacks are delivered every 100 ms. Each accepted job
// represents one useful frame. No dummy submission or optimistic release exists.
function simulate({maxPending=8,gpuMS=3,reportedGPU=gpuMS,pollMS=100,duration=1000}={}) {
  const window=new BoundedSubmissionWindow({maxPending}),jobs=[];
  let nextGPU=0,submitted=0,peak=0,nextPoll=pollMS;
  for(let frame=0;frame<duration/(1000/60);frame++) {
    const now=frame*1000/60;
    if(now>=nextPoll) {
      for(const job of jobs) if(!job.retired&&job.done<=now) {window.release(job.token);job.retired=true;}
      nextPoll+=pollMS;
    }
    const token=window.tryAcquire({now,gpuMS:reportedGPU});
    if(token===null) continue;
    nextGPU=Math.max(now,nextGPU)+gpuMS;jobs.push({token,done:nextGPU,retired:false});
    submitted++;peak=Math.max(peak,window.pending);
  }
  return {submitted,peak,pending:window.pending,jobs};
}

check('Eight slots sustain useful 60 Hz work under a 100 ms notification floor',()=>{
  const old=simulate({maxPending:2}),current=simulate();
  assert.ok(old.submitted<=20);assert.equal(current.submitted,60);
  assert.ok(current.peak<=8);assert.ok(current.pending<=8);
  assert.equal(current.jobs.length,current.submitted);
});

check('An expensive measured workload uses one slot rather than an eight-frame backlog',()=>{
  const result=simulate({gpuMS:100});
  assert.equal(result.peak,1);assert.ok(result.submitted<=10);
});

check('Unexpectedly slow GPU work still respects the unknown-cost hard cap',()=>{
  const result=simulate({gpuMS:400,reportedGPU:0,duration:3000});
  assert.ok(result.peak<=8);assert.ok(result.pending<=8);
  assert.ok(result.submitted<=15);
});

console.log(`${passed}/${passed} submission-window host checks passed; no GPU execution performed.`);
