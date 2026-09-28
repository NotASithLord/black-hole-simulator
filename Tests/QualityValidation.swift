import Foundation

/// Deterministic, GPU-independent checks of the production workload controller.
@main
struct QualityValidation {
    static var checks = 0
    static var failures = 0
    static func check(_ condition: Bool, _ name: String) {
        checks += 1; if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(name)")
    }
    static func same(_ a: QualityWorkload, _ b: QualityWorkload) -> Bool {
        a.scale == b.scale && a.tolerance == b.tolerance && a.maxSteps == b.maxSteps &&
        a.samples == b.samples && a.maxStep == b.maxStep && a.targetMS == b.targetMS && a.fps == b.fps
    }
    static func controller(_ mode: QualityMode, wallpaper: Bool = false, constrained: Bool = false) -> AdaptiveQuality {
        var result = AdaptiveQuality()
        result.configure(mode: mode, wallpaper: wallpaper, constrained: constrained, appearance: .radiant)
        return result
    }
    static func main() {
        let defaults: [(QualityMode, Float, Float, Int, Int, Float, Double, Int)] = [
            (.auto, 0.65, 2e-6, 2048, 1, 0.025, 16.7, 60),
            (.efficient, 0.6, 3e-6, 2048, 1, 0.025, 12, 30),
            (.cinematic, 0.85, 8e-7, 4096, 2, 0.018, 33.3, 30),
            (.ultra, 1, 3e-7, 8192, 2, 0.012, 80, 120)
        ]
        for (mode, scale, tolerance, steps, samples, step, target, fps) in defaults {
            let quality = controller(mode), w = quality.workload
            check(w.scale == scale && w.tolerance == tolerance && w.maxSteps == steps && w.samples == samples && w.maxStep == step && w.targetMS == target && w.fps == fps && quality.phase == "Calibrating", "\(mode.rawValue) configures its documented workload")
        }

        var ultra = controller(.ultra)
        let baseline = ultra.workload
        ultra.refineCached(milliseconds: 500)
        check(same(ultra.workload, baseline), "Expensive measured trace does not trigger cached refinement")
        ultra = controller(.ultra)
        ultra.refineCached(milliseconds: 100)
        check(ultra.workload.samples == 4 && ultra.phase == "Refining cached transport", "Affordable measured trace doubles Max Fidelity samples from two to four")
        ultra.refineCached(milliseconds: 100)
        check(ultra.workload.samples == 8, "Second affordable Max Fidelity stage reaches eight samples")
        for _ in 0..<20 { ultra.refineCached(milliseconds: 0.1) }
        check(ultra.workload.samples == 8, "Cached Max Fidelity remains bounded at eight samples")
        check(ultra.workload.scale == 1 && ultra.workload.tolerance == baseline.tolerance && ultra.workload.maxSteps == baseline.maxSteps && ultra.workload.maxStep == baseline.maxStep, "Cached refinement never weakens Max Fidelity integration accuracy")

        var cinematic = controller(.cinematic)
        for _ in 0..<20 { cinematic.refineCached(milliseconds: 1) }
        check(cinematic.workload.scale == 1 && cinematic.workload.samples == 4, "Other cached quality modes retain the four-sample ceiling")

        var auto = controller(.auto)
        auto.refineCached(milliseconds: 1)
        check(abs(auto.workload.scale - 0.975) < 1e-6 && auto.workload.samples == 1, "Cached Auto increases resolution before sample count")
        auto.refineCached(milliseconds: 1)
        check(auto.workload.scale == 1 && auto.workload.samples == 1, "Second Auto stage reaches native resolution without overshoot")
        auto.refineCached(milliseconds: 1)
        check(auto.workload.samples == 2, "Third Auto stage increases sampling")
        let thirdStage = auto.workload
        for _ in 0..<20 { auto.refineCached(milliseconds: 0.01) }
        check(same(auto.workload, thirdStage), "Cached refinement stops after three stages even below the sample ceiling")
        auto.configure(mode: .auto, wallpaper: false, constrained: false, appearance: .radiant)
        check(same(auto.workload, thirdStage) && auto.phase == "Refining cached transport", "Repeated identical configuration preserves adaptive state")
        auto.configure(mode: .auto, wallpaper: false, constrained: false, appearance: .scientific)
        check(same(auto.workload, controller(.auto).workload) && auto.phase == "Calibrating", "Switching to Scientific resets workload and calibration phase")
        auto.configure(mode: .auto, wallpaper: false, constrained: false, appearance: .radiant)
        auto.refineCached(milliseconds: 1)
        check(abs(auto.workload.scale - 0.975) < 1e-6, "Changing appearance also resets the cached-refinement stage budget")

        for constrained in [false, true] {
            var wallpaper = controller(.ultra, wallpaper: true, constrained: constrained)
            let before = wallpaper.workload
            for _ in 0..<20 { wallpaper.refineCached(milliseconds: 0.01) }
            check(same(wallpaper.workload, before) && wallpaper.phase == "Calibrating", "Wallpaper never performs expensive cached refinement (constrained=\(constrained))")
            check(before.scale == 0.6 && before.samples == 1 && before.fps == (constrained ? 15 : 30) && before.targetMS == (constrained ? 9 : 15), "Wallpaper configures its energy-conscious frame budget (constrained=\(constrained))")
        }

        var invalid = controller(.auto)
        let original = invalid.workload
        for cost in [Double.nan, Double.infinity, -Double.infinity, 0, -1] {
            invalid.refineCached(milliseconds: cost); invalid.record(milliseconds: cost)
        }
        check(same(invalid.workload, original) && invalid.phase == "Calibrating", "Nonfinite and nonpositive timings leave workload and phase unchanged")
        for _ in 0..<3 { invalid.refineCached(milliseconds: 1) }
        check(invalid.workload.scale == 1 && invalid.workload.samples == 2, "Rejected timing values do not consume cached-refinement stages")
        invalid = controller(.auto)
        for _ in 0..<30 { invalid.record(milliseconds: .nan) }
        for _ in 0..<15 { invalid.record(milliseconds: 1) }
        check(same(invalid.workload, original), "Rejected timings do not advance moving-camera calibration")
        invalid.record(milliseconds: 1)
        check(invalid.workload.scale > original.scale && invalid.phase == "Adaptive", "Moving-camera calibration starts only after sixteen valid measured traces")

        var scientificReset = controller(.auto)
        for _ in 0..<16 { scientificReset.record(milliseconds: 100) }
        check(scientificReset.workload.scale < original.scale, "Slow moving-camera measurements lower Auto rendering resolution")
        scientificReset.configure(mode: .auto, wallpaper: false, constrained: false, appearance: .scientific)
        for _ in 0..<15 { scientificReset.record(milliseconds: 1) }
        check(same(scientificReset.workload, original) && scientificReset.phase == "Calibrating", "Appearance change discards previous trace timing history")
        print("\(checks - failures)/\(checks) adaptive quality checks passed")
        if failures > 0 { exit(1) }
    }
}
