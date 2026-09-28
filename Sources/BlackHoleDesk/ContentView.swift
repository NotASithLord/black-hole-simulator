import SwiftUI

struct ContentView: View {
    @Binding var settings: RenderSettings
    @State private var controlsVisible = true
    @StateObject private var telemetry = RenderTelemetry()

    var body: some View {
        ZStack(alignment: .topLeading) {
            MetalView(settings: $settings, telemetry: telemetry, onDoubleClick: { controlsVisible.toggle() })
                .ignoresSafeArea()

            if settings.showHUD {
                VStack(alignment: .leading, spacing: 3) {
                    Text(telemetry.device)
                    Text("\(telemetry.resolution)  ·  \(telemetry.fps) FPS  ·  \(telemetry.gpuMS) ms GPU")
                    Text("\(telemetry.workload) \(telemetry.cached ? "cached samples/s" : "rays/s")  ·  \(telemetry.samples) samples/pixel")
                    Text("RK local target \(telemetry.tolerance) · cap \(telemetry.steps) steps")
                    Text(telemetry.phase)
                    Text(settings.diskRotation ? "Disk: \(settings.diskPlayback.label)" : "Disk: frozen")
                    if telemetry.flowTimeClamped && settings.appearance == .radiant { Text("Turbulence catch-up limited · orbital clock intact") }
                    if settings.appearance == .scientific { Text("Progressive: up to \(telemetry.accumulatedSamples) samples/pixel") }
                    if settings.appearance == .radiant && telemetry.edgeSamples > 0 {
                        Text("Edges: \(telemetry.edgeSamples) samples · \(telemetry.refinedPixels) pixels")
                        if telemetry.edgeOverflow > 0 { Text("Edge budget: \(telemetry.edgeOverflow) pixels use base sampling") }
                    }
                    Text("Unresolved pixels \(telemetry.unresolved) · invalid \(telemetry.nonfinite)")
                    Text("Kerr a/M \(String(format: "%.3f", settings.blackHoleSpin))  ·  G=c=M=1")
                    Text("\(telemetry.observer) · T max \(telemetry.temperature)")
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .padding(10)
                .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
                .padding(.leading, 18)
                .padding(.top, 78)
                .allowsHitTesting(false)
            }

            if controlsVisible {
                HStack(spacing: 10) {
                    Text("EVENT HORIZON")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                    Picker("Quality", selection: $settings.quality) {
                        ForEach(QualityMode.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 135)
                    Picker("Appearance", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 120)
                    Button("Cinematic presentation") { applyCinematicPresentation() }
                    Toggle("Cinematic camera", isOn: $settings.cinematic).toggleStyle(.button)
                    Toggle("HUD", isOn: $settings.showHUD).toggleStyle(.button)
                    Toggle("Wallpaper", isOn: $settings.wallpaperMode).toggleStyle(.button)
                    Toggle("Details", isOn: $settings.showPhysics).toggleStyle(.button)
                    Button(settings.paused ? "Resume" : "Pause") { settings.paused.toggle() }
                }
                .padding(10)
                .background(.black.opacity(0.42), in: Capsule())
                .padding(18)
                .foregroundStyle(.white)
            }

            if settings.showPhysics {
                ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("LIGHT & CAMERA").font(.system(size:11,weight:.bold,design:.monospaced))
                    Text(settings.appearance == .radiant ? "Radiant: art-directed emission + photographic glare. Kerr paths and relativistic beaming remain enabled." : "Scientific: original thermal spectrum and steady relativistic thin disk. No palette or glow.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Cinematic camera passage", isOn: $settings.cinematic)
                    Text("A slow, wide orbit with a shallow viewing angle and a restrained dolly. It moves only the observer, so every new position retraces Kerr paths; use it deliberately at Max Fidelity.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack { Text("Exposure"); Slider(value:$settings.exposureEV,in:-8...8); Text(String(format:"%+.1f EV",settings.exposureEV)).monospacedDigit() }
                    Toggle("Rotate disk material",isOn:$settings.diskRotation)
                    Picker("Disk playback",selection:$settings.diskPlayback) {
                        ForEach(DiskPlayback.allCases) { Text($0.label).tag($0) }
                    }
                    Text(orbitalPeriodDescription).font(.caption2).foregroundStyle(.secondary)
                    if settings.appearance == .radiant {
                        Text("Cinematic flare uses the existing Radiant source and photographic response, plus a small co-moving emissivity variation. Kerr transport, disk parameters and Doppler shifts are unchanged.")
                            .font(.caption2).foregroundStyle(.secondary)
                        HStack { Text("Emission tint"); Slider(value:$settings.paletteTemperature,in:4000...11000); Text(String(format:"%.0f K",settings.paletteTemperature)).monospacedDigit() }
                        HStack { Text("Structure"); Slider(value:$settings.materialStrength,in:0...1) }
                        HStack { Text("Lens glow"); Slider(value:$settings.glowStrength,in:0...0.5) }
                        Toggle("Evolving fluid material",isOn:$settings.flowEnabled)
                        HStack { Text("Turbulence speed"); Slider(value:$settings.flowSpeed,in:0...3) }
                        Text("Material follows differential Kerr rotation and light-travel delays. The optional fluid texture is an instantaneous 2D turbulence proxy, not a relativistic plasma history. Tint is a palette temperature, not the gas temperature.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("PHYSICAL MODEL").font(.system(size:11,weight:.bold,design:.monospaced))
                    Text("Kerr spacetime · ZAMO observer\nZero-torque relativistic thin disk\nPlanck spectrum · CIE 1931 color")
                        .font(.caption).foregroundStyle(.secondary)
                    if settings.appearance == .radiant {
                        Toggle("Finite disk thickness",isOn:$settings.finiteThickness)
                        if settings.finiteThickness {
                            HStack { Text("Thickness"); Slider(value:$settings.thicknessMultiplier,in:0.1...2); Text(String(format:"%.2f×",settings.thicknessMultiplier)).monospacedDigit() }
                            HStack { Text("Surface ripples"); Slider(value:$settings.diskCorrugation,in:0...0.08) }
                            Text("Radius-dependent photosphere with self-occlusion and a smooth outer closure. Approximate pressure-based height, not a solved atmosphere. Ripples are optional, stationary shape variations.")
                                .font(.caption2).foregroundStyle(.secondary)
                            if thicknessIsLimited { Text("Thickness capped to keep this thin-disk approximation within its geometric limit.").font(.caption2).foregroundStyle(.orange) }
                        }
                        Toggle("Refine thin arcs and silhouettes",isOn:$settings.refineEdges)
                    } else {
                        Text("Razor-thin reference geometry").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack { Text("Spin"); Slider(value:$settings.blackHoleSpin,in:0...0.998); Text(String(format:"%.3f",settings.blackHoleSpin)).monospacedDigit() }
                    HStack { Text("Mass"); Picker("Mass",selection:$settings.massSolar) {
                        Text("10⁷ M☉").tag(10_000_000.0); Text("10⁸ M☉").tag(100_000_000.0); Text("10⁹ M☉").tag(1_000_000_000.0)
                    }.labelsHidden() }
                    HStack { Text("Accretion"); Picker("Accretion",selection:$settings.accretionSolarMassesPerYear) {
                        Text("0.001 M☉/yr").tag(0.001); Text("0.01 M☉/yr").tag(0.01); Text("0.1 M☉/yr").tag(0.1)
                    }.labelsHidden() }
                    HStack { Text("Outer radius"); Picker("Outer radius",selection:$settings.diskOuterRadius) {
                        Text("20 M").tag(20.0); Text("30 M").tag(30.0); Text("80 M").tag(80.0)
                    }.labelsHidden() }
                    Text(String(format:"Nominal L/L_Edd = %.3f",DiskModel(spin:Double(settings.blackHoleSpin),massSolar:settings.massSolar,accretionSolarMassesPerYear:settings.accretionSolarMassesPerYear).nominalEddingtonRatio))
                        .font(.caption2).foregroundStyle(.secondary)
                    if settings.appearance == .scientific { Toggle("Progressive sampling when stationary",isOn:$settings.progressive) }
                    Toggle("Show unresolved rays in magenta",isOn:$settings.diagnosticMode)
                    Text("Scientific source: steady thin disk. Its time runs at infinity. Optional co-moving light fluctuations below are prescribed, not GRMHD.")
                        .font(.caption2).foregroundStyle(.secondary)
                    HStack { Text("Light fluctuations"); Slider(value:$settings.perturbationAmplitude,in:0...0.2); Text(String(format:"%.0f%%",settings.perturbationAmplitude * 100)).monospacedDigit() }
                    Text("A bounded, differential-Kerr-rotating emissivity field evaluated at each ray's retarded emission time. Zero restores the steady Page–Thorne source.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("Drag: orbit · Right-drag: look · Scroll: zoom\nW/S: approach/retreat · A/D: azimuth · Q/E: elevation\nR: reset · H: HUD · ⇧⌘W: wallpaper")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(telemetry.capabilities).font(.caption2).foregroundStyle(.secondary)
                }
                .font(.system(size:12))
                .padding(16)
                }.frame(width:360).frame(maxHeight:650)
                .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:12))
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topTrailing)
                .padding(.top,76).padding(.trailing,18)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var thicknessIsLimited: Bool {
        let model = DiskModel(spin:Double(settings.blackHoleSpin),massSolar:settings.massSolar,accretionSolarMassesPerYear:settings.accretionSolarMassesPerYear,outerRadius:settings.diskOuterRadius)
        return DiskGeometry.nominalHeightScale(for:model,multiplier:settings.thicknessMultiplier) > Double(DiskGeometry.heightScale(for:model,multiplier:settings.thicknessMultiplier)) * 1.00001
    }

    private var orbitalPeriodDescription: String {
        let spin = Double(settings.blackHoleSpin)
        let period = DiskMotion.orbitalPeriod(radius:DiskPhysics.isco(spin:spin),spin:spin,massSolar:settings.massSolar)
        return String(format:"Inner-edge orbit: %.2f physical hours · %.1f seconds at selected playback. Faster playback changes time, not the gas velocity used for Doppler shifts.",period/3600,period/settings.diskPlayback.rawValue)
    }

    /// A convenience look preset. These are deliberately presentation and playback
    /// controls only; it does not alter Kerr transport or the thin-disk model.
    private func applyCinematicPresentation() {
        settings.appearance = .radiant
        settings.exposureEV = 0.25
        settings.paletteTemperature = 6800
        settings.materialStrength = 0.92
        settings.glowStrength = 0.30
        settings.flowEnabled = true
        settings.flowSpeed = 1.15
        settings.diskRotation = true
        settings.diskPlayback = .timeLapse
        settings.perturbationAmplitude = 0.06
        // The disk/material remains live at the selected quality.  A moving
        // observer needs a newly solved transfer map at every position, so
        // presentation does not silently trade physical ray tracing for an
        // interpolated camera move.  The optional camera passage is explicit.
        settings.cinematic = false
    }
}

final class RenderTelemetry: ObservableObject {
    @Published var device = "Calibrating Metal GPU…"
    @Published var resolution = "—"
    @Published var fps = "—"
    @Published var gpuMS = "—"
    @Published var workload = "—"
    @Published var steps = 0
    @Published var samples = 0
    @Published var accumulatedSamples = 0
    @Published var tolerance = "—"
    @Published var phase = "Calibrating"
    @Published var capabilities = ""
    @Published var temperature = "—"
    @Published var observer = "—"
    @Published var unresolved = "checking…"
    @Published var nonfinite = 0
    @Published var cached = false
    @Published var refinedPixels = 0
    @Published var edgeOverflow = 0
    @Published var edgeSamples = 0
    @Published var flowTimeClamped = false
}
