import Foundation

enum QualityMode: String, CaseIterable, Identifiable {
    case auto = "Auto", efficient = "Efficient", cinematic = "Cinematic", ultra = "Max Fidelity"
    var id: String { rawValue }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case radiant = "Radiant", scientific = "Scientific"
    var id: String { rawValue }
}

enum DiskPlayback: Double, CaseIterable, Identifiable {
    case realTime = 1, slowTimeLapse = 100, timeLapse = 1000, fastTimeLapse = 4000
    var id: Double { rawValue }
    var label: String {
        switch self {
        case .realTime: return "1× real time"
        case .slowTimeLapse: return "100× time-lapse"
        case .timeLapse: return "1,000× time-lapse"
        case .fastTimeLapse: return "4,000× time-lapse"
        }
    }
}

struct RenderSettings {
    var quality: QualityMode = .ultra
    var showHUD = true
    var wallpaperMode = false
    var cinematic = false
    var paused = false
    var resetCamera = false
    var blackHoleSpin: Float = 0.82
    var diskTilt: Float = 0.32
    var exposureEV: Float = 0
    var massSolar: Double = 100_000_000
    var accretionSolarMassesPerYear: Double = 0.1
    var diskOuterRadius: Double = 30
    var perturbationAmplitude: Float = 0
    var diagnosticMode = false
    var progressive = true
    var showPhysics = false
    // Artistic source / photographic response, independent of Kerr transport.
    var appearance: AppearanceMode = .radiant
    var materialStrength: Float = 0.85
    var paletteTemperature: Float = 7000
    var glowStrength: Float = 0.22
    var flowEnabled = true
    var flowSpeed: Float = 1
    var diskRotation = true
    var diskPlayback: DiskPlayback = .timeLapse
    var finiteThickness = true
    var thicknessMultiplier: Float = 0.75
    var diskCorrugation: Float = 0
    var refineEdges = true
}
