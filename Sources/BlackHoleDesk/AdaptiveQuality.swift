import Metal
import Foundation

struct QualityWorkload {
    var scale: Float
    var tolerance: Float
    var maxSteps: Int
    var samples: Int
    var maxStep: Float
    var targetMS: Double
    var fps: Int
}

/// Only changes numerical accuracy and sampling. Emission model and metric are
/// identical at every quality level. Max Fidelity never relaxes its tolerance.
struct AdaptiveQuality {
    private(set) var workload = QualityWorkload(scale: 0.65, tolerance: 1e-6, maxSteps: 2048, samples: 1, maxStep: 0.02, targetMS: 16.7, fps: 60)
    private var lastMode: QualityMode?
    private var lastAppearance: AppearanceMode?
    private var lastWallpaper = false
    private var lastConstrained = false
    private var timings: [Double] = []
    private var calibrated = false
    private var cadence = 0
    private var cachedRefinements = 0
    private(set) var phase = "Calibrating"
    private(set) var capabilities = ""
    private(set) var pixelLimit = 12_000_000

    mutating func inspect(_ device: MTLDevice) {
        let memory = device.recommendedMaxWorkingSetSize
        pixelLimit = min(33_177_600, max(2_000_000, Int(memory / 16 / 48)))
        let family = device.supportsFamily(.apple9) ? "Apple 9" : device.supportsFamily(.apple8) ? "Apple 8" : device.supportsFamily(.apple7) ? "Apple 7" : "Metal"
        capabilities = "\(family) · \(device.hasUnifiedMemory ? "unified" : "discrete") · \(memory / (1024*1024*1024)) GB working set"
    }

    mutating func configure(mode: QualityMode, wallpaper: Bool, constrained: Bool, appearance: AppearanceMode = .scientific) {
        guard lastMode != mode || lastWallpaper != wallpaper || lastConstrained != constrained || lastAppearance != appearance else { return }
        lastMode = mode; lastWallpaper = wallpaper; lastConstrained = constrained; lastAppearance = appearance
        timings = []; cadence = 0; calibrated = false; cachedRefinements = 0; phase = "Calibrating"
        switch mode {
        case .auto: workload = .init(scale: 0.65, tolerance: 2e-6, maxSteps: 2048, samples: 1, maxStep: 0.025, targetMS: 16.7, fps: 60)
        case .efficient: workload = .init(scale: 0.6, tolerance: 3e-6, maxSteps: 2048, samples: 1, maxStep: 0.025, targetMS: 12, fps: 30)
        case .cinematic: workload = .init(scale: 0.85, tolerance: 8e-7, maxSteps: 4096, samples: 2, maxStep: 0.018, targetMS: 33.3, fps: 30)
        case .ultra: workload = .init(scale: 1, tolerance: 3e-7, maxSteps: 8192, samples: 2, maxStep: 0.012, targetMS: 80, fps: 120)
        }
        if wallpaper { workload.scale = 0.6; workload.samples = 1; workload.targetMS = constrained ? 9 : 15; workload.fps = constrained ? 15 : 30 }
    }

    /// A cached view can afford a more expensive one-off transfer map than a
    /// moving camera. Use measured TRACE cost, never the cheap shading cost,
    /// for a bounded, at-most-three-stage refinement on faster hardware.
    mutating func refineCached(milliseconds: Double) {
        guard !lastWallpaper, cachedRefinements < 3, milliseconds.isFinite, milliseconds > 0 else { return }
        cachedRefinements += 1
        let budget: Double
        switch lastMode {
        case .ultra: budget = 600
        case .cinematic: budget = 260
        case .auto: budget = 160
        default: budget = 80
        }
        guard milliseconds < budget * 0.65 else { return }
        if workload.scale < 0.99 {
            workload.scale = min(1, workload.scale * Float(min(1.5,sqrt(budget * 0.8 / milliseconds))))
        } else {
            let ceiling = lastMode == .ultra ? 8 : 4
            let predicted = Int(Double(workload.samples) * budget * 0.8 / milliseconds)
            workload.samples = min(ceiling, min(workload.samples * 2, max(workload.samples,predicted)))
        }
        phase = "Refining cached transport"
    }

    mutating func record(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds > 0 else { return }
        timings.append(milliseconds); cadence += 1
        if timings.count > 24 { timings.removeFirst() }
        guard timings.count >= 16, cadence >= (calibrated ? 24 : 16) else { return }
        cadence = 0; calibrated = true; phase = lastMode == .ultra && !lastWallpaper ? "Accuracy priority" : "Adaptive"
        let sorted = timings.sorted(); let ms = sorted[sorted.count/2]
        let target = workload.targetMS
        if lastMode == .ultra && !lastWallpaper {
            if ms < target * 0.7 { workload.samples = min(32, workload.samples + max(1, workload.samples/2)) }
            else if ms > target * 1.3 { workload.samples = max(1, workload.samples - max(1, workload.samples/3)) }
            return // full resolution and tight numerical tolerances are inviolable.
        }
        if ms > target * 1.15 {
            if workload.samples > 1 { workload.samples -= 1 }
            else { workload.scale = max(0.3, workload.scale * Float(sqrt(target / ms))) }
        } else if ms < target * 0.75 {
            if workload.scale < 0.99 { workload.scale = min(1, workload.scale + 0.06) }
            else if !lastWallpaper { workload.samples = min(8, workload.samples + 1) }
        }
    }
}
