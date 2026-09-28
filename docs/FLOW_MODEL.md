# Cinematic disk material flow

This solver is available in the native macOS app only. The browser target uses
an [analytic emitting-material model](../Browser/README.md#scientific-scope).

The optional cinematic material solves a **reduced, forced incompressible 2D fluid equation on a flat computational strip**. It is not a general-relativistic magnetohydrodynamic accretion simulation, and its dye is not a prediction of gas density, temperature, or emitted power. Physical appearance bypasses this simulation.

## Equations and coordinates

The periodic coordinate is `x = phi/pi` in `[0,2]`; the radial coordinate is `y = log(r/r_in)/log(r_out/r_in)` in `[0,1]`. These are material-texture coordinates, not an orthonormal basis or a curved-space metric. The calibrated API accepts `orbitalAngularRate=playbackRate × Ω(r_in)/t_g` in **inner-edge radians per display second**, where `Ω(r)=1/(r^(3/2)+a)` and `t_g=GM/c³` in seconds. Its prescribed mean velocity is therefore `U = (orbitalAngularRate/pi × Ω(r)/Ω(r_in), 0)`. This converts the actual Kerr relative angular rates and the chosen physical mass into explicit time-lapse playback, rather than silently choosing an unrelated fluid spin rate.

The separate turbulence-speed setting `s` is clamped to `[0,4]`. It does not multiply the prescribed orbital rate a second time. The stored velocity perturbation `v` and dye evolve according to the reduced computational-domain equations

```
∂v/∂t + (U+s v)·∇v + (v·∇)U = -∇p + s(ν∇²v + f - γv)
∇·v = 0
∂d/∂t + (U+s v)·∇d = s[κ∇²d + 0.08(d_seed-d)]
```

`ν=0.00002`, `κ=0.000004`, and `γ=0.08` are artistic computational-domain parameters. At `s=1` these are the ordinary perturbation equations around the prescribed mean shear. `s=0` removes turbulent transport, diffusion, and dye sources but **does not stop the bulk orbital advection**; a zero timestep freezes everything. The latent velocity field may still be advected/projected at `s=0`, but it has no effect on dye transport then. A low-amplitude deterministic streamfunction provides curl forcing `f`; a multiscale periodic initial field/source supplies dye contrast. Unlike an animated noise-only texture, velocity and dye persist and are advected by the PDE solver. The forcing clock integrates `s × dt` and the mean source phase separately integrates `orbitalAngularRate × dt`, avoiding phase jumps when the rate changes.

For source compatibility, omitting the new optional `orbitalAngularRate` parameter retains the original standalone-test behavior: 0.055 inner revolutions per animation second, with `speed` multiplying the entire simulation clock. This legacy mode is not a physical mass-scaled rate. Its zero-speed behavior is fully paused. The app uses the calibrated parameter; existing validation tools can still exercise the legacy API unchanged.

## Discretization and efficiency

- Packed MAC/staggered velocity components, consistent backward divergence and forward pressure gradient, periodic azimuth, impermeable/free-slip radial boundaries.
- Midpoint backtracing with bilinear semi-Lagrangian advection; explicit viscosity/dye diffusion at a bounded stable timestep; operator-split pressure projection with 16 (256×128) or 24 (512×256) Jacobi iterations. Pressure is only approximately converged; this is an interactive visual solver, not a precision CFD result.
- Half-precision state storage, float arithmetic, float32 pressure/divergence. Deterministic streamfunction initialization, clamp dye to `[0,1]`, clamp perturbation components to `±0.25`, repair non-finite states defensively. These bounds prioritize robust display over exact conservation.
- At most four substeps of ≤1/60 display second per submitted frame in calibrated mode. A long pause or slow tracing frame advances at most 1/15 second, deliberately discarding excess time to avoid a spiral of simulation work. `timeWasClamped` reports this for the most recent call; `droppedDisplayTimeSeconds` accumulates discarded display time. Consequently the dye can lag the analytic source clock under sustained slow rendering or unsubmitted frames: calibration is not a guarantee of synchronized history. Legacy mode applies the same cap to its speed-scaled animation clock. The maximum turbulence-speed multiplier four remains within the explicit viscosity/diffusion stability limit at the largest supported grid.
- All textures use tracked resources on one ordered Metal command queue; every pass reads and writes distinct textures. Separate encoders establish pass dependencies. Resizing the small flow grid or changing disk radii/spin resets it deterministically. Physical mode should not call the encoder at all.
- Texture channels: `R=dye`, `G=intrinsic azimuthal perturbation velocity`, `B=intrinsic radial perturbation velocity`, `A=0`. Calibrated turbulent transport multiplies stored velocity by `s`; mean rotation is separate. Emission samples `u=fract(phi/2pi)`, `v=normalized log radius`.

## Scientific boundaries

This solver includes neither compressibility, energy conservation, radiation transport, magnetic fields, MRI, vertical structure, nor covariant stress-energy evolution. The spatial mapping also omits polar/relativistic metric terms. It is a controlled artistic source model layered behind the unchanged Kerr geodesic/redshift calculation. Spectral palette changes and dye-to-emission conversion must also be labeled as artistic.

Bulk rotation can now be calibrated to physical Boyer–Lindquist angular rates and an explicit time-lapse multiplier. That does **not** turn the reduced turbulence into physical plasma dynamics. The renderer samples its **current** dye state at ray intersections. No field-history buffer exists, so this secondary material proxy does **not** have correct path-dependent retarded evolution. The dominant analytic material pattern can independently evaluate `phi − Ω(r)[sourceTime/t_g − rayDelay]`, preserving the actual ray delay while advancing source time with playback; do not scale the delay itself by the playback multiplier. The separate stationary thermal disk/ray delay calculations remain available as the scientific baseline. A full faithful fluid disk requires validated relativistic MHD/radiation-MHD simulation data and a suitable time-history/radiative-transfer renderer.

## Numerical-method reference

Jos Stam, *Stable Fluids*, SIGGRAPH 1999, pp. 121–128, [doi:10.1145/311535.311548](https://doi.org/10.1145/311535.311548). The implementation follows the broad semi-Lagrangian advection/projection splitting approach, not a transcription of the paper or its source code. The explicit low-viscosity step here is bounded by the chosen grid and timestep rather than Stam's implicit diffusion solve.

## Repeatable validation

Run `bash verify-flow.sh` on a Metal-capable Mac. Both standalone test programs compile directly with the production solver:

- `Tests/FlowValidation.swift` preserves the 21 legacy-API checks: initialization, finite/bounded evolving fields, impermeable radial walls, deterministic replay, zero-step/zero-speed stability, long-frame capping, and the production pressure projection's reduction of a controlled pure-gradient velocity field. It records remaining divergence and flow-only GPU time at both resolutions in `outputs/flow-validation.json`.
- `Tests/FlowCalibrationValidation.swift` checks the calibrated API independently. With zero turbulence, it measures the actual Fourier phase of production-GPU dye at three radii after one display second and compares it with `playbackRate × Ω(r)/t_g`. It also checks zero-rate freezing, finite/bounded dye, clamp reporting, and cumulative dropped-time accounting. `outputs/flow-calibration-validation.json` records the mass, spin, playback multiplier, measured/expected phases, and the explicit 0.03-radian harmonic-phase tolerance (0.006 radian in the material angle for the selected fifth harmonic).

These tests establish numerical behavior of the reduced visual model; they do not validate it as accretion physics or demonstrate retarded turbulence evolution.
