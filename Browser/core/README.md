# Compiled physics core

`physics.c` is compiled to WebAssembly. Its double-precision Page–Thorne quadrature,
471-wavelength CIE integration, physical unit conversion and source clock run in
WASM; GPU ray tracing runs in WebGPU WGSL. The exported adaptive-scale helper
remains available, while the motion-first UI uses `src/quality.js` for faster
resolution response and frame scheduling. There is no
WASI runtime, JavaScript math import, allocator or per-frame memory growth.

The core preserves the native model: stationary zero-torque Page–Thorne thermal
emission, isotropic blackbody, signed Kerr spin, and a bounded prescribed finite
photosphere. It is not a solved GRMHD flow or disk atmosphere. The CIE data is
CC BY-SA 4.0; its full attribution is retained in `cie1931.h`.

## JavaScript interface (ABI 1)

Instantiate `core.wasm` without imports. `init_spectrum()` builds the invariant
color table once. `init_model(spin, massSolar, mdotSolarMassesPerYear, outerRadius,
thicknessMultiplier)` rebuilds the disk table on physical parameter changes.
Both return `0` on success; invalid model parameters return `1` without mutation.
The dimensionless radial solution is cached by spin and outer radius. Mass and
accretion changes rescale it without repeating quadrature; height-only changes
update metadata without rebuilding the table. Spectral initialization is
idempotent and precomputes wavelength-only factors while retaining all samples.

`memory` is exported. Read `radial_count() × 4` floats at `radial_ptr()` and
`spectral_count() × 4` floats at `spectral_ptr()`. The fixed sizes are 4096 and 2048.
Radial entries contain `(T_eff kelvin, flux W/m² per face, Ω inverse M, u^t)`;
spectral entries contain linear sRGB radiance and CIE Y, divided by the Y of a
10,000 K blackbody. Upload the buffers on changes, never each frame.

Read 11 doubles at `metadata_ptr()`, in this order:

0. ISCO radius in M
1. Outer radius in M
2. Log radial minimum
3. Log radial step
4. Peak effective temperature in kelvin
5. Log spectral temperature minimum
6. Log spectral temperature step
7. Gravitational time `GM/c³` in seconds
8. Nominal binding-energy efficiency
9. Nominal Eddington ratio
10. Bounded photosphere height coefficient in M

`isco(spin)` and `orbital_period(radiusM, spin, massSolar)` are scalar helpers.
`advance_clock(elapsedSeconds, playbackRate, activeInteger)` returns accumulated
source seconds, with `clock_seconds()` and `reset_clock()`. Playback affects the
observation clock, not orbital velocities or travel delays. Freeze elapsed time
when hidden/paused. `adaptive_scale(currentScale, measuredMS, budgetMS, minimum,
maximum)` applies deadband, damping and bounded upward/downward changes.

Build with `node Browser/tools/build-wasm.mjs`; run invariants with
`node Browser/tests/wasm-core.mjs`. A pinned compiler is downloaded into `work/`
only when no `WASI_SDK_PATH` is supplied. Serving the prebuilt target requires no
compiler, runtime package or network downloads.
