import assert from 'node:assert/strict';

// Exhaust the finite nonnegative half-float domain relevant to a completed
// camera pyramid level. This is a CPU proof of the constant-filter identity
// used when later logical levels alias a 1×1 texture; it does not run WGSL.
const f32=Math.fround;
function half(bits) {
  const exponent=(bits>>>10)&31, fraction=bits&1023;
  return exponent===0?fraction*2**-24:(1+fraction/1024)*2**(exponent-15);
}
function constantDownsample(value) {
  let sum=0;
  for(let y=-1;y<=1;y++)for(let x=-1;x<=1;x++) {
    const weight=(x===0?2:1)*(y===0?2:1)/16;
    sum=f32(sum+f32(Math.max(0,value)*weight));
  }
  return Math.min(sum,60000);
}
let count=0;
for(let bits=0;bits<0x7c00;bits++) {
  const value=half(bits);
  if(value>60000)continue;
  assert.equal(constantDownsample(value),value,`Constant half-float pixel 0x${bits.toString(16)} changed`);
  count++;
}
assert.equal(constantDownsample(0),0);
assert.equal(constantDownsample(60000),60000);
// The first level is always executed, even for a 1×1 source: it applies the
// existing nonnegative/60000 clamp before any aliasing can be valid.
assert.equal(constantDownsample(-1),0);
assert.equal(constantDownsample(65504),60000);
console.log(`PASS Every one of ${count} finite nonnegative half-float values ≤60000 is unchanged by the 1×1 binomial filter.`);
console.log('PASS Initial 1×1 filtering retains the existing negative and high-radiance clamps.');
console.log('2/2 camera mathematical invariants passed on the CPU; no GPU execution was performed.');
