import {mkdir, copyFile, cp, stat, readFile, readdir, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {execFileSync} from 'node:child_process';

const root = fileURLToPath(new URL('..', import.meta.url));
// Reject invalid shader syntax/types before publishing files to the local app.
execFileSync(process.execPath,[path.join(root,'tools/check-wgsl.mjs')],{stdio:'inherit'});
execFileSync(process.execPath,[path.join(root,'tests/shared-swift-source.mjs')],{stdio:'inherit'});
const dist = path.resolve(root, '../outputs/BlackHoleBrowser');
await mkdir(dist, {recursive:true});
for (const file of ['index.html','style.css']) await copyFile(path.join(root,file),path.join(dist,file));
await cp(path.join(root,'src'),path.join(dist,'src'),{recursive:true});
await copyFile(path.join(root,'public/core.wasm'),path.join(dist,'core.wasm'));
await copyFile(path.join(root,'public/core-build.json'),path.join(dist,'core-build.json'));
await mkdir(path.join(dist,'fixtures'),{recursive:true});
for (const [from,to] of [['Tests/physics_cases.json','physics_cases.json'],['Browser/tests/fixtures/native-reference.json','native-reference.json']]) {
  await copyFile(path.resolve(root,'..',from),path.join(dist,'fixtures',to));
}
await copyFile(path.resolve(root,'../LICENSE'),path.join(dist,'LICENSE'));
await copyFile(path.resolve(root,'../THIRD_PARTY_NOTICES.md'),path.join(dist,'THIRD_PARTY_NOTICES.md'));
await cp(path.resolve(root,'../licenses'),path.join(dist,'licenses'),{recursive:true});
try { await copyFile(path.join(root,'README.md'),path.join(dist,'README.md')); } catch (e) {if(e.code!=='ENOENT') throw e;}
await copyFile(path.join(root,'PERFORMANCE.md'),path.join(dist,'PERFORMANCE.md'));
const wasm=await stat(path.join(dist,'core.wasm'));
// Identify the exact deployed workload so different engines/builds cannot be
// accidentally compared using a stale report. No machine/user paths included.
const versioned=['index.html','style.css','core.wasm','core-build.json',
  ...(await readdir(path.join(dist,'src'))).filter(name=>/\.(js|wgsl)$/.test(name)).map(name=>`src/${name}`),
  'fixtures/physics_cases.json','fixtures/native-reference.json'].sort();
const digest=createHash('sha256'),files={};
for(const name of versioned) {
  const bytes=await readFile(path.join(dist,name));
  const sha256=createHash('sha256').update(bytes).digest('hex');
  files[name]={bytes:bytes.length,sha256};digest.update(`${name}\0${sha256}\n`);
}
await writeFile(path.join(dist,'build.json'),JSON.stringify({schema:1,sourceDigest:digest.digest('hex'),files},null,2)+'\n');
console.log(`Built outputs/BlackHoleBrowser; compiled WASM ${wasm.size.toLocaleString()} bytes.`);
