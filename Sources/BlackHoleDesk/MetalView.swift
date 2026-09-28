import AppKit
import MetalKit
import SwiftUI

struct MetalView: NSViewRepresentable {
    @Binding var settings: RenderSettings
    let telemetry: RenderTelemetry
    var onDoubleClick: (() -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(settings: settings, telemetry: telemetry) }
    func makeNSView(context: Context) -> MTKView {
        let view = InteractiveMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        let renderer = context.coordinator.renderer
        view.onDrag = { [weak renderer] x,y,look in renderer?.drag(x: x, y: y, look: look) }
        view.onZoom = { [weak renderer] delta in renderer?.zoom(delta) }
        view.onKey = { [weak renderer] key,down in renderer?.key(key, down: down) }
        view.onDoubleClick = onDoubleClick
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.delegate = renderer
        renderer.view = view
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.renderer.settings = settings
        (view as? InteractiveMetalView)?.onDoubleClick = onDoubleClick
    }
    final class Coordinator {
        let renderer: BlackHoleRenderer
        init(settings: RenderSettings, telemetry: RenderTelemetry) { renderer = BlackHoleRenderer(settings: settings, telemetry: telemetry) }
    }
}

final class InteractiveMetalView: MTKView {
    var onDrag: ((Float,Float,Bool)->Void)?
    var onZoom: ((Float)->Void)?
    var onKey: ((UInt16,Bool)->Void)?
    var onDoubleClick: (() -> Void)?
    private var lastDragLocation: NSPoint?
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDragLocation = event.locationInWindow
        // Native handling keeps SwiftUI's double-tap recognizer from capturing
        // the mouse sequence before MTKView receives orbit/free-look drags.
        if event.clickCount == 2 { onDoubleClick?() }
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDragLocation = event.locationInWindow
    }
    private func deliverDrag(_ event: NSEvent, look: Bool) {
        let point = event.locationInWindow
        // Position differences also support synthesized tablet/UI-test events
        // that provide valid locations but report zero deltaX/deltaY.
        let dx = lastDragLocation.map { point.x - $0.x } ?? event.deltaX
        let dy = lastDragLocation.map { $0.y - point.y } ?? event.deltaY
        lastDragLocation = point
        onDrag?(Float(dx), Float(dy), look)
    }
    override func mouseDragged(with event: NSEvent) { deliverDrag(event, look: false) }
    override func rightMouseDragged(with event: NSEvent) { deliverDrag(event, look: true) }
    override func mouseUp(with event: NSEvent) { lastDragLocation = nil }
    override func rightMouseUp(with event: NSEvent) { lastDragLocation = nil }
    override func scrollWheel(with event: NSEvent) { onZoom?(Float(event.scrollingDeltaY)) }
    override func keyDown(with event: NSEvent) {
        if [0,1,2,13,12,14].contains(event.keyCode) { onKey?(event.keyCode,true) }
        else { super.keyDown(with:event) }
    }
    override func keyUp(with event: NSEvent) { onKey?(event.keyCode,false) }
}

/// The order is mirrored verbatim by Metal Uniforms; 176 bytes, alignment 8.
struct Uniforms {
    var resolution: SIMD2<UInt32> = .init(1,1)
    var time: Float = 0, spin: Float = 0.82, diskTilt: Float = 0
    var cameraYaw: Float = 0, cameraPitch: Float = 0.06, cameraDistance: Float = 10.5
    var steps: UInt32 = 2048, samples: UInt32 = 1, frame: UInt32 = 0
    var observerRadius: Float = 80, verticalFOV: Float = 0.3
    var integrationTolerance: Float = 2e-6, maxStep: Float = 0.025
    var diskInnerRadius: Float = 3, diskOuterRadius: Float = 80, exposure: Float = 0.03
    var diskTableCount: UInt32 = 0
    var diskLogRadiusMin: Float = 0, diskLogRadiusStep: Float = 1
    var massTimeSeconds: Float = 492.549, perturbationAmplitude: Float = 0
    var temperatureTableCount: UInt32 = 0
    var temperatureLogMin: Float = 0, temperatureLogStep: Float = 1
    var diagnosticMode: UInt32 = 0
    var padding: Float = 0, lookYaw: Float = 0, lookPitch: Float = 0
    var appearanceMode: UInt32 = 0
    var materialStrength: Float = 0.85, paletteTemperature: Float = 7000, flowTime: Float = 0
    var flowLogRadiusMin: Float = 0, flowLogRadiusSpan: Float = 1, flowTimeScale: Float = 1
    var flowEnabled: UInt32 = 0
    var diskHeightScale: Float = 0, diskCorrugation: Float = 0
    var edgeSamples: UInt32 = 0, edgeCapacity: UInt32 = 0
    var materialShutterSeconds: Float = 0
    var materialTimeSamples: UInt32 = 1
}

