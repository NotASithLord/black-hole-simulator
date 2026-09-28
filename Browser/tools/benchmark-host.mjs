import {performance} from 'node:perf_hooks';
import os from 'node:os';
import {KerrRenderer} from '../src/renderer.js';

// CPU-only microbenchmark, not a browser/GPU FPS result. Same workload before
// and after host changes; run several trials to expose JIT/GC variability.
const renderer=new KerrRenderer({});
renderer.width=640;renderer.height=360;renderer.samples=1;
renderer.meta=new Float64Array([2.8,30,Math.log(2.8),.001,100000,300,10000000,492.55,.12,.05,0]);
let checksum=0;
const iterations=100_000,trials=[];
function trial() {
  const start=performance.now();
  for(let i=0;i<iterations;i++) {
    const buffer=renderer.uniforms(i/60);
    checksum+=new DataView(buffer).getFloat32(8,true);
  }
  return performance.now()-start;
}
trial();
for(let i=0;i<7;i++) trials.push(trial());
const sorted=[...trials].sort((a,b)=>a-b);
console.log(JSON.stringify({scope:'Node host-only uniform packing; not browser or GPU performance',
  node:process.version,cpu:os.cpus()[0]?.model,arch:process.arch,iterations,
  medianMS:sorted[3],trialsMS:trials,checksum},null,2));
