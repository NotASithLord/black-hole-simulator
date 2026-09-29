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
        a.samples == b.samples && a.maxStep == b.maxStep && a.targetMS == b.targetMS && a.fps == b.fps && a.materialSamples == b.materialSamples
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
            (.ultra, 1, 3e-7, 8192, 2, 0.012, 1000 / 120 * 0.875, 120)
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

        check(RenderSettings().quality == .ultra, "Native app starts in Max Fidelity")
        var display = AdaptiveQuality()
        for refresh in [30, 60, 120, 144] {
            display.configure(mode: .ultra, wallpaper: false, constrained: false, appearance: .radiant, refreshRate: refresh)
            let w = display.workload
            check(w.fps == min(120, refresh) && abs(w.targetMS * Double(w.fps) / 1000 - 0.875) < 1e-12,
                  "Max Fidelity targets 87.5% of its actual requested display cadence (\(refresh) Hz)")
        }
        let configured = display.configurationID
        display.configure(mode: .ultra, wallpaper: false, constrained: false, appearance: .radiant, refreshRate: 144)
        check(display.configurationID == configured, "Unchanged display configuration does not reset calibration")
        display.configure(mode: .ultra, wallpaper: false, constrained: true, appearance: .radiant, refreshRate: 120)
        check(display.workload.fps == 30 && abs(display.workload.targetMS - 1000 / 30 * 0.65) < 1e-12,
              "Low-power or thermal constraints retain foreground GPU headroom")
        check(display.configurationID != configured, "Changed quality configuration invalidates old timing generations")
        let constrainedWork = display.workload
        for _ in 0..<24 { display.refineCached(milliseconds: 0.01); display.recordCached(milliseconds: 0.01) }
        check(same(display.workload, constrainedWork), "Thermal and low-power constraints suppress expensive cached refinements")

        var material = controller(.ultra)
        let materialBase = material.workload
        for _ in 0..<16 { material.recordCached(milliseconds: 1) }
        check(material.workload.materialSamples == 8, "Cached spare time doubles shutter integration from four to eight samples")
        for _ in 0..<24 { material.recordCached(milliseconds: 1) }
        check(material.workload.materialSamples == 16, "Fast cached rendering reaches sixteen shutter samples")
        for _ in 0..<240 { material.recordCached(milliseconds: 0.01) }
        check(material.workload.materialSamples == 16, "Cached controller never fabricates work beyond useful shutter ceiling")
        check(material.workload.scale == materialBase.scale && material.workload.samples == materialBase.samples && material.workload.tolerance == materialBase.tolerance && material.workload.maxSteps == materialBase.maxSteps && material.workload.maxStep == materialBase.maxStep,
              "Cached shutter adaptation does not invalidate transfer geometry or weaken physics")
        for _ in 0..<240 { material.recordCached(milliseconds: 100) }
        check(material.workload.materialSamples == 4, "Slow cached frames retain Max Fidelity's four-sample shutter floor")
        for cost in [Double.nan, Double.infinity, -Double.infinity, 0, -1] { material.recordCached(milliseconds: cost) }
        check(material.workload.materialSamples == 4, "Invalid cached timings cannot change shutter quality")
        material.configure(mode: .ultra, wallpaper: false, constrained: false, appearance: .scientific)
        for _ in 0..<240 { material.recordCached(milliseconds: 1) }
        check(material.workload.materialSamples == 4, "Scientific rendering does not run photographic shutter adaptation")
        for mode in [QualityMode.auto, .efficient, .cinematic] {
            var other = controller(mode); let previous = other.workload
            for _ in 0..<64 { other.recordCached(milliseconds: 1) }
            check(same(other.workload, previous), "\(mode.rawValue) retains its explicit energy/quality policy")
        }
        for constrained in [false, true] {
            var wallpaper = controller(.ultra, wallpaper: true, constrained: constrained)
            for _ in 0..<64 { wallpaper.recordCached(milliseconds: 1) }
            check(wallpaper.workload.materialSamples == 1, "Wallpaper keeps one shutter sample (constrained=\(constrained))")
        }
        var movingRadiant = controller(.ultra)
        for _ in 0..<1024 { movingRadiant.record(milliseconds: 0.01) }
        check(movingRadiant.workload.samples == 8, "Radiant controller sample ceiling matches its actual eight-sample transfer allocation")
        for _ in 0..<1024 { movingRadiant.record(milliseconds: 1000) }
        check(movingRadiant.workload.samples == 1 && movingRadiant.workload.scale == 1 && movingRadiant.workload.tolerance == materialBase.tolerance,
              "Slow tracing keeps full resolution and exact Max Fidelity integration contract")
        var discrete = AdaptiveQuality()
        discrete.configure(mode: .ultra, wallpaper: false, constrained: false, appearance: .radiant, refreshRate: 60)
        for _ in 0..<16 { discrete.record(milliseconds: Double(discrete.workload.samples) * 10) }
        check(discrete.workload.samples == 1, "A ten-millisecond ray sample settles below the 60 Hz GPU budget")
        var stableDiscrete = true
        for _ in 0..<240 {
            discrete.record(milliseconds: Double(discrete.workload.samples) * 10)
            stableDiscrete = stableDiscrete && discrete.workload.samples == 1
        }
        check(stableDiscrete, "Discrete ray-sample adaptation does not oscillate when the next sample exceeds budget")
        var tiny = controller(.ultra)
        tiny.refineCached(milliseconds: .leastNonzeroMagnitude)
        for _ in 0..<48 { tiny.record(milliseconds: .leastNonzeroMagnitude) }
        check(tiny.workload.samples <= 8, "Subnormal positive timings cannot overflow predicted sample counts")
        print("\(checks - failures)/\(checks) adaptive quality checks passed")
        if failures > 0 { exit(1) }
    }
}
