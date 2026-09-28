import Foundation
import Metal

/// Verifies actual production source shading, then renders an offscreen movie
/// from one cached finite-photosphere transfer map at calibrated source times.
enum RotationValidation {
    static func difference(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
        var error: Float = 0
        for i in a.indices { for channel in 0..<3 {
            error = max(error, abs(a[i][channel] - b[i][channel]) / max(1, max(abs(a[i][channel]), abs(b[i][channel]))))
        } }
        return error
    }

    static func baseUniforms(model: DiskModel, disk: DiskRadialTable, spectrum: DiskSpectralTable) -> Uniforms {
        var u = Uniforms()
        u.spin = Float(model.spin); u.diskInnerRadius = disk.innerRadius; u.diskOuterRadius = disk.outerRadius
        u.diskTableCount = UInt32(disk.values.count); u.diskLogRadiusMin = disk.logRadiusMin; u.diskLogRadiusStep = disk.logRadiusStep
        u.temperatureTableCount = UInt32(spectrum.values.count); u.temperatureLogMin = spectrum.logTemperatureMin; u.temperatureLogStep = spectrum.logTemperatureStep
        u.massTimeSeconds = Float(model.gravitationalTimeSeconds)
        u.appearanceMode = 1; u.materialStrength = 0.85; u.paletteTemperature = 7000
        u.flowLogRadiusMin = log(disk.innerRadius); u.flowLogRadiusSpan = log(disk.outerRadius / disk.innerRadius)
        u.materialShutterSeconds = 0; u.materialTimeSamples = 1
        return u
    }

