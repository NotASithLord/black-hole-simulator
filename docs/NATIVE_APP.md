# Native macOS app

This guide covers the SwiftUI/Metal target. For the WebAssembly/WebGPU target,
see the [browser guide](../Browser/README.md); for an overview of both, see the
[project README](../README.md). Commands below run from the repository root.

Native SwiftUI, AppKit and Metal for macOS. **Radiant**, the default appearance, adds warm art-directed emission, evolving GPU fluid texture, and photographic glare to an accurate Kerr ray tracer. **Scientific** retains the original thermal thin-disk rendering for comparison. No film assets, painted photon rings, or MLX are used. The fluid/material treatment is explicitly not a complete relativistic plasma simulation.

## New appearance and efficient animation

- **Radiant:** amber outer material, hot ivory highlights, intrinsic disk filaments, evolving fluid detail, and a soft multiscale lens response. The artistic palette changes emission color; it is not a claim that the physical gas has cooled. Before material attenuation, palette chromaticity is normalized to the physical received luminance, preserving the Doppler brightness asymmetry.
- **Scientific:** Page–Thorne flux, Planck spectrum, full relativistic color/brightness shifts, and the previous neutral display response. No fluid texture, palette remapping, or glow. Stationary progressive sampling remains available.
- **Details → Light & Camera:** exposure, emission tint, structure, lens glow, fluid motion and animation speed. The optional Cinematic camera passage moves only the observer; it is separate from the `Cinematic` quality mode.
- **Cached transport:** a stationary Radiant camera traces multisampled Kerr paths once, storing emitter radius, azimuth, travel delay and redshift. Each subsequent frame evolves and shades the emitting material through that same map. Moving the camera, changing spin/radii or integration/sampling settings rebuilds it. This is reuse of solved light paths, not a screen-space imitation of lensing. Cached samples are labeled separately from newly traced rays in the HUD.
- **Actual reduced fluid solve:** a 256×128 or 512×256 Metal incompressible flow solver advects persistent velocity and emission dye, with differential shear, viscosity, forcing and approximate pressure projection. It uses artistic texture coordinates and accelerated time, not GRMHD. It samples the current dye field, without a retarded-time history. See `docs/FLOW_MODEL.md` for the equations and limits.
- **Finite photosphere:** Radiant now defaults to a modest, radius-dependent disk height tied to the selected mass and accretion rate. Rays stop at the first opaque surface, so foreground material can genuinely hide secondary images. The arbitrary outer boundary closes smoothly instead of becoming a vertical wall. Scientific keeps the razor-thin reference geometry.
- **Thin-arc sampling:** only pixels near detected image/occlusion boundaries receive an additional 4, 8 or 16 stratified geodesic samples. This refines the actual light paths instead of blurring the silhouette. Those samples are cached with the rest of the geometry.
- **Visible differential rotation:** the dominant material now uses an explicitly labelled, integrated source clock, defaulting to 1,000× time-lapse. At the default mass/spin, an ISCO orbit is about 4.73 physical hours, or 17.0 display seconds at 1,000×. Inner material moves faster than outer material; camera orbit is a separate control. Choose 1× for real-time physics, 100×, 1,000× or 4,000× in Details.
- **Celestial environment:** Radiant can reveal a faint, static procedural stellar field only for rays that the existing Kerr integrator classifies as escaped. It uses the stored azimuth and polar coordinate at the finite escape surface, so the image is lensed by the same solved path rather than painted behind the hole. It is a cinematic environmental field, not a real star catalogue or an astrophysical sky model; Scientific retains the black reference sky.

The wider default field of view gives the disk breathing room. Material and camera controls do not change the metric or geodesic accuracy. All cached samples are shaded afresh each frame, so animation is not blurred with stale temporal history.

## Run

Open `outputs/BlackHoleDesk.app`, or build and open it:

```sh
bash build.sh --run
```

The supplied build script targets Apple Silicon and macOS 14+, using the Apple Command Line Tools. A Swift package is also provided for Xcode. If duplicate SwiftBridging module definitions are present in Command Line Tools, the direct build applies a compiler-local overlay without modifying the installed tools. The app is ad-hoc signed for local use, not notarized for distribution. Quit a running copy before reopening a rebuilt app.

## Physics

