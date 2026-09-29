import Foundation

/// Prograde equatorial Kerr orbital kinematics. For the raised photosphere,
/// radius is the same pseudo-cylindrical radius used by its emitter model.
/// Playback accelerates observation time, never the gas velocity/redshift or
/// the stored null-geodesic travel delay.
enum DiskMotion {
    static func angularVelocity(radius: Double, spin: Double) -> Double {
        DiskPhysics.angularVelocity(radius: radius, spin: spin)
    }

    static func orbitalPeriod(radius: Double, spin: Double, massSolar: Double) -> Double {
        DiskPhysics.orbitalPeriod(radius: radius, spin: spin, massSolar: massSolar)
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
typealias SourceClock = SharedSourceClock
