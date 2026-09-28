import Foundation

/// A stationary, equatorial, optically thick Page–Thorne disk with zero torque at
/// ISCO. Radius is in GM/c²; spin is a*=Jc/(GM²), signed relative to disk rotation.
/// The local spectrum is an isotropic blackbody at T_eff (color correction=1).
/// This is a defined physical model, not a GRMHD or disk-atmosphere calculation.
struct DiskModel: Equatable {
    var spin: Double
    var massSolar: Double = 100_000_000
    var accretionSolarMassesPerYear: Double = 0.01
    var outerRadius: Double = 80

    var gravitationalRadiusMeters: Double { DiskPhysics.gravitationalConstant * massSolar * DiskPhysics.solarMass / pow(DiskPhysics.speedOfLight, 2) }
    var gravitationalTimeSeconds: Double { gravitationalRadiusMeters / DiskPhysics.speedOfLight }
    var accretionKilogramsPerSecond: Double { accretionSolarMassesPerYear * DiskPhysics.solarMass / DiskPhysics.julianYear }
    /// Binding-energy efficiency; excludes photon capture and returning radiation.
    var nominalEfficiency: Double { 1 - DiskPhysics.circularOrbit(radius: DiskPhysics.isco(spin: spin), spin: spin).energy }
    var nominalEddingtonRatio: Double {
        let eddington = 4 * Double.pi * DiskPhysics.gravitationalConstant * massSolar * DiskPhysics.solarMass * DiskPhysics.protonMass * DiskPhysics.speedOfLight / DiskPhysics.thomsonCrossSection
        return nominalEfficiency * accretionKilogramsPerSecond * pow(DiskPhysics.speedOfLight, 2) / eddington
    }
}

struct DiskRadialTable {
    /// x: T_eff[K], y: F[W/m² per disk face], z: Ω[1/(GM/c³)], w: u^t.
    let values: [SIMD4<Float>]
    let innerRadius: Float
    let outerRadius: Float
    let logRadiusMin: Float
    let logRadiusStep: Float
    let peakTemperature: Float
}

struct DiskSpectralTable {
    /// xyz: linear sRGB radiance; w: CIE Y. All divided by Y of a 10,000 K
    /// blackbody using the identical visible wavelength integration. This is one
    /// fixed exposure unit, not per-color normalization; brightness is preserved.
    let values: [SIMD4<Float>]
    let logTemperatureMin: Float
    let logTemperatureStep: Float
}

enum DiskPhysics {
    static let gravitationalConstant = 6.67430e-11
    static let speedOfLight = 299_792_458.0
    static let solarMass = 1.98847e30
    static let julianYear = 31_557_600.0
    static let stefanBoltzmann = 5.670374419e-8
    static let planckConstant = 6.62607015e-34
    static let boltzmannConstant = 1.380649e-23
    static let protonMass = 1.67262192369e-27
    static let thomsonCrossSection = 6.6524587321e-29

    struct CircularOrbit {
        let energy: Double
        let angularMomentum: Double
        let omega: Double
        let ut: Double
        let angularMomentumDerivative: Double
        let omegaDerivative: Double
    }

    // Bardeen, Press & Teukolsky (1972), ApJ 178:347; Page & Thorne (1974),
    // ApJ 191:499 eq.15. Positive disk angular momentum, signed hole spin.
    static func isco(spin: Double) -> Double {
        let a = min(0.9999, max(-0.9999, spin))
        let z1 = 1 + cbrt(1 - a * a) * (cbrt(1 + a) + cbrt(1 - a))
        let z2 = sqrt(3 * a * a + z1 * z1)
        return 3 + z2 - (a < 0 ? -1 : 1) * sqrt(max(0, (3 - z1) * (3 + z1 + 2 * z2)))
    }

    static func circularOrbit(radius r: Double, spin a: Double) -> CircularOrbit {
        let root = sqrt(r)
        let r32 = r * root
        let core = r32 - 3 * root + 2 * a
        precondition(core > 0, "Circular orbit must lie outside the photon orbit")
        let denominator = pow(r, 0.75) * sqrt(core)
        let numeratorL = r * r - 2 * a * root + a * a
        let energy = (r32 - 2 * root + a) / denominator
        let angularMomentum = numeratorL / denominator
        let omega = 1 / (r32 + a)
        let dLogDenominator = 0.75 / r + 0.75 * (root - 1 / root) / core
        let dL = (2 * r - a / root) / denominator - angularMomentum * dLogDenominator
        return CircularOrbit(energy: energy, angularMomentum: angularMomentum, omega: omega,
                             ut: (r32 + a) / denominator,
                             angularMomentumDerivative: dL,
                             omegaDerivative: -1.5 * root * omega * omega)
    }

    // Eight-point Gauss–Legendre quadrature on each log-grid cell. The physical
    // integral is in dr, not d(log r). Analytic dL/dr avoids finite differences.
    private static let quadratureNodes = [0.1834346424956498, 0.5255324099163290, 0.7966664774136267, 0.9602898564975363]
    private static let quadratureWeights = [0.3626837833783620, 0.3137066458778873, 0.2223810344533745, 0.1012285362903763]

