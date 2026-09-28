import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { mkdir, readFile, access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const browser = path.join(root, 'Browser');
const toolDirectory = path.join(root, 'work/wasm-toolchain');
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
const compiler = path.join(sdk, 'bin/clang');
const exists = async p => { try { await access(p); return true; } catch { return false; } };
function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} exited ${result.status}`);
}

if (!(await exists(compiler))) {
  if (process.env.WASI_SDK_PATH) throw new Error(`No clang in WASI_SDK_PATH: ${sdk}`);
  if (!hashes[key]) throw new Error(`Automatic compiler download unsupported for ${key}; set WASI_SDK_PATH.`);
  await mkdir(toolDirectory, { recursive: true });
  const archive = path.join(toolDirectory, `${distribution}.tar.gz`);
  const url = `https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-33/${distribution}.tar.gz`;
  if (!(await exists(archive))) {
    console.log(`Downloading pinned WASI SDK 33 into work/ (${key}).`);
    run('curl', ['-fL', '--retry', '2', '--connect-timeout', '20', '-o', archive, url]);
  }
  const hash = createHash('sha256');
  for await (const chunk of fs.createReadStream(archive)) hash.update(chunk);
  if (hash.digest('hex') !== hashes[key]) throw new Error('Compiler archive checksum mismatch.');
  run('tar', ['-xzf', archive, '-C', toolDirectory]);
}

const exports = ['radial_ptr', 'spectral_ptr', 'metadata_ptr', 'radial_count', 'spectral_count',
  'abi_version', 'init_model', 'init_spectrum', 'isco', 'orbital_period', 'advance_clock',
  'clock_seconds', 'reset_clock', 'adaptive_scale'];
await mkdir(path.join(browser, 'public'), { recursive: true });
const output = path.join(browser, 'public/core.wasm');
// SDK 33's LTO libc adds an unnecessary WASI entropy constructor. The ordinary
// static libm is standalone, while -O3 still inlines/optimizes this single C TU.
run(compiler, ['--target=wasm32-wasip1', '-std=c11', '-O3', '-msimd128', '-nostartfiles',
  '-fno-fast-math', '-fvisibility=hidden', '-ffile-prefix-map=' + root + '=.',
  '-Wl,--no-entry', '-Wl,--strip-all', '-Wl,--export-memory',
  '-Wl,--initial-memory=262144', '-Wl,--max-memory=262144', '-Wl,-z,stack-size=65536',
  ...exports.map(name => '-Wl,--export=' + name),
  path.join(browser, 'core/physics.c'), '-lm', '-o', output]);
const bytes = await readFile(output);
const module = new WebAssembly.Module(bytes);
if (WebAssembly.Module.imports(module).length) throw new Error('Standalone core unexpectedly requires runtime imports.');
console.log(`Built Browser/public/core.wasm (${bytes.length.toLocaleString()} bytes, no runtime imports).`);
