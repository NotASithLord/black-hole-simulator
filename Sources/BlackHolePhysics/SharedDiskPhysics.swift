/// A stationary, equatorial, optically thick Page–Thorne disk with zero torque
/// at ISCO. Radius is in GM/c²; signed spin is relative to disk rotation. This
/// model is neither GRMHD nor a disk-atmosphere simulation.
public struct DiskModel: Equatable {
    public var spin: Double
    public var massSolar: Double
    public var accretionSolarMassesPerYear: Double
    public var outerRadius: Double

    public init(spin: Double, massSolar: Double = 100_000_000,
                accretionSolarMassesPerYear: Double = 0.01, outerRadius: Double = 80) {
        self.spin = spin
        self.massSolar = massSolar
        self.accretionSolarMassesPerYear = accretionSolarMassesPerYear
        self.outerRadius = outerRadius
    }

    public var gravitationalRadiusMeters: Double {
        SharedDiskPhysics.gravitationalConstant * massSolar * SharedDiskPhysics.solarMass /
            (SharedDiskPhysics.speedOfLight * SharedDiskPhysics.speedOfLight)
    }
    public var gravitationalTimeSeconds: Double { gravitationalRadiusMeters / SharedDiskPhysics.speedOfLight }
    public var accretionKilogramsPerSecond: Double {
        accretionSolarMassesPerYear * SharedDiskPhysics.solarMass / SharedDiskPhysics.julianYear
    }
    /// Binding-energy efficiency, excluding photon capture and returning light.
    public var nominalEfficiency: Double {
        1 - SharedDiskPhysics.circularOrbit(radius: SharedDiskPhysics.isco(spin: spin), spin: spin).energy
    }
    public var nominalEddingtonRatio: Double {
        SharedDiskPhysics.eddingtonRatio(model: self, efficiency: nominalEfficiency)
    }
}

public enum SharedDiskPhysics {
    public static let gravitationalConstant = 6.67430e-11
    public static let speedOfLight = 299_792_458.0
    public static let solarMass = 1.98847e30
    public static let julianYear = 31_557_600.0
    public static let stefanBoltzmann = 5.670374419e-8
    public static let planckConstant = 6.62607015e-34
    public static let boltzmannConstant = 1.380649e-23
    public static let protonMass = 1.67262192369e-27
    public static let thomsonCrossSection = 6.6524587321e-29
    public static let maximumAspectRatio = 0.20
    public static let maximumCorrugation = 0.08

    public struct CircularOrbit {
        public let energy: Double
        public let angularMomentum: Double
        public let omega: Double
        public let ut: Double
        public let angularMomentumDerivative: Double
        public let omegaDerivative: Double
    }

    // Bardeen, Press & Teukolsky (1972), ApJ 178:347; Page & Thorne (1974),
    // ApJ 191:499. Positive disk angular momentum and signed hole spin.
    public static func isco(spin: Double) -> Double {
        guard spin.isFinite else { return .nan }
        let a = min(0.9999, max(-0.9999, spin))
        let z1 = 1 + physicsCbrt(1 - a * a) * (physicsCbrt(1 + a) + physicsCbrt(1 - a))
        let z2 = physicsSqrt(3 * a * a + z1 * z1)
        return 3 + z2 - (a < 0 ? -1 : 1) * physicsSqrt(max(0, (3 - z1) * (3 + z1 + 2 * z2)))
    }

    public static func circularOrbit(radius r: Double, spin a: Double) -> CircularOrbit {
        let root = physicsSqrt(r)
        let r32 = r * root
        let core = r32 - 3 * root + 2 * a
        precondition(core > 0, "Circular orbit must lie outside the photon orbit")
        let denominator = physicsSqrt(r * root) * physicsSqrt(core)
        let numeratorL = r * r - 2 * a * root + a * a
        let angularMomentum = numeratorL / denominator
        let omega = 1 / (r32 + a)
        let dLogDenominator = 0.75 / r + 0.75 * (root - 1 / root) / core
        return CircularOrbit(energy: (r32 - 2 * root + a) / denominator,
                             angularMomentum: angularMomentum, omega: omega,
                             ut: (r32 + a) / denominator,
                             angularMomentumDerivative: (2 * r - a / root) / denominator - angularMomentum * dLogDenominator,
                             omegaDerivative: -1.5 * root * omega * omega)
    }

