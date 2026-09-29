import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import './precision-arithmetic.mjs';

// These tests evaluate scalar material expressions and isolated capture branches
// extracted from WGSL using JavaScript. They verify source transformations and
// observability, not GPU f32 accuracy, browser acceptance or runtime performance.
const source=await readFile(new URL('../src/kerr.wgsl',import.meta.url),'utf8');
const reference=await readFile(new URL('./fixtures/full-material-reference.wgsl',import.meta.url),'utf8');
const compensationReference=await readFile(new URL('./fixtures/compensated-reference.wgsl',import.meta.url),'utf8');
const clamp=(x,a,b)=>Math.min(b,Math.max(a,x));
const mix=(a,b,t)=>a+(b-a)*t;
const smoothstep=(a,b,x)=>{const t=clamp((x-a)/(b-a),0,1);return t*t*(3-2*t);};
const fract=x=>x-Math.floor(x);
const hash=n=>{let x=n>>>0;x^=x>>>16;x=Math.imul(x,0x7feb352d);x^=x>>>15;x=Math.imul(x,0x846ca68b);return(x^(x>>>16))>>>0;};
const random=x=>(hash(x)&0x00ffffff)/16777216;
const operations={log:0,sqrt:0,exp:0,pow:0,noise:0};
function materialNoise(p,period) {
  operations.noise++;
  const x=Math.floor(p[0]),y=Math.floor(p[1]);
  const q=p.map(v=>{const t=fract(v);return t*t*(3-2*t);});
  const x0=((x%period)+period)%period,x1=(x0+1)%period;
  const row0=Math.imul(y,0x9e3779b9),row1=Math.imul(y+1,0x9e3779b9);
  const a=random(Math.imul(x0,0x85ebca6b)^row0),b=random(Math.imul(x1,0x85ebca6b)^row0);
  const c=random(Math.imul(x0,0x85ebca6b)^row1),d=random(Math.imul(x1,0x85ebca6b)^row1);
  return mix(mix(a,b,q[0]),mix(c,d,q[0]),q[1]);
}
const scalarHelpers={
  sin:Math.sin,cos:Math.cos,abs:Math.abs,max:Math.max,floor:Math.floor,i32:x=>x|0,
  PI:Math.PI,random,clamp,mix,smoothstep,vec2:(x,y)=>[x,y],materialNoise,
  MaterialCoordinates:(logRadius,footprint,dye,shearRate,outerTaper,strength)=>({logRadius,footprint,dye,shearRate,outerTaper,strength}),
};
for(const name of ['log','sqrt','exp','pow']) {
  scalarHelpers[name]=(...args)=>{operations[name]++;return Math[name](...args);};
}
function functionText(text,name) {
  const start=text.indexOf(`fn ${name}(`);
  assert(start>=0,`Function ${name} exists`);
  const open=text.indexOf('{',start);
  let depth=1,end=open+1;
  while(depth){const c=text[end++];assert(end<=text.length,'Balanced function braces');if(c==='{')depth++;if(c==='}')depth--;}
  return {header:text.slice(start,open),body:text.slice(open,end)};
}
function scalarFunction(text,name,dependencies={}) {
  const {header,body}=functionText(text,name);
  const parameters=header.match(/\(([^]*?)\)\s*->/)[1].split(',').map(x=>x.trim().split(':')[0]);
  // Translate only the scalar helper subset used below. This is deliberately
  // not a general WGSL emulator; unexpected syntax fails rather than falling back.
  const js=body.replace(/vec2<f32>/g,'vec2').replace(/bitcast<u32>\(cohort\)/g,'(cohort>>>0)').replace(/(0x[0-9a-f]+)u/g,'$1');
  const helpers={...scalarHelpers,...dependencies};
  return Function(...Object.keys(helpers),`return function(${parameters.join(',')}) ${js}`)(...Object.values(helpers));
}
const oldMaterial=scalarFunction(reference,'materialTransmissionReference');
const coordinates=scalarFunction(source,'materialCoordinates');
const material=scalarFunction(source,'materialTransmission');
const sinc=scalarFunction(source,'materialShutterSinc');
const cohort=scalarFunction(source,'materialCohortLite');
const lite=scalarFunction(source,'materialTransmissionLite',{materialShutterSinc:sinc,materialCohortLite:cohort});
let checks=0;
function check(condition,label){assert(condition,label);checks++;console.log(`PASS ${label}`);}
const u={spin:.82,diskInnerRadius:2.80014129,diskOuterRadius:30,materialStrength:.9,diskLogRadiusMin:Math.log(2.80014129),flowLogRadiusSpan:Math.log(30/2.80014129)};
let comparisons=0;
for(const spin of [0,.5,.82,.998])for(const r of [u.diskInnerRadius,3,7,15,29,30])for(const phase of [-1000,-1,.4,13,999])for(const time of [-10000,0,12,1000,1e6])for(const footprint of [0,.01,.1])for(const dye of [0,.5,1])for(const strength of [0,.5,1]) {
  u.spin=spin;u.materialStrength=strength;
  const r32=r*Math.sqrt(r),omega=1/(r32+clamp(spin,0,.998));
  const before=oldMaterial(r,phase,time,dye,footprint,u);
  const after=material(coordinates(Math.log(r),r32,omega,dye,footprint,u),phase,time);
  assert.equal(after,before,'Hoisting retains the reference expression result');comparisons++;
}
check(comparisons===16200,`${comparisons} exact CPU source comparisons against the frozen full-material reference`);
u.spin=.82;u.materialStrength=.9;
for(const samples of [1,2,4]) {
  const r=6,r32=r*Math.sqrt(r),omega=1/(r32+u.spin),time=932,shutter=.04;
  let before=0,after=0;
  for(const key in operations)operations[key]=0;
  for(let j=0;j<samples;j++){const t=time+((j+.5)/samples-.5)*shutter;before+=oldMaterial(r,.6-omega*t,t,.5,.01,u);}
  const oldCount={...operations};
  for(const key in operations)operations[key]=0;
  const shared=coordinates(Math.log(r),r32,omega,.5,.01,u);
  for(let j=0;j<samples;j++){const t=time+((j+.5)/samples-.5)*shutter;after+=material(shared,.6-omega*t,t);}
  check(after===before&&oldCount.log===3*samples&&operations.log===2&&oldCount.sqrt===samples&&operations.sqrt===0,
    `${samples}-tap full-material shutter is identical; material-only logs ${oldCount.log}→${operations.log}, square roots ${oldCount.sqrt}→${operations.sqrt}`);
}
let lowest=Infinity,highest=-Infinity,contrastMin=Infinity,motionError=0,renewalJump=0;
for(const r of [3,6,12,25]) {
  const r32=r*Math.sqrt(r),omega=1/(r32+u.spin),lr=Math.log(r),f=.38/240*80/r;
  for(const seconds of [0,8000,400000,4000000]) {
    let low=Infinity,high=-Infinity;
    for(let j=0;j<256;j++){const value=lite(lr,r32,j*2*Math.PI/256,seconds/492,omega,.0677,f,u);assert(Number.isFinite(value));low=Math.min(low,value);high=Math.max(high,value);}
    lowest=Math.min(lowest,low);highest=Math.max(highest,high);contrastMin=Math.min(contrastMin,high-low);
  }
  const shearRate=1.5*r32*omega*omega;
  motionError=Math.max(motionError,Math.abs(cohort(lr-u.diskLogRadiusMin,shearRate,.76,omega,32,3,0,1,1)-cohort(lr-u.diskLogRadiusMin,shearRate,.76+omega*17,omega,49,3,0,1,1)));
  for(const n of [-2,0,1,16,126]) {
    const t=n*64,epsilon=1e-6;
    renewalJump=Math.max(renewalJump,Math.abs(lite(lr,r32,.76,t+epsilon,omega,.0677,f,u)-lite(lr,r32,.76,t-epsilon,omega,.0677,f,u)));
  }
}
check(lowest>=0&&highest<=1&&contrastMin>.03,`Lite source remains bounded and visibly structured through four million source seconds (minimum contrast ${contrastMin})`);
check(motionError<1e-12&&renewalJump<1e-6,'Lite source keeps Kerr angular motion within each cohort and continuous renewals');
// Freeze both pre-optimization capture branches. Normalize only these exact
// source blocks back to their originals before checking the unchanged transport
// hash. No equation, tolerance, disk intersection or diagnostic output is allowed
// to drift behind a newly accepted hash. Browser GPU execution remains required.
const captureReferences=[
  {name:'ordinary',functionName:'followRay',condition:'if(next.q.x>=captureU)',
    original:'if(next.q.x>=captureU) { o.state=crossing(old,next,c,h,0u,captureU); o.status=2u; break; }',
    optimized:'if(next.q.x>=captureU) { if(!radianceOnly) { o.state=crossing(old,next,c,h,0u,captureU); } o.status=2u; break; }'},
  {name:'compensated',functionName:'followWide',condition:'if(s.q.x>=captureU)',
    original:'if(s.q.x>=captureU) { y=wcross(y,next,c,h,0u,captureU); o.status=2u; break; }',
    optimized:'if(s.q.x>=captureU) { if(radianceOnly) { y=next; } else { y=wcross(y,next,c,h,0u,captureU); } o.status=2u; break; }'},
];
function blockText(text,start) {
  assert(start>=0,'Capture block exists');
  const open=text.indexOf('{',start);let depth=1,end=open+1;
  while(depth){const c=text[end++];assert(end<=text.length,'Balanced capture block');if(c==='{')depth++;if(c==='}')depth--;}
  return text.slice(start,end);
}
let protectedSource=source.slice(source.indexOf('fn finite('),source.indexOf('fn thermalSpectrum('));
// The precision portability change is limited to ds/dn/da/dm and their integer
// helpers. Restore its frozen original for the existing transport hash: the
// integrators, tolerances, event conditions and every other equation remain
// protected by the original digest. precision-metal.mjs executes these changed
// arithmetic primitives under both fast and strict Metal compilation.
const compensationStart=protectedSource.indexOf('fn ds('),compensationEnd=protectedSource.indexOf('fn dd(');
assert(compensationStart>=0&&compensationEnd>compensationStart);
protectedSource=protectedSource.slice(0,compensationStart)+compensationReference+protectedSource.slice(compensationEnd);
for(const reference of captureReferences) {
  const body=functionText(source,reference.functionName).body;
  reference.current=blockText(body,body.indexOf(reference.condition));
  const significant=text=>text.replace(/\/\/[^\n]*/g,'').replace(/\s+/g,'');
  assert.equal(significant(reference.current),significant(reference.optimized),
    'Hash normalization accepts only the exact approved capture-only control-flow change');
  assert.equal(protectedSource.split(reference.current).length,2,'One exact capture block is normalized');
  protectedSource=protectedSource.replace(reference.current,reference.original);
}
check(createHash('sha256').update(protectedSource).digest('hex')==='a162d3d1ee20e75a7cec26676b6ca2b142b34ae8515e9bb9157afc4fa57c8e6f',
  'Apart from tested compensation primitives and two invisible capture refinements, transport equations, tolerances, photosphere and redshift source remain unchanged');

