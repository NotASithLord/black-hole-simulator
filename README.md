# Black Hole Desk

A physically grounded Kerr black-hole renderer with a cinematic presentation
layer. Explore gravitational lensing, relativistic frequency shifts and an
animated accretion disk in a native macOS app or a WebGPU-enabled browser.

The renderer integrates light paths through Kerr spacetime; the shadow and
lensed disk images are not painted overlays. **Scientific** appearance uses a
thermal thin-disk source. **Radiant** adds explicitly art-directed emitting
material, a warm palette and optional photographic glare without replacing the
light-transport equations. No film assets or MLX are used.

This is an interactive visualization of a specified physical model, **not a
self-consistent relativistic plasma simulation**. Numerical checks and model
boundaries are documented below.

## Choose a target

| | Native macOS | Browser |
| --- | --- | --- |
| Renderer | SwiftUI, AppKit and Metal | WebAssembly physics core, JavaScript host and WebGPU/WGSL |
| Requirements | Apple Silicon, macOS 14+, Apple Command Line Tools | WebGPU and hardware acceleration; Node.js 18+ for local build tools |
| Default presentation | Radiant material, finite photosphere and photographic response | Motion first: thin disk, one cached ray per pixel, simple rotating material, no glow |
| Material | Analytic source plus an optional reduced 2D GPU fluid proxy | Analytic source; the native fluid proxy is not included |
| Desktop integration | Frameless desktop-level wallpaper window | Browser full screen; no WebGL fallback |
| Detailed guide | [Native app](docs/NATIVE_APP.md) | [Browser target](Browser/README.md) |

For animated Radiant views, both targets reuse solved ray paths while the camera
and geometry are stationary, then shade the evolving source through those paths. Moving the camera requires
new ray tracing and is more expensive than stationary disk animation. Calibration
and measured workload control quality; a GPU's marketing name is not a performance
guarantee.

## Run the native app

From the repository root:

```sh
bash build.sh --run
```

The script creates `outputs/BlackHoleDesk.app` and opens it. It compiles directly
with the installed Apple tools and ad-hoc signs the app for local use; it is not
a notarized distribution. `Package.swift` is also available for Xcode.

Drag to orbit, right-drag to look around, scroll to change field of view, and use
`W A S D Q E` to move the observer. `R` resets the camera and `H` toggles the HUD.
`Shift–Command–W` toggles the desktop-level wallpaper window. The control panel
separates material rotation, time-lapse playback and cinematic camera movement.
See the [native guide](docs/NATIVE_APP.md#controls) for all controls and quality modes.

## Run the browser target

From the repository root, with Node.js 18 or newer:

```sh
node Browser/tools/build.mjs
node Browser/tools/serve.mjs
```

Open [the local simulator](http://127.0.0.1:8765/). The included server binds only
to your computer. Opening `index.html` directly does not work: WebGPU needs a
supported browser in a secure context such as HTTPS or localhost.

The build uses the checked-in `Browser/public/core.wasm`, so a C compiler is not
required. Its first shader-validation run downloads a pinned, integrity-checked
development tool. The result in `outputs/BlackHoleBrowser/` is a self-contained
static application with no runtime CDN or service dependency, suitable for an
HTTPS static host. Rebuilding the C/WASM core and deployment details are in the
[browser guide](Browser/README.md#build-and-run).

Browser controls are similar to the native app; `Space` pauses. Motion first
prioritizes visible animation over spatial detail. More samples, finite thickness,
glare and tighter integration settings are opt-in. Frame-rate targets are budgets,
not promises, and live cross-engine GPU compatibility/performance remains to be
established for the latest optimization pass.

## Physics and presentation

- **Light transport:** finite-distance ZAMO observer tetrads, Kerr null geodesics,
  adaptive integration, disk intersections, relativistic frequency shifts and
  path-dependent light-travel delays. A compensated float-pair path handles
  demanding trajectories; it does not promise unrestricted double precision.
- **Thermal source:** a stationary, optically thick, zero-torque Page–Thorne disk.
  Double-precision CPU quadrature supplies the radial flux and temperature;
  Planck spectra use all 471 official CIE 1931 observer samples.
- **Optional thickness:** a bounded, pressure-inspired photosphere with a
  prescribed outer closure, not a solved vertical atmosphere. Raised-surface
  circular motion is a prescribed supported extension of equatorial kinematics.
- **Animated emission:** analytic material follows the radius-dependent Kerr
  angular rate and retarded emission time. Labelled time-lapse changes the source
  clock, not gas velocities, Doppler shifts or light-travel delays. The optional
  native fluid proxy is artistic 2D flow and has no retarded dye history.
- **Camera art:** palette remapping and glare are disclosed presentation choices.
  They do not claim to reproduce a particular film lens or a measured astrophysical
  image. A hot thermal disk is naturally blue-white in visible light.

Neither target solves GRMHD, magnetic turbulence, self-consistent radiation
hydrodynamics, atmospheric scattering, polarization, returning-radiation heating
or disk self-gravity. Navigation selects successive local observer frames; it
does not integrate a freely falling spacecraft worldline. Step budgets can leave
rays unresolved; the HUD and diagnostic view expose this rather than certifying
every pixel as converged.

Read the [disk model](docs/DISK_MODEL.md), [finite photosphere](docs/THICKNESS_MODEL.md),
[native material-flow model](docs/FLOW_MODEL.md), and
[cinematic-layer boundaries](docs/CINEMATIC_LAYER.md).

## Verify and profile

Native checks require a Metal-capable Apple Silicon Mac:

```sh
bash verify.sh
```

These exercise the production Metal shaders, compare deterministic rays against
an independent binary64 reference and analytic cases, validate source/camera
behavior, and produce offscreen renders and timing reports in `outputs/`.
Close the interactive app before GPU benchmarking. FFmpeg is needed only for
the optional encoded animation preview.

Browser offline checks:

```sh
npm --prefix Browser test
```

For actual browser/GPU checks, run the local server and open
[the verification suite](http://127.0.0.1:8765/?test=1) or
[the extended benchmark](http://127.0.0.1:8765/?benchmark=1), one visible browser
at a time. Reports identify the build, browser and adapter. Offline shader
validation, CPU tests and mocked submission tests are not evidence of a rendered
GPU result or cross-engine parity. See the
[browser performance report](Browser/PERFORMANCE.md) for measured results and
remaining validation work.

## Project map

| Directory | Contents |
| --- | --- |
| `Sources/BlackHoleDesk/` | Native app, Metal shaders, adaptive quality and production-GPU checks |
| `Browser/core/` | C source for the double-precision WASM physics core |
| `Browser/src/` | WGSL renderer, browser controls, quality controller and camera response |
| `Browser/tests/` | WASM, shader-source, host, lifecycle and benchmark tests |
| `Tests/` | Native physical-model checks and independent Python reference calculations |
| `docs/` | Native guide, equations, assumptions and presentation boundaries |

## References and attribution

The main scientific references are [Page & Thorne (1974)](https://articles.adsabs.harvard.edu/pdf/1974ApJ...191..499P),
[Gralla & Lupsasca (2020)](https://arxiv.org/abs/1910.12881), and
[James et al. (2015)](https://arxiv.org/abs/1502.03808).
See [third-party notices](THIRD_PARTY_NOTICES.md) for the official CIE dataset and
filmic-response attribution. No *Interstellar* imagery, textures or other film
assets are included.

No project-wide open-source license has been selected for the original application
code. Third-party components retain their licenses as documented in the notices.
