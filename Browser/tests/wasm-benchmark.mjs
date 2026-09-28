import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const filename = process.argv[2] || path.join(root, 'Browser/public/core.wasm');
const module = new WebAssembly.Module(await fs.readFile(filename));
const create = () => new WebAssembly.Instance(module).exports;
const percentile = (values, p) => [...values].sort((a, b) => a - b)[Math.floor((values.length - 1) * p)];
const summary = values => ({ medianMS: percentile(values, 0.5), p95MS: percentile(values, 0.95), minimumMS: Math.min(...values), samples: values.length });
const model = (w, spin = 0.82, mass = 1e8, mdot = 0.1, height = 0.75) => {
  if (w.init_model(spin, mass, mdot, 30, height)) throw Error('Benchmark parameters rejected');
};
// Warm the same compiled functions without hiding per-instance spectral startup.
for (let i = 0; i < 8; i++) { const warm = create(); warm.init_spectrum(); model(warm); }
const spectrum = [], initialModel = [];
for (let i = 0; i < 31; i++) {
  const w = create();
  let start = performance.now(); w.init_spectrum(); spectrum.push(performance.now() - start);
  start = performance.now(); model(w); initialModel.push(performance.now() - start);
}
function series(change) {
  const w = create(); model(w);
  const times = [];
  for (let block = 0; block < 31; block++) {
    const start = performance.now();
    for (let j = 0; j < 100; j++) change(w, block * 100 + j);
    times.push((performance.now() - start) / 100);
  }
  return summary(times);
}
const result = {
  environment: { runtime: process.versions.bun ? 'Bun/JavaScriptCore' : 'Node/V8',
    nodeCompatibility: process.version, bun: process.versions.bun,
    v8: process.versions.bun ? undefined : process.versions.v8, webkit: process.versions.webkit,
    architecture: process.arch, platform: process.platform,
    cpu: os.cpus()[0]?.model || 'Unavailable', cpuCount: os.cpus().length },
  protocol: 'Same compiled module, 8 warmups, 31 new instances for startup; parameter changes 31 blocks of 100 calls. CPU wall time only, not browser/WebGPU.',
  wasmBytes: (await fs.stat(filename)).size,
  spectrumStartup: summary(spectrum), radialStartup: summary(initialModel),
  spinChange: series((w, i) => model(w, i % 2 ? 0.82 : 0.83)),
  massChange: series((w, i) => model(w, 0.82, i % 2 ? 1e8 : 2e8)),
  accretionChange: series((w, i) => model(w, 0.82, 1e8, i % 2 ? 0.1 : 0.01)),
  heightChange: series((w, i) => model(w, 0.82, 1e8, 0.1, i % 2 ? 0.75 : 1)),
  repeatedModel: series(w => model(w)),
};
console.log(JSON.stringify(result, null, 2));
