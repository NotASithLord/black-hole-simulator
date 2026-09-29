import assert from 'node:assert/strict';
import {CompletionCadence} from '../src/completion-cadence.js';
import {adaptiveResolutionScale,adaptiveTiming} from '../src/quality.js';

let passed=0;
const check=(name,test)=>{test();passed++;console.log(`PASS ${name}`);};
const record=(cadence,at,generation=0)=>cadence.record({at,generation});

check('Ordinary fallback evidence requires both one second and 64 completed intervals',()=>{
  const slow=new CompletionCadence();
  assert.equal(record(slow,0),null);
  for(let index=1;index<64;index++)assert.equal(record(slow,index*20),null);
  assert.deepEqual(record(slow,1280),{ms:20,at:1280,generation:0,samples:64,durationMS:1280});
  const fast=new CompletionCadence();record(fast,0);
  for(let index=1;index<200;index++)assert.equal(record(fast,index*5),null);
  assert.deepEqual(record(fast,1000),{ms:5,at:1000,generation:0,samples:200,durationMS:1000});
});

check('Every completed interval belongs to exactly one adjacent window',()=>{
  const cadence=new CompletionCadence();record(cadence,1000);
  let result;
  for(let index=1;index<=128;index++) {
    result=record(cadence,1000+index*20);
    if(index%64===0)assert.equal(result.ms,20);else assert.equal(result,null);
  }
  assert.equal(result.at,3560);assert.equal(result.samples,64);
  assert.equal(cadence.startAt,3560);assert.equal(cadence.intervals,0);
});

check('Workload resets discard partial windows and reject late old-generation callbacks',()=>{
  const cadence=new CompletionCadence();record(cadence,0);record(cadence,1000);
  cadence.reset(7);
  assert.equal(cadence.startAt,null);assert.equal(cadence.intervals,0);
  assert.equal(record(cadence,2000,0),null);assert.equal(cadence.startAt,null);
  record(cadence,2100,7);record(cadence,2120,7);
  assert.equal(record(cadence,2130,6),null);assert.equal(cadence.intervals,1);
  cadence.reset();assert.equal(cadence.generation,7);assert.equal(cadence.startAt,null);
});

check('Invalid or backward timestamps cannot poison optional cadence evidence',()=>{
  const cadence=new CompletionCadence();record(cadence,100);record(cadence,120);
  for(const at of [NaN,Infinity,-Infinity,-1,119])assert.equal(record(cadence,at),null);
  assert.equal(cadence.lastAt,120);assert.equal(cadence.intervals,1);
  assert.equal(record(cadence,120),null);assert.equal(cadence.intervals,2,'Same-time batched completions still count');
  for(const options of [{minimumDurationMS:0},{minimumDurationMS:NaN},{minimumDurationMS:Infinity},
    {minimumIntervals:0},{minimumIntervals:1.5},{minimumIntervals:Infinity}])assert.throws(()=>new CompletionCadence(options),RangeError);
  for(const generation of [null,-1,1.5,NaN]) {
    assert.throws(()=>cadence.reset(generation),RangeError);
  }
});

function replay(rate,phase,{minimumDurationMS=1000,minimumIntervals=64,pollMS=100,seconds=20}={}) {
  const cadence=new CompletionCadence({minimumDurationMS,minimumIntervals}),samples=[];
  for(let frame=0;frame<rate*seconds;frame++) {
    const completed=phase+frame*1000/rate;
    // Work really completes at the requested rate; only host notification is
    // rounded to the next poll. This simulation claims nothing about GPU cost.
    const delivered=Math.ceil(completed/pollMS)*pollMS;
    const sample=record(cadence,delivered);
    if(sample)samples.push(sample);
  }
  return samples;
}

check('Regression: short windows can manufacture overload from 100 ms callback batch edges',()=>{
  const samples=replay(60,0,{minimumDurationMS:100,minimumIntervals:8});
  assert.ok(samples.some(sample=>sample.ms>(1000/60)*1.12));
  assert.ok(samples.some(sample=>sample.ms<(1000/60)*.8));
});

let lowestRatio=Infinity,highestRatio=0;
check('100 ms batches at 10–120 Hz and every poll phase cannot trigger fake headroom or overload',()=>{
  for(const rate of [10,20,30,60,120])for(let phase=0;phase<100;phase++) {
    const interval=1000/rate,samples=replay(rate,phase);
    assert.ok(samples.length>=2,`Enough independent windows at ${rate} Hz, phase ${phase}`);
    for(const sample of samples) {
      const ratio=sample.ms/interval;
      lowestRatio=Math.min(lowestRatio,ratio);highestRatio=Math.max(highestRatio,ratio);
      assert.ok(ratio>=.9&&ratio<=1.11,`Bounded edge error: ${rate} Hz, phase ${phase}, ratio ${ratio}`);
      const evidence=adaptiveTiming({generation:0,now:sample.at,intervalMS:interval,completion:sample});
      assert.equal(evidence.source,'throughput');assert.equal(evidence.budgetMS,interval);
      assert.equal(adaptiveResolutionScale(.7,evidence.observedMS,evidence.budgetMS,.2,1,evidence.source),.7,
        'Callback batching alone must not change resolution at the true target cadence');
    }
  }
});

check('Longer evidence still reports sustained real overload and remains throughput, not GPU cost',()=>{
  const samples=replay(10,0);
  assert.ok(samples.every(sample=>sample.ms===100&&sample.durationMS===5000&&sample.samples===50));
  const sample=samples.at(-1);
  const evidence=adaptiveTiming({generation:0,now:sample.at,intervalMS:1000/60,completion:sample});
  assert.equal(evidence.source,'throughput');assert.equal(evidence.observedMS,100);
  assert.ok(adaptiveResolutionScale(1,evidence.observedMS,evidence.budgetMS,.2,1,evidence.source)<1);
});

check('The five-second/eight-interval slow path retains useful 0.5, 1, 5 and 10 FPS evidence',()=>{
  for(const rate of [.5,1,5,10])for(let phase=0;phase<100;phase++) {
    const samples=replay(rate,phase,{seconds:50});
    assert.ok(samples.length>=2);
    for(const sample of samples) {
      assert.equal(sample.ms,1000/rate);
      assert.equal(sample.durationMS,rate<2?8000/rate:5000);
      assert.ok(sample.samples>=8&&sample.samples<64);
      const evidence=adaptiveTiming({generation:0,now:sample.at,intervalMS:1000/60,completion:sample});
      assert.equal(evidence.source,'throughput');
      assert.ok(adaptiveResolutionScale(1,evidence.observedMS,evidence.budgetMS,.2,1,evidence.source)<1);
    }
  }
});

console.log(`${passed}/${passed} completion-cadence checks passed; batched/true interval ratio ${lowestRatio.toFixed(4)}–${highestRatio.toFixed(4)} (host simulation only).`);
