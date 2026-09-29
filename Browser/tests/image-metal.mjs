#!/usr/bin/env node
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile,writeFile,mkdtemp,access} from 'node:fs/promises';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {gunzipSync} from 'node:zlib';
import {spawnSync} from 'node:child_process';
import {WASI} from 'node:wasi';
import {KerrRenderer} from '../src/renderer.js';

// Execute production browser transport/material shaders on a native Metal GPU.
// This is an optional macOS numerical/image regression, NOT browser automation,
// presentation validation, or evidence about browser/GPU performance.
// Run check:shaders first to populate the pinned compiler cache.
assert.equal(process.platform,'darwin','This optional test needs a macOS Metal GPU.');
const root=resolve(dirname(fileURLToPath(import.meta.url)),'../..');
const archive=await readFile(join(root,'work/wgsl-review/naga-wasi-cli-0.1.0.tgz'));
assert.equal(createHash('sha512').update(archive).digest('base64'),
  'MUqUe+Xu2eRbRf8UCgbXSHoGx3P8PF4rjuD2Q1EonNFfvT57iYcVnbZQi0pIlA2GxHA+K4X8Q9CKxjqBnFW7EA==');
const tar=gunzipSync(archive);let compiler;
for(let offset=0;offset+512<=tar.length;) {
  const header=tar.subarray(offset,offset+512),name=header.subarray(0,100).toString().split('\0')[0];
  if(!name)break;
  const size=Number.parseInt(header.subarray(124,136).toString().replace(/\0/g,'').trim(),8);
  assert(Number.isSafeInteger(size)&&size>=0&&offset+512+size<=tar.length);
  if(name==='package/wasi/naga.wasm')compiler=tar.subarray(offset+512,offset+512+size);
  offset+=512+Math.ceil(size/512)*512;
}
assert(compiler,'Pinned Naga compiler member exists');
const scratch=await mkdtemp(join(root,'work/image-portability-'));
const shader=await readFile(join(root,'Browser/src/kerr.wgsl'),'utf8');
await writeFile(join(scratch,'kerr.wgsl'),shader);
const wasi=new WASI({version:'preview1',args:['naga','--metal-version','2.4','/shaders/kerr.wgsl','/shaders/kerr.metal'],
  env:{},preopens:{'/shaders':scratch},returnOnExit:true});
const compilerInstance=await WebAssembly.instantiate(await WebAssembly.compile(compiler),{wasi_snapshot_preview1:wasi.wasiImport});
assert.equal(wasi.start(compilerInstance)??0,0,'Production WGSL translates to Metal');
const translated=await readFile(join(scratch,'kerr.metal'),'utf8');
function entryPoint(name,bindings) {
  const start=translated.indexOf(`kernel void ${name}(`),open=translated.indexOf('{',start);
  assert(start>=0&&open>start);
  let end=open+1,depth=1;
  while(depth) {assert(end<translated.length);const character=translated[end++];if(character==='{')depth++;if(character==='}')depth--;}
  let index=0;
  const kernel=translated.slice(start,end).replace(/\[\[user\(fake0\)\]\]/g,()=>`[[${bindings[index++]}]]`);
  assert.equal(index,bindings.length,`${name} host ABI is unchanged`);
  return kernel;
}
// Preserve every generated helper/function body verbatim. The CLI has no host
// binding map, so only its placeholder entry-point resource attributes change.
const metal=translated.slice(0,translated.indexOf('kernel void traceGeometry('))+
  entryPoint('traceGeometry',['buffer(0)','buffer(1)','buffer(2)'])+'\n'+
  entryPoint('shadeGeometry',['buffer(0)','buffer(1)','buffer(2)','buffer(3)','texture(0)','buffer(4)']);
await writeFile(join(scratch,'image.metal'),metal);
const wasm=await readFile(join(root,'Browser/public/core.wasm'));
const {instance}=await WebAssembly.instantiate(wasm,{}),core=instance.exports;
assert.equal(core.abi_version(),1);core.init_spectrum();
const spectrum=new Uint8Array(core.memory.buffer,core.spectral_ptr(),core.spectral_count()*16).slice();
await writeFile(join(scratch,'spectrum.bin'),spectrum);
const base={mass:1e8,accretion:.1,outerRadius:30,spin:.82,cameraDistance:80,fov:.48,
  lookYaw:0,lookPitch:0,diagnosticMode:false,energy:false,appearance:'radiant',rotation:true,
  paletteTemperature:7000};
const configurations=[
  {id:'max',width:240,height:160,samples:4,zeroUnresolved:true,
    settings:{...base,quality:'max',thickness:0,glowStrength:0,cameraYaw:-.28,cameraPitch:.06,
      materialStrength:.9,fluctuations:0,playback:4000}},
  {id:'auto',width:480,height:320,samples:1,zeroUnresolved:false,
    settings:{...base,quality:'auto',thickness:.75,glowStrength:.28,cameraYaw:0,cameraPitch:.12,
      materialStrength:.85,fluctuations:.06,playback:1000}},
];
for(const configuration of configurations) {
  // Use the actual host ABI writer, not a second hand-written uniform model.
  const renderer=new KerrRenderer({});renderer.core=core;
  Object.assign(renderer.settings,configuration.settings);
  renderer.width=configuration.width;renderer.height=configuration.height;renderer.samples=configuration.samples;
  renderer.updateModel();
  await writeFile(join(scratch,`${configuration.id}-disk.bin`),
    new Uint8Array(core.memory.buffer,core.radial_ptr(),core.radial_count()*16).slice());
  for(const time of [0,8000]) await writeFile(join(scratch,`${configuration.id}-${time}.bin`),
    new Uint8Array(renderer.uniforms(time)).slice());
}
await writeFile(join(scratch,'fixtures.json'),JSON.stringify({configurations,
  shaderSHA256:createHash('sha256').update(shader).digest('hex'),
  wasmSHA256:createHash('sha256').update(wasm).digest('hex')}));
const flags=[];
try {
  const include='/Library/Developer/CommandLineTools/usr/include/swift/';
  await access(`${include}bridging.modulemap`);await access(`${include}module.modulemap`);
  const overlay=join(scratch,'toolchain-overlay.json');
  await writeFile(overlay,JSON.stringify({version:0,roots:[{type:'file',name:`${include}module.modulemap`,
    'external-contents':join(root,'BuildSupport/empty.modulemap')}]}));
  flags.push('-vfsoverlay',overlay,'-Xcc','-ivfsoverlay','-Xcc',overlay);
} catch {}
const build=spawnSync('swiftc',[...flags,join(root,'Browser/tests/image-metal.swift'),'-o',join(scratch,'validate-image')],{encoding:'utf8'});
assert.equal(build.status,0,build.stderr);
let failed=false;
for(const mode of ['fast','safe']) {
  const run=spawnSync(join(scratch,'validate-image'),[scratch,mode],{encoding:'utf8',timeout:180000});
  if(run.stderr)process.stderr.write(run.stderr);
  process.stdout.write(run.stdout);
  await writeFile(join(scratch,`${mode}.json`),run.stdout);
  if(run.status!==0)failed=true;
}
console.log(`Naga→Metal fixed-image results (not a browser test): ${scratch}`);
if(failed)process.exitCode=1;