    @inline(__always)
    private static func fluxIntegrand(radius r: Double, spin a: Double) -> Double {
        let root = physicsSqrt(r)
        let r32 = r * root
        let core = r32 - 3 * root + 2 * a
        let numeratorL = r * r - 2 * a * root + a * a
        let dLogDenominator = 0.75 / r + 0.75 * (root - 1 / root) / core
        // (E−ΩL)L,r = L,r/u^t. The common orbit normalization cancels
        // algebraically, retaining the same double-precision quadrature.
        return (2 * r - a / root - numeratorL * dLogDenominator) / (r32 + a)
    }

    /// Eight-point Gauss–Legendre integration in dr on each logarithmic cell.
    public static func fluxIntegral(from lower: Double, to upper: Double, spin: Double) -> Double {
        let midpoint = 0.5 * (lower + upper)
        let halfWidth = 0.5 * (upper - lower)
        // Inline fixed-size storage works without an allocator on both targets.
        let nodes = SIMD4<Double>(0.1834346424956498, 0.5255324099163290, 0.7966664774136267, 0.9602898564975363)
        let weights = SIMD4<Double>(0.3626837833783620, 0.3137066458778873, 0.2223810344533745, 0.1012285362903763)
        var sum = 0.0
        for index in 0..<4 {
            let offset = halfWidth * nodes[index]
            sum += weights[index] * (fluxIntegrand(radius: midpoint - offset, spin: spin) +
                                     fluxIntegrand(radius: midpoint + offset, spin: spin))
        }
        return sum * halfWidth
    }

    static func physicalFluxScale(model: DiskModel) -> Double {
        let radius = model.gravitationalRadiusMeters
        return model.accretionKilogramsPerSecond * speedOfLight * speedOfLight /
            (4 * Double.pi * radius * radius)
    }

    static func eddingtonRatio(model: DiskModel, efficiency: Double) -> Double {
        let eddington = 4 * Double.pi * gravitationalConstant * model.massSolar * solarMass *
            protonMass * speedOfLight / thomsonCrossSection
        return efficiency * model.accretionKilogramsPerSecond * speedOfLight * speedOfLight / eddington
    }

    /// Flux from ONE disk surface (Page–Thorne 1974, eqs.11b,12,15d).
    public static func flux(radius: Double, spin: Double, integral: Double, model: DiskModel) -> Double {
        let orbit = circularOrbit(radius: radius, spin: spin)
        let factor = -orbit.omegaDerivative * orbit.ut * orbit.ut * max(0, integral) / radius
        return physicalFluxScale(model: model) * factor
    }

    /// B_lambda in W sr^-1 m^-3, with wavelength measured in meters.
    public static func planckRadiance(wavelength: Double, temperature: Double) -> Double {
        guard temperature > 0 else { return 0 }
        let exponent = planckConstant * speedOfLight / (wavelength * boltzmannConstant * temperature)
        guard exponent < 700 else { return 0 }
        let squared = wavelength * wavelength
        return 2 * planckConstant * speedOfLight * speedOfLight /
            (squared * squared * wavelength * physicsExpm1(exponent))
    }

    /// All 471 official CIE 1931 1 nm samples; endpoint trapezoid weights and
    /// 683 lm/W conversion. Y is luminance; X/Z are its photometric analogues.
    public static func blackbodyXYZ(temperature: Double) -> SIMD3<Double> {
        guard temperature > 0 else { return SIMD3(repeating: 0) }
        return CIE1931.withSamples { samples in
            var result = SIMD3<Double>(repeating: 0)
            for index in 0..<samples.count {
                let sample = samples[index]
                let weight = index == 0 || index == samples.count - 1 ? 0.5 : 1
                let radiance = planckRadiance(wavelength: sample.x * 1e-9, temperature: temperature)
                let scale = radiance * 1e-9 * 683 * weight
                result.x += sample.y * scale
                result.y += sample.z * scale
                result.z += sample.w * scale
            }
            return result
        }
    }

