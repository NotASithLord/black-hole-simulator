# Source and cross-engine optimization review

## Cached-animation stability correction — 2026-09-29

The initial high-utilization pass exposed a control-loop regression: automatic
quality changes called the same invalidation path as camera input, which caused
a tiny one-ray moving preview followed by a second four-ray stationary build.
The preview stayed on screen while tracing blocked animation. A narrow timing
deadband repeatedly triggered this cycle from ordinary GPU timing variation.

Quality-only changes now preserve stationary sampling and enqueue the exact
chosen replacement dimensions directly. Their sizing calibration remains fixed
instead of changing as the rebuild changes measured throughput. Cache replacements
also require distinct, sustained timing evidence, a meaningful pixel difference
and trace-cost-aware cooldown. The 87.5% execution budget remains a reference, not
a requirement to discard a stable map whenever timing differs by a few percent.
The HUD includes a map-build count so repeated rebuilding is visible.

A regression test drives the actual application loop for sixty simulated seconds
with noisy GPU timing: the old source creates seven maps instead of three, while
the corrected source stays at its three startup maps. Sustained overload and
recovery each replace the map once at four samples, without an intervening blurry
preview. This is deterministic host evidence, not an FPS benchmark. Real camera
motion still requires new rays; a genuine map rebuild can still briefly pause
animation. No transport equations, shader precision or shared Swift math changed.

Validation: the full browser offline suite passes, including 87 quality-policy
and 42 application-loop checks. Those two suites also pass under JavaScriptCore
through Bun. Sparse timestamp simulations at 7.5–10 FPS retain overload recovery
when evidence alternates between GPU timestamps and completed-frame cadence.
These simulations are policy tests, not measurements of those browser engines.

The repository merge retains bounded Max Fidelity supersampling from the newer
GPU-scaling commits. It uses the stable controller above, not the superseded
narrow utilization loop. Supersampling may exceed display resolution but cannot
multiply the mode's pixel ceiling or calibrated tracing budget. Motion and energy
saving retain their non-supersampled paths.

## Max Fidelity efficiency pass — 2026-09-29

Both targets default to Max Fidelity. The shared Swift equations, compiled WASM
and browser transport shaders are unchanged. Independent review found no reason
to replace the existing allocation-free numerical core or its lookup caches.

- Native frame-loop cache keys are typed `Equatable` values rather than formatted
  strings. The initial radial table is no longer rebuilt on the first frame.
- Native foreground Max Fidelity uses a display-aware 87.5% GPU command-time
  budget, with separate traced/cached feedback and caps that match submitted work.
  Useful cached shutter integration can increase from four to eight or sixteen
  samples without retracing the Kerr map. Physical equations and integration
  tolerances are unchanged.
- Browser Max Fidelity uses an 87.5% measured GPU frame-time reference,
  workload-local timestamp smoothing and bounded resolution recovery. The original
  narrow controller band was replaced by the stability policy above; smooth
  cached animation takes priority over closely tracking utilization. These are
  policy changes, not measured GPU utilization or frame-rate improvements.
- The browser requests supported ray-map buffer limits up to 562.5 MiB instead
  of an arbitrary 256 MiB cap, enough for the existing 4K/four-ray ceiling with
  reserve. Requests do not allocate those buffers; viewport, calibration and
  actual adapter limits still determine allocations.
- Bounded queues, no-timestamp fallbacks, hidden/paused sleep, energy controls
  and wallpaper throttling remain. Reaching the maximum useful workload may
  legitimately leave the GPU below the target; no redundant work is injected.

