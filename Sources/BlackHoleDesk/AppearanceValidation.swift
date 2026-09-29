import AppKit
import Metal

/// Exercises production Metal source, not CPU imitations of the renderer.
/// Image exports are already display-linear: only the sRGB transfer is applied.
enum AppearanceValidation {
    struct Report {
        var checks = [[String: Any]]()
        mutating func check(_ passed: Bool, _ name: String, details: String = "") {
            checks.append(["name": name, "passed": passed, "details": details])
            print("\(passed ? "PASS" : "FAIL") \(name) \(details)")
        }
    }

    static func texture(device: MTLDevice, width: Int, height: Int, pixels: [SIMD4<Float>]) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = device.makeTexture(descriptor: descriptor)!
        pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 16)
        }
        return texture
    }

    static func read(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) throws -> [SIMD4<Float>] {
        let componentBytes = texture.pixelFormat == .rgba16Float ? 2 : 4
        precondition(texture.pixelFormat == .rgba16Float || texture.pixelFormat == .rgba32Float)
        let rowBytes = ((texture.width * 4 * componentBytes + 255) / 256) * 256
        let buffer = device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared)!
        let command = queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0), sourceSize: .init(width: texture.width, height: texture.height, depth: 1), to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        let bytes = buffer.contents()
        var result = [SIMD4<Float>](); result.reserveCapacity(texture.width * texture.height)
        for y in 0..<texture.height {
            for x in 0..<texture.width {
                let pixel = bytes.advanced(by: y * rowBytes + x * componentBytes * 4)
                if componentBytes == 2 {
                    let values = pixel.assumingMemoryBound(to: UInt16.self)
                    result.append(.init(Float(Float16(bitPattern: values[0])), Float(Float16(bitPattern: values[1])), Float(Float16(bitPattern: values[2])), Float(Float16(bitPattern: values[3]))))
                } else {
                    let values = pixel.assumingMemoryBound(to: Float.self)
                    result.append(.init(values[0], values[1], values[2], values[3]))
                }
            }
        }
        return result
    }

    static func finish(_ command: MTLCommandBuffer) throws -> Double {
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        return (command.gpuEndTime - command.gpuStartTime) * 1000
    }

    static func savePNG(_ pixels: [SIMD4<Float>], width: Int, height: Int, path: String) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
        let bytes = bitmap.bitmapData!
        for i in pixels.indices {
            for channel in 0..<3 {
                let linear = Double(max(0, min(1, pixels[i][channel])))
                let srgb = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
                bytes[i * 4 + channel] = UInt8(max(0, min(255, srgb * 255 + 0.5)))
            }
            bytes[i * 4 + 3] = 255
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }

    static func finiteDisplay(_ pixels: [SIMD4<Float>]) -> Bool {
        pixels.allSatisfy { value in
            (0..<3).allSatisfy { value[$0].isFinite && value[$0] >= 0 && value[$0] <= 1.0001 }
        }
    }

    static func luminance(_ color: SIMD4<Float>) -> Float { 0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z }

    /// Exact comparison is intentional here. The Scientific response must not
    /// sample the cinematic pyramid or depend on its photographic controls.
    static func bitwiseEqual(_ lhs: [SIMD4<Float>], _ rhs: [SIMD4<Float>]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for i in lhs.indices {
            for channel in 0..<4 where lhs[i][channel].bitPattern != rhs[i][channel].bitPattern { return false }
        }
        return true
    }

    static func cameraChecks(device: MTLDevice, queue: MTLCommandQueue, camera: CameraResponse, report: inout Report) throws {
        let size = 128
        func render(_ values: [SIMD4<Float>], settings: RenderSettings) throws -> [SIMD4<Float>] {
            let source = texture(device: device, width: size, height: size, pixels: values)
            let command = queue.makeCommandBuffer()!
            let output = camera.encode(command: command, source: source, settings: settings)
            _ = try finish(command)
            return try read(output, device: device, queue: queue)
        }
        // The Scientific branch is a separate, byte-stable display path. This
        // patterned HDR image prevents a uniform input from hiding an accidental
        // sample of the photographic bloom pyramid.
        let pattern = (0..<(size * size)).map { index -> SIMD4<Float> in
            let x = Float(index % size) / Float(size - 1), y = Float(index / size) / Float(size - 1)
            return .init(0.002 + 80 * x * x, 0.001 + 14 * y, 0.0005 + 2 * x * y, 1)
        }
        var scientific = RenderSettings(); scientific.appearance = .scientific
        let scientificReference = try render(pattern, settings: scientific)
        scientific.glowStrength = 0.65
        let scientificWithGlareControl = try render(pattern, settings: scientific)
        report.check(bitwiseEqual(scientificReference, scientificWithGlareControl), "Scientific response is byte-identical when photographic glare changes")

        for appearance in AppearanceMode.allCases {
            var settings = RenderSettings(); settings.appearance = appearance
            let black = try render([SIMD4<Float>](repeating: .init(0, 0, 0, 1), count: size * size), settings: settings)
            report.check(black.allSatisfy { $0.x == 0 && $0.y == 0 && $0.z == 0 }, "\(appearance.rawValue): exact black remains black")
            let warm = try render([SIMD4<Float>](repeating: .init(8, 2, 0.2, 1), count: size * size), settings: settings)
            report.check(finiteDisplay(warm) && warm.allSatisfy { $0.x > $0.y && $0.y > $0.z }, "\(appearance.rawValue): warm HDR chromatic ordering preserved")
            if appearance == .radiant {
                var noGlare = settings; noGlare.glowStrength = 0
                let unspread = try render([SIMD4<Float>](repeating: .init(8, 2, 0.2, 1), count: size * size), settings: noGlare)
                let difference = zip(warm, unspread).reduce(Float(0)) { partial, pair in
                    max(partial, max(abs(pair.0.x - pair.1.x), max(abs(pair.0.y - pair.1.y), abs(pair.0.z - pair.1.z))))
                }
                report.check(difference < 0.001, "Highlight-only glare leaves a uniform radiance field unchanged", details: "maximum display-linear difference=\(difference)")
                var maximumGlare = settings; maximumGlare.glowStrength = 0.65
                let highGlareBlack = try render([SIMD4<Float>](repeating: .init(0, 0, 0, 1), count: size * size), settings: maximumGlare)
                report.check(highGlareBlack.allSatisfy { $0.x == 0 && $0.y == 0 && $0.z == 0 }, "Maximum photographic glare cannot create light from black")
            }
            var last: Float = -1, monotonic = true, bounded = true
            for brightness: Float in [0.001, 0.01, 0.1, 1, 10, 100, 1000, 10000] {
                let pixels = try render([SIMD4<Float>](repeating: .init(brightness, brightness, brightness, 1), count: size * size), settings: settings)
                let value = pixels[size * (size / 2) + size / 2].x
                monotonic = monotonic && value >= last; last = value
                bounded = bounded && finiteDisplay(pixels)
            }
            report.check(monotonic, "\(appearance.rawValue): response monotonic over seven decades of radiance")
            report.check(bounded, "\(appearance.rawValue): HDR output finite and SDR-bounded")
            var impulse = [SIMD4<Float>](repeating: .init(0, 0, 0, 1), count: size * size)
            for y in (size / 2 - 2)...(size / 2 + 2) {
                for x in (size / 2 - 2)...(size / 2 + 2) { impulse[y * size + x] = .init(600, 200, 30, 1) }
            }
            let pixels = try render(impulse, settings: settings)
            let glow = luminance(pixels[(size / 2) * size + size / 2 + 10])
            report.check(appearance == .radiant ? glow > 0 : glow == 0, "\(appearance.rawValue): glare is isolated to photographic mode", details: "off-source luminance=\(glow)")
        }
    }

    static func run(outputDirectory: String) throws {
        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let (device, queue, library) = try GPUVerification.context()
        let camera = try CameraResponse(device: device, library: library)
        var report = Report()
        try cameraChecks(device: device, queue: queue, camera: camera, report: &report)

        let flow = try DiskFlow(device: device, library: library)
        let settings = RenderSettings()
        let model = DiskModel(spin: Double(settings.blackHoleSpin), massSolar: settings.massSolar, accretionSolarMassesPerYear: settings.accretionSolarMassesPerYear, outerRadius: settings.diskOuterRadius)
        let disk = DiskPhysics.radialTable(for: model, count: 4096), spectrum = DiskPhysics.spectralTable(count: 4096)
        let diskBuffer = device.makeBuffer(bytes: disk.values, length: disk.values.count * 16, options: .storageModeShared)!
        let spectrumBuffer = device.makeBuffer(bytes: spectrum.values, length: spectrum.values.count * 16, options: .storageModeShared)!
        var flowTexture: MTLTexture!
        var initialFlow = [SIMD4<Float>](), flowTimes = [Double]()
        for frame in 0..<61 {
            let command = queue.makeCommandBuffer()!
            flowTexture = flow.encode(command: command, deltaTime: 1 / 60, spin: settings.blackHoleSpin, innerRadius: disk.innerRadius, outerRadius: disk.outerRadius, speed: settings.flowSpeed, quality: 1)
            let elapsed = try finish(command)
            if frame > 0 { flowTimes.append(elapsed) }
            else { initialFlow = try read(flowTexture, device: device, queue: queue) }
        }
        let finalFlow = try read(flowTexture, device: device, queue: queue)
        let flowFinite = finalFlow.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }
        report.check(flowFinite, "GPU fluid field remains finite after sixty updates")
        report.check(finalFlow.allSatisfy { $0.x >= 0 && $0.x <= 1 }, "GPU advected dye stays in [0,1]")
        report.check(finalFlow.allSatisfy { abs($0.y) <= 0.251 && abs($0.z) <= 0.251 }, "GPU perturbation velocities stay within solver safety bounds")
        let flowChange = zip(initialFlow, finalFlow).reduce(Float(0)) { $0 + abs($1.0.x - $1.1.x) } / Float(finalFlow.count)
        report.check(flowChange > 1e-5, "GPU material dye evolves rather than remaining static", details: "mean absolute dye change=\(flowChange)")

        let width = 1440, height = 960, samples = 2
        var uniforms = Uniforms()
        uniforms.resolution = .init(UInt32(width), UInt32(height)); uniforms.samples = UInt32(samples)
        uniforms.steps = 8192; uniforms.integrationTolerance = 3e-7; uniforms.maxStep = 0.012
        let initialCamera = CameraState()
        uniforms.cameraYaw = initialCamera.yaw; uniforms.cameraPitch = initialCamera.pitch; uniforms.observerRadius = initialCamera.radius; uniforms.verticalFOV = initialCamera.fov
        uniforms.spin = settings.blackHoleSpin; uniforms.diskInnerRadius = disk.innerRadius; uniforms.diskOuterRadius = disk.outerRadius
        uniforms.diskTableCount = UInt32(disk.values.count); uniforms.diskLogRadiusMin = disk.logRadiusMin; uniforms.diskLogRadiusStep = disk.logRadiusStep
        uniforms.temperatureTableCount = UInt32(spectrum.values.count); uniforms.temperatureLogMin = spectrum.logTemperatureMin; uniforms.temperatureLogStep = spectrum.logTemperatureStep
        uniforms.massTimeSeconds = Float(model.gravitationalTimeSeconds)
        uniforms.flowLogRadiusMin = log(disk.innerRadius); uniforms.flowLogRadiusSpan = log(disk.outerRadius / disk.innerRadius)
        uniforms.materialStrength = settings.materialStrength; uniforms.paletteTemperature = settings.paletteTemperature
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
        let radiance = device.makeTexture(descriptor: descriptor)!, direct = device.makeTexture(descriptor: descriptor)!
        descriptor.textureType = .type2DArray; descriptor.arrayLength = samples
        let mapping = device.makeTexture(descriptor: descriptor)!
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw GPUVerification.failure("Missing production kernel \(name)") }
            return try device.makeComputePipelineState(function: function)
        }
        let traceGeometry = try pipeline("traceGeometry"), shadeGeometry = try pipeline("shadeGeometry"), traceDirect = try pipeline("traceKerr")
        let edgeDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint, width: 1, height: 1, mipmapped: false)
        edgeDescriptor.storageMode = .shared; edgeDescriptor.usage = .shaderRead
        let emptyEdges = device.makeTexture(descriptor: edgeDescriptor)!
        var noEdge: UInt32 = UInt32.max
        emptyEdges.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &noEdge, bytesPerRow: 4)
        let emptyEdgeHits = device.makeBuffer(length: 16, options: .storageModeShared)!
        uniforms.edgeSamples = 0; uniforms.edgeCapacity = 0
        let traceCommand = queue.makeCommandBuffer()!, trace = traceCommand.makeComputeCommandEncoder()!
        trace.setComputePipelineState(traceGeometry); trace.setTexture(mapping, index: 0)
        trace.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        trace.dispatchThreads(.init(width: width, height: height, depth: samples), threadsPerThreadgroup: .init(width: traceGeometry.threadExecutionWidth, height: 4, depth: 1))
        trace.endEncoding()
        let geometryMS = try finish(traceCommand)
        func shade(_ command: MTLCommandBuffer, _ input: Uniforms) {
            var input = input
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(shadeGeometry); encoder.setTexture(mapping, index: 0); encoder.setTexture(flowTexture, index: 1); encoder.setTexture(radiance, index: 2)
            encoder.setTexture(emptyEdges, index: 3); encoder.setBuffer(emptyEdgeHits, offset: 0, index: 3)
            encoder.setBytes(&input, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setBuffer(diskBuffer, offset: 0, index: 1); encoder.setBuffer(spectrumBuffer, offset: 0, index: 2)
            encoder.dispatchThreads(.init(width: width, height: height, depth: 1), threadsPerThreadgroup: .init(width: shadeGeometry.threadExecutionWidth, height: 4, depth: 1))
            encoder.endEncoding()
        }
        uniforms.appearanceMode = 0; uniforms.flowEnabled = 0
        let physicalCommand = queue.makeCommandBuffer()!
        shade(physicalCommand, uniforms)
        var physicalSettings = settings; physicalSettings.appearance = .scientific
        let physicalDisplay = camera.encode(command: physicalCommand, source: radiance, settings: physicalSettings)
        _ = try finish(physicalCommand)
        let physicalHDR = try read(radiance, device: device, queue: queue)
        let physicalPixels = try read(physicalDisplay, device: device, queue: queue)
        try savePNG(physicalPixels, width: width, height: height, path: "\(outputDirectory)/scientific-comparison.png")
        let directCommand = queue.makeCommandBuffer()!, encoder = directCommand.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(traceDirect); encoder.setTexture(direct, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setBuffer(diskBuffer, offset: 0, index: 1); encoder.setBuffer(spectrumBuffer, offset: 0, index: 2)
        encoder.dispatchThreads(.init(width: width, height: height, depth: 1), threadsPerThreadgroup: .init(width: traceDirect.threadExecutionWidth, height: 4, depth: 1))
        encoder.endEncoding(); let directMS = try finish(directCommand)
        let directHDR = try read(direct, device: device, queue: queue)
        var cacheDifference: Float = 0
        for i in physicalHDR.indices {
            for channel in 0..<4 { cacheDifference = max(cacheDifference, abs(physicalHDR[i][channel] - directHDR[i][channel]) / max(1, abs(directHDR[i][channel]))) }
        }
        report.check(cacheDifference < 2e-6, "Cached geometry matches direct physical ray tracing", details: "maximum relative/absolute mixed error=\(cacheDifference)")
        report.check(physicalHDR.allSatisfy { $0.w >= 0 }, "Reference camera has no unresolved geodesic samples")

        // Palette-only chromaticity must not erase the relativistic brightness
        // pattern. Material attenuation and camera compression are disabled.
        uniforms.appearanceMode = 1; uniforms.materialStrength = 0
        let paletteCommand = queue.makeCommandBuffer()!; shade(paletteCommand, uniforms); _ = try finish(paletteCommand)
        let paletteHDR = try read(radiance, device: device, queue: queue)
        func exactY(_ value: SIMD4<Float>) -> Float { 0.2126729 * value.x + 0.7151522 * value.y + 0.0721750 * value.z }
        var brightnessError: Float = 0, lostLuminance: Float = 0
        for i in physicalHDR.indices {
            let difference = abs(exactY(paletteHDR[i]) - exactY(physicalHDR[i]))
            brightnessError = max(brightnessError, difference / max(1e-5, exactY(physicalHDR[i])))
            lostLuminance = max(lostLuminance, difference)
        }
        report.check(brightnessError < 2e-5, "Artistic palette preserves physical received luminance and Doppler asymmetry", details: "maximum relative luminance error=\(brightnessError), maximum absolute difference=\(lostLuminance)")

        uniforms.materialStrength = settings.materialStrength; uniforms.flowEnabled = 1
        // Exercise the production shader's adaptive shutter levels without
        // changing the transfer map, source, fluid snapshot, or exposure width.
        func shutterFrame(samples: UInt32, seconds: Float, appearance: UInt32 = 1) throws -> [SIMD4<Float>] {
            var input = uniforms
            input.materialTimeSamples = samples; input.materialShutterSeconds = seconds
            input.appearanceMode = appearance
            let command = queue.makeCommandBuffer()!
            shade(command, input); _ = try finish(command)
            return try read(radiance, device: device, queue: queue)
        }
        let shutterSeconds = Float(0.5 * settings.diskPlayback.rawValue / 60)
        for sampleCount: UInt32 in [4, 8, 16] {
            let pixels = try shutterFrame(samples: sampleCount, seconds: shutterSeconds)
            report.check(pixels.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite } && pixels.contains { luminance($0) > 1e-5 },
                         "\(sampleCount)-sample physical shutter integration is finite and visibly emitting")
            let bounded = pixels.indices.allSatisfy { index in
                let physicalY = exactY(physicalHDR[index])
                return physicalY <= 1e-5 || exactY(pixels[index]) <= physicalY * 1.00002 + 1e-5
            }
            report.check(bounded, "\(sampleCount)-sample shutter preserves the physical disk-luminance bound")
        }
        let instantaneous4 = try shutterFrame(samples: 4, seconds: 0)
        let instantaneous16 = try shutterFrame(samples: 16, seconds: 0)
        report.check(bitwiseEqual(instantaneous4, instantaneous16), "Zero-width shutter bypasses extra samples bit-for-bit")
        let scientific16 = try shutterFrame(samples: 16, seconds: shutterSeconds, appearance: 0)
        report.check(bitwiseEqual(scientific16, physicalHDR), "Scientific transport bypasses photographic shutter controls bit-for-bit")

        uniforms.materialTimeSamples = 4; uniforms.materialShutterSeconds = shutterSeconds
        var updateTimes = [Double](), radiantPixels = [SIMD4<Float>]()
        for frame in 0..<13 {
            let command = queue.makeCommandBuffer()!
            flowTexture = flow.encode(command: command, deltaTime: 1 / 60, spin: settings.blackHoleSpin, innerRadius: disk.innerRadius, outerRadius: disk.outerRadius, speed: settings.flowSpeed, quality: 1)
            shade(command, uniforms)
            let display = camera.encode(command: command, source: radiance, settings: settings)
            let elapsed = try finish(command)
            if frame > 0 { updateTimes.append(elapsed) }
            if frame == 12 { radiantPixels = try read(display, device: device, queue: queue) }
        }
        try savePNG(radiantPixels, width: width, height: height, path: "\(outputDirectory)/radiant-render.png")
        report.check(finiteDisplay(physicalPixels) && finiteDisplay(radiantPixels), "Full-scene scientific and radiant frames have finite display values")
        let radiantHDR = try read(radiance, device: device, queue: queue)
        // Material remains attenuating at pixels with a physical disk hit.
        // Radiant may additionally show the deliberately faint celestial
        // field only where an integrated ray escaped the disk/black hole, so
        // those zero-disk pixels are excluded rather than being misreported
        // as an emissivity violation.
        var diskEnergyBound = true, celestialVoidPixels = 0
        var celestialVoidPeak: Float = 0
        for index in radiantHDR.indices {
            let physicalY = exactY(physicalHDR[index]), radiantY = exactY(radiantHDR[index])
            if physicalY > 1e-5 {
                diskEnergyBound = diskEnergyBound && radiantY <= physicalY * 1.00002 + 1e-5
            } else if radiantY > 1e-5 {
                celestialVoidPixels += 1
                celestialVoidPeak = max(celestialVoidPeak, radiantY)
            }
        }
        report.check(diskEnergyBound, "Material structure does not exceed unmodulated physical luminance at disk-hit pixels")
        report.check(celestialVoidPixels > 0, "Radiant escaped rays reveal the faint lensed celestial field", details: "\(celestialVoidPixels) void pixels; peak luminance=\(celestialVoidPeak)")
        let warmPixels = radiantPixels.filter { $0.x > 0.03 && $0.x > $0.z * 1.1 }.count
        report.check(warmPixels > width * height / 100, "Radiant image contains resolved warm emission", details: "\(warmPixels) visibly warm pixels")
        let sortedUpdates = updateTimes.sorted(), sortedFlow = flowTimes.sorted()
        let metrics: [String: Any] = ["device": device.name, "resolution": [width, height], "geometrySamplesPerPixel": samples, "geometryBuildGPUms": geometryMS, "directPhysicalTraceGPUms": directMS, "stationaryFluidMaterialCameraGPUms": sortedUpdates[sortedUpdates.count / 2], "fluidOnlyGPUms": sortedFlow[sortedFlow.count / 2], "celestialVoidPixels": celestialVoidPixels, "celestialVoidPeak": celestialVoidPeak, "uniformStride": MemoryLayout<Uniforms>.stride, "checks": report.checks, "scientificImage": "scientific-comparison.png", "radiantImage": "radiant-render.png"]
        try GPUVerification.write(metrics, to: "\(outputDirectory)/appearance-validation.json")
        let failures = report.checks.filter { !($0["passed"] as! Bool) }.count
        print("\(report.checks.count - failures)/\(report.checks.count) appearance checks passed. Geometry \(geometryMS) ms; stationary update \(sortedUpdates[sortedUpdates.count / 2]) ms")
        if failures > 0 { throw GPUVerification.failure("\(failures) appearance checks failed; see appearance-validation.json") }
    }
}
