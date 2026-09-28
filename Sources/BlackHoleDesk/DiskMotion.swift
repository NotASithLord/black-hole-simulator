import Foundation

/// Prograde equatorial Kerr orbital kinematics. For the raised photosphere,
/// radius is the same pseudo-cylindrical radius used by its emitter model.
/// Playback accelerates observation time, never the gas velocity/redshift or
/// the stored null-geodesic travel delay.
enum DiskMotion {
    static func angularVelocity(radius: Double, spin: Double) -> Double {
        guard radius.isFinite, radius > 0, spin.isFinite, abs(spin) < 1 else { return 0 }
        let denominator = pow(radius, 1.5) + spin
        return denominator > 0 && denominator.isFinite ? 1 / denominator : 0
    }

    static func orbitalPeriod(radius: Double, spin: Double, massSolar: Double) -> Double {
        guard massSolar.isFinite, massSolar > 0 else { return 0 }
        let omega = angularVelocity(radius: radius, spin: spin)
        guard omega > 0 else { return 0 }
        return 2 * .pi * DiskModel(spin: spin, massSolar: massSolar).gravitationalTimeSeconds / omega
    }

    /// Radians per display second, not turns or texture-coordinate units.
    static func fluidAngularRate(innerRadius: Double, spin: Double, massSolar: Double,
                                 playbackRate: Double) -> Float {
        guard playbackRate.isFinite, playbackRate >= 0 else { return 0 }
        let period = orbitalPeriod(radius: innerRadius, spin: spin, massSolar: massSolar)
        guard period > 0 else { return 0 }
        let rate = 2 * .pi * playbackRate / period
        return rate.isFinite && rate <= Double(Float.greatestFiniteMagnitude) ? Float(rate) : 0
    }
}

/// Integrated BL-coordinate seconds measured at infinity. Changing playback
/// speed changes the slope, not the current phase. Dropped render submissions
/// do not discard source time. Camera motion keeps its separate wall clock.
struct SourceClock {
    private(set) var seconds: Double = 0

    mutating func advance(elapsed: Double, rate: Double, active: Bool = true) {
        guard active, elapsed.isFinite, elapsed >= 0, rate.isFinite, rate >= 0 else { return }
        let next = seconds + elapsed * rate
        if next.isFinite { seconds = next }
    }
}