**Observer:** rays originate from an orthonormal ZAMO tetrad at the actual selected radius and inclination. Camera direction is converted to conserved photon energy, axial angular momentum, and Carter constant. No observer-at-infinity approximation is used for the camera. Moving the viewing position selects a succession of ZAMO observers; it is not a free-falling spacecraft worldline with a separately specified velocity.

**Propagation:** Carter's separated Kerr equations, in units G=c=M=1, evolve in Mino time. Reciprocal radius and cos(theta) pass smoothly through turning points. Embedded Dormand–Prince integration controls local truncation error, disk events are localized along the higher-order trajectory, and conserved-potential residuals are monitored. Both azimuth and coordinate light-travel time are integrated. Failed or budget-exhausted rays are counted in the HUD and can be displayed in magenta; the local tolerance is not a guaranteed global image-error bound.

Near unstable photon orbits, a condition test selects a compensated arithmetic path: each radial, azimuth and time quantity uses a pair of floats, with step-doubling error control. This addresses accumulated roundoff that ordinary GPU precision failed to resolve. Camera uniforms and conserved quantities still enter at float32 precision. Extremely near a critical orbit, tiny changes in those inputs can amplify into a noticeable escaped-ray direction difference; the validation report quantifies that separately. This does not claim unrestricted double-precision accuracy everywhere.

**Emission:** the disk flux comes from the Page–Thorne relativistic integral, evaluated in Double with eight-point Gauss–Legendre quadrature on a logarithmic radius grid. It vanishes at the spin-dependent ISCO. The local effective temperature follows F=σT⁴; its isotropic surface spectrum is Planck radiation. At an opaque disk intersection, `g=1/[E_camera u^t (1−Ωξ)]` gives the observed/emitted frequency ratio. Liouville's theorem allows exact blackbody transfer through `Bν(gT)` without applying a second beaming factor.

