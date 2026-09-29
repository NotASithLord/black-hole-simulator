#!/usr/bin/env node
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile,writeFile,mkdtemp,access} from 'node:fs/promises';
import {resolve,join,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {gunzipSync} from 'node:zlib';
import {spawnSync} from 'node:child_process';
import {WASI} from 'node:wasi';

// macOS-only execution check of the actual WGSL through the same Naga→Metal
// compiler family as Firefox. It deliberately enables Metal fast math, then
// repeats with strict arithmetic. It does not control a browser or prove API
// compatibility. Run check:shaders first to populate the pinned compiler cache.
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
const scratch=await mkdtemp(join(root,'work/wide-portability-'));
const baseline=process.argv.includes('--baseline');
let input=await readFile(join(root,'Browser/src/kerr.wgsl'),'utf8');
if(baseline) {
  // Reproduce the original arithmetic after the fix has been committed too:
  // keep all current transport equations and replace only these primitives.
  const start=input.indexOf('fn ds('),end=input.indexOf('fn dd(');
  assert(start>=0&&end>start);
  input=input.slice(0,start)+await readFile(join(root,'Browser/tests/fixtures/compensated-reference.wgsl'),'utf8')+input.slice(end);
}
assert(input.includes('fn validateKerr('));
await writeFile(join(scratch,'kerr.wgsl'),input);
const wasi=new WASI({version:'preview1',args:['naga','--metal-version','2.4','/shaders/kerr.wgsl','/shaders/kerr.metal'],
  env:{},preopens:{'/shaders':scratch},returnOnExit:true});
const instance=await WebAssembly.instantiate(await WebAssembly.compile(compiler),{wasi_snapshot_preview1:wasi.wasiImport});
assert.equal(wasi.start(instance)??0,0,'Production WGSL translates to Metal');
const translated=await readFile(join(scratch,'kerr.metal'),'utf8');
const kernelStart=translated.indexOf('kernel void validateKerr('),open=translated.indexOf('{',kernelStart);
let end=open+1,depth=1;
while(depth){assert(end<translated.length);const c=translated[end++];if(c==='{')depth++;if(c==='}')depth--;}
let binding=0;
const kernel=translated.slice(kernelStart,end).replace(/\[\[user\(fake0\)\]\]/g,()=>`[[buffer(${binding++})]]`);
assert.equal(binding,4,'Assign uniform/input/output/array-size bindings only');
// Naga CLI has no host binding map. Retain its function bodies verbatim, omit
// unused entry points, and assign the four Metal ABI buffer indices above.
const arithmeticKernel=`
kernel void wideArithmeticValidation(uint index [[thread_position_in_grid]],
    device metal::float4 const* inputs [[buffer(0)]], device metal::float4* outputs [[buffer(1)]]) {
    metal::float4 input=inputs[index];
    metal::float2 sum=da(input.xy,input.zw), product=dm(input.xy,input.zw);
    outputs[index]=metal::float4(sum,product);
}
`;
await writeFile(join(scratch,'validation.metal'),translated.slice(0,translated.indexOf('kernel void traceGeometry('))+kernel+arithmeticKernel);
const flags=[];
try {
  const include='/Library/Developer/CommandLineTools/usr/include/swift/';
  await access(`${include}bridging.modulemap`);await access(`${include}module.modulemap`);
  const overlay=join(scratch,'toolchain-overlay.json');
  await writeFile(overlay,JSON.stringify({version:0,roots:[{type:'file',name:`${include}module.modulemap`,
    'external-contents':join(root,'BuildSupport/empty.modulemap')}]}));
  flags.push('-vfsoverlay',overlay,'-Xcc','-ivfsoverlay','-Xcc',overlay);
} catch {}
const compile=spawnSync('swiftc',[...flags,join(root,'Browser/tests/precision-metal.swift'),'-o',join(scratch,'validate')],{encoding:'utf8'});
assert.equal(compile.status,0,compile.stderr);
let failed=false;
for(const mode of ['fast','safe']) {
  const run=spawnSync(join(scratch,'validate'),[join(scratch,'validation.metal'),join(root,'Tests/physics_cases.json'),
    join(root,'Browser/tests/fixtures/native-reference.json'),mode],{encoding:'utf8',timeout:120000});
  if(run.stderr)process.stderr.write(run.stderr);
  process.stdout.write(run.stdout);
  await writeFile(join(scratch,`${mode}.json`),run.stdout);
  if(baseline&&mode==='fast') {
    const result=JSON.parse(run.stdout);
    const cases=JSON.parse(await readFile(join(root,'Tests/physics_cases.json'),'utf8')).cases;
    const expected=cases.filter(row=>/^boundary-a.*-scale(?:0\.9999|1\.0001)$/.test(row.id)).map(row=>row.id).sort();
    assert.equal(expected.length,12,'Baseline target contains the twelve near-critical rays');
    assert.deepEqual(result.failures.map(row=>row.id).sort(),expected,'Original fast-math compensation reproduces exactly the boundary failures');
    assert.equal(result.matched,result.rays-12);
    assert.equal(run.status,1,'The unchanged positive test rejects the broken baseline');
  } else if(run.status!==0)failed=true;
}
console.log(`Naga→Metal ${baseline?'baseline':'current'} results: ${scratch}`);
if(failed)process.exitCode=1;
