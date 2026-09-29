// Migration audit: compare the actual previous binary with the current Swift
// binary. The archived binary/fixtures belong in ignored work/, not production.
// node Browser/tests/shared-swift-parity.mjs previous.wasm [current.wasm] [native.json]
// Add --benchmark for paired CPU measurements. This does not measure WebGPU.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const args = process.argv.slice(2).filter(arg => !arg.startsWith('--'));
assert.ok(args[0], 'Supply the archived reference WASM filename');
const files = [args[0], args[1] || path.join(root, 'Browser/public/core.wasm')];
const bytes = await Promise.all(files.map(file => fs.readFile(file)));
const modules = bytes.map(value => new WebAssembly.Module(value));
const create = index => new WebAssembly.Instance(modules[index]).exports;
const instances = [create(0), create(1)];
const metadata = w => new Float64Array(w.memory.buffer, w.metadata_ptr(), 11);
const radial = w => new Float32Array(w.memory.buffer, w.radial_ptr(), w.radial_count() * 4);
const spectral = w => new Float32Array(w.memory.buffer, w.spectral_ptr(), w.spectral_count() * 4);
const bitPattern = value => new Uint32Array(value.buffer, value.byteOffset, value.length);
const relative = (a, b) => Math.abs(a - b) / Math.max(1e-30, Math.abs(a));
const scalarEqual = (a, b, label, tolerance = 1e-11) => {
  if (Object.is(a, b) || (a === b)) return;
  assert.ok(Number.isFinite(a) && Number.isFinite(b) && relative(a, b) <= tolerance,
    `${label}: reference ${a}, candidate ${b}`);
};
const report = {
  protocol: 'Actual binary-to-binary CPU audit. No browser, compositor or GPU equivalence is implied.',
  binaries: bytes.map((value, index) => ({ name: path.basename(files[index]), bytes: value.length,
    sha256: crypto.createHash('sha256').update(value).digest('hex') })),
  criteria: { lutRelative: 3e-7, physicalDoubleRelative: 1e-11,
    exactRejectionAndCacheBehavior: true, hostImports: 0, fixedMemoryBytes: 262144 },
  checks: 0, models: 0, cacheTransitions: 0, invalidModels: 0,
};
function check(value, label) { assert.ok(value, label); report.checks++; }
function stats() { return { floats: 0, changedBits: 0, maximumRelative: 0, maximumULPs: 0 }; }
const orderedBits = value => value & 0x80000000 ? 0x80000000 - (value & 0x7fffffff) : 0x80000000 + value;
function compareFloats(a, b, result, label) {
  assert.equal(a.length, b.length, label);
  const ab = bitPattern(a), bb = bitPattern(b);
  for (let i = 0; i < a.length; i++) {
    assert.ok(Number.isFinite(a[i]) && Number.isFinite(b[i]), `${label}[${i}] is finite`);
    const error = relative(a[i], b[i]);
    result.floats++;
    result.changedBits += ab[i] !== bb[i];
    result.maximumRelative = Math.max(result.maximumRelative, error);
    result.maximumULPs = Math.max(result.maximumULPs, Math.abs(orderedBits(ab[i]) - orderedBits(bb[i])));
    assert.ok(error <= report.criteria.lutRelative, `${label}[${i}]: ${a[i]} versus ${b[i]}, relative ${error}`);
  }
  report.checks++;
}
function compareMetadata(a, b, label) {
  let maximumRelative = 0;
  for (let i = 0; i < a.length; i++) {
    scalarEqual(a[i], b[i], `${label}[${i}]`);
    maximumRelative = Math.max(maximumRelative, relative(a[i], b[i]));
  }
  return maximumRelative;
}
function exact(a, b, label) { assert.deepEqual(Array.from(a), Array.from(b), label); report.checks++; }
for (const [index, w] of instances.entries()) {
  exact(WebAssembly.Module.imports(modules[index]), [], 'No host math, JS or WASI imports');
  exact([w.abi_version(), w.radial_count(), w.spectral_count()], [1, 4096, 2048], 'Stable host ABI');
  check(w.memory.buffer.byteLength === 262144, 'Fixed memory allocation');
  check(w.init_spectrum() === 0, 'Spectral initialization succeeds');
}
const [reference, candidate] = instances;
report.radial = stats(); report.spectral = stats(); report.maximumMetadataRelative = 0;
compareFloats(spectral(reference), spectral(candidate), report.spectral, 'Spectral LUT');
for (const w of instances) {
  const saved = bitPattern(spectral(w)).slice();
  w.init_spectrum();
  exact(bitPattern(spectral(w)), saved, 'Spectral cache is bit-stable');
}
const profiles = [];
for (const spin of [-.9999, -.9, 0, .82, .998, .9999]) {
  for (const outer of [30, 80, 100000]) for (const [mass, mdot, height] of [[1e7, .001, .75], [1e8, .1, .4], [1e9, 1, 1]]) {
    profiles.push([spin, mass, mdot, outer, height]);
  }
}
profiles.push([.82, 1e8, 0, 30, 0], [.82, 1e8, .1, 30, 0], [.82, 1e8, .1, 30, .75]);
for (const values of profiles) {
  exact(instances.map(w => w.init_model(...values)), [0, 0], 'Model accepted by both binaries');
  compareFloats(radial(reference), radial(candidate), report.radial, `Radial ${values.join(',')}`);
  report.maximumMetadataRelative = Math.max(report.maximumMetadataRelative,
    compareMetadata(metadata(reference), metadata(candidate), 'Physical metadata'));
  report.models++;
}
const cacheCases = [
  [.82, 1e8, .1, 30, .75], [.82, 2e8, .1, 30, .75], [.82, 2e8, .001, 30, .75],
  [.82, 2e8, .001, 30, .4], [.82, 2e8, .001, 80, .4], [.998, 2e8, .001, 80, .4],
  [-.9, 1e7, 0, 30, 1], [.82, 1e8, .1, 30, .75],
];
for (const parameters of cacheCases) {
  for (const [index, w] of instances.entries()) {
    const fresh = create(index); fresh.init_spectrum(); fresh.init_model(...parameters);
    w.init_model(...parameters);
    exact(bitPattern(radial(w)), bitPattern(radial(fresh)), 'Cached and fresh radial bytes match');
    exact(metadata(w), metadata(fresh), 'Cached and fresh metadata match');
  }
  report.cacheTransitions++;
}
const valid = [.82, 1e8, .1, 30, .75];
const invalidValues = [
  [NaN, Infinity, -Infinity, -1, 1], [0, -1, NaN, Infinity, -Infinity],
  [-1, NaN, Infinity, -Infinity], [0, 1, NaN, Infinity, -Infinity], [-1, NaN, Infinity, -Infinity],
];
for (const [parameter, values] of invalidValues.entries()) for (const value of values) {
  const parameters = [...valid]; parameters[parameter] = value;
  for (const w of instances) {
    const beforeMeta = metadata(w).slice(), beforeRadial = bitPattern(radial(w)).slice();
    const beforeSpectrum = bitPattern(spectral(w)).slice();
    check(w.init_model(...parameters) === 1, 'Invalid model is rejected');
    exact(metadata(w), beforeMeta, 'Rejected model preserves metadata');
    exact(bitPattern(radial(w)), beforeRadial, 'Rejected model preserves radial table');
    exact(bitPattern(spectral(w)), beforeSpectrum, 'Rejected model preserves spectrum');
  }
  report.invalidModels++;
}
for (const spin of [-2, -.9999, -.9, 0, .82, .9999, 2, NaN, Infinity, -Infinity]) {
  scalarEqual(reference.isco(spin), candidate.isco(spin), `ISCO ${spin}`);
}
for (const radius of [0, 1, 6, 30, 1e5, NaN, Infinity, -Infinity]) {
  for (const spin of [-1, -.9999, 0, .998, 1, NaN]) for (const mass of [0, 1e7, 1e8, 1e9, NaN]) {
    scalarEqual(reference.orbital_period(radius, spin, mass), candidate.orbital_period(radius, spin, mass), 'Orbital period');
  }
}
const clockCases = [[1 / 120, 1000, 1], [50, 1000, 0], [-1, 1000, 1], [NaN, 1000, 1],
  [1, Infinity, 1], [Infinity, 1, 1], [1, -1, 1], [1, 4000, 1], [Number.MAX_VALUE, 1, 1],
  [Number.MAX_VALUE, Number.MAX_VALUE, 1]];