**Thickness:** the baseline photosphere uses `z=3(L_nom/L_Edd)/eta × [1−sqrt(r_ISCO/rho)]`, with `rho=r sin(theta)` in pseudo-cylindrical Boyer–Lindquist coordinates. This is the radiation-pressure-inspired surface prescription used by [Taylor & Reynolds (2018)](https://arxiv.org/abs/1712.05418) and [Zhou et al. (2020)](https://arxiv.org/abs/2004.12589), not a newly solved atmosphere. The default height multiplier is 0.75, a presentation adjustment giving a maximum half-height/radius of about 5.36%, compared with 7.15% at multiplier one; full top-to-bottom thickness is twice that. A prescribed smooth taper closes the last 20% of the finite outer radius; that boundary treatment is our modeling choice, not a prediction from those papers. The app normalizes the emitter's circular velocity using the actual off-equatorial Kerr metric and evaluates the existing thermal law at cylindrical radius. The latter is still a thin-disk flux approximation. A disclosed geometric guardrail limits half-height/radius to 0.20; it does not validate high-accretion physics. Optional small surface ripples are prescribed, stationary geometry, off by default, and are not driven by the fluid solver. See `docs/THICKNESS_MODEL.md` for conventions, equations and limitations.

**Color and fluctuations:** Planck radiance is integrated against all 471 official CIE 1931 observer samples, converted to linear sRGB, and stored in a spectral table. All temperatures share one fixed luminance reference. Scientific mode uses exposure and common-factor highlight compression; its hot source is blue-white. Radiant mode deliberately maps local emission chromaticity to a warmer thermal palette while retaining the calculated redshift. The optional light-fluctuation field is a bounded, deterministic co-moving emissivity modulation evaluated at each ray's retarded emission time and carried by the existing differential Kerr angular rate. Its mapped-footprint damping prevents unresolved shear from becoming pixel flicker; zero restores the steady Page–Thorne source. It is a prescribed visual/material variation, not a GRMHD temperature history or a change to the mean thin-disk table.

**Camera:** Radiant derives a small halo and restrained horizontal aperture streak from resolved HDR highlights, then applies a filmic luminance curve and SDR gamut compression. Constant and black fields stay unchanged; a bright calculated disk arc—not a painted black-hole overlay—causes the photographic artifacts. This is a generic photographic response, not a measured IMAX lens or full ACES color pipeline. Half-float glare storage clamps exceptionally large values as a numerical safeguard; it is not a universally energy-conserving radiometric instrument. The filmic fit is adapted from [Krzysztof Narkowicz](https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/), available under CC0.

**Time and rotation:** a Double-precision host clock accumulates Boyer–Lindquist coordinate seconds at the selected playback rate, independently of how many GPU submissions finish. Changing speed changes its slope, not its phase. At radius `rho`, the intrinsic analytic material uses `phi − Omega(rho) × [sourceSeconds/t_g − rayDelay]`, with `Omega=1/(rho^(3/2)+a)` and `t_g=GM/c³`. Playback scales source time only: the stored travel delay and emitter velocity/Doppler factor are never multiplied by playback speed. Thus different lensed paths see different, correctly delayed phases of this prescribed material. Equatorial circular kinematics follow the Kerr model; raised-surface motion remains the supported, prescribed extension documented in the thickness model. The stationary, axisymmetric Scientific source has no visible motion unless its optional prescribed perturbations are enabled.

The optional fluid dye's mean angular rate is calibrated to the same orbital law and playback speed, but its perturbations remain an artistic 2D proxy. Its bounded solver may discard catch-up time after expensive tracing frames; the HUD flags that limit without slowing the analytic orbital clock. Dye has no retarded history. Do not interpret the entire combined material as a causal GRMHD simulation. Pause, freezing disk rotation, and normal-window occlusion freeze disk evolution. The cinematic camera always uses its separate wall clock.

Radiant uses bounded material-only temporal sampling (four in Max, two in Auto/Cinematic, one in Efficient/wallpaper) over a centred half-frame exposure, expressed in physical source seconds. This reduces motion shimmer without retracing the geodesics. It averages only analytic material attenuation; the fluid snapshot, spectrum, camera and geometry are held fixed. It is not full moving-camera or relativistic-fluid motion blur. Spatial filtering additionally suppresses unresolved fine structure as differential rotation winds the prescribed filaments. The general reason for temporal filtering is discussed in [James et al. (2015), Appendix A.3.2](https://arxiv.org/html/1502.03808).

Default source: spin 0.82, mass 10⁸ M☉, accretion rate 0.1 M☉/year, outer emitting radius 30M. The peak effective temperature is approximately 94,400 K and nominal L/L_Edd≈0.057. The outer cutoff is a selectable source boundary, not a prediction of a universal disk edge. Controls allow 20M, 30M or 80M.

## Controls

| Control | Action |
|---|---|
| Left drag | Change observer azimuth and inclination |
| Right drag | Look around in the local observer frame |
| Scroll | Change optical field of view |
| W/S | Approach/retreat (12–300M) |
| A/D, Q/E | Change azimuth, elevation |
| R / H | Reset camera / toggle HUD |
| Shift–Command–W | Toggle desktop-level wallpaper window |
| Double-click | Hide/show control strip |
| Radiant / Scientific | Switch art-directed source/camera versus thermal baseline |
| Cinematic presentation | Applies a restrained Radiant presentation preset: warm photographic palette, stronger material structure and glare, a bounded 6% co-moving light variation, and live material at 1,000× time-lapse. It leaves the selected spacetime, disk geometry, spin/mass/accretion settings, and Doppler shifts alone. |
| Cinematic camera | Move the ZAMO observer through a slow, wide passage. Each new position retraces the Kerr map, so use it deliberately at Max Fidelity; it is independent of material rotation. |
| Details → Rotate disk material / Disk playback | Freeze material, or choose physical 1× / labelled time-lapse rates |
| Details → Turbulence speed | Change optional fluid perturbations without changing the calibrated mean orbit |
| Details | Light/camera controls, physical parameters, error display, and optional prescribed light fluctuations |
| Details → Physical model, in Radiant | Finite thickness on/off, height multiplier, optional surface ripples, thin-arc refinement |

Click the render area before using movement keys. Orbit varies viewing inclination slowly and therefore rebuilds the ray map. Wallpaper is a frameless desktop-level window on the current display; leaving it restores its previous frame. This is not a macOS wallpaper provider and does not yet manage multiple displays independently.

## Quality and hardware use

All quality modes use the same metric and chosen source appearance. The renderer inspects Metal GPU families, unified memory, and recommended working-set size. Navigation calibration measures actual GPU command duration; subsequent adaptation uses a rolling median of traced frames. Cached material-only frames do not falsely increase the tracing budget. After 45 stationary cached frames, a separate bounded refinement uses the last measured **trace** cost to increase resolution/sampling if there is headroom for a one-off map build. There are at most three refinement stages per quality configuration; build budgets are 600 ms Max, 260 ms Cinematic, 160 ms Auto, 80 ms Efficient. Wallpaper skips this refinement. GPU capacity is not inferred from CPU cores or a marketing model name.

| Mode | Numerical target / sampling policy |
|---|---|
| Auto | Local target 2×10⁻⁶; adapt internal resolution and samples toward 60 FPS |
| Efficient | Local target 3×10⁻⁶; lower starting resolution, 30 FPS ceiling |
| Cinematic | Local target 8×10⁻⁷; 30 FPS budget, more sampling |
| Max Fidelity | Local target 3×10⁻⁷; full drawable resolution within memory limits, up to 8,192 integration attempts and 32 samples/frame; accept lower FPS |

Max Fidelity does not lower its accuracy target or render scale to meet a frame-time budget. It adjusts samples per submitted frame and progressively averages additional independent samples while the camera and physical scene are stationary. Camera, physical parameters, resolution, or sampling changes invalidate history; moving/perturbed scenes do not reuse stale frames. History is stored in float32 linear radiance. A larger GPU can spend more work per frame at the same physics settings; no particular future GPU's performance is claimed without measurement.

The preceding progressive policy applies to Scientific mode. Radiant caches up to eight samples/pixel in Max Fidelity (four in other modes), with its additional memory included in the render-resolution cap. It updates material/camera each frame without a progressive radiance history. Full-resolution tight-tolerance camera motion still costs a fresh expensive trace; fast stationary animation does not imply equally fast navigation. Fluid quality is 512×256 in Max Fidelity, 256×128 otherwise and in wallpaper mode.

Sparse edge refinement uses 16 samples in Max, 8 in Auto/Cinematic, and 4 in Efficient/wallpaper. It replaces the base sample estimate at selected pixels and reserves up to 3% of the frame, capped at 200,000 pixels. If that storage fills, remaining pixels keep their valid base samples; the HUD reports the overflow. Resolution limits include the sparse storage. An entirely subpixel image can still escape detection if all base/neighbor rays miss it; this is bounded adaptive sampling, not a proof that every photon subring is resolved. Changing thickness, ripples or edge sampling invalidates the cached geometry.

Per-pixel valid-frame counts prevent failed rays from being averaged as black. This avoids adding that bias to known valid history, but missing samples remain unresolved information, not a reconstructed physical answer. Error-display mode bypasses accumulation so failures remain visible. Averaging becomes an exponential moving estimate after 65,535 valid frames to bound float32 history weights. The HUD sample count is an upper bound; individual pixels may have fewer valid samples.

Wallpaper uses a 30 FPS ceiling and a lower GPU budget, reduced further in Low Power Mode or serious thermal states. Normal minimized/occluded windows stop issuing GPU work. At most two command buffers are in flight. The HUD reports completed FPS separately from GPU milliseconds, rays/sec, local tolerance, the integration cap, accumulated samples and unresolved pixels.

## Verify and profile

```sh
bash verify.sh
```

This builds the app, checks disk energetics and color calculations, runs deterministic rays through the actual production Metal integrator, compares them against an independent binary64 reference and analytic photon orbits, then benchmarks two offscreen render workloads. Results appear in `outputs/physics-validation.md`, `outputs/disk-validation.txt`, `outputs/gpu-benchmark.json` and `outputs/physical-render.png`. Close the interactive app before benchmarking to avoid sharing GPU time. Measurements are scene- and machine-dependent.

It also runs the production camera/material tests and saves `outputs/radiant-render.png`, `outputs/scientific-comparison.png`, and `outputs/appearance-validation.json`. Tests compare cached and direct physical shading, verify palette luminance preservation before material modulation, check glow/color/HDR response, and exercise fluid evolution. `outputs/flow-validation.json` records additional pressure/projection checks. Image exports are actual Metal renders, not mockups.

Rotation checks exercise the actual shader's orbital phase, mass scaling, light-travel timing, shutter averaging and time-varying material, plus host clock continuity and frame-rate independence. `outputs/rotation-preview.mp4` is an actual cached Metal render with stationary camera and 1,000× source playback, not a screen-space rotating image. The preview is not looped: differentially rotating radii have different orbital periods. `outputs/rotation-validation.json` and `outputs/disk-motion-validation.txt` record the checks. FFmpeg is required only for encoding the optional preview, not for the app or its numerical checks.

Finite-surface tests additionally compare GPU first-hit coordinates, self-occlusion, off-plane velocity normalization and frequency shifts against an independent binary64 surface-event calculation. Reproduce separately with `outputs/BlackHoleDesk.app/Contents/MacOS/BlackHoleDesk --thickness-test outputs` followed by `python3 Tests/validate_thickness.py`. The matched images `photosphere-thin.png`, `photosphere-finite.png` and `photosphere-finite-aa.png` use identical material/camera settings so geometry and sampling differences are visible.

The independently implemented reference uses Boyer–Lindquist r/theta rather than the shader's reciprocal-radius/polar-cosine equations. Tests include Schwarzschild shadow radius 3√3 M, Kerr photon-orbit capture brackets, weak-field deflection, finite-distance tetrad normalization, polar rays, free-look rays, disk event positions, retarded times, invariant residuals and numerical convergence. These checks are evidence for the tested cases, not universal astrophysical validation.

## Model boundaries

A thin, stationary, optically thick disk is a physical model with explicit assumptions. Finite thickness is now modeled geometrically, but vertical hydrostatic/radiative balance is not solved. This is not a self-consistent GRMHD radiation simulation: physical plasma turbulence, magnetic stresses, atmospheric scattering, polarization, self-gravity, returning-radiation heating and feedback remain outside the model. The reduced 2D material solver is not a substitute for those equations. A camera inside the opaque disk body is unsupported and counted as unresolved, rather than given invented interior emission. A velocity-boosted observer, time-dependent spacetime, and arbitrary spin-axis orientation are also outside the current model. Inputs must be interpreted within the thin-disk regime; selecting a large nominal Eddington ratio does not make this a validated thick-disk model.

The final film *Interstellar* deliberately adjusted some brightness and spectral effects. Matching its final appearance exactly is therefore not the scientific validation target. [James et al., 2015](https://arxiv.org/abs/1502.03808).

## Architecture and sources

- `MetalView.swift`: native input, camera, GPU submission, progressive history, telemetry.
- `AdaptiveQuality.swift`: capability inspection and measured workload control.
- `ShaderSource.swift`: Kerr propagation, observer tetrad, frequency transfer and display.
- `CameraResponse.swift`: normalized multiscale glare, filmic luminance response and SDR presentation.
- `docs/CINEMATIC_LAYER.md`: a concise boundary between calculated transport and the optional cinematic layer.
- `DiskFlow.swift`: reduced GPU velocity/dye solver for artistic emission material.
- `DiskGeometry.swift`: pressure-inspired photosphere and explicit thickness guardrail.
- `DiskMotion.swift`: Kerr orbital periods and phase-continuous, frame-rate-independent source clock.
- `RotationValidation.swift` / `Tests/DiskMotionValidation.swift`: GPU material-motion checks, animated preview and host clock tests.
- `GeometryRefinement.swift`: sparse, cached geodesic supersampling at image boundaries.
- `ThicknessValidation.swift` / `Tests/validate_thickness.py`: production-GPU and independent finite-surface checks.
- `AppearanceValidation.swift`: production-GPU transport, fluid, color and camera checks plus image export.
- `DiskPhysics.swift` / `CIE1931.swift`: physical disk and spectral tables.
- `GPUVerification.swift` / `Tests/`: production-GPU diagnostics and independent checks.
- `docs/DISK_MODEL.md`: disk equations, assumptions and test details.
- `THIRD_PARTY_NOTICES.md`: official CIE dataset attribution and license.

Primary equations: [Gralla & Lupsasca, 2020](https://arxiv.org/abs/1910.12881), [James et al., 2015](https://arxiv.org/abs/1502.03808), [Page & Thorne, 1974](https://articles.adsabs.harvard.edu/pdf/1974ApJ...191..499P). Color data: [CIE 1931 2° standard observer](https://cie.co.at/datatable/cie-1931-colour-matching-functions-2-degree-observer).