struct CameraState {
    var yaw: Float = -0.28, pitch: Float = 0.06, radius: Float = 80, fov: Float = 0.48
    var lookYaw: Float = 0, lookPitch: Float = 0
    // Kept separate from the observer radius so manual dolly controls remain
    // exact while the presentation path adds and removes its small offset.
    var cinematicDollyOffset: Float = 0
}

final class BlackHoleRenderer: NSObject, MTKViewDelegate {
    weak var view: MTKView?
    var settings: RenderSettings {
        didSet {
            if oldValue.paused != settings.paused || oldValue.diskRotation != settings.diskRotation {
                lastFrame = CACurrentMediaTime()
                pendingFlowElapsed = 0
            }
        }
    }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let tracePipeline: MTLComputePipelineState
    private let geometryPipeline: MTLComputePipelineState
    private let shadingPipeline: MTLComputePipelineState
    private let cameraResponse: CameraResponse
    private let edgeRefinement: GeometryRefinement
    private let diskFlow: DiskFlow
    private let neutralFlow: MTLTexture
    private let accumulationPipeline: MTLComputePipelineState
    private let diagnosticsPipeline: MTLComputePipelineState
    private let presentPipeline: MTLRenderPipelineState
    private let telemetry: RenderTelemetry
    private var target: MTLTexture?
    private var geometry: MTLTexture?
    private var geometryKey = ""
    private var histories: [MTLTexture] = []
    private var historyIndex = 0
    private var historyCount: UInt32 = 0
    private var renderedFrames: UInt32 = 0
    private var historyKey = ""
    private var radial: DiskRadialTable
    private var spectral: DiskSpectralTable
    private var radialBuffer: MTLBuffer
    private var spectralBuffer: MTLBuffer
    private var modelKey = ""
    private var camera = CameraState()
    private var keys = Set<UInt16>()
    private var quality = AdaptiveQuality()
    private var simulationTime: Double = 0
    private var sourceClock = SourceClock()
    private var pendingFlowElapsed: Double = 0
    private var lastFrame = CACurrentMediaTime()
    private var lastTelemetry = CACurrentMediaTime()
    private var completionCount = 0
    private var gpuMS: Double = 0
    private var lastTraceMS: Double = 0
    private var cachedFrameCount = 0
    private var previousReset = false
    private var clockObservers: [NSObjectProtocol] = []
    private var wallpaperActive = false
    private var savedWindowFrame: CGRect?
    private var savedStyle: NSWindow.StyleMask?
    private let inFlight = DispatchSemaphore(value: 2)

