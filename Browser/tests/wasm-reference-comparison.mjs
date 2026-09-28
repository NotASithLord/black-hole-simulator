// Optional source-optimization audit against an archived pre-change WASM core.
// Run: node Browser/tests/wasm-reference-comparison.mjs path/to/reference.wasm
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
if(!process.argv[2]) throw Error('Supply a reference WASM file to compare against.');
const create=async filename=>new WebAssembly.Instance(new WebAssembly.Module(await fs.readFile(filename))).exports;
const old=await create(process.argv[2]), current=await create(path.join(root,'Browser/public/core.wasm'));
let maxRadialRelative=0,maxMetadataRelative=0,radialChangedFloats=0,radialFloats=0,cases=0;
const meta=w=>new Float64Array(w.memory.buffer,w.metadata_ptr(),11);
for(const spin of [-.9999,-.9,0,.82,.998,.9999]) {
  for(const outer of [30,80,100000]) for(const [mass,mdot,height] of [[1e7,.001,.75],[1e8,.1,.4],[1e9,1,1]]) {
    assert.equal(old.init_model(spin,mass,mdot,outer,height),0);
    assert.equal(current.init_model(spin,mass,mdot,outer,height),0);
    const a=new Float32Array(old.memory.buffer,old.radial_ptr(),old.radial_count()*4);
    const b=new Float32Array(current.memory.buffer,current.radial_ptr(),current.radial_count()*4);
    for(let i=0;i<a.length;i++) {
      assert.ok(Number.isFinite(b[i]));
      maxRadialRelative=Math.max(maxRadialRelative,Math.abs(a[i]-b[i])/Math.max(1e-30,Math.abs(a[i])));
      radialChangedFloats+=a[i]!==b[i];radialFloats++;
    }
    for(let i=0;i<11;i++) maxMetadataRelative=Math.max(maxMetadataRelative,Math.abs(meta(old)[i]-meta(current)[i])/Math.max(1e-30,Math.abs(meta(old)[i])));
    cases++;
  }
}
old.init_spectrum();current.init_spectrum();
const a=new Float32Array(old.memory.buffer,old.spectral_ptr(),old.spectral_count()*4);
const b=new Float32Array(current.memory.buffer,current.spectral_ptr(),current.spectral_count()*4);
let maxSpectralRelative=0,spectralChangedFloats=0;
for(let i=0;i<a.length;i++) {
  assert.ok(Number.isFinite(b[i]));
  maxSpectralRelative=Math.max(maxSpectralRelative,Math.abs(a[i]-b[i])/Math.max(1e-30,Math.abs(a[i])));
  spectralChangedFloats+=a[i]!==b[i];
}
assert.ok(maxRadialRelative<3e-7,'Radial output must stay within a few f32 ulps of pre-change double quadrature');
assert.ok(maxMetadataRelative<1e-11,'Double physical metadata must retain reference precision');
assert.ok(maxSpectralRelative<3e-7,'Spectral output must stay within a few f32 ulps of pre-change CIE integration');
console.log(JSON.stringify({passed:true,cases,radialFloats,radialChangedFloats,maxRadialRelative,
  maxMetadataRelative,spectralFloats:a.length,spectralChangedFloats,maxSpectralRelative},null,2));