    static func run(outputDirectory: String) throws {
        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let (device, queue, library) = try GPUVerification.context()
        let settings = RenderSettings()
        let model = DiskModel(spin: Double(settings.blackHoleSpin), massSolar: settings.massSolar, accretionSolarMassesPerYear: settings.accretionSolarMassesPerYear, outerRadius: settings.diskOuterRadius)
        let disk = DiskPhysics.radialTable(for: model), spectrum = DiskPhysics.spectralTable(count: 4096)
        let radialBuffer = device.makeBuffer(bytes: disk.values, length: disk.values.count * 16, options: .storageModeShared)!
        let spectralBuffer = device.makeBuffer(bytes: spectrum.values, length: spectrum.values.count * 16, options: .storageModeShared)!
        let probeSource = #"""
        kernel void probeRotatingMaterial(constant Uniforms& u [[buffer(0)]],
                                          device const float4* hits [[buffer(1)]],
                                          device const float4* disk [[buffer(2)]],
                                          device const float4* spectrum [[buffer(3)]],
                                          device float4* output [[buffer(4)]],
                                          constant float& footprint [[buffer(5)]],
                                          constant uint& count [[buffer(6)]],uint index [[thread_position_in_grid]]) {
            if(index>=count) return;
            output[index]=float4(shadeHit(hits[index],.5,footprint,u,disk,spectrum),1.);
        }
        """#
        let compile = MTLCompileOptions(); compile.fastMathEnabled = false
        let testLibrary = try device.makeLibrary(source: ShaderSource.code + probeSource, options: compile)
        let probe = try device.makeComputePipelineState(function: testLibrary.makeFunction(name: "probeRotatingMaterial")!)
        func evaluate(_ hits: [SIMD4<Float>], _ parameters: Uniforms, footprint: Float = 0) throws -> [SIMD4<Float>] {
            var parameters = parameters, footprint = footprint, count = UInt32(hits.count)
            let input = device.makeBuffer(bytes: hits, length: hits.count * 16, options: .storageModeShared)!
            let output = device.makeBuffer(length: hits.count * 16, options: .storageModeShared)!
            let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(probe); encoder.setBytes(&parameters, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setBuffer(input, offset: 0, index: 1); encoder.setBuffer(radialBuffer, offset: 0, index: 2); encoder.setBuffer(spectralBuffer, offset: 0, index: 3); encoder.setBuffer(output, offset: 0, index: 4)
            encoder.setBytes(&footprint, length: 4, index: 5); encoder.setBytes(&count, length: 4, index: 6)
            encoder.dispatchThreads(.init(width: hits.count, height: 1, depth: 1), threadsPerThreadgroup: .init(width: probe.threadExecutionWidth, height: 1, depth: 1)); encoder.endEncoding()
            _ = try AppearanceValidation.finish(command)
            let values = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: hits.count)
            return Array(UnsafeBufferPointer(start: values, count: hits.count))
        }
        var report = AppearanceValidation.Report()
        var u = baseUniforms(model: model, disk: disk, spectrum: spectrum); u.time = 1234
        var periodicError: Float = 0, progradeError: Float = 0
        for radius: Float in [3.2, 6, 12, 25] {
            let hits = (0..<64).map { index in SIMD4<Float>(radius, Float(index) * 2 * .pi / 64 + 0.17, 70 + Float(index) * 0.125, 0.9) }
            let initial = try evaluate(hits, u)
            var advanced = u
            advanced.time += Float(DiskMotion.orbitalPeriod(radius: Double(radius), spin: model.spin, massSolar: model.massSolar))
            periodicError = max(periodicError, difference(initial, try evaluate(hits, advanced)))
            let delta: Float = 5700
            advanced.time = u.time + delta
            let rotation = Float(DiskMotion.angularVelocity(radius: Double(radius), spin: model.spin)) * delta / u.massTimeSeconds
            let moved = hits.map { SIMD4<Float>($0.x, $0.y + rotation, $0.z, $0.w) }
            progradeError = max(progradeError, difference(initial, try evaluate(moved, advanced)))
        }
        report.check(periodicError < 0.0002, "Production material repeats after each radius-specific orbital period", details: "four radii; maximum normalized radiance error=\(periodicError); zero pixel footprint and zero shutter isolate local advection")
        report.check(progradeError < 0.0002, "Material advects prograde at the radius-dependent Kerr angular velocity", details: "maximum normalized co-moving radiance error=\(progradeError)")
        let hits = (0..<96).map { index in SIMD4<Float>(6, Float(index) * 2 * .pi / 96 + 0.31, 77.25, 0.85) }
        let base = try evaluate(hits, u)
        var scaledMass = u; scaledMass.massTimeSeconds *= 10; scaledMass.time *= 10
        let massError = difference(base, try evaluate(hits, scaledMass))
        report.check(massError < 0.0002, "Ten times the mass and elapsed time preserve the dimensionless rotating pattern", details: "maximum normalized radiance error=\(massError); source spectrum held fixed to isolate kinematics")
        var delayedTime = u; delayedTime.time += 32 * u.massTimeSeconds
        let delayedHits = hits.map { SIMD4<Float>($0.x, $0.y, $0.z + 32, $0.w) }
        let retardedError = difference(try evaluate(hits, u, footprint: 0.004), try evaluate(delayedHits, delayedTime, footprint: 0.004))
        report.check(retardedError < 0.0002, "Equal retarded emission times yield identical material through different path delays", details: "maximum normalized radiance error=\(retardedError)")
        var shifted = u; shifted.time += 5000
        let animated = try evaluate(hits, shifted)
        report.check(difference(base, animated) > 0.02, "Calibrated elapsed source time produces visible material evolution")
        var physical = u; physical.appearanceMode = 0
        let steady = try evaluate(hits, physical)
        physical.time += 1_000_000
        report.check(difference(steady, try evaluate(hits, physical)) == 0, "The unperturbed Scientific emission remains exactly stationary")
        report.check(base.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.x >= 0 && $0.y >= 0 && $0.z >= 0 } && animated.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "Rotating source radiance stays finite and nonnegative")

        var shutter = u; shutter.materialShutterSeconds = 3000; shutter.materialTimeSamples = 4
        let averaged = try evaluate(hits, shutter, footprint: 0.002)
        var independentAverage = [SIMD4<Float>](repeating: .zero, count: hits.count)
        for index in 0..<4 {
            var instantaneous = u
            instantaneous.time += (Float(index) / 4 + 0.125 - 0.5) * shutter.materialShutterSeconds
            let values = try evaluate(hits, instantaneous, footprint: 0.002)
            for i in values.indices { independentAverage[i] += values[i] / 4 }
        }
        let shutterError = difference(averaged, independentAverage)
        report.check(shutterError < 0.0002, "Four-tap physical shutter equals independent centered midpoint integration", details: "maximum normalized radiance error=\(shutterError)")
        var oneTap = shutter; oneTap.materialTimeSamples = 1
        report.check(difference(try evaluate(hits, oneTap), base) < 1e-6, "One temporal sample stays at shutter center")
        shutter.materialShutterSeconds = 0
        report.check(difference(try evaluate(hits, shutter), base) < 1e-6, "Zero shutter width exactly restores instantaneous material")
        let preview = try renderPreview(device: device, queue: queue, library: library, model: model, disk: disk, spectrum: spectrum, radialBuffer: radialBuffer, spectralBuffer: spectralBuffer, outputDirectory: outputDirectory, report: &report)
        let failures = report.checks.filter { !($0["passed"] as! Bool) }.count
        try GPUVerification.write(["device": device.name, "uniformStride": MemoryLayout<Uniforms>.stride, "checks": report.checks, "preview": preview], to: "\(outputDirectory)/rotation-validation.json")
        print("\(report.checks.count - failures)/\(report.checks.count) production rotation checks passed")
        if failures > 0 { throw GPUVerification.failure("Rotation validation failed") }
    }

    static func renderPreview(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary, model: DiskModel, disk: DiskRadialTable, spectrum: DiskSpectralTable, radialBuffer: MTLBuffer, spectralBuffer: MTLBuffer, outputDirectory: String, report: inout AppearanceValidation.Report) throws -> [String: Any] {
        let width = 960, height = 640, fps = 30, frameCount = 240, playback = 1000.0
        let workspace = URL(fileURLWithPath: outputDirectory).deletingLastPathComponent()
        let framesDirectory = workspace.appendingPathComponent("work/rotation-frames")
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)
        let trace = try device.makeComputePipelineState(function: library.makeFunction(name: "traceGeometry")!)
        let shade = try device.makeComputePipelineState(function: library.makeFunction(name: "shadeGeometry")!)
        let flow = try DiskFlow(device: device, library: library), camera = try CameraResponse(device: device, library: library)
        let refinement = try GeometryRefinement(device: device, library: library)
        var u = baseUniforms(model: model, disk: disk, spectrum: spectrum)
        let pose = CameraState()
        u.resolution = .init(UInt32(width), UInt32(height)); u.samples = 4; u.steps = 8192; u.integrationTolerance = 3e-7; u.maxStep = 0.012
        u.cameraYaw = pose.yaw; u.cameraPitch = pose.pitch; u.observerRadius = pose.radius; u.verticalFOV = pose.fov
        u.diskHeightScale = DiskGeometry.heightScale(for: model, multiplier: RenderSettings().thicknessMultiplier); u.diskCorrugation = 0
        u.edgeSamples = 16; u.edgeCapacity = UInt32(width * height * 3 / 100); u.flowEnabled = 1
        u.materialShutterSeconds = Float(0.5 * playback / Double(fps)); u.materialTimeSamples = 4
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
        let radiance = device.makeTexture(descriptor: d)!
        d.textureType = .type2DArray; d.arrayLength = Int(u.samples)
        let mapping = device.makeTexture(descriptor: d)!
        refinement.prepare(width: width, height: height, samples: Int(u.edgeSamples), capacity: Int(u.edgeCapacity))
        let geometry = queue.makeCommandBuffer()!, geometryEncoder = geometry.makeComputeCommandEncoder()!
        geometryEncoder.setComputePipelineState(trace); geometryEncoder.setTexture(mapping, index: 0); geometryEncoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        geometryEncoder.dispatchThreads(.init(width: width, height: height, depth: Int(u.samples)), threadsPerThreadgroup: .init(width: trace.threadExecutionWidth, height: 4, depth: 1)); geometryEncoder.endEncoding()
        let edgeCounter = refinement.encode(command: geometry, mapping: mapping, uniforms: u)
        let geometryMS = try AppearanceValidation.finish(geometry)
        let angularRate = DiskMotion.fluidAngularRate(innerRadius: Double(disk.innerRadius), spin: model.spin, massSolar: model.massSolar, playbackRate: playback)
        var settings = RenderSettings(); settings.appearance = .radiant
        var gpuTimes = [Double](), firstPixels = [SIMD4<Float>](), lastPixels = [SIMD4<Float>]()
        var allFramesFinite = true, unresolved = 0
        for frame in 0..<frameCount {
            try autoreleasepool {
                u.time = Float(Double(frame) * playback / Double(fps))
                let command = queue.makeCommandBuffer()!
                let flowTexture = flow.encode(command: command, deltaTime: frame == 0 ? 0 : 1 / Float(fps), spin: Float(model.spin), innerRadius: disk.innerRadius, outerRadius: disk.outerRadius, speed: 1, quality: 1, orbitalAngularRate: angularRate)
                let encoder = command.makeComputeCommandEncoder()!
                encoder.setComputePipelineState(shade)
                encoder.setTexture(mapping, index: 0); encoder.setTexture(flowTexture, index: 1); encoder.setTexture(radiance, index: 2); encoder.setTexture(refinement.lookup, index: 3)
                encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setBuffer(radialBuffer, offset: 0, index: 1); encoder.setBuffer(spectralBuffer, offset: 0, index: 2); encoder.setBuffer(refinement.hits, offset: 0, index: 3)
                encoder.dispatchThreads(.init(width: width, height: height, depth: 1), threadsPerThreadgroup: .init(width: shade.threadExecutionWidth, height: 4, depth: 1)); encoder.endEncoding()
                let display = camera.encode(command: command, source: radiance, settings: settings)
                let elapsed = try AppearanceValidation.finish(command)
                if frame > 0 { gpuTimes.append(elapsed) }
                let pixels = try AppearanceValidation.read(display, device: device, queue: queue)
                allFramesFinite = allFramesFinite && AppearanceValidation.finiteDisplay(pixels)
                if frame == 0 { firstPixels = pixels }
                if frame == frameCount - 1 {
                    lastPixels = pixels
                    let raw = try AppearanceValidation.read(radiance, device: device, queue: queue)
                    unresolved = raw.filter { $0.w < 0 }.count
                }
                let name = String(format: "frame-%04d.png", frame)
                try AppearanceValidation.savePNG(pixels, width: width, height: height, path: framesDirectory.appendingPathComponent(name).path)
                if frame % 30 == 0 { print("Rendered calibrated rotation preview: \(frame + 1)/\(frameCount) frames") }
            }
        }
        var changed = 0
        for i in firstPixels.indices {
            let difference = firstPixels[i] - lastPixels[i]
            if abs(difference.x) + abs(difference.y) + abs(difference.z) > 0.02 { changed += 1 }
        }
        report.check(allFramesFinite && unresolved == 0, "All calibrated preview frames remain finite with resolved geometry", details: "\(frameCount) frames; final unresolved pixels=\(unresolved)")
        report.check(changed > width * height / 100, "The actual production camera shows visible rotation over eight seconds", details: "\(changed) changed display pixels; fixed camera and geodesic map")
        report.check(!flow.timeWasClamped && flow.droppedDisplayTimeSeconds == 0, "Offline preview advances the fluid without dropping display time")
        try AppearanceValidation.savePNG(firstPixels, width: width, height: height, path: "\(outputDirectory)/rotation-first-frame.png")
        try AppearanceValidation.savePNG(lastPixels, width: width, height: height, path: "\(outputDirectory)/rotation-last-frame.png")
        let sorted = gpuTimes.sorted(), median = sorted[sorted.count / 2]
        print("Calibrated rotation preview: geometry \(geometryMS) ms; cached animated frame median \(median) ms")
        return ["width": width, "height": height, "fps": fps, "frames": frameCount, "durationSeconds": Double(frameCount) / Double(fps), "playbackRate": playback, "massSolar": model.massSolar, "spin": model.spin, "shutterPhysicalSeconds": u.materialShutterSeconds, "temporalSamples": u.materialTimeSamples, "geometrySamples": u.samples, "edgeSamples": u.edgeSamples, "edgePixels": edgeCounter.map { Int($0.contents().load(as: UInt32.self)) } ?? 0, "geometryGPUms": geometryMS, "cachedFrameMedianGPUms": median, "pngDirectory": "work/rotation-frames", "movie": "rotation-preview.mp4", "fluidLimit": "Eulerian material turbulence remains a current-frame proxy, not a retarded GRMHD field history"]
    }
}