    static func fluxIntegral(from lower: Double, to upper: Double, spin: Double) -> Double {
        let midpoint = 0.5 * (lower + upper)
        let halfWidth = 0.5 * (upper - lower)
        var sum = 0.0
        for index in 0..<quadratureNodes.count {
            let offset = halfWidth * quadratureNodes[index]
            for r in [midpoint - offset, midpoint + offset] {
                let orbit = circularOrbit(radius: r, spin: spin)
                sum += quadratureWeights[index] * orbit.angularMomentumDerivative / orbit.ut
            }
        }
        return sum * halfWidth
    }

    /// Page–Thorne (1974), eqs.11b,12,15d: sqrt(-g)=r in (t,r,phi,z)
    /// coordinates, so F = Mdot c²/(4π r_g²) [-Ω,r/(r(E-ΩL)²)]
    /// integral_ISCO^r (E-ΩL)L,r dr. This is flux from ONE surface.
    static func flux(radius: Double, spin: Double, integral: Double, model: DiskModel) -> Double {
        let orbit = circularOrbit(radius: radius, spin: spin)
        let physicalScale = model.accretionKilogramsPerSecond * pow(speedOfLight, 2) / (4 * Double.pi * pow(model.gravitationalRadiusMeters, 2))
        let radialFactor = -orbit.omegaDerivative * orbit.ut * orbit.ut * max(0, integral) / radius
        return physicalScale * radialFactor
    }

    static func radialTable(for model: DiskModel, count: Int = 4096) -> DiskRadialTable {
        precondition(count >= 2 && model.massSolar > 0 && model.accretionSolarMassesPerYear >= 0)
        precondition(abs(model.spin) <= 0.9999, "Extremal Kerr requires a separate limiting treatment")
        let inner = isco(spin: model.spin)
        precondition(model.outerRadius > inner)
        let logMin = log(inner)
        let step = (log(model.outerRadius) - logMin) / Double(count - 1)
        var values = [SIMD4<Float>]()
        values.reserveCapacity(count)
        var integral = 0.0
        var previous = inner
        var peak = 0.0
        for index in 0..<count {
            let radius = exp(logMin + Double(index) * step)
            if index > 0 { integral += fluxIntegral(from: previous, to: radius, spin: model.spin) }
            let orbit = circularOrbit(radius: radius, spin: model.spin)
            let f = index == 0 ? 0 : flux(radius: radius, spin: model.spin, integral: integral, model: model)
            let temperature = pow(f / stefanBoltzmann, 0.25)
            peak = max(peak, temperature)
            values.append(SIMD4(Float(temperature), Float(f), Float(orbit.omega), Float(orbit.ut)))
            previous = radius
        }
        return DiskRadialTable(values: values, innerRadius: Float(inner), outerRadius: Float(model.outerRadius),
                               logRadiusMin: Float(logMin), logRadiusStep: Float(step), peakTemperature: Float(peak))
    }

    /// B_lambda in W sr^-1 m^-3, with lambda measured in meters.
    static func planckRadiance(wavelength: Double, temperature: Double) -> Double {
        guard temperature > 0 else { return 0 }
        let exponent = planckConstant * speedOfLight / (wavelength * boltzmannConstant * temperature)
        guard exponent < 700 else { return 0 }
        return 2 * planckConstant * pow(speedOfLight, 2) / (pow(wavelength, 5) * expm1(exponent))
    }

    /// Trapezoid integration of all 471 official 1nm samples, 360...830nm.
    /// X/Z are photometric analogues and Y is luminance in cd/m² (683 lm/W).
    static func blackbodyXYZ(temperature: Double) -> SIMD3<Double> {
        var xyz = SIMD3<Double>(repeating: 0)
        for (index, sample) in CIE1931.samples.enumerated() {
            let endpointWeight = index == 0 || index == CIE1931.samples.count - 1 ? 0.5 : 1
            let radiance = planckRadiance(wavelength: sample.x * 1e-9, temperature: temperature)
            xyz += SIMD3(sample.y, sample.z, sample.w) * (radiance * 1e-9 * 683 * endpointWeight)
        }
        return xyz
    }

    static func linearSRGB(xyz: SIMD3<Double>) -> SIMD3<Double> {
        // IEC sRGB/D65 XYZ-to-linear-RGB matrix. No white adaptation is applied:
        // real blackbody chromaticity is retained instead of white-balancing it.
        SIMD3(3.2404542 * xyz.x - 1.5371385 * xyz.y - 0.4985314 * xyz.z,
              -0.9692660 * xyz.x + 1.8760108 * xyz.y + 0.0415560 * xyz.z,
              0.0556434 * xyz.x - 0.2040259 * xyz.y + 1.0572252 * xyz.z)
    }

    static func spectralTable(count: Int = 2048) -> DiskSpectralTable {
        precondition(count >= 2)
        let logMin = log(300.0)
        let step = (log(10_000_000.0) - logMin) / Double(count - 1)
        let referenceY = blackbodyXYZ(temperature: 10_000).y
        let values = (0..<count).map { index -> SIMD4<Float> in
            let temperature = exp(logMin + Double(index) * step)
            let xyz = blackbodyXYZ(temperature: temperature) / referenceY
            let rgb = linearSRGB(xyz: xyz)
            return SIMD4(Float(rgb.x), Float(rgb.y), Float(rgb.z), Float(xyz.y))
        }
        return DiskSpectralTable(values: values, logTemperatureMin: Float(logMin), logTemperatureStep: Float(step))
    }
}
