import Foundation

/// Finite, optically thick photosphere inspired by Taylor & Reynolds (2018),
/// eq. 4 and z=2H, and Zhou et al. (2020), eqs. 6–7. This is an approximate
/// prescribed surface, not a solved vertical atmosphere or GRMHD disk.
enum DiskGeometry {
    /// z is the positive photosphere HALF-height; pressure scale height H=z/2.
    /// This rendering bound is a modeling guardrail, not a law of thin disks.
    static let maximumAspectRatio = 0.20
    static let maximumCorrugation = 0.08

    /// Maximum allowed coefficient A in z=A[1-sqrt(r_ISCO/rho)]. The radial
    /// maximum of z/rho occurs at rho=(9/4)r_ISCO and equals 4A/(27r_ISCO).
    /// Reserve the full supported corrugation amplitude, keeping z/rho <=0.20.
    static func maximumHeightScale(innerRadius: Double) -> Double {
        guard innerRadius.isFinite, innerRadius > 0 else { return 0 }
        return maximumAspectRatio * 27 * innerRadius / (4 * (1 + maximumCorrugation))
    }

    /// Nominal coefficient BEFORE the geometric guardrail, in units GM/c².
    /// lambda = eta Mdot c² / L_Edd, so A=3 lambda/eta, not 6 lambda/eta.
    /// Multiplier!=1 is an explicitly chosen geometry variation.
    static func nominalHeightScale(for model: DiskModel, multiplier: Float) -> Double {
        guard model.spin.isFinite, abs(model.spin) <= 0.9999,
              model.massSolar.isFinite, model.massSolar > 0,
              model.accretionSolarMassesPerYear.isFinite, model.accretionSolarMassesPerYear >= 0,
              multiplier.isFinite, multiplier > 0 else { return 0 }
        let efficiency = model.nominalEfficiency
        guard efficiency.isFinite, efficiency > 0 else { return 0 }
        let requested = 3 * model.nominalEddingtonRatio / efficiency * Double(multiplier)
        return requested.isNaN ? 0 : max(0, requested)
    }

    /// Bounded coefficient uploaded to Metal. At fixed physical Mdot/M, the
    /// efficiency cancels from the uncapped coefficient; spin still controls
    /// r_ISCO, the radial profile, rotation, and the maximum allowed coefficient.
    static func heightScale(for model: DiskModel, multiplier: Float) -> Float {
        let requested = nominalHeightScale(for: model, multiplier: multiplier)
        guard requested > 0, model.spin.isFinite, abs(model.spin) <= 0.9999 else { return 0 }
        let inner = DiskPhysics.isco(spin: model.spin)
        return Float(min(requested, maximumHeightScale(innerRadius: inner)))
    }

    /// Positive photosphere half-height at pseudo-cylindrical radius rho.
    /// The opaque body spans -height...+height. A prescribed C² quintic closure
    /// takes its height smoothly to zero over the final 20% of outer radius,
    /// avoiding an artificial vertical wall at the finite source cutoff. The
    /// intersection test must still enforce the radial extent of the body.
    /// Corrugation is stationary, phenomenological geometry and defaults to 0
    /// in the app. It is not the evolving fluid texture interpreted as height.
    static func height(radius rho: Double, azimuth phi: Double, innerRadius: Double,
                       outerRadius: Double, heightScale: Double, corrugation: Double) -> Double {
        guard rho.isFinite, phi.isFinite, innerRadius.isFinite, outerRadius.isFinite,
              rho > innerRadius, innerRadius > 0, outerRadius > innerRadius, rho < outerRadius,
              heightScale.isFinite, heightScale > 0 else { return 0 }
        let amplitude = corrugation.isFinite ? min(maximumCorrugation, max(0, corrugation)) : 0
        let logRadius = log(rho / innerRadius)
        let modulation = 1 + amplitude * (0.65 * cos(3 * phi + 2 * logRadius)
                                       + 0.35 * cos(7 * phi - 3 * logRadius))
        // Evaluate the descending smoothstep through its complement coordinate
        // to avoid cancellation from 1-smoothstep(t) near the outer edge.
        let closureCoordinate = min(1, max(0, (outerRadius - rho) / (0.2 * outerRadius)))
        let closure = closureCoordinate * closureCoordinate * closureCoordinate
                    * (10 + closureCoordinate * (-15 + 6 * closureCoordinate))
        return heightScale * (1 - sqrt(innerRadius / rho)) * modulation * closure
    }
}