instances.forEach(w => w.reset_clock());
for (let repeat = 0; repeat < 120; repeat++) {
  scalarEqual(reference.advance_clock(1 / 120, 1000, 1), candidate.advance_clock(1 / 120, 1000, 1), 'Clock frame integration', 0);
}
for (const parameters of clockCases) {
  scalarEqual(reference.advance_clock(...parameters), candidate.advance_clock(...parameters), 'Clock validity and overflow', 0);
  scalarEqual(reference.clock_seconds(), candidate.clock_seconds(), 'Clock getter', 0);
}
for (const current of [.1, .5, 1, 2, NaN]) for (const measured of [0, 8, 16, 100, NaN, Infinity]) {
  for (const [minimum, maximum] of [[.25, 1], [0, 1], [1, .25], [.25, NaN]]) {
    scalarEqual(reference.adaptive_scale(current, measured, 16, minimum, maximum),
      candidate.adaptive_scale(current, measured, 16, minimum, maximum), 'Adaptive scale');
  }
}
if (args[2]) {
  const native = JSON.parse(await fs.readFile(args[2], 'utf8'));
  assert.equal(native.schema, 1);
  const fromBits = values => new Float32Array(Uint32Array.from(values).buffer);
  report.native = { cases: 0, radial: stats(), spectral: stats(), maximumPhysicalDoubleRelative: 0 };
  compareFloats(fromBits(native.spectralBits), spectral(candidate), report.native.spectral, 'Native spectral LUT');
  for (const entry of native.cases) {
    candidate.init_model(...entry.parameters);
    compareFloats(fromBits(entry.radialBits), radial(candidate), report.native.radial, 'Native radial LUT');
    const meta = metadata(candidate);
    const physical = [meta[0], meta[7], meta[8], meta[9]];
    report.native.maximumPhysicalDoubleRelative = Math.max(report.native.maximumPhysicalDoubleRelative,
      compareMetadata(entry.physicalDouble, physical, 'Native physical constants'));
    entry.metadataFloat.forEach((value, index) => scalarEqual(value, Math.fround(meta[index]), 'Native f32 metadata', 3e-7));
    scalarEqual(entry.orbitalPeriod, candidate.orbital_period(12, entry.parameters[0], entry.parameters[1]), 'Native orbital period');
    report.native.cases++;
  }
  native.spectralMetadataFloat.forEach((value, index) => scalarEqual(value,
    Math.fround(metadata(candidate)[index + 5]), 'Native spectral metadata', 3e-7));
}
if (process.argv.includes('--benchmark')) {
  const percentile = (values, fraction) => [...values].sort((a, b) => a - b)[Math.floor((values.length - 1) * fraction)];
  const summarize = values => ({ medianMS: percentile(values, .5), p95MS: percentile(values, .95),
    minimumMS: Math.min(...values), samples: values.length });
  const model = (w, spin = .82, mass = 1e8, mdot = .1, height = .75) => w.init_model(spin, mass, mdot, 30, height);
  const paired = run => {
    const times = [[], []], ratios = [];
    for (let i = 0; i < 31; i++) {
      for (const index of i % 2 ? [1, 0] : [0, 1]) times[index].push(run(index, i));
      ratios.push(times[1][i] / times[0][i]);
    }
    return { reference: summarize(times[0]), candidate: summarize(times[1]),
      pairedMedianRatio: percentile(ratios, .5), pairedP95Ratio: percentile(ratios, .95) };
  };
  for (let i = 0; i < 8; i++) for (const index of [0, 1]) {
    const w = create(index); w.init_spectrum(); model(w);
  }
  function startup(operation, constructInside = false) {
    return paired(index => {
      let w = constructInside ? undefined : create(index);
      const start = performance.now();
      if (constructInside) w = create(index);
      operation(w);
      return performance.now() - start;
    });
  }
  function series(change) {
    const pair = [create(0), create(1)]; pair.forEach(w => model(w));
    for (const w of pair) for (let i = 0; i < 400; i++) change(w, i);
    return paired((index, block) => {
      const start = performance.now();
      for (let i = 0; i < 100; i++) change(pair[index], block * 100 + i);
      return (performance.now() - start) / 100;
    });
  }
  report.benchmark = {
    environment: { runtime: process.versions.bun ? 'Bun/JavaScriptCore' : 'Node/V8', nodeCompatibility: process.version,
      bun: process.versions.bun, v8: process.versions.bun ? undefined : process.versions.v8,
      webkit: process.versions.webkit, architecture: process.arch, platform: process.platform,
      cpu: os.cpus()[0]?.model || 'Unavailable', cpuCount: os.cpus().length },
    protocol: 'CPU wall time, same precompiled modules, 8 warmups and 31 pairs in alternating order. Startup uses fresh instances; changes use 400 warmups then 31 blocks of 100 calls. A ratio below 1 favors the candidate. This is not a live browser benchmark.',
    instanceStartup: startup(() => {}, true),
    completeStartup: startup(w => { w.init_spectrum(); model(w); }, true),
    spectrumStartup: startup(w => w.init_spectrum()),
    radialStartup: startup(w => model(w)),
    spinChange: series((w, i) => model(w, i % 2 ? .82 : .83)),
    massChange: series((w, i) => model(w, .82, i % 2 ? 1e8 : 2e8)),
    accretionChange: series((w, i) => model(w, .82, 1e8, i % 2 ? .1 : .01)),
    heightChange: series((w, i) => model(w, .82, 1e8, .1, i % 2 ? .75 : 1)),
    repeatedModel: series(w => model(w)),
  };
}
report.passed = true;
console.log(JSON.stringify(report, null, 2));
