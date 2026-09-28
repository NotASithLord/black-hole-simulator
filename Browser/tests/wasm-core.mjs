import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const module=new WebAssembly.Module(await fs.readFile(path.join(root, 'Browser/public/core.wasm')));
assert.deepEqual(WebAssembly.Module.imports(module), [], 'Core has no host math or WASI imports');
const w=new WebAssembly.Instance(module).exports;
let checks=0;
function check(condition,label) { assert.ok(condition,label); checks++; console.log(`PASS ${label}`); }
const relative=(a,b)=>Math.abs(a-b)/Math.max(1e-30,Math.abs(b));
const meta=()=>new Float64Array(w.memory.buffer,w.metadata_ptr(),11);
const radial=()=>new Float32Array(w.memory.buffer,w.radial_ptr(),w.radial_count()*4);
const spectral=()=>new Float32Array(w.memory.buffer,w.spectral_ptr(),w.spectral_count()*4);
check(w.abi_version()===1&&w.radial_count()===4096&&w.spectral_count()===2048,'Fixed ABI and native LUT dimensions');
check(relative(w.isco(0),6)<1e-14,'Schwarzschild ISCO = 6M');
check(relative(w.isco(0.998),1.2369706551751847)<1e-12,'High-spin Kerr ISCO reference');
check(w.isco(-0.9999)>8.999,'Retrograde ISCO approaches 9M');
check(w.init_model(0,1e8,0.01,1000,0.75)===0,'Valid physical disk accepted');
check(relative(meta()[8],1-Math.sqrt(8/9))<1e-12,'Schwarzschild binding efficiency');
const G=6.67430e-11,C=299792458,MSUN=1.98847e30,YEAR=31557600;
const rg=G*1e8*MSUN/(C*C),physicalScale=(0.01*MSUN/YEAR)*C*C/(4*Math.PI*rg*rg);
let maxFluxError=0;
for(const index of [3,10,64,256,1024,2048,4095]) {
  const r=Math.exp(meta()[2]+index*meta()[3]),x=Math.sqrt(r),x0=Math.sqrt(6),s3=Math.sqrt(3);
  // Independent closed form of the Schwarzschild Page-Thorne radial integral.
  const integral=x-x0-s3/2*Math.log(((x-s3)*(x0+s3))/((x+s3)*(x0-s3)));
  const omega=1/(r*x),ut=1/Math.sqrt(1-3/r),domega=-1.5*x*omega*omega;
  const flux=physicalScale*(-domega*ut*ut*integral/r);
  maxFluxError=Math.max(maxFluxError,relative(radial()[index*4+1],flux));
}
check(maxFluxError<2e-6,`Page-Thorne flux versus independent Schwarzschild closed form (${maxFluxError})`);
w.init_model(0.82,1e8,0.01,80,0.75);
const baselinePeak=meta()[4];
check(radial()[0]===0&&radial()[1]===0,'Exact zero torque flux at ISCO');
check(radial().every(v=>Number.isFinite(v)&&v>=0),'Finite nonnegative disk LUT');
check(relative(meta()[7],492.5639893961039)<1e-12,'Gravitational time in physical seconds');
w.init_model(0.82,1e8,0.16,80,0.75);
check(relative(meta()[4]/baselinePeak,2)<1e-12,'Temperature scales as accretion rate to one quarter power');
w.init_model(0.82,4e8,0.01,80,0.75);
check(relative(meta()[4]/baselinePeak,0.5)<1e-12,'Temperature scales as inverse square root mass');
w.init_model(0.82,1e8,0.1,30,0.75);
check(relative(meta()[10],1.01360343)<1e-8,'Native documented default finite height coefficient');
const preserved=[...meta()],preservedRadial=radial().slice();
check(w.init_model(0.82,0,0.1,30,0.75)===1&&w.init_model(NaN,1e8,0.1,30,0.75)===1&&
  w.init_model(0.82,1e8,0.1,1,0.75)===1&&meta().every((v,i)=>v===preserved[i])&&
  radial().every((v,i)=>v===preservedRadial[i]),'Invalid physical parameters preserve prior tables');