    init(settings: RenderSettings, telemetry: RenderTelemetry) {
        self.settings = settings; self.telemetry = telemetry
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal is unavailable") }
        self.device = device; self.queue = queue
        precondition(MemoryLayout<Uniforms>.stride == 176, "Metal/Swift uniform layout mismatch")
        let model = DiskModel(spin: Double(settings.blackHoleSpin), massSolar: settings.massSolar, accretionSolarMassesPerYear: settings.accretionSolarMassesPerYear, outerRadius: settings.diskOuterRadius)
        radial = DiskPhysics.radialTable(for: model, count: 4096)
        spectral = DiskPhysics.spectralTable(count: 4096)
        radialBuffer = device.makeBuffer(bytes: radial.values, length: radial.values.count * 16, options: .storageModeShared)!
        spectralBuffer = device.makeBuffer(bytes: spectral.values, length: spectral.values.count * 16, options: .storageModeShared)!
        do {
            let options = MTLCompileOptions(); options.fastMathEnabled = false
            let library = try device.makeLibrary(source: ShaderSource.code + "\n" + DiagnosticsSource.code + "\n" + CameraResponse.metalSource, options: options)
            tracePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "traceKerr")!)
            geometryPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "traceGeometry")!)
            shadingPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "shadeGeometry")!)
            cameraResponse = try CameraResponse(device: device, library: library)
            edgeRefinement = try GeometryRefinement(device: device, library: library)
            diskFlow = try DiskFlow(device: device)
            accumulationPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "accumulate")!)
            diagnosticsPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "diagnoseFrame")!)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "cameraPresentFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
            presentPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch { fatalError("Metal renderer compilation failed: \(error)") }
        let neutralDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
        neutralDescriptor.usage = .shaderRead; neutralDescriptor.storageMode = .shared
        neutralFlow = device.makeTexture(descriptor: neutralDescriptor)!
        var neutral = SIMD4<Float>(0.5,0,0,0)
        neutralFlow.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: &neutral, bytesPerRow: 16)
        super.init(); quality.inspect(device)
        // MTKView may stop callbacks while hidden/minimized; don't count that
        // unobserved interval as active source time when it becomes visible.
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            clockObservers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] notification in
                guard let self, let window = notification.object as? NSWindow, window === self.view?.window else { return }
                self.lastFrame = CACurrentMediaTime()
                self.pendingFlowElapsed = 0
            })
        }
    }

    deinit { for observer in clockObservers { NotificationCenter.default.removeObserver(observer) } }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { historyKey = "" }

    func draw(in view: MTKView) {
        updateWindow(view)
        let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        quality.configure(mode: settings.quality, wallpaper: settings.wallpaperMode, constrained: constrained, appearance: settings.appearance)
        view.preferredFramesPerSecond = settings.wallpaperMode && constrained ? 15 : quality.workload.fps
        let now = CACurrentMediaTime(); let elapsed = now-lastFrame
        let dt = Float(min(elapsed,1)); lastFrame = now
        guard !settings.paused, view.window?.isMiniaturized != true else { pendingFlowElapsed = 0; return }
        if !settings.wallpaperMode, view.window?.occlusionState.contains(.visible) == false { pendingFlowElapsed = 0; return }
        // Camera animation keeps wall time. Source time is separately
        // integrated so playback changes do not jump phase or speed the camera.
        simulationTime += elapsed
        sourceClock.advance(elapsed:elapsed,rate:settings.diskPlayback.rawValue,active:settings.diskRotation)
        if settings.diskRotation { pendingFlowElapsed += max(0,elapsed) }
        if previousReset != settings.resetCamera { camera = CameraState(); previousReset = settings.resetCamera; keys.removeAll() }
        if view.window?.isKeyWindow == false { keys.removeAll() }
        updateCamera(dt)
        guard inFlight.wait(timeout:.now()) == .success else { return }
        var committed = false
        defer { if !committed { geometryKey = ""; inFlight.signal() } }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return }
        updateDisk()
        var work = quality.workload
        let radiant = settings.appearance == .radiant
        // Cached maps are multisampled, not temporally accumulated radiance.
        // Cap their memory separately from the progressive scientific path.
        if radiant { work.samples = min(work.samples, settings.quality == .ultra ? 8 : 4) }
        let nativePixels = max(1, view.drawableSize.width * view.drawableSize.height)
        // Sparse edge samples (up to 3% × 16 samples), lookup, and pixel list
        // add <13 bytes/pixel; reserve sixteen in addition to the base map.
        let memoryPixels = Int(device.recommendedMaxWorkingSetSize) / 16 / (64 + (radiant ? 16 + work.samples*16 : 0))
        let scale = min(CGFloat(work.scale), sqrt(CGFloat(min(quality.pixelLimit,memoryPixels))/nativePixels))
        let width = max(8, Int(view.drawableSize.width * scale)), height = max(8, Int(view.drawableSize.height * scale))
        if target?.width != width || target?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:width,height:height,mipmapped:false)
            descriptor.usage = [.shaderRead,.shaderWrite]; descriptor.storageMode = .private
            target = device.makeTexture(descriptor:descriptor)
            histories = (0..<2).compactMap { _ in device.makeTexture(descriptor:descriptor) }
            historyKey = ""; geometryKey = ""
        }
        guard let target, histories.count == 2 else { return }
        var uniforms = makeUniforms(width:width,height:height,work:work)
        if edgeRefinement.prepare(width:width,height:height,samples:Int(uniforms.edgeSamples),capacity:Int(uniforms.edgeCapacity)) { geometryKey = "" }
        let stable = !radiant && settings.progressive && !settings.cinematic && keys.isEmpty && settings.perturbationAmplitude == 0 && !settings.diagnosticMode
        let key = "\(width),\(height),\(camera),\(modelKey),\(work.tolerance),\(work.maxStep),\(work.maxSteps),\(work.samples),\(settings.diagnosticMode)"
        if !stable || key != historyKey { historyCount = 0; historyKey = key }
        guard let cb = queue.makeCommandBuffer() else { return }
        cb.label = radiant ? "Cached Kerr + evolving disk + photographic response" : "Kerr geodesics + physical thermal disk"
        var traced = true
        var edgeCounter: MTLBuffer?
        if radiant {
            if geometry?.width != width || geometry?.height != height || geometry?.arrayLength != work.samples {
                let d = MTLTextureDescriptor()
                d.textureType = .type2DArray; d.pixelFormat = .rgba32Float
                d.width = width; d.height = height; d.arrayLength = work.samples
                d.usage = [.shaderRead,.shaderWrite]; d.storageMode = .private
                geometry = device.makeTexture(descriptor: d); geometryKey = ""
            }
            guard let geometry else { return }
            // Camera + metric + source intersection boundary + accuracy fully
            // determine this transfer map. Material/exposure/time do not.
            let transferKey = "\(width),\(height),\(camera),\(settings.blackHoleSpin),\(uniforms.diskInnerRadius),\(uniforms.diskOuterRadius),\(uniforms.diskHeightScale),\(uniforms.diskCorrugation),\(uniforms.edgeSamples),\(uniforms.edgeCapacity),\(work.tolerance),\(work.maxStep),\(work.maxSteps),\(work.samples)"
            traced = transferKey != geometryKey
            if traced {
                let e = cb.makeComputeCommandEncoder()!
                e.setComputePipelineState(geometryPipeline); e.setTexture(geometry,index:0)
                e.setBytes(&uniforms,length:MemoryLayout<Uniforms>.stride,index:0)
                e.dispatchThreads(.init(width:width,height:height,depth:work.samples),threadsPerThreadgroup:.init(width:geometryPipeline.threadExecutionWidth,height:4,depth:1))
                e.endEncoding()
                edgeCounter = edgeRefinement.encode(command:cb,mapping:geometry,uniforms:uniforms)
                geometryKey = transferKey
            }
            let orbitalRate = DiskMotion.fluidAngularRate(innerRadius:Double(uniforms.diskInnerRadius),spin:Double(settings.blackHoleSpin),massSolar:settings.massSolar,playbackRate:settings.diskRotation ? settings.diskPlayback.rawValue : 0)
            let flow = settings.flowEnabled ? diskFlow.encode(command:cb,deltaTime:settings.diskRotation ? Float(pendingFlowElapsed) : 0,spin:settings.blackHoleSpin,innerRadius:uniforms.diskInnerRadius,outerRadius:uniforms.diskOuterRadius,speed:settings.flowSpeed,quality:settings.quality == .ultra && !settings.wallpaperMode ? 1 : 0,orbitalAngularRate:orbitalRate) : neutralFlow
            telemetry.flowTimeClamped = settings.flowEnabled && diskFlow.timeWasClamped
            let e = cb.makeComputeCommandEncoder()!
            e.setComputePipelineState(shadingPipeline)
            e.setTexture(geometry,index:0); e.setTexture(flow,index:1); e.setTexture(target,index:2)
            e.setTexture(edgeRefinement.lookup,index:3); e.setBuffer(edgeRefinement.hits,offset:0,index:3)
            e.setBytes(&uniforms,length:MemoryLayout<Uniforms>.stride,index:0)
            e.setBuffer(radialBuffer,offset:0,index:1); e.setBuffer(spectralBuffer,offset:0,index:2)
            dispatch(e,pipeline:shadingPipeline,width:width,height:height); e.endEncoding()
        } else {
            let encoder = cb.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(tracePipeline); encoder.setTexture(target,index:0)
            encoder.setBytes(&uniforms,length:MemoryLayout<Uniforms>.stride,index:0)
            encoder.setBuffer(radialBuffer,offset:0,index:1); encoder.setBuffer(spectralBuffer,offset:0,index:2)
            dispatch(encoder,pipeline:tracePipeline,width:width,height:height); encoder.endEncoding()
        }
        var diagnostics: MTLBuffer?
        if renderedFrames % 16 == 0 {
            diagnostics = device.makeBuffer(length:8,options:.storageModeShared)
            if let diagnostics, let count = cb.makeComputeCommandEncoder() {
                memset(diagnostics.contents(),0,8)
                count.setComputePipelineState(diagnosticsPipeline); count.setTexture(target,index:0); count.setBuffer(diagnostics,offset:0,index:0)
                dispatch(count,pipeline:diagnosticsPipeline,width:width,height:height); count.endEncoding()
            }
        }
        var displayTexture = target
        if stable, let accumulate = cb.makeComputeCommandEncoder() {
            let next = 1-historyIndex
            var count = historyCount
            accumulate.setComputePipelineState(accumulationPipeline)
            accumulate.setTexture(target,index:0); accumulate.setTexture(histories[historyIndex],index:1); accumulate.setTexture(histories[next],index:2)
            accumulate.setBytes(&count,length:4,index:0)
            dispatch(accumulate,pipeline:accumulationPipeline,width:width,height:height); accumulate.endEncoding()
            historyIndex = next; displayTexture = histories[next]; historyCount = min(historyCount+1,65535)
        }
        displayTexture = cameraResponse.encode(command: cb, source: displayTexture, settings: settings)
        guard let render = cb.makeRenderCommandEncoder(descriptor:pass) else { return }
        render.setRenderPipelineState(presentPipeline); render.setFragmentTexture(displayTexture,index:0)
        render.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); render.endEncoding(); cb.present(drawable)
        let semaphore = inFlight; let completedHistory = historyCount
        let diagnosticResult = diagnostics; let completedTrace = traced; let completedWork = work
        let completedEdges = edgeCounter; let edgeCapacity = Int(uniforms.edgeCapacity); let edgeSamples = Int(uniforms.edgeSamples)
        cb.addCompletedHandler { [weak self] command in
            semaphore.signal()
            let duration = (command.gpuEndTime-command.gpuStartTime)*1000
            let failure = command.error?.localizedDescription
            let unresolved = diagnosticResult.map { Int($0.contents().load(as:UInt32.self)) }
            let invalid = diagnosticResult.map { Int($0.contents().advanced(by:4).load(as:UInt32.self)) }
            let markedEdges = completedEdges.map { Int($0.contents().load(as:UInt32.self)) }
            DispatchQueue.main.async {
                if let markedEdges {
                    self?.telemetry.refinedPixels = min(markedEdges,edgeCapacity)
                    self?.telemetry.edgeOverflow = max(0,markedEdges-edgeCapacity)
                } else if edgeSamples == 0 { self?.telemetry.refinedPixels = 0; self?.telemetry.edgeOverflow = 0 }
                self?.telemetry.edgeSamples = edgeSamples
                if let unresolved { self?.telemetry.unresolved = String(format:"%.4f%%",100*Double(unresolved)/Double(width*height)) }
                if let invalid { self?.telemetry.nonfinite = invalid }
                self?.completed(ms:duration,width:width,height:height,work:completedWork,history:completedHistory,traced:completedTrace,radiant:radiant,error:failure)
            }
        }
        pendingFlowElapsed = 0
        renderedFrames &+= 1; committed = true; cb.commit()
    }

    private func dispatch(_ encoder:MTLComputeCommandEncoder,pipeline:MTLComputePipelineState,width:Int,height:Int) {
        let w = pipeline.threadExecutionWidth
        encoder.dispatchThreads(.init(width:width,height:height,depth:1),threadsPerThreadgroup:.init(width:w,height:4,depth:1))
    }
    private func updateDisk() {
        let key = "\(settings.blackHoleSpin),\(settings.massSolar),\(settings.accretionSolarMassesPerYear),\(settings.diskOuterRadius)"
        guard key != modelKey else { return }; modelKey = key
        radial = DiskPhysics.radialTable(for:.init(spin:Double(settings.blackHoleSpin),massSolar:settings.massSolar,accretionSolarMassesPerYear:settings.accretionSolarMassesPerYear,outerRadius:settings.diskOuterRadius),count:4096)
        radialBuffer = device.makeBuffer(bytes:radial.values,length:radial.values.count*16,options:.storageModeShared)!
    }
    private func makeUniforms(width:Int,height:Int,work:QualityWorkload)->Uniforms {
        var u = Uniforms()
        u.resolution = .init(UInt32(width),UInt32(height)); u.time = Float(sourceClock.seconds)
        u.spin = settings.blackHoleSpin; u.cameraYaw = camera.yaw; u.cameraPitch = camera.pitch
        u.observerRadius = camera.radius; u.verticalFOV = camera.fov; u.lookYaw = camera.lookYaw; u.lookPitch = camera.lookPitch
        u.steps = UInt32(work.maxSteps); u.samples = UInt32(work.samples); u.frame = renderedFrames
        u.integrationTolerance = work.tolerance; u.maxStep = work.maxStep
        u.diskInnerRadius = Float(radial.innerRadius); u.diskOuterRadius = Float(radial.outerRadius)
        u.diskTableCount = UInt32(radial.values.count); u.diskLogRadiusMin = Float(radial.logRadiusMin); u.diskLogRadiusStep = Float(radial.logRadiusStep)
        u.temperatureTableCount = UInt32(spectral.values.count); u.temperatureLogMin = Float(spectral.logTemperatureMin); u.temperatureLogStep = Float(spectral.logTemperatureStep)
        u.exposure = 0.03 * pow(2,settings.exposureEV)
        u.massTimeSeconds = Float(DiskModel(spin:Double(settings.blackHoleSpin),massSolar:settings.massSolar).gravitationalTimeSeconds)
        u.perturbationAmplitude = settings.perturbationAmplitude; u.diagnosticMode = settings.diagnosticMode ? 1 : 0
        u.appearanceMode = settings.appearance == .radiant ? 1 : 0
        u.materialStrength = settings.materialStrength; u.paletteTemperature = settings.paletteTemperature
        u.flowTime = Float(simulationTime); u.flowTimeScale = settings.flowSpeed
        u.flowLogRadiusMin = log(u.diskInnerRadius); u.flowLogRadiusSpan = log(u.diskOuterRadius/u.diskInnerRadius)
        u.flowEnabled = settings.flowEnabled && settings.appearance == .radiant ? 1 : 0
        if settings.appearance == .radiant && settings.diskRotation {
            u.materialTimeSamples = settings.wallpaperMode || settings.quality == .efficient ? 1 : settings.quality == .ultra ? 4 : 2
            u.materialShutterSeconds = Float(0.5 * settings.diskPlayback.rawValue / Double(max(1,work.fps)))
        }
        let model = DiskModel(spin:Double(settings.blackHoleSpin),massSolar:settings.massSolar,accretionSolarMassesPerYear:settings.accretionSolarMassesPerYear,outerRadius:settings.diskOuterRadius)
        if settings.appearance == .radiant && settings.finiteThickness {
            u.diskHeightScale = DiskGeometry.heightScale(for:model,multiplier:settings.thicknessMultiplier)
            u.diskCorrugation = min(0.08,max(0,settings.diskCorrugation))
        }
        if settings.appearance == .radiant && settings.refineEdges {
            u.edgeSamples = settings.quality == .ultra && !settings.wallpaperMode ? 16 : settings.quality == .efficient || settings.wallpaperMode ? 4 : 8
            u.edgeCapacity = UInt32(min(200_000,max(64,width*height*3/100)))
        }
        return u
    }
    private func completed(ms:Double,width:Int,height:Int,work:QualityWorkload,history:UInt32,traced:Bool,radiant:Bool,error:String?) {
        guard error == nil else { telemetry.phase = "GPU error: \(error!)"; geometryKey = ""; return }
        // Never mistake a cheap cached update for a cheap geodesic trace:
        // doing so would repeatedly inflate work and invalidate the cache.
        if traced { quality.record(milliseconds:ms); lastTraceMS = ms; cachedFrameCount = 0 }
        else if radiant {
            cachedFrameCount += 1
            if cachedFrameCount == 45 { quality.refineCached(milliseconds:lastTraceMS) }
        }
        gpuMS = gpuMS == 0 ? ms : gpuMS*0.85+ms*0.15
        completionCount += 1
        let now = CACurrentMediaTime(); guard now-lastTelemetry >= 0.5 else { return }
        let fps = Double(completionCount)/(now-lastTelemetry); lastTelemetry = now; completionCount = 0
        telemetry.device = device.name; telemetry.capabilities = quality.capabilities
        telemetry.phase = radiant ? (traced ? "Tracing Kerr transfer map" : "Cached Kerr · live materials") : quality.phase
        telemetry.resolution = "\(width) × \(height)"; telemetry.fps = String(format:"%.1f",fps); telemetry.gpuMS = String(format:"%.1f",gpuMS)
        let baseWork = width*height*work.samples
        let edgeWork = telemetry.refinedPixels * (traced ? telemetry.edgeSamples : max(0,telemetry.edgeSamples-work.samples))
        telemetry.workload = String(format:"%.1fM",Double(baseWork + (radiant ? edgeWork : 0))*fps/1e6)
        telemetry.steps = work.maxSteps; telemetry.samples = work.samples; telemetry.accumulatedSamples = Int(history)*work.samples
        telemetry.cached = radiant && !traced
        telemetry.tolerance = String(format:"%.0e",work.tolerance)
        telemetry.temperature = String(format:"%.0f K",radial.peakTemperature)
        telemetry.observer = String(format:"r %.1f M · i %.1f°",camera.radius,90-camera.pitch*180/Float.pi)
    }
    private func updateCamera(_ dt:Float) {
        let travel = dt * max(1,camera.radius*0.2)
        if keys.contains(13) { camera.radius -= travel }; if keys.contains(1) { camera.radius += travel }
        if keys.contains(0) { camera.yaw -= dt*0.2 }; if keys.contains(2) { camera.yaw += dt*0.2 }
        if keys.contains(12) { camera.pitch -= dt*0.15 }; if keys.contains(14) { camera.pitch += dt*0.15 }

        if settings.cinematic {
            // A deliberately quiet presentation path: a broad, low-latitude
            // observer orbit and a very small dolly cycle.  This changes only
            // the observer tetrad used for rays; the Kerr solution and source
            // model are rebuilt from the current user-selected parameters.
            let baseRadius = camera.radius - camera.cinematicDollyOffset
            let dollyPhase = Float(simulationTime * 0.004)
            let verticalPhase = Float(simulationTime * 0.006)
            camera.yaw += dt * 0.010
            let desiredDolly = baseRadius * 0.035 * sin(dollyPhase)
            camera.radius = baseRadius + desiredDolly
            camera.cinematicDollyOffset = desiredDolly
            let desiredPitch: Float = 0.075 + 0.012 * sin(verticalPhase + 0.65)
            let settle = min(1, dt * 0.35)
            camera.pitch += (desiredPitch - camera.pitch) * settle
        } else {
            // Remove the display-only dolly term exactly once when leaving the
            // preset, retaining the radius established by user input.
            camera.radius -= camera.cinematicDollyOffset
            camera.cinematicDollyOffset = 0
        }
        camera.radius = max(12,min(300,camera.radius)); camera.pitch = max(-1.4,min(1.4,camera.pitch))
    }
    func drag(x:Float,y:Float,look:Bool) {
        if look { camera.lookYaw += x*0.004; camera.lookPitch = max(-1.3,min(1.3,camera.lookPitch+y*0.004)) }
        else { camera.yaw += x*0.005; camera.pitch = max(-1.4,min(1.4,camera.pitch+y*0.004)) }
    }
    func zoom(_ delta:Float) { camera.fov = max(0.07,min(1.6,camera.fov*exp(delta*0.004))) }
    func key(_ code:UInt16,down:Bool) { if down { keys.insert(code) } else { keys.remove(code) } }
    private func updateWindow(_ view:MTKView) {
        guard let window = view.window, wallpaperActive != settings.wallpaperMode else { return }
        wallpaperActive = settings.wallpaperMode
        if wallpaperActive {
            savedWindowFrame = window.frame; savedStyle = window.styleMask
            window.styleMask = [.borderless]; window.level = .init(rawValue:Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior = [.canJoinAllSpaces,.stationary,.ignoresCycle]
            if let screen = window.screen { window.setFrame(screen.frame,display:true) }
        } else {
            window.styleMask = savedStyle ?? [.titled,.closable,.miniaturizable,.resizable]
            window.level = .normal; window.collectionBehavior = [.managed,.fullScreenPrimary]
            if let frame = savedWindowFrame { window.setFrame(frame,display:true) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}