Metal command-buffer timings measure this app's GPU work ([Apple documentation](https://developer.apple.com/documentation/metal/mtlcommandbuffer/gpustarttime)).
WebGPU timestamp queries are optional and precision-limited ([WebGPU specification](https://gpuweb.github.io/gpuweb/#timestamp)).
Neither is an adapter-wide utilization counter. Actual browser/driver performance
still needs live GPU measurements; offline tests do not establish that result.

Validation: the full browser offline suite passes, including 57 quality-policy,
52 capability/exception, 34 application-loop and 12 renderer-host checks. Native
compilation, 53 deterministic quality checks and 32 production Metal appearance
checks pass. The new 8/16-sample shutter paths remain finite and emitting; the
Scientific and zero-width shutter bypasses remain bit-identical. An isolated
Apple M4 test at 1440×960 with two cached geometry samples and four shutter samples
measured a 3.77 ms median for fluid/material/camera work. This is not a before/after
speedup or a measurement of the live adaptive renderer's utilization.

## Previous review and migration

2026-09-27 review; 2026-09-28 shared Swift migration · Apple M4 · macOS 26.6.2

## Shared Swift migration — 2026-09-28

Both targets now compile `Sources/BlackHolePhysics/*.swift`. The native app uses
small array adapters; the browser's `WasmExports.swift` preserves its existing
ABI and fixed-memory buffers. The duplicate C physics and CIE data files were
removed. Metal/WGSL rendering, controls and quality policies were not changed.

The actual Swift WASM and archived C WASM were compared across 57 model profiles:
all **933,888 radial and 8,192 spectral float values are bit-identical**, as are
the physical double-precision metadata. Tests also cover eight cache transitions,
23 rejected model inputs with state preservation, orbital helpers, source time
and adaptive scaling. Comparison with the previous native Swift implementation
also preserves all 884,736 radial and 8,192 spectral float values across its 54
profiles. These are tested values, not a guarantee for every possible input or
GPU backend.

Paired CPU comparison (Swift time / previous C time; lower is faster):

| Workload | Node/V8 | Bun/JavaScriptCore |
| --- | ---: | ---: |
| Complete physics startup | 1.006× | 1.012× |
| Spectral initialization | 1.004× | 1.043× |
| Radial initialization | 0.819× | 0.916× |
| Spin change | 0.860× | 0.910× |
| Mass change | 0.716× | 0.991× |
| Accretion change | 0.708× | 0.978× |

Protocol: actual precompiled modules, eight warmups, 31 alternating-order pairs;
model updates use 400 warmups followed by 31 blocks of 100 calls. Complete startup
medians were 5.070 → 5.124 ms in Node and 4.500 → 4.458 ms in Bun; medians of paired
ratios differ from ratios of independent medians. Height/repeated-model calls
remain tens of nanoseconds and varied by roughly 2–6%. Startup is approximately
unchanged, with faster geometry updates; literal identical timings are not claimed.
These are CPU measurements, **not new browser FPS or GPU results**.

The module grows from 29,563 to 56,997 bytes (about 27 KiB extra uncompressed),
retaining zero imports, fixed 256 KiB memory and compiler-enforced no heap
allocation. Ordered scalar spectral accumulation and IEEE hardware square root
avoid compiler overhead without reduced precision, samples or relaxed math.
Swift runtime and statically linked math notices are retained under `licenses/`.

The default source/provenance test rejects stale WASM after a shared-source change.
The final native build passes 31 disk-physics and 23 source-motion checks; its
177-ray Metal diagnostics in both Auto and Max Fidelity agree with the independent
binary64 reference on every capture/disk/escape classification. The offline
browser suite passes with the new module, including 11 shared-source/artifact
checks. Live browser rendering has not been remeasured in this migration.
To repeat the migration comparison with an archived previous module and optional
native fixture:

```sh
node Browser/tests/shared-swift-parity.mjs previous.wasm Browser/public/core.wasm native-before.json --benchmark
```

Use Bun in place of Node for the JavaScriptCore CPU comparison. The native fixture
generator is `Browser/tests/shared-swift-native-fixture.swift`; archived binaries
and local raw reports are not application dependencies. The earlier review and
its historical C-to-C performance measurements are retained below.

## Scope and status

Four parallel review tracks covered compiled source physics, shader arithmetic,
the application lifecycle, and WebGPU camera/resource portability. Source-level
changes were validated before browser-specific work. Native Swift/Metal files
were not modified in that September 27 pass. Motion first remains the default.

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