const start=performance.now();
check(w.init_spectrum()===0,'Compiled CIE spectral integration completes');
const spectrumMS=performance.now()-start;
check(spectral().every(Number.isFinite),'Finite 300K through 10 million K spectral LUT');
function spectralAt(temperature) {
  const p=(Math.log(temperature)-meta()[5])/meta()[6],i=Math.floor(p),f=p-i;
  return Array.from({length:4},(_,c)=>spectral()[i*4+c]*(1-f)+spectral()[(i+1)*4+c]*f);
}
check(Math.abs(spectralAt(10000)[3]-1)<0.0001,'10,000 K photometric normalization retains luminance');
const rgb=spectralAt(2856);
// Independent sRGB-to-XYZ inverse matrix gives Illuminant A chromaticity.
const X=.4124564*rgb[0]+.3575761*rgb[1]+.1804375*rgb[2];
const Y=.2126729*rgb[0]+.7151522*rgb[1]+.0721750*rgb[2];
const Z=.0193339*rgb[0]+.1191920*rgb[1]+.9503041*rgb[2];
check(Math.abs(X/(X+Y+Z)-.44757)<8e-5&&Math.abs(Y/(X+Y+Z)-.40745)<8e-5,'CIE blackbody chromaticity matches Illuminant A');
const period=w.orbital_period(6,0,1e8);
check(relative(period,2*Math.PI*492.5639893961039*Math.pow(6,1.5))<1e-12,'Physical orbital period');
check(relative(w.orbital_period(6,0,4e8)/period,4)<1e-12,'Orbital period scales with mass');
w.reset_clock();for(let i=0;i<120;i++)w.advance_clock(1/120,1000,1);
check(Math.abs(w.clock_seconds()-1000)<1e-9,'Source time independent of render frame rate');
const before=w.clock_seconds();w.advance_clock(50,1000,0);w.advance_clock(-1,1000,1);w.advance_clock(NaN,1000,1);
check(w.clock_seconds()===before,'Pause and invalid elapsed preserve source phase');
w.advance_clock(1,4000,1);
check(Math.abs(w.clock_seconds()-5000)<1e-9,'Playback changes slope continuously');
check(w.adaptive_scale(1,100,16,0.25,1)===0.9,'Slow GPU gets bounded resolution decrease');
check(w.adaptive_scale(0.5,8,16,0.25,1)===0.52,'Fast GPU gets gradual resolution increase');
check(w.adaptive_scale(0.5,16,16,0.25,1)===0.5,'Adaptive controller deadband preserves stable quality');
check(w.memory.buffer.byteLength===262144,'Fixed 256KiB memory without allocator or growth');
const savedSpectrum=new Uint32Array(w.memory.buffer,w.spectral_ptr(),w.spectral_count()*4).slice();
w.init_spectrum();
check(new Uint32Array(w.memory.buffer,w.spectral_ptr(),w.spectral_count()*4).every((v,i)=>v===savedSpectrum[i]),
  'Repeated spectral initialization preserves every uploaded float bit');
const cacheCases=[
  [.82,1e8,.1,30,.75], [.82,2e8,.1,30,.75], [.82,2e8,.001,30,.75],
  [.82,2e8,.001,30,.4], [.82,2e8,.001,80,.4], [.998,2e8,.001,80,.4],
  [-.9,1e7,0,30,1], [.82,1e8,.1,30,.75],
];
let cacheParity=true;
for(const parameters of cacheCases) {
  const fresh=new WebAssembly.Instance(module).exports;
  w.init_model(...parameters);fresh.init_model(...parameters);
  const reused=new Uint32Array(w.memory.buffer,w.radial_ptr(),w.radial_count()*4);
  const rebuilt=new Uint32Array(fresh.memory.buffer,fresh.radial_ptr(),fresh.radial_count()*4);
  const freshMeta=new Float64Array(fresh.memory.buffer,fresh.metadata_ptr(),11);
  cacheParity&&=reused.every((value,index)=>value===rebuilt[index])&&
    [...meta()].every((value,index)=>index===5||index===6||value===freshMeta[index]);
}
check(cacheParity,'Geometry/thermal cache transitions exactly match independent fresh instances');
console.log(`${checks}/${checks} WASM core checks passed; spectral generation ${spectrumMS.toFixed(2)} ms.`);