    public static func linearSRGB(xyz: SIMD3<Double>) -> SIMD3<Double> {
        // IEC sRGB/D65 matrix. No white adaptation: retain blackbody color.
        SIMD3(3.2404542 * xyz.x - 1.5371385 * xyz.y - 0.4985314 * xyz.z,
              -0.9692660 * xyz.x + 1.8760108 * xyz.y + 0.0415560 * xyz.z,
              0.0556434 * xyz.x - 0.2040259 * xyz.y + 1.0572252 * xyz.z)
    }

    public static func angularVelocity(radius: Double, spin: Double) -> Double {
        guard radius.isFinite, radius > 0, spin.isFinite, abs(spin) < 1 else { return 0 }
        let denominator = radius * physicsSqrt(radius) + spin
        return denominator > 0 && denominator.isFinite ? 1 / denominator : 0
    }

    public static func orbitalPeriod(radius: Double, spin: Double, massSolar: Double) -> Double {
        guard radius.isFinite, radius > 0, spin.isFinite, abs(spin) < 1,
              massSolar.isFinite, massSolar > 0 else { return 0 }
        let denominator = radius * physicsSqrt(radius) + spin
        let time = gravitationalConstant * massSolar * solarMass /
            (speedOfLight * speedOfLight * speedOfLight)
        return denominator > 0 ? 2 * Double.pi * time * denominator : 0
    }

    public static func maximumHeightScale(innerRadius: Double) -> Double {
        guard innerRadius.isFinite, innerRadius > 0 else { return 0 }
        return maximumAspectRatio * 27 * innerRadius / (4 * (1 + maximumCorrugation))
    }

    public static func nominalHeightScale(for model: DiskModel, multiplier: Double) -> Double {
        guard model.spin.isFinite, abs(model.spin) <= 0.9999,
              model.massSolar.isFinite, model.massSolar > 0,
              model.accretionSolarMassesPerYear.isFinite, model.accretionSolarMassesPerYear >= 0,
              multiplier.isFinite, multiplier > 0 else { return 0 }
        let efficiency = model.nominalEfficiency
        guard efficiency.isFinite, efficiency > 0 else { return 0 }
        let requested = 3 * model.nominalEddingtonRatio / efficiency * multiplier
        return requested.isNaN ? 0 : max(0, requested)
    }

    public static func heightScale(for model: DiskModel, multiplier: Double) -> Double {
        let requested = nominalHeightScale(for: model, multiplier: multiplier)
        guard requested > 0, model.spin.isFinite, abs(model.spin) <= 0.9999 else { return 0 }
        return min(requested, maximumHeightScale(innerRadius: isco(spin: model.spin)))
    }

    /// Multiplier of the analytic raised-photosphere profile. The thin-disk
    /// closure and 20%-height cap are shared by both native and browser tables.
    public static func photosphereHeightScale(eddingtonRatio: Double, efficiency: Double,
                                              innerRadius: Double, multiplier: Double) -> Double {
        min(3 * eddingtonRatio / efficiency * multiplier, maximumHeightScale(innerRadius: innerRadius))
    }

    public static func adaptiveScale(current: Double, measuredMS: Double, budgetMS: Double,
                                     minimum: Double, maximum: Double) -> Double {
        guard current.isFinite, minimum.isFinite, maximum.isFinite, minimum > 0, maximum >= minimum else { return current }
        guard measuredMS.isFinite, measuredMS > 0, budgetMS.isFinite, budgetMS > 0 else {
            return min(maximum, max(minimum, current))
        }
        let ratio = budgetMS / measuredMS
        if ratio >= 0.88 && ratio <= 1.12 { return min(maximum, max(minimum, current)) }
        let target = current * physicsSqrt(ratio)
        let next = current + 0.20 * (target - current)
        return min(maximum, max(minimum, min(current * 1.04, max(current * 0.90, next))))
    }
}

