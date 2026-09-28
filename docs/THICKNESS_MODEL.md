# Finite photosphere and self-occlusion

This document gives the native photosphere prescription and defaults. The
browser target shares the pressure-inspired surface but defaults to zero height
in Motion first; native optional surface corrugation is not exposed there.

The finite disk is an opaque, prescribed photosphere embedded in unchanged Kerr spacetime. A backward ray stops at its first entry into the disk body, so nearer surface material can hide farther emission. This adds genuine geometric thickness and self-occlusion; it is not a screen-space darkening trick. It does not solve a gas atmosphere, vertical hydrostatic balance, or radiative transfer through a volume.

## Baseline surface and the factor of two

We adopt the simple radiation-pressure-supported profile used by [Taylor & Reynolds (2018), equation 4 and the discussion below it](https://arxiv.org/abs/1712.05418). Their pressure scale height is `H=(3/2)(mdot_Edd/eta)[1−sqrt(r_ISCO/rho)]`, and their assumed photosphere is at `z=2H`. The upper/lower photospheres are therefore `±z`, and the full top-to-bottom thickness is `2z=4H`.

[Zhou et al. (2020), equations 6–7 and the accompanying finite-thickness thermal model](https://arxiv.org/abs/2004.12589), use the same prescription. Neither source treats this simple surface as a complete self-consistent disk solution.

The code's explicit convention is

```
r_g = GM/c²
eta = 1 − E_ISCO
L_Edd = 4 pi G M m_p c / sigma_T
lambda = L_nom/L_Edd = eta Mdot c²/L_Edd
Mdot_Edd = L_Edd/(eta c²), so Mdot/Mdot_Edd = lambda
A_nominal = 3 lambda/eta × thicknessMultiplier
z_pressure(rho) = A [1 − sqrt(r_ISCO/rho)]
rho = r sin(theta), z_coordinate = r cos(theta)
```

`A`, `r`, `rho`, and `z` are in units `r_g`. `rho` and `z_coordinate` are **pseudo-cylindrical Boyer–Lindquist coordinates**, not proper lengths or Kerr–Schild Cartesian coordinates. Using the selected finite outer radius to reduce `lambda` would incorrectly change the inner disk geometry: `lambda` uses the nominal untruncated binding-energy luminosity, consistently with the existing disk model.

The underlying pressure profile is zero at/below `rho=r_ISCO`, rises outward, and approaches `A`. The renderer additionally closes the finite emitting annulus smoothly at its chosen outer cylindrical radius, as specified below. Multiplying the height changes only geometry, not accretion rate or the stored Page–Thorne thermal flux. Values other than one are therefore prescribed variations, not a recalculated physical equilibrium.

## Prescribed outer-annulus closure

An abrupt truncation of a positive-height opaque body produces a vertical cylindrical wall. That wall would need its own radial atmosphere/emission model; extending the surface temperature down it merely makes the arbitrary cutoff visibly look like a solid rim. The renderer instead multiplies the pressure height by a **prescribed geometric taper**, leaving the inner profile unchanged:

```
t = clamp((r_outer − rho)/(0.2 r_outer), 0, 1)
C(rho) = t³ (10 − 15t + 6t²)
z(rho,phi) = z_pressure(rho) × corrugationFactor(rho,phi) × C(rho)
```

`C=1` for `rho≤0.8 r_outer` and `C=0` at/beyond `r_outer`. Both its first and second derivatives vanish at either transition: the closure is C², so upper and lower surfaces meet the equatorial plane without a vertical outer wall. The complementary coordinate `t` avoids subtracting nearly equal numbers near the outer edge. The ray intersection still enforces the outer radial boundary. This geometric closure is explicitly **not** derived from vertical equilibrium, the fluid simulation, or a physical outer-disk transition. It does not change the Page–Thorne thermal lookup. It is an artistic boundary condition for the selected finite annulus, distinct from the published untruncated pressure profile.

## Guardrail and reference numbers

The following cap is our implementation choice. For the uncorrugated, untapered pressure profile,

```
max(z/rho) = 4A/(27 r_ISCO), at rho = (9/4) r_ISCO.
A_max = 0.20 × 27 r_ISCO / [4 × 1.08]
A = min(A_nominal, A_max)
```

The factor 1.08 reserves the entire supported corrugation amplitude. Thus every supported surface has photosphere half-height `z/rho≤0.20`, or pressure height `H/rho≤0.10`; an uncorrugated capped profile has an upper bound `z/rho=0.185185`. The closure multiplier is between zero and one, so it cannot violate this bound; the untapered maximum is retained only when it falls inside the untapered part of the annulus. This guardrail prevents arbitrarily thick geometry from being passed off as a thin-disk result. It does **not** establish the physical validity of the flux, opacity, or thermal state at arbitrary input accretion rates. A capped result should be disclosed as capped rather than claimed as a prediction. Above roughly a few tenths Eddington, radial energy advection and other missing physics become particularly important.

For the application's nominal `M=10^8 M_sun`, `Mdot=0.1 M_sun/year`, `a=0.82`, outer radius `30 M`, multiplier one, and zero corrugation:

| Quantity | Value |
|---|---:|
| `r_ISCO` | 2.80014129 M |
| `eta` | 0.12712156 |
| `L_nom/L_Edd` | 0.05726704 |
| `A_nominal` (uncapped) | 1.35147124 M |
| Maximum `z/rho` | 0.07150281 |
| Radius of maximum aspect ratio | 6.30031790 M |
| `z` at `rho=6 M` | 0.42821733 M |
| `z` at `rho=10 M` | 0.63632183 M |
| `z` at `rho=30 M`, with outer closure | 0 M |
| Extrapolated pressure height at `rho=30 M`, before closure | 0.93857954 M |
| `A_max` | 3.50017661 M |

The shipped default multiplier is 0.75: a presentation adjustment reducing these heights by 25%, with `A=1.01360343 M` and maximum `z/rho=0.05362711` (5.36%). The table above retains the unscaled, multiplier-one reference. Neither profile is capped at these parameters. At this spin/mass, the cap starts at thickness multiplier about 2.58990 for the default accretion rate, or `Mdot≈0.258990 M_sun/year` (`lambda≈0.148316`) at multiplier one. The conservative reserved corrugation bound is independent of whether corrugation is actually enabled.

## Optional corrugation

The CPU/Metal contract is exactly

```
q = log(rho/r_ISCO)
c = clamp(corrugation, 0, 0.08)
f = 1 + c [0.65 cos(3 phi + 2q) + 0.35 cos(7 phi − 3q)]
z(rho,phi) = A [1 − sqrt(r_ISCO/rho)] f C(rho)
```

Default `c=0` retains an axisymmetric stationary surface. Any nonzero value is a small prescribed stationary pattern, **not** height derived from the material-flow solver. In particular, an azimuthally corrugated stationary surface and purely circular fluid velocity do not by themselves describe fluid moving tangent to that surface. Do not interpret that optional appearance setting as a dynamically self-consistent atmosphere.

## Surface emitter velocity and redshift

Following the finite-thickness kinematic prescription, the angular velocity is evaluated at the corresponding equatorial cylindrical radius, `Omega=1/(rho^(3/2)+a)`. The actual four-velocity must nevertheless be normalized using the Kerr metric **at the off-equatorial emitting point**:

```
Sigma = r² + a² cos²(theta)
g_tt = −(1−2r/Sigma)
g_tphi = −2ar sin²(theta)/Sigma
g_phiphi = [r²+a²+2a²r sin²(theta)/Sigma] sin²(theta)
D = −g_tt − 2 Omega g_tphi − Omega² g_phiphi
u^t = 1/sqrt(D), u^phi = Omega u^t, u^r=u^theta=0
g_munu u^mu u^nu = −1
```

Reject `D≤0` or a nonfinite value instead of inventing a timelike emitter. Reusing equatorial `u^t` at a raised surface is incorrect. With the renderer's conserved photon angular-momentum ratio `xi=Lz/E_inf` and `cameraEnergy=E_inf/E_camera`, the observed frequency shift is `g=1/[cameraEnergy u^t (1−Omega xi)]`; compare against the direct four-vector contraction in tests. These circular off-plane trajectories are a prescribed supported flow, not free geodesics.

The radial thermal law is still the thin-disk Page–Thorne baseline evaluated at the cylindrical source radius. Raising its emitting surface does not turn that baseline into a vertically solved atmosphere. All existing exclusions—magnetic stresses, radial energy transport, self-consistent optical depth, returning-radiation heating, and photon histories of the artistic material flow—remain relevant.
