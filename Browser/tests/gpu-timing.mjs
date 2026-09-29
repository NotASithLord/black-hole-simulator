import assert from 'node:assert/strict';
import {validateGPUTimestamps,GPUTimingHealth} from '../src/gpu-timing.js';

let passed=0;
const check=(name,fn)=>{fn();passed++;console.log(`PASS ${name}`);};
const sample=(origin=1_000_000n)=>[origin,origin+2_000_000n,origin+2_500_000n,origin+3_000_000n];
const validate=(values,extra={})=>validateGPUTimestamps(values,{wallMS:10,...extra});
const failReason=(values,reason,extra={})=>assert.deepEqual(validate(values,extra),{valid:false,reason});

check('Ordered counters produce total, compute and presentation durations',()=>{
  assert.deepEqual(validate(sample()),{valid:true,reason:null,gpuMS:3,emissionMS:2,presentationMS:.5});
});
check('Subtraction precedes conversion even near the u64 maximum',()=>{
  const offset=(1n<<64n)-10_000_000n;
  assert.equal(validate(sample(offset)).gpuMS,3);
});
check('Every internal counter boundary must be monotonic',()=>{
  for(const values of [[20n,10n,30n,40n],[10n,30n,20n,40n],[10n,20n,40n,30n]])failReason(values,'unordered-counters');
});
check('A wrap or epoch reset DURING a sample is rejected, not repaired with abs',()=>{
  failReason([(1n<<64n)-2n,(1n<<64n)-1n,0n,1n],'unordered-counters');
});
check('A reset BETWEEN samples remains valid',()=>{
  assert.equal(validate(sample(0n),{previousStamps:sample(9_000_000_000_000n)}).valid,true);
});
check('Zero origin is legal; zero TOTAL duration supplies no timing',()=>{
  assert.equal(validate(sample(0n)).valid,true);
  failReason([0n,0n,0n,0n],'zero-span');failReason([4n,4n,4n,4n],'zero-span');
});
check('Timestamp quantization may collapse an individual pass',()=>{
  assert.deepEqual(validate([100n,100n,1_000_100n,1_000_100n]),{valid:true,reason:null,gpuMS:1,emissionMS:0,presentationMS:0});
});
check('An identical four-counter tuple is stale, not a fresh measurement',()=>{
  failReason(sample(),'stale-counters',{previousStamps:sample()});
});
check('Changed counters with identical durations are valid',()=>{
  assert.equal(validate(sample(2_000_000n),{previousStamps:sample()}).valid,true);
});
check('Missing, malformed, signed and overflowing counters are rejected',()=>{
  for(const values of [null,[],{length:4},[1n,2n,3n],[-1n,2n,3n,4n],[0n,1n,2n,1n<<64n],
    [0,1,2,NaN],[0,1,2,Infinity],[0,1,2,.5],[0,1,2,Number.MAX_SAFE_INTEGER+1],['0',1n,2n,3n]])failReason(values,'invalid-counters');
});
check('Native BigUint64Array and exact numeric counters are supported',()=>{
  assert.equal(validate(new BigUint64Array(sample())).valid,true);
  assert.equal(validate(sample().map(Number)).valid,true);
});
check('Negative, missing or nonfinite wall spans cannot validate a query',()=>{
  for(const wallMS of [-1,NaN,Infinity,undefined])failReason(sample(),'invalid-wall-span',{wallMS});
});
check('GPU spans cannot greatly exceed host elapsed wall time',()=>{
  failReason(sample(),'implausible-span',{wallMS:.1});
  assert.equal(validate(sample(),{wallMS:1}).valid,true); // 2 ms clock slack.
});
check('Timer granularity tolerance is bounded and configurable',()=>{
  assert.equal(validate([0n,0n,1_000_000n,1_000_000n],{wallMS:0}).valid,true);
  failReason(sample(),'implausible-span',{wallMS:1,clockSlackMS:0});
});
check('Even a long wall delay does not make absurd GPU spans plausible',()=>{
  failReason([0n,1n,2n,6_000_000_000n],'implausible-span',{wallMS:10_000});
});
check('Invalid validation limits are rejected',()=>{
  for(const extra of [{maxSpanMS:0},{maxSpanMS:NaN},{clockSlackMS:-1},{clockSlackMS:Infinity}])failReason(sample(),'invalid-wall-span',extra);
});
check('Unsupported timestamps stay optional and never schedule queries',()=>{
  const health=new GPUTimingHealth({available:false});
  assert.equal(health.shouldMeasure(0),false);
  assert.deepEqual(health.record(sample(),{now:0,wallMS:10}),{valid:false,reason:'unavailable'});
  assert.deepEqual(health.failure('map-failed',0),{valid:false,reason:'unavailable'});
  assert.equal(health.status.invalidSamples,0);
});
check('One bad sample is discarded without disabling future timing',()=>{
  const health=new GPUTimingHealth();health.record([0n,0n,0n,0n],{now:0,wallMS:10});
  assert.equal(health.shouldMeasure(1),true);assert.equal(health.status.suspended,false);
  assert.equal(health.record(sample(),{now:2,wallMS:10}).valid,true);
  assert.equal(health.status.lastFailure,null);
});
check('Three consecutive bad samples activate a five-second cooldown',()=>{
  const health=new GPUTimingHealth();
  for(let now=0;now<3;now++)health.failure('map-failed',now);
  assert.equal(health.status.retryAt,5002);assert.equal(health.shouldMeasure(5001),false);
  assert.equal(health.shouldMeasure(5002),true);
});
check('Four bad samples out of six catch intermittent corruption',()=>{
  const health=new GPUTimingHealth();
  for(let now=0;now<6;now++) {
    if(now===2||now===5)health.record(sample(BigInt(now+1)*10_000_000n),{now,wallMS:10});
    else health.failure('unordered-counters',now);
    if(now===4)assert.equal(health.status.suspended,true);
  }
  // A successful recovery probe is allowed to clear a tripped breaker.
  assert.equal(health.status.suspended,false);
});
check('Failed recovery probes back off to a capped sixty seconds',()=>{
  const health=new GPUTimingHealth();
  for(let now=0;now<3;now++)health.failure('unordered-counters',now);
  for(const expected of [10_000,20_000,40_000,60_000,60_000]) {
    const now=health.status.retryAt;assert.equal(health.shouldMeasure(now),true);
    health.failure('map-failed',now);assert.equal(health.status.cooldownMS,expected);
  }
});
check('A good retry restores timing and starts a fresh health window',()=>{
  const health=new GPUTimingHealth();
  for(let now=0;now<3;now++)health.failure('map-failed',now);
  const now=health.status.retryAt;
  assert.equal(health.record(sample(),{now,wallMS:10}).valid,true);
  assert.equal(health.status.suspended,false);assert.equal(health.status.retryAt,0);
  health.failure('map-failed',now+1);assert.equal(health.status.suspended,false);
  assert.equal(health.status.validSamples,1);assert.equal(health.status.invalidSamples,4);
});
check('Health owns a copy of query counters after their mapped buffer is reused',()=>{
  const health=new GPUTimingHealth(),values=new BigUint64Array(sample());
  health.record(values,{now:0,wallMS:10});values.fill(0n);
  assert.equal(health.record(sample(),{now:1,wallMS:10}).reason,'stale-counters');
});
check('Counter resets do not force health fallback',()=>{
  const health=new GPUTimingHealth();
  health.record(sample(99_000_000_000n),{now:0,wallMS:10});
  assert.equal(health.record(sample(0n),{now:1,wallMS:10}).valid,true);
});
check('Nonfinite scheduling clocks never mutate health or enable queries',()=>{
  const health=new GPUTimingHealth();
  assert.equal(health.shouldMeasure(NaN),false);
  assert.equal(health.record(sample(),{now:NaN,wallMS:10}).reason,'invalid-clock');
  assert.equal(health.failure('map-failed',Infinity).reason,'invalid-clock');
  assert.equal(health.status.invalidSamples,0);
});
console.log(`${passed} GPU timing validation and recovery checks passed.`);