// Evaluate the actual branch text with an instrumented endpoint solver. This is
// control-flow/observability testing, not a JavaScript geodesic approximation.
// The endpoint solver's arbitrary output stands for any backend's refinement.
function captureBranch(text) {
  const js=text.replace(/\b(\d+)u\b/g,'$1');
  return Function('old','next','c','h','captureU','radianceOnly','crossing','wcross',`
    const o={state:next,status:4};let y=old;const s=next;
    for(let once=0;once<1;once++){${js}}
    return {o,y};
  `);
}
const noEndpointReads=new Proxy({}, {get(){throw Error('A capture record must not read endpoint or metric fields');}});
const recordBody=functionText(source,'geometryRecord').body
  .replace(/vec4<f32>/g,'vec4').replace(/\b(\d+)u\b/g,'$1');
const captureRecord=Function('vec4','f32',`return function(ray,u)${recordBody}`)(
  (...values)=>values,Math.fround,
);
let capturedComparisons=0,diagnosticComparisons=0,nonCaptureComparisons=0;
for(const reference of captureReferences) {
  const before=captureBranch(reference.original),after=captureBranch(reference.current);
  for(let i=0;i<1024;i++) {
    const captureU=Math.fround(.3+i/8192),h=Math.fround(.004+i/1e7);
    const old={q:{x:captureU-.001},identity:`old-${i}`},c={identity:`constants-${i}`};
    for(const crossed of [false,true])for(const radianceOnly of [false,true]) {
      const next={q:{x:crossed?captureU+.001:captureU-.0005},identity:`next-${i}`};
      const refined={q:{x:captureU},identity:`refined-${i}`};
      const run=fn=>{
        const calls=[];
        const crossing=(...args)=>{calls.push(args);return refined;};
        const value=fn(old,next,c,h,captureU,radianceOnly,crossing,crossing);
        return {value,calls};
      };
      const previous=run(before),current=run(after);
      if(!crossed) {
        assert.deepEqual(current,previous);assert.equal(current.calls.length,0);nonCaptureComparisons++;
      } else if(!radianceOnly) {
        assert.deepEqual(current,previous);assert.equal(current.calls.length,1);diagnosticComparisons++;
        assert.deepEqual(current.calls[0],[old,next,c,h,0,captureU]);
      } else {
        assert.equal(previous.calls.length,1);assert.equal(current.calls.length,0);
        assert.equal(current.value.o.status,previous.value.o.status);
        assert.deepEqual(captureRecord({status:current.value.o.status,state:noEndpointReads,constants:noEndpointReads},noEndpointReads),[-2,0,0,0]);
        assert.deepEqual(captureRecord({status:previous.value.o.status,state:noEndpointReads,constants:noEndpointReads},noEndpointReads),[-2,0,0,0]);
        capturedComparisons++;
      }
    }
  }
}
check(capturedComparisons===2048,'2,048 captured-ray branch comparisons preserve opaque geometry records while skipping refinement');
check(diagnosticComparisons===2048,'2,048 diagnostic capture comparisons preserve exact endpoint-solver inputs, outputs and call counts');
check(nonCaptureComparisons===4096,'4,096 non-capture branch comparisons retain every state field and do not invoke the shortcut');
check(functionText(source,'traceGeometry').body.includes('followRay(vec2<f32>(gid)+jitter,u,true)')&&
  ['validateKerr','validateSurface'].every(name=>functionText(source,name).body.includes('followRay(validationPixels[i].xy,params,false)')),
  'Only opaque production records request radiance-only transport; both diagnostic entry points retain full event refinement');
const calls=(name,callee)=>(functionText(source,name).body.match(new RegExp(`\\b${callee}\\(`,'g'))??[]).length;
const ordinaryDerivatives=calls('crossing','derivative')+calls('crossing','rk45')*calls('rk45','derivative');
const wideDerivatives=calls('wcross','wd')+calls('wcross','wstep')*calls('wstep','wrk4')*calls('wrk4','wd');
check(ordinaryDerivatives===17&&wideDerivatives===27,
  'Each skipped source-level refinement removes 17 ordinary or 27 compensated derivative evaluations (not a measured GPU speedup)');
const shade=functionText(source,'shadeHit').body;
check(shade.indexOf('if(u.appearanceMode==0u && u.perturbationAmplitude<=0.0)')<shade.indexOf('let r32='),'Steady Scientific source returns before orbital and material work');
const compute=functionText(source,'shadeGeometry').body;
check(compute.includes('if(needsFootprint)')&&compute.indexOf('if(needsFootprint)')<compute.indexOf('let other=geometry['),'Unused material footprints skip neighbor geometry reads');
console.log(`${checks}/${checks} shader-source checks passed (CPU expression evaluation only).`);
