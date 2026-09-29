# Event Horizon · WebAssembly + WebGPU

A browser target for the native black-hole simulator. The same Swift CPU physics
core used by the native app is compiled to WebAssembly; Kerr light transport, animated emission and photographic
response execute on the GPU using WGSL compute and render passes.

The default is **Max Fidelity**: tight Kerr integration tolerances, up to four
cached rays per pixel, detailed rotating material and a 60 FPS target. Resolution
adapts to the actual GPU, with up to 8.29 million pixels within memory and
measured trace-time limits. Stationary Max Fidelity can supersample above display
resolution when measured GPU headroom permits. With GPU timestamps, the controller targets 87.5%
of the frame interval for useful rendering work; this is not a measurement or
guarantee of total-device GPU utilization. Smaller GPUs still scale down.

**Motion first** remains an explicit low-cost option with one ray per pixel and
simple material. Energy saving, finite photosphere height, photographic glow and
extra emission fluctuations remain separate controls. The disk still starts thin
with glow/fluctuations off; quality does not silently change the physical model.
Frame targets are not performance guarantees, and moving-camera tracing remains
substantially more expensive than animating cached geometry.

The browser needs WebGPU and hardware acceleration. Open the application over
`http://localhost`, `http://127.0.0.1`, or HTTPS; opening `index.html` directly with
`file://` does not work. There is no WebGL fallback.

## Build and run

From the repository root, with Node.js 18 or newer:

```sh
node Browser/tools/build.mjs
node Browser/tools/serve.mjs
```

Then visit `http://127.0.0.1:8765`. From inside `Browser/`, the equivalent commands
are `node tools/build.mjs` and `node tools/serve.mjs`. Set `PORT` to choose a
different local port. The development server binds only to this computer.

The build copies a self-contained static application into
`outputs/BlackHoleBrowser/`. It uses the checked-in `public/core.wasm`, so no Swift
compiler is needed. Before copying files, the build validates both WGSL shaders
with a pinned, integrity-checked offline Naga compiler. Its first invocation
downloads the development tool into `work/`; subsequent checks use that cache.
This compiler runs only during development, not in the application.
The tracked input rays in `../Tests/physics_cases.json` and numerical native
reference in `tests/fixtures/native-reference.json` are included in every build;
no pre-existing `outputs/` directory or locally generated GPU report is needed.
Deploy the contents of that output directory to any HTTPS static host,
preserving relative paths and serving `.wasm` as `application/wasm` and `.js` as
JavaScript. Node is only needed for the included build/server tools, not for
viewing a hosted build. The application does not use external CDNs or services.

To rebuild after changing `Sources/BlackHolePhysics/` or its Swift WASM adapter:

```sh
node Browser/tools/build-wasm.mjs
node Browser/tests/wasm-core.mjs
node Browser/tools/build.mjs
```

The first compiler build downloads pinned, SHA-256-verified Swift 6.4.0 and WASI
SDK 33 toolchains into `work/wasm-toolchain/`. Swift is compiled in Embedded mode;
the SDK supplies the linker and statically linked math routines, not a second
implementation of the physics. The automatic Swift download supports macOS and
requires several GB of local disk space. On other hosts supply an Embedded/WASM-
capable compiler with `SWIFT_WASM_COMPILER_PATH` or `SWIFT_TOOLCHAIN_PATH`.
`WASI_SDK_PATH` selects an existing SDK. Toolchains are development dependencies,
not part of the deployed app, and no system compiler files are modified.

## Architecture and scaling

| Component | Execution | Responsibility |
| --- | --- | --- |
| `../Sources/BlackHolePhysics/` | Shared Swift, compiled to native code and WASM | Double-precision Page–Thorne quadrature, 4,096-entry radial table, 2,048-entry spectrum from all 471 CIE wavelengths, physical units and source clock |
| `core/WasmExports.swift` | Thin WASM adapter | Existing browser ABI and caller-owned fixed-memory buffers; no duplicated physics equations |
| `src/kerr.wgsl` tracing | WebGPU compute | Kerr null geodesics, finite photosphere intersections, travel delay and redshift |
| Cached ray records | GPU storage buffer | Radius, source azimuth, delay and redshift for each pixel sample; 16 bytes per sample |
| `src/kerr.wgsl` shading | WebGPU compute | Retarded rotating material, thermal/colored emission and prescribed light variation |
| `src/camera.js` and `camera.wgsl` | WebGPU compute/render | HDR glare pyramid, halo/streak response, tone mapping and canvas presentation |
| Browser host and `src/quality.js` | JavaScript | Controls, GPU limits, adaptive resolution, resource lifecycle, calibration and submission scheduling |