/// Reuses caller-owned buffers; no allocation, memory growth, or per-frame copy
/// is required. Native owns Swift arrays; WebAssembly owns fixed linear memory.
/// Counts remain configurable for higher-resolution native reference checks.
public struct DiskTableBuilder {
    private let radial: UnsafeMutableBufferPointer<SIMD4<Float>>
    private let spectral: UnsafeMutableBufferPointer<SIMD4<Float>>
    private let radialFactors: UnsafeMutableBufferPointer<Double>
    private let spectralPreparation: UnsafeMutableBufferPointer<SIMD4<Double>>
    private let metadata: UnsafeMutableBufferPointer<Double>
    private var cachedSpin = 0.0
    private var cachedOuter = 0.0
    private var cachedMass = 0.0
    private var cachedAccretion = 0.0
    private var geometryReady = false
    private var thermalReady = false
    private var spectrumReady = false

    public init(radial: UnsafeMutableBufferPointer<SIMD4<Float>>,
                spectral: UnsafeMutableBufferPointer<SIMD4<Float>>,
                radialFactors: UnsafeMutableBufferPointer<Double>,
                spectralPreparation: UnsafeMutableBufferPointer<SIMD4<Double>>,
                metadata: UnsafeMutableBufferPointer<Double>) {
        precondition(metadata.count >= 11)
        self.radial = radial
        self.spectral = spectral
        self.radialFactors = radialFactors
        self.spectralPreparation = spectralPreparation
        self.metadata = metadata
    }

    /// Rejection preserves all previous table data and cache state.
    public mutating func initializeModel(model: DiskModel, thicknessMultiplier: Double) -> Bool {
        precondition(radial.count >= 2 && radialFactors.count >= radial.count)
        guard model.spin.isFinite, abs(model.spin) <= 0.9999,
              model.massSolar.isFinite, model.massSolar > 0,
              model.accretionSolarMassesPerYear.isFinite, model.accretionSolarMassesPerYear >= 0,
              model.outerRadius.isFinite, thicknessMultiplier.isFinite, thicknessMultiplier >= 0 else { return false }
        let sameSpin = geometryReady && model.spin == cachedSpin
        let inner = sameSpin ? metadata[0] : SharedDiskPhysics.isco(spin: model.spin)
        guard model.outerRadius > inner else { return false }
        let efficiency = sameSpin ? metadata[8] : 1 - SharedDiskPhysics.circularOrbit(radius: inner, spin: model.spin).energy
        let ratio = SharedDiskPhysics.eddingtonRatio(model: model, efficiency: efficiency)
        let physicalScale = SharedDiskPhysics.physicalFluxScale(model: model)
        let logMin = physicsLog(inner)
        let step = (physicsLog(model.outerRadius) - logMin) / Double(radial.count - 1)
        let changedGeometry = !sameSpin || model.outerRadius != cachedOuter
        if changedGeometry {
            var integral = 0.0
            var previous = inner
            for index in 0..<radial.count {
                let radius = physicsExp(logMin + Double(index) * step)
                if index > 0 { integral += SharedDiskPhysics.fluxIntegral(from: previous, to: radius, spin: model.spin) }
                let orbit = SharedDiskPhysics.circularOrbit(radius: radius, spin: model.spin)
                radialFactors[index] = index == 0 ? 0 : -orbit.omegaDerivative * orbit.ut * orbit.ut * max(0, integral) / radius
                radial[index].z = Float(orbit.omega)
                radial[index].w = Float(orbit.ut)
                previous = radius
            }
            cachedSpin = model.spin
            cachedOuter = model.outerRadius
            geometryReady = true
        }
        var peak = metadata[4]
        if changedGeometry || !thermalReady || model.massSolar != cachedMass || model.accretionSolarMassesPerYear != cachedAccretion {
            peak = 0
            for index in 0..<radial.count {
                let flux = physicalScale * radialFactors[index]
                let temperature = physicsSqrt(physicsSqrt(flux / SharedDiskPhysics.stefanBoltzmann))
                radial[index].x = Float(temperature)
                radial[index].y = Float(flux)
                peak = max(peak, temperature)
            }
            cachedMass = model.massSolar
            cachedAccretion = model.accretionSolarMassesPerYear
            thermalReady = true
        }
        metadata[0] = inner
        metadata[1] = model.outerRadius
        metadata[2] = logMin
        metadata[3] = step
        metadata[4] = peak
        metadata[7] = model.gravitationalTimeSeconds
        metadata[8] = efficiency
        metadata[9] = ratio
        metadata[10] = SharedDiskPhysics.photosphereHeightScale(eddingtonRatio: ratio, efficiency: efficiency,
                                                               innerRadius: inner, multiplier: thicknessMultiplier)
        return true
    }

