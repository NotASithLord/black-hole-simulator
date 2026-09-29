import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { mkdir, readFile, readdir, access, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const browser = path.join(root, 'Browser');
const toolDirectory = path.join(root, 'work/wasm-toolchain');
const buildDirectory = path.join(root, 'work/swift-wasm-build');
// Official release digests, pinned rather than resolving "latest" at build time.
const hashes = {
  'arm64-macos': '85c997a2665ead91673b5bb88b7d0df3fc8900df3bfa244f720d478187bbdc78',
  'x86_64-macos': '18f3f201ba9734e6a4455b0b6410690395a55e9ffa9f6f5066f66083a94b93b3',
  'arm64-linux': '4f98ee738c7abb45c81a94d1461fc53cc569d1cd01498951c8184d841a027844',
  'x86_64-linux': '0ba8b5bfaeb2adf3f29bab5841d76cf5318ab8e1642ea195f88baba1abd47bce',
};
const platform = process.platform === 'darwin' ? 'macos' : process.platform;
const architecture = process.arch === 'x64' ? 'x86_64' : process.arch;
const key = `${architecture}-${platform}`;
const distribution = `wasi-sdk-33.0-${key}`;
const sdk = process.env.WASI_SDK_PATH || path.join(toolDirectory, distribution);
const linker = path.join(sdk, 'bin/wasm-ld');
const exists = async p => { try { await access(p); return true; } catch { return false; } };
function run(command, args, capture = false) {
  const result = spawnSync(command, args, { cwd: root, stdio: capture ? 'pipe' : 'inherit', encoding: 'utf8' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} exited ${result.status}${capture ? `\n${result.stderr}` : ''}`);
  return result.stdout;
}
async function sha256(file) {
  const hash = createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}
async function downloadVerified(url, archive, expectedHash) {
  if (!(await exists(archive))) {
    // Do not leave a partial download looking like a complete cached archive.
    const partial = `${archive}.download`;
    run('curl', ['-fL', '--retry', '2', '--connect-timeout', '20', '-o', partial, url]);
    if (await sha256(partial) !== expectedHash) throw new Error('Compiler archive checksum mismatch.');
    await rename(partial, archive);
  } else if (await sha256(archive) !== expectedHash) {
    throw new Error(`Compiler archive checksum mismatch: ${path.basename(archive)}`);
  }
}

if (!(await exists(linker))) {
  if (process.env.WASI_SDK_PATH) throw new Error(`No wasm-ld in WASI_SDK_PATH: ${sdk}`);
  if (!hashes[key]) throw new Error(`Automatic compiler download unsupported for ${key}; set WASI_SDK_PATH.`);
  await mkdir(toolDirectory, { recursive: true });
  const archive = path.join(toolDirectory, `${distribution}.tar.gz`);
  const url = `https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-33/${distribution}.tar.gz`;
  console.log(`Preparing pinned WASI SDK 33 linker and math library in work/ (${key}).`);
  await downloadVerified(url, archive, hashes[key]);
  run('tar', ['-xzf', archive, '-C', toolDirectory]);
}

// Apple/Xcode toolchains need not contain the freestanding WebAssembly standard
// library. Use the official Swift.org distribution, extracted locally rather
// than installed globally. The package supports both Apple Silicon and Intel.
const swiftVersion = '6.4.0';
const swiftPackageHash = '8fd03185b98fe27f54a54631c2449decf75d5b466ce8e34abbd414141063c6aa';
const swiftPackage = `swift-${swiftVersion}-RELEASE-osx.pkg`;
const swiftExtracted = path.join(toolDirectory, `swift-${swiftVersion}-extracted`);
const defaultCompiler = path.join(swiftExtracted,
  `swift-${swiftVersion}-RELEASE-osx-package.pkg/Payload/usr/bin/swiftc`);
const compiler = process.env.SWIFT_WASM_COMPILER_PATH ||
  (process.env.SWIFT_TOOLCHAIN_PATH ? path.join(process.env.SWIFT_TOOLCHAIN_PATH, 'usr/bin/swiftc') : defaultCompiler);
if (!(await exists(compiler))) {
  if (process.env.SWIFT_WASM_COMPILER_PATH || process.env.SWIFT_TOOLCHAIN_PATH) {
    throw new Error(`Swift compiler not found: ${compiler}`);
  }
  if (process.platform !== 'darwin') {
    throw new Error('Automatic Swift toolchain download is supported on macOS. Set SWIFT_WASM_COMPILER_PATH to an official Swift 6.4 compiler with Embedded WebAssembly support.');
  }
  await mkdir(toolDirectory, { recursive: true });
  const archive = path.join(toolDirectory, swiftPackage);
  const url = `https://download.swift.org/swift-${swiftVersion}-release/xcode/swift-${swiftVersion}-RELEASE/${swiftPackage}`;
  console.log(`Preparing official Swift ${swiftVersion} in work/ (no global installation).`);
  await downloadVerified(url, archive, swiftPackageHash);
  // Verify the signed, notarized Swift.org installer before reading its payload.
  run('pkgutil', ['--check-signature', archive]);
  if (await exists(swiftExtracted)) {
    throw new Error(`Incomplete Swift extraction at ${swiftExtracted}; move that directory aside before rebuilding.`);
  }
  run('pkgutil', ['--expand-full', archive, swiftExtracted]);
}

const exports = ['radial_ptr', 'spectral_ptr', 'metadata_ptr', 'radial_count', 'spectral_count',
  'abi_version', 'init_model', 'init_spectrum', 'isco', 'orbital_period', 'advance_clock',
  'clock_seconds', 'reset_clock', 'adaptive_scale'];
await mkdir(buildDirectory, { recursive: true });
const sharedDirectory = path.join(root, 'Sources/BlackHolePhysics');
const sources = (await readdir(sharedDirectory)).filter(name => name.endsWith('.swift')).sort()
  .map(name => path.join(sharedDirectory, name));
if (sources.length === 0) throw new Error('Shared Swift physics sources are missing.');
sources.push(path.join(browser, 'core/WasmExports.swift'));
const object = path.join(buildDirectory, 'physics.o');
const candidate = path.join(buildDirectory, 'core.wasm');
const validationCandidate = path.join(buildDirectory, 'core-validation.wasm');
const linkMap = path.join(buildDirectory, 'core.map');
const compilerVersionOutput = run(compiler, ['--version'], true).trim();
const compilerVersion = compilerVersionOutput.match(/^(?:Apple )?Swift version [\d][\w.-]*(?: \([\w .,+()-]+\))?/)?.[0];
const compilerHostTarget = compilerVersionOutput.match(/^Target: ([\w.-]+)$/m)?.[1];
const linkerVersion = run(linker, ['--version'], true).match(/^LLD [\d][\w.-]*/)?.[0];
if (!compilerVersion || !compilerHostTarget || !linkerVersion) throw new Error('Unrecognized compiler/linker version output.');
console.log(compilerVersion);
// -no-allocations is enforced by the compiler. Safe Swift arithmetic remains
// enabled; neither unchecked optimization nor relaxed floating point is used.
const compilerFlags = ['-target', 'wasm32-unknown-none-wasm',
  '-enable-experimental-feature', 'Embedded', '-enable-experimental-feature', 'Extern',
  '-wmo', '-O', '-no-allocations', '-parse-as-library', '-Xcc', '-msimd128',
  // Freestanding WASM has no entropy host for a C stack canary. Keep Swift's
  // bounds/overflow checks and WebAssembly's sandbox; omit only that canary.
  '-Xfrontend', '-disable-stack-protector',
  '-file-prefix-map', '<project>=.', '-module-name', 'BlackHolePhysics'];
run(compiler, [...compilerFlags.map(value => value.replace('<project>', root)),
  ...sources, '-c', '-o', object]);
// SDK 33 keeps musl's ordinary math routines in libc.a (libm.a is an empty
// compatibility archive). The linker takes only referenced members, with no
// WASI entry point, allocator, entropy constructor or host runtime.
const linkerFlags = ['--no-entry', '--strip-all', '--export-memory',
  '--initial-memory=262144', '--max-memory=262144', '-z', 'stack-size=65536',
  ...exports.map(name => `--export=${name}`)];
const library = path.join(sdk, 'share/wasi-sysroot/lib/wasm32-wasip1/libc.a');
const linkArguments = [...linkerFlags, `--Map=${linkMap}`, object, library];
// Only the validation link exposes the private linker boundary. Keep the
// delivered module's existing JavaScript ABI unchanged.
run(linker, [...linkArguments, '--export=__heap_base', '-o', validationCandidate]);
const bytes = await readFile(validationCandidate);
const module = new WebAssembly.Module(bytes);
if (WebAssembly.Module.imports(module).length) throw new Error('Standalone core unexpectedly requires runtime imports.');
const core = new WebAssembly.Instance(module).exports;
for (const name of exports) if (typeof core[name] !== 'function') throw new Error(`Missing core ABI export: ${name}`);
if (core.abi_version() !== 1 || core.radial_count() !== 4096 || core.spectral_count() !== 2048) {
  throw new Error('Swift core ABI or table sizes changed.');
}
if (!(core.memory instanceof WebAssembly.Memory) || core.memory.buffer.byteLength !== 262144) {
  throw new Error('Swift core must have exactly 256 KiB of initial linear memory.');
}
let growthRejected = false;
try { core.memory.grow(1); } catch { growthRejected = true; }
if (!growthRejected) throw new Error('Swift core must have a fixed, non-growable memory.');
const ranges = [[core.radial_ptr(), 4096 * 16], [core.spectral_ptr(), 2048 * 16], [core.metadata_ptr(), 11 * 8]];
if (core.radial_ptr() !== 110592 || core.metadata_ptr() + 88 !== 256824) {
  throw new Error('The verified fixed Swift storage arena layout changed.');
}
for (const [start, size] of ranges) {
  if (!Number.isInteger(start) || start < core.__heap_base.value || start % 16 !== 0 || start + size > 262144) {
    throw new Error('Swift output storage overlaps linked data/stack, is misaligned, or exceeds fixed memory.');
  }
}
for (let i = 0; i < ranges.length; i++) for (let j = i + 1; j < ranges.length; j++) {
  if (Math.max(ranges[i][0], ranges[j][0]) < Math.min(ranges[i][0] + ranges[i][1], ranges[j][0] + ranges[j][1])) {
    throw new Error('Swift core output buffers overlap.');
  }
}
if (core.init_spectrum() !== 0 || core.init_model(0.82, 1e8, 0.1, 30, 0) !== 0) {
  throw new Error('Swift core initialization smoke test failed.');
}
for (const [start, size] of ranges.slice(0, 2)) {
  if (!new Float32Array(core.memory.buffer, start, size / 4).every(Number.isFinite)) {
    throw new Error('Swift core produced a non-finite GPU table.');
  }
}
const metadata = new Float64Array(core.memory.buffer, core.metadata_ptr(), 11);
if (!metadata.every(Number.isFinite) || !(metadata[0] > 0)) throw new Error('Swift core metadata smoke test failed.');
const sourceHashes = {};
for (const source of sources) sourceHashes[path.relative(root, source)] = await sha256(source);
run(linker, [...linkArguments, '-o', candidate]);
const finalBytes = await readFile(candidate);
const finalModule = new WebAssembly.Module(finalBytes);
const finalExports = WebAssembly.Module.exports(finalModule).map(item => item.name).sort();
if (WebAssembly.Module.imports(finalModule).length ||
    JSON.stringify(finalExports) !== JSON.stringify(['memory', ...exports].sort())) {
  throw new Error('The delivered Swift module must preserve the exact standalone JavaScript ABI.');
}
const finalCore = new WebAssembly.Instance(finalModule).exports;
if (finalCore.memory.buffer.byteLength !== 262144 || finalCore.radial_ptr() !== core.radial_ptr() ||
    finalCore.spectral_ptr() !== core.spectral_ptr() || finalCore.metadata_ptr() !== core.metadata_ptr() ||
    finalCore.init_spectrum() !== 0 || finalCore.init_model(0.82, 1e8, 0.1, 30, 0) !== 0) {
  throw new Error('The final Swift module differs from the validated link.');
}
for (const [start, size] of ranges) {
  if (!Buffer.from(core.memory.buffer, start, size).equals(Buffer.from(finalCore.memory.buffer, start, size))) {
    throw new Error('The final Swift module changed the validated numerical results.');
  }
}
const linkedRuntimeObjects = [...new Set([...(await readFile(linkMap, 'utf8')).matchAll(/libc\.a\(([\w.-]+)\)/g)]
  .map(match => match[1]))].sort();
// A new runtime dependency needs a corresponding license audit before shipping.
const auditedRuntimeObjects = ['__math_divzero.c.obj', '__math_invalid.c.obj', '__math_oflow.c.obj',
  '__math_uflow.c.obj', '__math_xflow.c.obj', 'cbrt.c.obj', 'exit.c.obj', 'exp.c.obj',
  'exp_data.c.obj', 'expm1.c.obj', 'log.c.obj', 'log_data.c.obj'];
if (linkedRuntimeObjects.some(name => !auditedRuntimeObjects.includes(name))) {
  throw new Error('Linked runtime objects changed; review the link map and third-party notices before publishing.');
}
const provenance = {
  schema: 1, language: 'Swift', compilerVersion, compilerHostTarget, compilerFlags,
  linkerVersion, linkerFlags, target: 'wasm32-unknown-none-wasm',
  swiftPackageSHA256: compiler === defaultCompiler ? swiftPackageHash : null,
  wasiSDK: 33, wasiSDKArchiveSHA256: process.env.WASI_SDK_PATH ? null : hashes[key],
  wasiLibcRevision: '161b3195fc2558d2b1ba3eb9ffae3b2b47407623',
  linkedMathArchive: 'wasi-sysroot/lib/wasm32-wasip1/libc.a',
  linkedMathArchiveSHA256: await sha256(library), linkedRuntimeObjects,
  buildScriptSHA256: await sha256(fileURLToPath(import.meta.url)),
  sourceHashes, wasmSHA256: createHash('sha256').update(finalBytes).digest('hex'),
  bytes: finalBytes.length, heapBase: core.__heap_base.value, memoryBytes: 262144,
  maximumMemoryBytes: 262144, stackBytes: 65536,
  fixedArena: { start: core.radial_ptr(), end: core.metadata_ptr() + 88 },
  heapAllocation: false, abiVersion: finalCore.abi_version(),
  radialCount: finalCore.radial_count(), spectralCount: finalCore.spectral_count(),
  exports: WebAssembly.Module.exports(finalModule),
  imports: WebAssembly.Module.imports(finalModule),
};
const provenanceJSON = JSON.stringify(provenance, null, 2) + '\n';
const provenanceCandidate = path.join(buildDirectory, 'provenance.json');
await writeFile(provenanceCandidate, provenanceJSON);
// Publish only after linking, ABI/memory validation and numerical smoke tests.
await mkdir(path.join(browser, 'public'), { recursive: true });
await rename(candidate, path.join(browser, 'public/core.wasm'));
// The source guard rejects a stale/mismatched pair if a process is interrupted
// between these two individually atomic file replacements.
const publicProvenanceCandidate = path.join(buildDirectory, 'core-build.json');
await writeFile(publicProvenanceCandidate, provenanceJSON);
await rename(publicProvenanceCandidate, path.join(browser, 'public/core-build.json'));
console.log(`Built Browser/public/core.wasm from shared Swift (${finalBytes.length.toLocaleString()} bytes, no runtime imports, no heap allocation).`);