For a stationary camera and geometry, expensive ray paths are reused while the
disk continues rotating. Camera/geometry changes retrace those paths. The trace
is split into bounded strips so the page can report progress and accept input
during a rebuild. A three-copy startup probe measures completion notification
delivery, not GPU speed. Prompt hosts retain two queued strips and an 8 ms wall
throughput target. Coarse-delivery hosts use paced useful submissions, at most
eight outstanding strips, and a 32 ms target. Each strip is bounded by 64 rows
and a 65,536-ray target (with an irreducible eight-row minimum). Cancellation
drains actual completions before replacing resources. These are scheduling
bounds, not guaranteed GPU durations; no browser-name check selects the policy.
Camera input does not repeatedly cancel the in-flight camera
snapshot: a completed low-resolution view is presented, then the newest pose is
traced. Physical-model changes still cancel incompatible maps. Tables are rebuilt
and uploaded only when physical parameters change, not on camera movements.
Animation uses the GPU cache and a small parameter update. Interactive frames
are submitted without awaiting GPU completion on every frame. Prompt hosts use
two outstanding frames; coarse hosts allow up to eight, narrowed by valid GPU
cost measurements and stopped by a 250 ms oldest-notification guard. Elapsed
time never retires a submission. Timing readbacks happen asynchronously; invalid
timestamp counters are discarded without failing rendering. Persistent timing
failures suspend instrumentation with bounded recovery probes. Longer completed-
frame windows provide fallback throughput, never an invented GPU execution time.
Paused/static views and hidden pages stop issuing unnecessary frames and stop
polling animation callbacks entirely. Input wakes a single loop; delayed
refinement uses one scheduled event rather than repeated idle polling.
The WASM core uses fixed 256 KiB memory,
requires no host imports and performs no per-frame allocation or memory growth.

| Quality | Maximum integration steps | Cached samples per pixel | Nominal frame target | Pixel ceiling |
| --- | ---: | ---: | ---: | ---: |
| Motion first | 2,048 | 1 | 60 FPS | 0.2304 million moving/energy; up to 2.0736 million calibrated stationary |
| Auto | 4,096 | 1 | 60 FPS | 1.5 million |
| Efficient | 2,048 | 1 | 30 FPS | 0.6 million |
| Cinematic | 4,096 | 2 | 30 FPS | 2.5 million |
| Max fidelity (default) | 8,192 | 4 | 60 FPS | 8.29 million |

These are budgets and ceilings, not guaranteed frame rates or fixed render sizes.
Internal resolution is constrained by adapter storage limits, pixel ceilings and
measured workload. Stationary Max Fidelity can grow to three times the display's
linear resolution, but never beyond its pixel or calibrated trace-time ceiling;
camera motion and energy saving do not supersample. Higher modes use tighter integration tolerances and more
spatial/material sampling. GPU timestamp measurements are used when supported;
otherwise submission completion provides a broader timing estimate. Energy saver
targets 20 FPS. Camera passage requires continuous retracing and is considerably
more expensive than animating a stationary view.

Max Fidelity smooths current-workload GPU timestamps against an 87.5% frame-time
budget, but prioritizes stable cached animation over tracking that budget exactly.
It tolerates ordinary timing noise, requires several distinct timing windows and
a meaningful pixel-count change (15% for reductions and Max GPU recovery;
5% for conservative recovery), and waits at least five seconds between
reductions or fifteen seconds before upgrades (longer after expensive traces).
Recovery is bounded at 10% linear resolution per decision; stale timings cannot
increase work. Quality-only replacements directly build a stationary four-ray
map: they do not enter the low-resolution camera-motion preview path. The current
map's sizing calibration stays fixed during automatic quality adjustment.
Without timestamps, the
conservative completed-frame cadence fallback remains. Energy saving uses the
lower timing budget. Once useful resolution reaches its ceiling, the renderer
does not repeat ray tracing or add dummy work just to keep the GPU busy. Supported
ray-map buffer limits are requested up to 562.5 MiB, sufficient for the existing
4K/four-ray ceiling with reserve; smaller adapter limits are honored and this
request does not allocate memory by itself.

