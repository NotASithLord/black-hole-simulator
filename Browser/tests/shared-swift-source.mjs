// Verify that the distributed browser binary belongs to the exact same Swift
// physics sources compiled by the native application. No compiler installation
// or network access is necessary to validate the checked-in artifact.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const read = file => fs.readFile(path.join(root, file));
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
let checks = 0;
function check(condition, description) { assert.ok(condition, description); checks++; console.log(`PASS ${description}`); }
const provenance = JSON.parse(await read('Browser/public/core-build.json'));
check(provenance.schema === 1 && provenance.language === 'Swift' && /Swift version 6\./.test(provenance.compilerVersion),
  'Distributed core records its Swift compiler and provenance schema');
const sharedFiles = (await fs.readdir(path.join(root, 'Sources/BlackHolePhysics')))
  .filter(name => name.endsWith('.swift')).sort().map(name => `Sources/BlackHolePhysics/${name}`);
assert.ok(sharedFiles.length > 0, 'Shared Swift physics source directory is populated');
const expectedSources = [...sharedFiles, 'Browser/core/WasmExports.swift'].sort();
assert.deepEqual(Object.keys(provenance.sourceHashes).sort(), expectedSources,
  'The complete shared Swift core and its ABI adapter are represented in provenance');
for (const file of expectedSources) assert.equal(hash(await read(file)), provenance.sourceHashes[file],
  `${file} changed without rebuilding core.wasm; run npm run build:wasm`);
check(true, 'WASM provenance matches every current shared Swift source byte');

const binary = await read('Browser/public/core.wasm');
check(binary.length === provenance.bytes && hash(binary) === provenance.wasmSHA256,
  'Distributed WASM bytes match the verified Swift build digest');
const module = new WebAssembly.Module(binary);
assert.deepEqual(WebAssembly.Module.imports(module), []);
assert.deepEqual(provenance.imports, []);
// Some engines additionally expose proposal-specific type metadata. Compare
// the portable name/kind interface, not engine-specific reflection fields.
const portableExports = entries => entries.map(({name, kind}) => ({name, kind}));
assert.deepEqual(portableExports(WebAssembly.Module.exports(module)), portableExports(provenance.exports));
check(true, 'Artifact exports match provenance and require no host runtime imports');
const w = new WebAssembly.Instance(module).exports;
check(w.abi_version() === 1 && provenance.abiVersion === 1 &&
  w.radial_count() === 4096 && provenance.radialCount === 4096 &&
  w.spectral_count() === 2048 && provenance.spectralCount === 2048,
  'Shared Swift build preserves the existing browser ABI and table dimensions');
check(provenance.memoryBytes === 262144 && provenance.stackBytes === 65536 &&
  w.memory.buffer.byteLength === provenance.memoryBytes,
  'Swift core retains the fixed 256 KiB memory and 64 KiB stack budget');
assert.throws(() => w.memory.grow(1), RangeError);
check(true, 'Swift memory cannot grow after initialization');
const ranges = [[w.radial_ptr(), 4096 * 16], [w.spectral_ptr(), 2048 * 16], [w.metadata_ptr(), 11 * 8]];
for (const [start, size] of ranges) {
  assert.ok(Number.isInteger(start) && start % 16 === 0 && start >= provenance.heapBase &&
    start + size <= provenance.memoryBytes, 'Output arena is aligned and separate from linker data/stack');
}
for (let i = 0; i < ranges.length; i++) for (let j = i + 1; j < ranges.length; j++) {
  assert.ok(Math.max(ranges[i][0], ranges[j][0]) >= Math.min(ranges[i][0] + ranges[i][1], ranges[j][0] + ranges[j][1]),
    'Output tables must not overlap');
}
check(true, 'Browser output buffers are aligned, bounded and nonoverlapping');
check(provenance.compilerFlags.includes('-no-allocations') && provenance.compilerFlags.includes('-O') &&
  provenance.compilerFlags.includes('wasm32-unknown-none-wasm') &&
  !provenance.compilerFlags.includes('-Ounchecked') && !provenance.compilerFlags.includes('-ffast-math'),
  'Swift provenance records checked, freestanding, allocation-free optimization');

const manifest = (await read('Package.swift')).toString();
const build = (await read('build.sh')).toString();
const wasmBuild = (await read('Browser/tools/build-wasm.mjs')).toString();
assert.equal(hash(Buffer.from(wasmBuild)), provenance.buildScriptSHA256,
  'WASM build settings changed without rebuilding the distributed core');
const adapter = (await read('Sources/BlackHoleDesk/DiskPhysics.swift')).toString();
check(/\.target\(name:\s*"BlackHolePhysics"\)/.test(manifest) &&
  /dependencies:\s*\["BlackHolePhysics"\]/.test(manifest) &&
  /swiftc[^\n]+Sources\/BlackHolePhysics\/\*\.swift/.test(build) &&
  wasmBuild.includes("'Sources/BlackHolePhysics'") && wasmBuild.includes('readdir(sharedDirectory)') &&
  /typealias DiskPhysics\s*=\s*(?:BlackHolePhysics\.)?SharedDiskPhysics/.test(adapter),
  'Native package, direct native build and WASM build all consume the same Swift physics');
for (const file of ['Browser/core/physics.c', 'Browser/core/cie1931.h', 'Sources/BlackHoleDesk/CIE1931.swift']) {
  await assert.rejects(fs.access(path.join(root, file)), { code: 'ENOENT' }, `${file} duplicates the shared source`);
}
check(true, 'No separate C physics implementation or duplicate CIE data remains');
console.log(`${checks}/${checks} shared Swift source and artifact checks passed.`);
