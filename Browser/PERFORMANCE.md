# Source and cross-engine optimization review

2026-09-27 · Apple M4 · macOS 26.6.2

## Scope and status

Four parallel review tracks covered compiled source physics, shader arithmetic,
the application lifecycle, and WebGPU camera/resource portability. Source-level
changes were validated before browser-specific work. Native Swift/Metal files
were not modified. Motion first remains the default.

**Cross-engine GPU validation is still pending.** The following installed versions
were recorded on the development machine, not validated by rendering this build:

| Engine | Installed browser | Project GPU result |
| --- | --- | --- |
| Chromium/Blink + Dawn | Chrome 153.0.8010.53 | Not run |
| WebKit | Safari 26.6.2 | Not run |
| Gecko + wgpu | Firefox 155.0; Developer Edition 157.0 | Not run |

Vendor support is documented for [Chrome on macOS](https://developer.chrome.com/docs/web-platform/webgpu/overview),
[Safari 26](https://webkit.org/blog/17333/webkit-features-in-safari-26-0/), and
[Firefox 147+ on Apple Silicon](https://www.firefox.com/en-US/firefox/147.0/releasenotes/).
That does not establish this project's shader acceptance, visual correctness or
speed in any of them. Node/V8 and Bun/JavaScriptCore CPU tests below are also not
Chrome or Safari browser tests. No SpiderMonkey runtime result is claimed.

## Measured source improvements

Actual compiled WASM, median CPU wall milliseconds, on the same Mac:

| Workload | Node 22.22.3 / V8 before → after | Bun 1.4.0 / JavaScriptCore before → after |
| --- | ---: | ---: |
| CIE spectral table initialization | 7.170 → 4.953 | 4.671 → 3.750 |
| Spin change | 0.1062 → 0.0911 | 0.1149 → 0.0945 |
| Mass change | 0.1013 → 0.00828 | 0.1151 → 0.00619 |
| Accretion change | 0.1017 → 0.00831 | 0.1155 → 0.00619 |

Protocol: eight warmups, 31 fresh instances for startup, and 31 blocks of 100
parameter changes. The compared module grows from 29,113 to 29,563 bytes; memory
remains fixed at 256 KiB with no imports or allocator. Raw paired reports and the
pre-change module were retained locally during development and are not included
in this repository. The current-core benchmark is reproducible with the commands
below; the historical paired comparison additionally requires that baseline.

The optimizations cancel a common orbital normalization analytically, precompute
wavelength-only factors once, and cache the dimensionless radial solution by
spin/outer radius. Mass/accretion changes rescale that solution; height-only
changes no longer repeat quadrature. All f64 integration and all 471 wavelengths,
4,096 radial entries and 2,048 spectral entries are retained.

Across 54 profiles, all 884,736 compared radial floats and 8,192 spectral floats
are bit-identical to the pre-change module. Maximum relative f64 metadata change
is 2.18×10⁻¹⁶. Independent Schwarzschild flux and physical-scaling tests also pass.

Uniform-packing microbenchmark in Node/V8: 100,000 packs, seven measured trials,
median 21.557 → 8.348 ms. One scratch buffer replaces repeated allocation. This is
a small CPU housekeeping improvement, **not a frame-rate speedup**. CPU table
initialization is likewise not the dominant cost of tracing a moving camera.

## Program and WebGPU changes

- Settled paused, static and hidden views schedule zero animation-frame callbacks
  or periodic timers. Input wakes one loop; refinement gets one delayed event.
- Network fetches/adapter discovery and independent pipeline compilation overlap.
- Completed trace throughput seeds bounded ray strips, avoiding a repeated tiny
  warmup. Cancellation still operates between bounded submissions.
- Adaptation separates fresh GPU execution time from completed-frame throughput.
  Submission-to-completion queue latency is no longer treated as GPU work;
  samples are invalidated across workload changes and idle periods so browser
  scheduling delays do not endlessly force down resolution.
- Full source shading reuses radius/logarithm/orbital invariants across shutter
  taps. Material-only logarithms at 1/2/4 taps fall from 3/6/12 to 2; redundant
  square roots fall from 1/2/4 to 0. Steady Scientific emission skips unused
  source work; unused material footprints skip neighboring geometry reads.
- With glow enabled, its dependent dispatches share one compute pass and pipeline
  binding. Later bind groups are shared across source images. Repeated 1×1 tail
  levels alias one texture, duplicate fragment samples are reused, and unchanged
  camera settings cause no additional uniform upload.
- GPU timestamps attach to the actual emission/presentation passes, with no
  empty marker pass. Optional features remain optional. Fault injection checks
  cleanup and subsequent recovery after encoding/mapping errors.

These are verified code/resource-work reductions, **not measured GPU speedups**.
Apart from the two captured-ray endpoint guards described below, the ray
integrator, compensated critical-ray math, redshift and photosphere code are
source-identical to the reviewed baseline. A source hash guards that boundary.
No reduced physics tolerance, approximate exponential, f16 ray arithmetic,
browser-name-specific workgroup size or speculative subgroup path was introduced.
WGSL permits backend reassociation/fusion, so CPU expression equality is not a
promise of bit-identical GPU results. See the [WGSL specification](https://www.w3.org/TR/WGSL/).

## Second GPU-utilization pass

Three parallel reviews focused on trace scheduling, shader work and adaptive
headroom. This pass was verified with source, CPU and host-controller tests;
no live browser rendering or new GPU timing result is claimed.

- **Bounded trace pipelining:** keep a successor strip queued while the host
  receives the oldest completion fence. There are at most two outstanding strips,
  each 8–64 rows, with an estimated 8 ms target from completed wall throughput.
  Separate ordered uniform writes/submissions preserve one immutable camera/model
  snapshot. Cancellation and errors drain outstanding work before returning.
  This removes the mandatory host-delivery gap after every strip; whether that
  improves a particular browser's GPU utilization remains to be measured.
- **Discarded endpoint work:** only production rays already classified as captured
  skip final horizon-event refinement. Their geometry output is always
  `(-2,0,0,0)` and cannot read the discarded endpoint. The source path removes
  17 ordinary or 27 compensated derivative evaluations plus bracket iterations
  per affected capture. Some backends may already eliminate dead work; this is
  not an FPS measurement. Diagnostic rays retain the original exact call path.
- **Measured quality headroom:** Motion first can grow from its 230,400-pixel
  ceiling to 2,073,600 pixels for a calibrated stationary view, still limited by
  the same 100 ms trace budget, display, storage and texture limits. Motion uses
  the original cap and 24 ms budget; energy saving uses the original cap and
  20 FPS target. One ray, simple material and no-glow defaults are unchanged.
- **Faster recovery when justified:** fresh GPU timestamps below 36% of the
  execution budget permit a 10% linear-resolution increase. Completion-only
  evidence or moderate headroom retains the previous 3% cap. Synthetic constant
  abundant-headroom recovery from 0.2 to 1 takes 17 decisions instead of 55;
  these are controller decisions, not measured seconds or device performance.

Validation: **261 named offline checks pass**, plus the WGSL validator's valid/
invalid self-checks and both production shaders. New scheduler tests deliberately
defer fences to prove two-strip overlap, coverage, ownership and cancellation.
Cancellation cannot hide a failed successor, and cleanup preserves the primary
error when multiple queued jobs or host callbacks fail.
Shader tests compare 2,048 capture branches, 2,048 diagnostic branches and 4,096
non-capture branches, and normalize only the two exact approved guards before
checking the original transport source hash. Actual-app tests cover enlarged
refinement, energy toggles during sleep and hard cancellation during a trace.
The changed scheduling, quality, source and application tests also pass under
Bun/JavaScriptCore; neither that nor Node/V8 is a browser rendering test.
The publication check also validates a tracked, metadata-free native fixture so
fresh clones can build and run offline checks without prior local GPU reports.

No new emission-map buffer, subgroup requirement, engine-specific workgroup
shape, or ray compaction was introduced without GPU-backed evidence.

## Repeatable live comparison

Build and start the local server normally, then open this same address separately
in Chrome, Safari and Firefox, one visible test at a time:

```text
http://127.0.0.1:8765/?benchmark=1
```

The expanded path runs the existing 177-ray native-reference regression and image
checks, followed by six fixed source/presentation workloads, warmup + 40 measured
cached frames per workload, five camera traces, six resize/glow transitions, and
120 animation-frame callbacks with bounded asynchronous submissions. The test
aborts on hidden tabs instead of reporting background-throttled results. Controls
are temporarily locked, and original settings/canvas dimensions are restored.

Reports include the actual user agent, disclosed adapter, device limits, optional
features, SHA-256 build identity, finite/HDR/unresolved counters, median/p95 wall
and GPU timings, and callback/submission cadence. Submitted FPS is not proof of
compositor-presented FPS. Timestamp precision may be quantized. No fixed FPS
threshold is presented as a correctness test.

Use **Download report** or the local `outputs/browser-reports/<engine>/` archive.
Reports are retained separately per run and build; `browser-verification.json`
is only the latest compatibility copy. Keep power mode, display size/refresh,
temperature and other GPU workloads comparable; repeat runs before attributing
small differences to an engine. A production browser result is required before
claiming Chromium/WebKit/Gecko parity or choosing engine-specific optimizations.

## Reproduction and remaining work

```sh
npm --prefix Browser test
npm --prefix Browser run benchmark:cpu
```

For an optional paired comparison against a separately retained earlier physics
module, run `node Browser/tests/wasm-reference-comparison.mjs /path/to/core-before.wasm`.
The historical baseline is not needed for building or the default test suite.

The offline suite includes actual compiled physics, source-expression equivalence,
exhaustive half-float filter invariants, capability/exception mocks, event-loop
integration, and benchmark-controller tests. Offline Naga validation is not a
substitute for Dawn, WebKit or wgpu executing the shaders.

Next evidence-dependent work: collect the three live reports; inspect near-critical
ray convergence/visuals; compare workgroup shapes and pipeline specialization at
equal image error; profile whether shader arithmetic, ray divergence, bandwidth,
browser IPC or presentation dominates. Those changes are deliberately not guessed
from browser names. Moving-camera light transport remains the expensive path.