    private func preparedXYZ(temperature: Double) -> SIMD3<Double> {
        // Scalar accumulators preserve the ordered wavelength reduction while
        // avoiding vector-lane extraction/insertion around each libm call.
        var x = 0.0
        var y = 0.0
        var z = 0.0
        let inverseTemperature = 1 / temperature
        for index in 0..<471 {
            let exponent = spectralPreparation[index].x * inverseTemperature
            if exponent >= 700 { continue }
            let scale = 1 / physicsExpm1(exponent)
            let sample = spectralPreparation[index]
            x += sample.y * scale
            y += sample.z * scale
            z += sample.w * scale
        }
        return SIMD3(x, y, z)
    }

    /// Retains all 2048 default temperature bins and 471 CIE wavelengths. The
    /// expensive wavelength-only Planck/trapezoid factors are prepared once.
    @discardableResult
    public mutating func initializeSpectrum() -> Int32 {
        if spectrumReady { return 0 }
        precondition(spectral.count >= 2 && spectralPreparation.count >= 471)
        CIE1931.withSamples { samples in
            for index in 0..<samples.count {
                let sample = samples[index]
                let wavelength = sample.x * 1e-9
                let squared = wavelength * wavelength
                let exponent = SharedDiskPhysics.planckConstant * SharedDiskPhysics.speedOfLight /
                    (wavelength * SharedDiskPhysics.boltzmannConstant)
                let weight = 2 * SharedDiskPhysics.planckConstant * SharedDiskPhysics.speedOfLight * SharedDiskPhysics.speedOfLight /
                    (squared * squared * wavelength) * 1e-9 * 683 * (index == 0 || index == samples.count - 1 ? 0.5 : 1)
                spectralPreparation[index] = SIMD4(exponent, sample.y * weight, sample.z * weight, sample.w * weight)
            }
        }
        let logMin = physicsLog(300)
        let step = (physicsLog(10_000_000) - logMin) / Double(spectral.count - 1)
        let referenceY = preparedXYZ(temperature: 10_000).y
        for index in 0..<spectral.count {
            let xyz = preparedXYZ(temperature: physicsExp(logMin + Double(index) * step)) / referenceY
            let rgb = SharedDiskPhysics.linearSRGB(xyz: xyz)
            spectral[index] = SIMD4(Float(rgb.x), Float(rgb.y), Float(rgb.z), Float(xyz.y))
        }
        metadata[5] = logMin
        metadata[6] = step
        spectrumReady = true
        return 0
    }
}

/// BL-coordinate seconds at infinity. Playback changes its slope, never gas
/// velocity/redshift or stored light-travel delay. Camera time stays separate.
public struct SharedSourceClock {
    public private(set) var seconds: Double = 0
    public init() {}
    public mutating func advance(elapsed: Double, rate: Double, active: Bool = true) {
        guard active, elapsed.isFinite, elapsed >= 0, rate.isFinite, rate >= 0 else { return }
        let next = seconds + elapsed * rate
        if next.isFinite { seconds = next }
    }
    public mutating func reset() { seconds = 0 }
}