Motion first also renders the presentation at its internal resolution and lets
the browser upscale it, avoiding a full-Retina photographic pass. With glow off,
the camera allocates no glare pyramid and executes no blur passes. Enabling glow
allocates the seven logical levels lazily and aliases repeated 1×1 tail levels.
Its dependent dispatches share a compute pass; unchanged camera settings reuse
their last uniform upload. Resolution feedback samples roughly every 1.2 seconds,
but actual cache replacements require sustained evidence and the dwell times above.
Fresh GPU timestamps showing abundant
spare execution capacity permit up to 10% linear-resolution recovery per decision;
completion-only evidence retains the slower 3% limit. Camera motion starts with a 24 ms tracing budget;
still-view refinement starts with a 100 ms budget in Motion first. Calibration
is refreshed from completed ray maps, separately from cached-animation timing.
Turning on energy saver also rebuilds a smaller Motion-first map; turning it off
restores eligibility for calibrated stationary headroom.

## Controls

- Drag to orbit; right-drag to look around; scroll to change the camera's field of view.
- `W A S D Q E` fly the camera. `R` resets it.
- `Space` pauses; `H` toggles the HUD. Toolbar buttons also control pause, HUD and
  full screen.
- The Controls panel adjusts exposure, warm emission palette, material structure,
  glow and light fluctuations. Rotate emitting material and Disk playback control
  source motion; Slow camera passage controls the camera separately.
- Physical controls expose spin, mass, accretion rate and prescribed photosphere
  height. Show unresolved rays in magenta reveals numerical failures/budget
  exhaustion instead of blending them into the presentation.

The default disk playback is 4,000× observation time so differential rotation is
visible. This advances the source clock; it does not multiply gas velocities,
Doppler shifts or stored light-travel delays. Changing playback speed preserves
the accumulated source phase.

## Scientific scope

The source model is a stationary, optically thick, zero-torque Page–Thorne disk,
with a blackbody spectrum integrated against the official CIE 1931 observer.
It retains the native physical constants and double-precision CPU quadrature.
The raised photosphere is a prescribed, bounded pressure-inspired surface with
a smooth outer closure; it is not a solved vertical atmosphere.

Scientific appearance uses the equatorial reference disk and thermal emission.
Radiant adds a warm palette, analytic co-moving structure, prescribed emission
fluctuations and a photographic response. These appearance choices are separate
from the Kerr spacetime and light-transport equations.

Motion first uses two broad analytic source modes and smoothly renews emitting
patterns in 64 M cohorts. Each pattern is advected at the same Kerr orbital
frequency using retarded emission time; renewal prevents all visible contrast
from disappearing after prolonged shear at low resolution. Shutter averaging is
analytic. This is explicitly an artistic, prescribed emissivity model, not a
fluid solution. It removes fine noise octaves and neighbor-map derivative reads,
without changing the geodesic integrator, redshift equations or thermal tables.
The zero-height default selects the existing thin-disk model; increasing the
height control restores the more expensive finite photosphere intersections.
Captured production rays skip precise horizon-event endpoint refinement because
their cached record contains only the opaque capture classification. Diagnostic
rays still calculate the original endpoint; disk intersections, integration
tolerances, redshift and emitted colors are unchanged by this shortcut.

Browser-specific limits are explicit:

- The browser material is analytic. The native two-dimensional GPU fluid proxy
  is not included, and neither target is a full GRMHD simulation.
- Native sparse edge refinement is not ported yet. The browser uses its selected
  number of cached samples per pixel and material shutter sampling.
- WGSL uses `f32`, including compensated arithmetic near demanding trajectories.
  Compensated pairs are not guaranteed IEEE `f64`, and shader compiler behavior
  varies by backend. Native bit-for-bit numerical parity is not promised.
- Frame budgets, step caps and storage limits can leave rays unresolved. The
  diagnostic view and verification output expose this rather than certifying
  every rendered ray as converged.
- Browser full screen is available; native macOS desktop/wallpaper window
  integration remains a native-app feature.

## Verification

