import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

// Evaluate only the production integer residual-recovery helpers. JavaScript
// represents every intermediate integer here exactly (at most 49 bits); |0 and
// >>> reproduce WGSL's wrapping bit patterns. Explicit fround at the two high
// operations reproduces GPU f32 rounding. This checks the algorithm, while the
// optional precision-metal test checks its real fast-math compiler execution.
const source=await readFile(new URL('../src/kerr.wgsl',import.meta.url),'utf8');
const bits=new DataView(new ArrayBuffer(4));
const helpers={abs:Math.abs,max:Math.max,f32:Math.fround,i32:x=>x|0,u32:x=>x>>>0,
  bits32:x=>{bits.setFloat32(0,x,true);return bits.getUint32(0,true);},
  int32:x=>x|0,select:(a,b,condition)=>condition?b:a,
  ldexp:(value,exponent)=>Math.fround(value*2**exponent),
  vec2:(x,y)=>({x:Math.fround(x),y:Math.fround(y)})};
for(const name of ['significand','signedSignificand','dn','da','dm']) {
  const start=source.indexOf(`fn ${name}(`),open=source.indexOf('{',start);
  assert(start>=0);let end=open+1,depth=1;
  while(depth){assert(end<source.length);const c=source[end++];if(c==='{')depth++;if(c==='}')depth--;}
  const parameters=source.slice(start,open).match(/\(([^]*?)\)\s*->/)[1].split(',').map(x=>x.trim().split(':')[0]);
  let body=source.slice(open,end).replace(/\/\/[^\n]*/g,'').replace(/vec2<f32>/g,'vec2')
    .replace(/bitcast<u32>/g,'bits32').replace(/bitcast<i32>/g,'int32').replace(/\b(0x[\da-f]+|\d+)u\b/g,'$1');
  if(name==='dn'){assert(body.includes('let high=a+b;'));body=body.replace('let high=a+b;','let high=f32(a+b);');}
  if(name==='dm'){assert(body.includes('let p=a.x*b.x;'));body=body.replace('let p=a.x*b.x;','let p=f32(a.x*b.x);');}
  helpers[name]=Function(...Object.keys(helpers),`return function(${parameters.join(',')}) ${body}`)(...Object.values(helpers));
}
let seed=0x183da265;
const random=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/2**32;};
const float=()=>Math.fround((random()<.5?-1:1)*(1+random())*2**(Math.floor(random()*71)-35));
const value=pair=>pair.x+pair.y;
const cases=[[1,2**-24],[1+2**-23,-1],[1+2**-23,1+2**-23],[2**30,2**-30],[-1,1],[-(2**-20),2**-21]];
for(let i=0;i<10000;i++)cases.push([float(),float()]);
for(const [a,b] of cases) {
  const sum=helpers.dn(a,b),product=helpers.dm({x:a,y:0},{x:b,y:0});
  assert.equal(value(sum),a+b,`Exact two-float sum: ${a}, ${b}`);
  assert.equal(value(product),a*b,`Exact two-float product: ${a}, ${b}`);
  assert.equal(value(helpers.dn(a,-a)),0,'Exact cancellation');
}
let worst=0;
for(let i=0;i<10000;i++) {
  const a={x:float(),y:0},b={x:float(),y:0};
  a.y=Math.fround(a.x*(random()-.5)*2**-24);b.y=Math.fround(b.x*(random()-.5)*2**-24);
  const av=value(a),bv=value(b);
  const sumError=Math.abs(value(helpers.da(a,b))-(av+bv))/Math.max(Math.abs(av),Math.abs(bv));
  const productError=Math.abs(value(helpers.dm(a,b))-av*bv)/Math.abs(av*bv);
  worst=Math.max(worst,sumError,productError);
}
assert(worst<2**-44,`Two-float arithmetic error ${worst} stays below 2^-44`);
console.log(`PASS integer compensation: ${cases.length} exact sums/products/cancellations and 10000 two-float cases (worst relative error ${worst})`);
