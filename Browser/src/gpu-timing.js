const U64_MAX=(1n<<64n)-1n;

function counters(values) {
  if(!values||values.length!==4)return null;
  const result=[];
  for(let index=0;index<4;index++) {
    const value=values[index];
    if(typeof value!=='bigint'&&!(typeof value==='number'&&Number.isSafeInteger(value)))return null;
    const counter=BigInt(value);
    if(counter<0n||counter>U64_MAX)return null;
    result.push(counter);
  }
  return result;
}

/**
 * Validate one compute + presentation timestamp sample before subtraction.
 * GPU counters have an implementation-defined epoch and may reset BETWEEN
 * submissions. Only the four ordered writes within this submission are related;
 * never compare their absolute values with performance.now() or another epoch.
 * A zero-duration individual pass is legal with quantized timestamps. A wholly
 * zero-duration sample provides no usable workload measurement.
 */
export function validateGPUTimestamps(values,{wallMS,previousStamps=null,maxSpanMS=5000,clockSlackMS=2}={}) {
  const stamps=counters(values);
  if(!stamps)return {valid:false,reason:'invalid-counters'};
  if(!Number.isFinite(wallMS)||wallMS<0||!Number.isFinite(maxSpanMS)||maxSpanMS<=0||
    !Number.isFinite(clockSlackMS)||clockSlackMS<0)return {valid:false,reason:'invalid-wall-span'};
  for(let index=1;index<4;index++) {
    if(stamps[index]<stamps[index-1])return {valid:false,reason:'unordered-counters'};
  }
  const span=stamps[3]-stamps[0];
  if(span===0n)return {valid:false,reason:'zero-span'};
  const previous=counters(previousStamps);
  if(previous&&stamps.every((value,index)=>value===previous[index]))return {valid:false,reason:'stale-counters'};
  // Subtract in integer space FIRST: absolute nanosecond counters routinely
  // exceed Number's exact range, even when their small differences are exact.
  const gpuMS=Number(span)/1e6;
  if(gpuMS>maxSpanMS||gpuMS>wallMS*1.1+clockSlackMS)return {valid:false,reason:'implausible-span'};
  return {valid:true,reason:null,gpuMS,emissionMS:Number(stamps[1]-stamps[0])/1e6,
    presentationMS:Number(stamps[3]-stamps[2])/1e6};
}

/**
 * Small circuit breaker for OPTIONAL timing, not for rendering. A single bad
 * sample is discarded without disabling future queries. Persistent corruption
 * suspends query overhead briefly; a later valid probe restores timing. The host
 * continues rendering and uses its completion/cadence fallback throughout.
 * Keep this instance across camera/quality changes; those cannot repair counters.
 * Pass a monotonic millisecond clock as `now`. The host's queryBusy guard owns
 * concurrency: shouldMeasure() deliberately does not reserve a pending query.
 */
export class GPUTimingHealth {
  constructor({available=true,retryMS=5000,maxRetryMS=60000}={}) {
    this.available=available;
    this.retryMS=Math.max(1,Number.isFinite(retryMS)?retryMS:5000);
    this.maxRetryMS=Math.max(this.retryMS,Number.isFinite(maxRetryMS)?maxRetryMS:60000);
    this.retryAt=0;this.cooldownMS=0;this.suspended=false;
    this.consecutiveFailures=0;this.validSamples=0;this.invalidSamples=0;
    this.lastFailure=available?null:'unavailable';this.recent=[];this.previousStamps=null;
  }
  shouldMeasure(now) {
    return this.available&&Number.isFinite(now)&&(!this.suspended||now>=this.retryAt);
  }
  record(values,{wallMS,now,...options}={}) {
    if(!this.available)return {valid:false,reason:'unavailable'};
    if(!Number.isFinite(now))return {valid:false,reason:'invalid-clock'};
    const result=validateGPUTimestamps(values,{...options,wallMS,previousStamps:this.previousStamps});
    if(!result.valid)return this.failure(result.reason,now);
    this.previousStamps=counters(values);
    this.validSamples++;this.consecutiveFailures=0;this.lastFailure=null;
    // Recovery starts a clean health window; ordinary successful samples do not
    // erase intermittent corruption (e.g. bad, bad, good repeated forever).
    if(this.suspended)this.recent=[];
    this.suspended=false;this.retryAt=0;this.cooldownMS=0;
    this.recent.push(false);if(this.recent.length>6)this.recent.shift();
    return result;
  }
  failure(reason,now) {
    if(!this.available)return {valid:false,reason:'unavailable'};
    if(!Number.isFinite(now))return {valid:false,reason:'invalid-clock'};
    this.invalidSamples++;this.consecutiveFailures++;this.lastFailure=reason;
    this.recent.push(true);if(this.recent.length>6)this.recent.shift();
    if(this.suspended||this.consecutiveFailures>=3||this.recent.filter(Boolean).length>=4) {
      // A failed recovery probe backs off; ordinary pre-trip failures do not.
      this.cooldownMS=this.suspended?Math.min(this.maxRetryMS,this.cooldownMS*2):this.retryMS;
      this.retryAt=now+this.cooldownMS;this.suspended=true;
    }
    return {valid:false,reason};
  }
  get status() {
    return {available:this.available,suspended:this.suspended,retryAt:this.retryAt,cooldownMS:this.cooldownMS,
      validSamples:this.validSamples,invalidSamples:this.invalidSamples,lastFailure:this.lastFailure};
  }
}
