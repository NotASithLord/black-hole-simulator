#!/usr/bin/env node
/**
 * CPU-only WGSL parsing and semantic validation, with pinned Naga/WASI.
 * This does not create a GPU device, launch a browser, or execute shaders.
 * First use downloads the fixed compiler archive; subsequent runs are offline.
 * Upstream: https://github.com/ihasq/naga-wasi-cli (MIT OR Apache-2.0).
 * The upstream JavaScript wrapper is not executed. WASI receives only a scratch
 * directory containing shader copies, no environment variables or root access.
 */
import {createHash} from 'node:crypto';
import {mkdir, mkdtemp, open, readFile, writeFile} from 'node:fs/promises';
import {dirname, join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {gunzipSync} from 'node:zlib';
import {WASI} from 'node:wasi';

const workspace = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const packageName = 'naga-wasi-cli-0.1.0.tgz';
const archiveURL = `https://registry.npmjs.org/naga-wasi-cli/-/${packageName}`;
const integrity = 'MUqUe+Xu2eRbRf8UCgbXSHoGx3P8PF4rjuD2Q1EonNFfvT57iYcVnbZQi0pIlA2GxHA+K4X8Q9CKxjqBnFW7EA==';
const cacheDirectory = join(workspace, 'work', 'wgsl-review');

function withoutComments(source) {
  let clean=''; let commentDepth=0;
  for(let i=0;i<source.length;i++) {
    const pair=source.slice(i,i+2);
    if(commentDepth) {
      if(pair==='/*') { commentDepth++; i++; }
      else if(pair==='*/') { commentDepth--; i++; }
      else if(source[i]==='\n') clean+='\n';
    } else if(pair==='/*') { commentDepth=1; clean+=' '; i++; }
    else if(pair==='//') {
      while(i<source.length && source[i]!=='\n') i++;
      clean+='\n';
    } else { clean+=source[i]; }
  }
  return clean;
}

function checkFiniteLiteralBitcasts(source) {
  // Tint rejects a constant bitcast producing NaN or infinity; the pinned
  // Naga validator accepts it. Guard literal integer-to-f32 conversions.
  // Runtime bitcasts used by compensated arithmetic are intentionally allowed.
  // IEEE-754 binary32 has a nonfinite value exactly when all exponent bits are 1.
  const expression=/\bbitcast\s*<\s*f32\s*>\s*\(\s*((?:\(\s*)*)(-?)\s*(0x[\da-f]+|\d+)[iu]?\s*((?:\)\s*)*)\)/gi;
  for(const match of withoutComments(source).matchAll(expression)) {
    if((match[1].match(/\(/g)??[]).length !== (match[4].match(/\)/g)??[]).length) continue;
    const bits=BigInt.asUintN(32,BigInt(match[3])*(match[2] ? -1n : 1n));
    if((bits&0x7f800000n)===0x7f800000n) {
      throw Error('Non-finite literal f32 bitcast: WGSL constant expressions cannot produce NaN or infinity.');
    }
  }
}

function checkOperatorGrouping(source) {
  // Naga 24 and 30 accept some arithmetic/bitwise mixtures rejected by Tint
  // and WGSL's unary-only bitwise operands. Cover this known compiler gap.
  // This is a narrow grammar guard; Naga still performs parsing/type checking.
  // https://www.w3.org/TR/WGSL/#operator-precedence-associativity
  const tokens=withoutComments(source).match(/0x[\da-f]+[iu]?|(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?[fhiu]?|[A-Za-z_]\w*|<<=|>>=|<<|>>|[+\-*/%^&|=<>!]=|&&|\|\||\+\+|--|[^\s]/gi)??[];
  const fresh=()=>({arithmetic:false,bitwise:false,value:false});
  const stack=[fresh()];
  for(const token of tokens) {
    let state=stack[stack.length-1];
    if(['(', '[', '{'].includes(token)) { stack.push(fresh()); continue; }
    if([')', ']', '}'].includes(token)) {
      if(stack.length>1) stack.pop();
      stack[stack.length-1].value=token!=='}'; continue;
    }
    if([',',';','=','+=','-=','*=','/=','%=','^=','&=','|=','<<=','>>='].includes(token)) {
      stack[stack.length-1]=fresh(); continue;
    }
    if(['+','-','*','/','%','&','^','|'].includes(token)) {
      if(state.value) {
        if(['&','^','|'].includes(token)) state.bitwise=true;
        else state.arithmetic=true;
        if(state.arithmetic && state.bitwise) {
          throw Error('Arithmetic used with a bitwise operator requires explicit operand parentheses in WGSL.');
        }
      }
      state.value=false; continue;
    }
    if(['<<','>>','<','>','<=','>=','==','!=','&&','||','!', '~',':','return'].includes(token)) {
      state.value=false; continue;
    }
    if(token!=='.' && token!=='@') state.value=true;
  }
}

function verifyArchive(bytes) {
  if(createHash('sha512').update(bytes).digest('base64') !== integrity) {
    throw Error('Pinned WGSL compiler archive failed SHA-512 integrity verification.');
  }
}

async function compilerBytes() {
  await mkdir(cacheDirectory, {recursive:true});
  const cachedArchive = join(cacheDirectory, packageName);
  let bytes;
  try { bytes = await readFile(cachedArchive); }
  catch(error) {
    if(error.code !== 'ENOENT') throw error;
    console.log('Downloading pinned CPU-only WGSL validator (naga-wasi-cli 0.1.0)…');
    const response = await fetch(archiveURL, {signal:AbortSignal.timeout(30_000)});
    if(!response.ok) throw Error(`WGSL compiler download failed: HTTP ${response.status}`);
    bytes = Buffer.from(await response.arrayBuffer());
    verifyArchive(bytes);
    await writeFile(cachedArchive, bytes);
  }
  verifyArchive(bytes);
  // Read one known regular tar member in memory. No package scripts, archive
  // extraction paths, symlinks, or other bundled executables are used.
  const tar = gunzipSync(bytes, {maxOutputLength:8*1024*1024});
  for(let offset=0; offset+512<=tar.length;) {
    const header = tar.subarray(offset, offset+512);
    const name = header.subarray(0,100).toString('utf8').split('\0')[0];
    if(!name) break;
    const size = Number.parseInt(header.subarray(124,136).toString('ascii').replace(/\0/g,'').trim(),8);
    if(!Number.isSafeInteger(size) || size<0 || offset+512+size>tar.length) {
      throw Error('Malformed pinned compiler archive.');
    }
    if(name==='package/wasi/naga.wasm' && (header[156]===0 || header[156]===48)) {
      return tar.subarray(offset+512,offset+512+size);
    }
    offset+=512+Math.ceil(size/512)*512;
  }
  throw Error('Pinned compiler archive does not contain naga.wasm.');
}

async function validate(module, directory, filename) {
  try {
    const source=await readFile(join(directory,filename),'utf8');
    checkFiniteLiteralBitcasts(source);
    checkOperatorGrouping(source);
  }
  catch(error) { return {code:1,diagnostic:error.message}; }
  const logPath=join(directory,`${filename}.log`);
  const log=await open(logPath,'w');
  let code;
  try {
    const wasi=new WASI({
      version:'preview1', args:['naga',`/shaders/${filename}`], env:{},
      preopens:{'/shaders':directory}, stdout:log.fd, stderr:log.fd, returnOnExit:true,
    });
    const instance=await WebAssembly.instantiate(module,{wasi_snapshot_preview1:wasi.wasiImport});
    code=wasi.start(instance)??0;
  } finally { await log.close(); }
  return {code, diagnostic:await readFile(logPath,'utf8')};
}

async function main() {
  const module=await WebAssembly.compile(await compilerBytes());
  const scratch=await mkdtemp(join(cacheDirectory,'run-'));
  // These regressions prove that the validation path rejects errors seen in
  // browser reports, plus an ordinary semantic type error. They are shader
  // inputs for the compiler only; no entry point is ever executed.
  const fixtures=[
    {name:'valid-control',pass:true,source:'@compute @workgroup_size(1) fn main() {}'},
    {name:'valid-parenthesized-bitwise',pass:true,source:'fn mixed(x:u32,y:u32)->u32 { return (x*2u)^(y*3u); }'},
    {name:'valid-finite-bitcast',pass:true,source:'fn largestFinite()->f32 { return bitcast<f32>(0x7f7fffffu); }'},
    {name:'reserved-word',pass:false,source:'fn crossing(target:f32)->f32 { return target; }'},
    {name:'bitwise-precedence',pass:false,source:'fn mixed(x:u32,y:u32)->u32 { return x*2u^y*3u; }'},
    {name:'return-type',pass:false,source:'fn wrong()->f32 { return vec2<f32>(1.0,2.0); }'},
    {name:'nan-bitcast',pass:false,diagnosticIncludes:'Non-finite literal f32 bitcast',source:'fn invalid()->f32 { return bitcast<f32>(0x7fc00000u); }'},
    {name:'infinite-bitcast',pass:false,diagnosticIncludes:'Non-finite literal f32 bitcast',source:'fn invalid()->f32 { return bitcast<f32>(0x7f800000u); }'},
  ];
  for(const fixture of fixtures) {
    const filename=`${fixture.name}.wgsl`;
    await writeFile(join(scratch,filename),fixture.source);
    const result=await validate(module,scratch,filename);
    if((result.code===0)!==fixture.pass || (fixture.diagnosticIncludes && !result.diagnostic.includes(fixture.diagnosticIncludes))) {
      throw Error(`WGSL validator self-check failed: ${fixture.name}\n${result.diagnostic}`);
    }
  }
  console.log(`WGSL validator self-check: ${fixtures.filter(f=>f.pass).length} valid inputs accepted; ${fixtures.filter(f=>!f.pass).length} invalid inputs rejected.`);
  for(const filename of ['kerr.wgsl','camera.wgsl']) {
    const source=await readFile(join(workspace,'Browser','src',filename));
    await writeFile(join(scratch,filename),source);
    const result=await validate(module,scratch,filename);
    if(result.code!==0) throw Error(`${filename} failed WGSL validation:\n${result.diagnostic}`);
    console.log(`WGSL parse + semantic validation, operator grouping and finite literal bitcasts passed: ${filename}`);
  }
  console.log('Offline source validation complete; browser compilation and GPU execution remain separate checks.');
}

main().catch(error=>{ console.error(error.message); process.exitCode=1; });
