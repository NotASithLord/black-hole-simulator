import Foundation

/// Independent scalar and clock invariance checks; no GPU is required.
@main
struct DiskMotionValidation {
    static var checks = 0
    static var failures = 0
    static func check(_ condition: Bool, _ name: String, _ details: String = "") {
        checks += 1; if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(name) \(details)")
    }
    static func relative(_ a: Double, _ b: Double) -> Double { abs(a - b) / max(1e-30, abs(b)) }
    static func main() {
        let mass = 100_000_000.0, spin = 0.82
        // SI constants copied as explicit independent reference values.
        let gravitationalSeconds = 6.67430e-11 * (mass * 1.98847e30) / pow(299_792_458.0, 3)
        for radius in [3.0, 6, 12, 30] {
            let expected = 1 / (pow(radius, 1.5) + spin)
            check(relative(DiskMotion.angularVelocity(radius: radius, spin: spin), expected) < 1e-12, "Kerr differential angular velocity", "rho=\(radius)M")
            let expectedPeriod = 2 * Double.pi * gravitationalSeconds / expected
            check(relative(DiskMotion.orbitalPeriod(radius: radius, spin: spin, massSolar: mass), expectedPeriod) < 1e-12, "Physical orbital period conversion", "rho=\(radius)M, T=\(expectedPeriod / 3600)h")
        }
        let innerOmega = DiskMotion.angularVelocity(radius: 3, spin: spin)
        let outerOmega = DiskMotion.angularVelocity(radius: 30, spin: spin)
        check(innerOmega > outerOmega && outerOmega > 0, "Prograde inner material rotates faster than outer material")
        let sch = DiskMotion.orbitalPeriod(radius: 6, spin: 0, massSolar: mass)
        check(relative(sch, 2 * .pi * sqrt(216) * gravitationalSeconds) < 1e-12, "Schwarzschild r=6M period matches analytic limit")
        let basePeriod = DiskMotion.orbitalPeriod(radius: 6, spin: spin, massSolar: mass)
        let heavyPeriod = DiskMotion.orbitalPeriod(radius: 6, spin: spin, massSolar: mass * 10)
        check(relative(heavyPeriod, 10 * basePeriod) < 1e-12, "Orbital period scales linearly with black-hole mass")
        let rate = DiskMotion.fluidAngularRate(innerRadius: 3, spin: spin, massSolar: mass, playbackRate: 1000)
        check(relative(Double(rate), 1000 * innerOmega / gravitationalSeconds) < 1e-6, "Fluid calibration uses radians per display second")
        let realRate = DiskMotion.fluidAngularRate(innerRadius: 3, spin: spin, massSolar: mass, playbackRate: 1)
        check(relative(Double(rate), 1000 * Double(realRate)) < 1e-6, "Playback acceleration changes displayed rate without altering the orbit law")

        var whole = SourceClock(); whole.advance(elapsed: 8, rate: 1000)
        for fps in [30, 60, 120] {
            var partitioned = SourceClock()
            for _ in 0..<(8 * fps) { partitioned.advance(elapsed: 1 / Double(fps), rate: 1000) }
            check(abs(partitioned.seconds - whole.seconds) < 1e-7, "Physical source clock is frame-partition independent", "\(fps)fps -> \(partitioned.seconds)s")
        }
        var skipped = SourceClock()
        skipped.advance(elapsed: 0.25, rate: 1000); skipped.advance(elapsed: 3.5, rate: 1000); skipped.advance(elapsed: 4.25, rate: 1000)
        check(abs(skipped.seconds - whole.seconds) < 1e-12, "Large elapsed intervals do not slow physical motion when frames are skipped")
        var paused = SourceClock(); paused.advance(elapsed: 2, rate: 1000)
        paused.advance(elapsed: 100, rate: 4000, active: false)
        check(paused.seconds == 2000, "Paused or hidden source clock remains frozen")
        paused.advance(elapsed: 1, rate: 1000)
        check(paused.seconds == 3000, "Resuming adds new active elapsed time without a pause catch-up")
        var changing = SourceClock(); changing.advance(elapsed: 2, rate: 100)
        changing.advance(elapsed: 0, rate: 4000)
        check(changing.seconds == 200, "Changing playback rate does not instantaneously change source phase")
        changing.advance(elapsed: 0.5, rate: 4000)
        check(changing.seconds == 2200, "New playback rate applies only to subsequent elapsed time")
        for (elapsed, rate) in [(Double.nan, 1.0), (.infinity, 1), (-1, 1), (1, .nan), (1, .infinity), (1, -1), (0, 1000)] {
            changing.advance(elapsed: elapsed, rate: rate)
        }
        check(changing.seconds == 2200, "Negative and nonfinite elapsed times or rates are rejected")
        var stopped = SourceClock(); stopped.advance(elapsed: 100, rate: 0)
        check(stopped.seconds == 0, "Zero playback rate freezes physical source time")
        print("\(checks - failures)/\(checks) disk motion checks passed")
        if failures > 0 { exit(1) }
    }
}
