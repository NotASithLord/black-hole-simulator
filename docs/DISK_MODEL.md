# Accretion disk and visible spectrum

This document describes the native model, defaults and validation. The browser
shares the thermal equations but has different presentation defaults and some
table sizes; see the [browser model and limitations](../Browser/README.md#scientific-scope).

The scientific baseline uses an equatorial, stationary, optically thick Page–Thorne thin disk with zero stress at the ISCO. Its mean flow follows circular Kerr geodesics. The radial flux is calculated from the relativistic specific energy, angular momentum, and angular velocity, rather than a Newtonian radial power law. The model excludes returning-radiation heating, magnetic stress in the plunging region, finite thickness, radial heat transport, atmosphere scattering, and self-gravity. These are physical model assumptions, not claims that all astrophysical disks behave this way. [Page & Thorne, 1974, equations 11b, 12, and 15](https://articles.adsabs.harvard.edu/pdf/1974ApJ...191..499P).

The default **Radiant** appearance layers explicit artistic palette and material modulation over this baseline and uses photographic glare/filmic display mapping. Its separate reduced 2D flow is documented in `FLOW_MODEL.md`; its current-state dye is not a retarded GRMHD solution. Select **Scientific** to view the source described below without those artistic additions.

In units r = R/(GM/c²) and Ω = Ω_physical GM/c³, the flux emitted from each face is

```
F = [Mdot c² / (4π (GM/c²)²)]
    × [-dΩ/dr / (r (E − ΩL)²)]
    × integral_ISCO^r (E − ΩL) (dL/dr) dr.
T_eff = (F / sigma_SB)^(1/4).
```

The integral is evaluated in Double using eight-point Gauss–Legendre quadrature per cell of a 4096-sample logarithmic radial grid. An analytic derivative of L avoids finite-difference noise. The lookup table stores temperature, physical flux, orbital frequency, and u^t. Radius is not a Euclidean proper distance.

The application's default model is M = 10⁸ solar masses, Mdot = 0.1 solar masses/year, spin 0.82, and an outer emitting radius of 30 GM/c². Its peak effective temperature is about 94,418 K, and GM/c³ is 492.564 seconds. Its nominal binding-energy luminosity before photon capture is approximately 5.73% of Eddington for an untruncated disk; the selected finite emitting region radiates less. The configurable outer edge is an explicit source truncation, not a universal radius predicted by the thin-disk equations. It does not change the calculated flux inside that edge.

For reuse and independent tests, the `DiskModel` type retains defaults of Mdot = 0.01 solar masses/year and outer radius 80 GM/c²; its peak temperature at spin 0.82 is about 53,095 K. The application passes its own parameters explicitly. Both parameter sets define chosen idealized systems. Mass and accretion rate are independent inputs; the code does not solve for self-consistent thickness, optical depth, ionization, or an accretion-state transition. Parameter changes can move the chosen system outside the physical validity of an optically thick, radiatively efficient thin disk.

The local spectrum is Planck B_lambda(T_eff), with isotropic emitted specific intensity and color correction equal to one. Planck radiance is integrated against all 471 official [CIE 1931 2° observer samples](https://cie.co.at/datatable/cie-1931-colour-matching-functions-2-degree-observer), at 1 nm intervals from 360 to 830 nm, and converted from XYZ to linear sRGB. See `THIRD_PARTY_NOTICES.md` for the dataset license. The [ICC sRGB specification](https://registry.color.org/rgb-registry/files/sRGB.pdf) describes the display color space.

The application's spectral table spans 300–10⁷ K with 4096 logarithmic samples; the reusable function and independent test use 2048 samples. All radiances are divided by one fixed reference, the luminance of a 10,000 K blackbody; brightness differences between temperatures remain intact. CIE 1931 describes the standard photopic 2° colorimetric observer, not an individual viewer, a camera's sensor response, ultraviolet/X-ray emission, or dark-adapted human vision. The 360–830 nm spectral integration is a visible-color calculation, not a bolometric luminosity calculation. Exposure, tone mapping, and clipping to the SDR sRGB display gamut are separate display operations, and the displayed pixel is not an absolute radiance measurement. A hot disk is naturally blue-white in visible light; a warm film palette is not imposed.

Liouville invariance gives I_nu,obs = g³ I_nu,em(nu_obs/g). For a blackbody this is exactly B_nu(g T_eff), so the shader samples the spectral table at g T_eff. It must not apply an additional g³ or T⁴ multiplier. Equivalently, I_lambda,obs(lambda) = g⁵ B_lambda(g lambda,T_eff). Isotropic surface radiance also has no extra cosine-of-emission-angle multiplier.

An axisymmetric stationary disk is time-independent. Any enabled orbiting temperature perturbation is an explicitly prescribed departure from the mean disk, not a magnetohydrodynamic simulation. Its phase uses the emission event's retarded coordinate time: the elapsed Boyer–Lindquist time in units GM/c³ minus the ray's coordinate travel time. The application's clock is measured at infinity; it is not the local observer's proper clock. A selected playback rate scales the accumulated coordinate time, never the geodesic delay or emitter velocity. The default Radiant material is shown at labelled 1,000× playback; 1× remains selectable. An ISCO orbit at the default mass/spin takes about 4.73 hours physically, explaining why 1× looks nearly static over seconds. Pausing, freezing rotation, or hiding the application pauses disk evolution. The camera keeps a separate wall clock. Camera navigation samples local ZAMO observer frames at successive positions rather than integrating a freely falling observer's worldline and velocity.

## Reproducible verification

After `bash build.sh` has created the local toolchain overlay:

```sh
swiftc -O -vfsoverlay work/toolchain-overlay.json \
  -Xcc -ivfsoverlay -Xcc work/toolchain-overlay.json \
  Sources/BlackHoleDesk/CIE1931.swift \
  Sources/BlackHoleDesk/DiskPhysics.swift \
  Tests/DiskPhysicsValidation.swift -o work/disk_validation
./work/disk_validation
```

The 31 checks cover Schwarzschild and Kerr ISCOs, E − ΩL = 1/u^t, dE/dr = ΩdL/dr, the independent analytic Schwarzschild flux integral, zero ISCO torque, mass/accretion-rate scaling, emitted-energy balance, official CIE column sums, blackbody chromaticity, spectral redshift invariance, and lookup interpolation.

The initial local run measured a maximum relative Schwarzschild integral error of 1.21×10⁻¹¹, circular-energy-identity error of 1.60×10⁻⁹, and emitted-energy residual below 1.26×10⁻⁷ of Mdot c² across spins 0, 0.82, and 0.998 after an analytic outer-tail correction. The tested spectral interpolation luminance error was at most 0.155% over selected temperatures from 1000 to 10⁶ K. These are specific test results, not a global error bound on the rendered image or an astrophysical validation.