`node Browser/tests/native-fixture.mjs` verifies that the checked-in native
reference covers all 177 input rays, matches their input-file digest, and
contains finite numerical results.
This fixture is a regression snapshot from the native Metal implementation,
with device metadata and timing measurements removed; it is not an independent
physics reference or evidence of browser compatibility/performance. The native
validation command in the repository README can generate a fresh report for
comparison without overwriting the checked-in baseline.

`node Browser/tools/check-wgsl.mjs` parses and type-checks both production shaders
without a browser or GPU. It also checks invalid regression fixtures so reserved
identifiers, ambiguous bitwise expressions and invalid return types cannot
silently pass. The build runs this check automatically. Passing it does not
establish GPU driver compatibility or correctness of a rendered image.

`node Browser/tests/wasm-core.mjs` tests the actual compiled module: Schwarzschild
closed-form flux, Kerr ISCO references, physical scaling, spectral chromaticity,
time continuity and the adaptive controller. It also rejects unexpected runtime
imports and checks the fixed memory/table interface.

`node Browser/tests/shared-swift-source.mjs` verifies that the checked-in WASM
matches the hashes of the shared Swift sources and adapter, and that both native
build paths use those sources. The migration's paired numerical/performance
audit is documented in [PERFORMANCE.md](PERFORMANCE.md).

`node Browser/tests/renderer-host.mjs` uses a fake submission queue to verify that
a camera change during the final trace strip cannot publish stale geometry.
It also tests immutable camera snapshots, bounded nonblocking submissions,
table-cache invalidation, Max Fidelity defaults and optional lightweight mode. These are host tests, not
GPU rendering tests. `tests/trace-queue.mjs` explicitly delays completion fences
to check two-strip overlap, complete coverage, cancellation and failure draining.
`tests/quality.mjs` checks resolution limits, weak adapters
and frame cadence; `tests/camera-host.mjs` checks lazy glare allocation and pass
scheduling. `tests/app-host.mjs` exercises the actual application loop with a
mock DOM and queue: continuous dragging, pause/resume, visibility changes and
source-clock continuity. `npm test` inside `Browser/` runs the offline checks.
On a Metal-capable Mac, `npm run check:precision-metal` additionally translates
the production WGSL with Naga and executes the 177 reference rays plus 4,096
arithmetic cases with Metal fast math both enabled and disabled. This tests the
shader arithmetic backend, not a browser's API, scheduling or presentation.
`npm run check:image-metal` also executes production transport and shading for
fixed Max/Auto images, checking finite HDR, resolved rays and disk animation with
the actual Swift-WASM tables. It likewise does not claim browser compatibility.

For GPU/browser verification, run the included local server and open:

```text
http://127.0.0.1:8765/?test=1
```

The browser verification path reports through the local server to
`outputs/browser-verification.json`. Consult that generated report for the
tested browser/adapter, actual results and timing; a successful CPU test is not
evidence that a browser GPU shader compiled or rendered successfully. The report
endpoint is local tooling and is unnecessary on a deployed static host.
The suite includes low-detail animation at startup and after a long-running
source clock, alongside the existing full-material checks. On completion, the
page resumes interactive rendering; dismiss the report with Continue interactive
view. For normal use without running the suite, open the base URL with no query.

For the extended fixed-workload comparison, open `?benchmark=1` in one visible
browser at a time. Reports include the build digest and engine/device information,
and can be downloaded from the page. The local server archives each run separately
under `outputs/browser-reports/`, preventing one engine from overwriting another.
See [PERFORMANCE.md](PERFORMANCE.md) for measured CPU improvements, scientific
equivalence tests, the browser matrix and outstanding live-GPU verification.

## Attribution

CIE 2019, *Colour-matching functions of CIE 1931 standard colorimetric observer*,
International Commission on Illumination, Vienna:
<https://doi.org/10.25039/CIE.DS.xvudnb9b>. The complete 1 nm dataset, 360–830 nm,
is included in `../Sources/BlackHolePhysics/CIE1931.swift` under
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Numeric values
are preserved; formatting was converted to Swift inline storage. No CIE endorsement is
claimed. Keep this attribution and the data license when redistributing.

See `THIRD_PARTY_NOTICES.md` in the deployed output and repository for additional
scientific references and the photographic tone-curve attribution.
