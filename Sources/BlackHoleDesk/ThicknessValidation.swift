import Foundation
import Metal

/// Production-GPU intersection diagnostics and matched thin/thick captures.
/// The independent BL-coordinate event integrator lives in validate_thickness.py.
enum ThicknessValidation {
    static func run(outputDirectory: String) throws {
        try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        let (device, queue, library) = try GPUVerification.context()
        guard let function = library.makeFunction(name: "validateSurface") else { throw GPUVerification.failure("Missing finite-surface diagnostic kernel") }
        let pipeline = try device.makeComputePipelineState(function: function)
        var settings = RenderSettings()
        let model = DiskModel(spin: Double(settings.blackHoleSpin), massSolar: settings.massSolar, accretionSolarMassesPerYear: settings.accretionSolarMassesPerYear, outerRadius: settings.diskOuterRadius)
        let heightScale = DiskGeometry.heightScale(for: model, multiplier: settings.thicknessMultiplier)
        var report = AppearanceValidation.Report(), cases = [[String: Any]]()
        let groups: [(String, Float, Float, Float, Float, Float, Int, Int)] = [
            ("thin", 0.82, 80, 0.06, 0, 0, 12, 9),
            ("upper", 0.82, 80, 0.06, heightScale, 0, 20, 15),
            ("lower", 0.82, 80, -0.06, heightScale, 0, 20, 15),
            ("corrugated", 0.82, 80, 0.13, heightScale, 0.08, 16, 12),
            ("schwarzschild", 0, 50, 0.12, 2, 0.08, 12, 9),
            ("close-extremal", 0.998, 12, 0.6, 0.5, 0.08, 12, 9),
            ("grazing", 0.82, 80, 0.06, heightScale, 0.08, 1, 1),
            ("grazing-fine", 0.82, 80, 0.06, heightScale, 0.08, 1, 1),
            ("inside-opaque", 0.82, 12, 0.005, heightScale, 0, 2, 2)
        ]
        var upperHits = 0, lowerHits = 0, taperedHits = 0, badStatus = 0
        var unsupportedInside = 0
        var largestResidual: Float = 0, largestNormError: Float = 0
        for (name, spin, distance, pitch, height, corrugation, columns, rows) in groups {
            var uniforms = Uniforms()
            uniforms.resolution = .init(1440, 960); uniforms.spin = spin
            uniforms.observerRadius = distance; uniforms.cameraPitch = pitch; uniforms.cameraYaw = -0.28
            uniforms.verticalFOV = distance < 20 ? 1.1 : 0.48
            uniforms.diskInnerRadius = Float(DiskPhysics.isco(spin: Double(spin))); uniforms.diskOuterRadius = 30
            uniforms.integrationTolerance = 3e-7; uniforms.maxStep = 0.012; uniforms.steps = 8192
            if name == "grazing-fine" { uniforms.maxStep = 0.003 }
            uniforms.diskHeightScale = height; uniforms.diskCorrugation = corrugation
            var pixels = [SIMD4<Float>]()
            for y in 0..<rows { for x in 0..<columns {
                pixels.append(.init((Float(x) + 0.5) * 1440 / Float(columns) + 0.173, (Float(y) + 0.5) * 960 / Float(rows) + 0.291, 0, 0))
            } }
            // Tight scans across the equatorial silhouette and outer rim,
            // including non-grid-aligned samples rather than only interiors.
            if name == "upper" || name == "lower" {
                for y: Float in [441.37, 459.73, 479.83, 500.19, 519.61] {
                    for x in 0..<32 { pixels.append(.init(12.41 + Float(x) * 45.5, y, 0, 0)) }
                }
            }
            if name.hasPrefix("grazing") {
                pixels.removeAll()
                for y: Float in [194.37, 211.73, 358.83, 479.91, 524.19, 547.61, 571.23, 741.37] {
                    for x in 0..<40 { pixels.append(.init(6.41 + Float(x) * 36.5, y, 0, 0)) }
                }
            }
            var count = UInt32(pixels.count)
            let input = device.makeBuffer(bytes: pixels, length: pixels.count * 16, options: .storageModeShared)!
            let output = device.makeBuffer(length: pixels.count * 24 * 4, options: .storageModeShared)!
            let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline); encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setBuffer(input, offset: 0, index: 1); encoder.setBuffer(output, offset: 0, index: 2); encoder.setBytes(&count, length: 4, index: 3)
            encoder.dispatchThreads(.init(width: pixels.count, height: 1, depth: 1), threadsPerThreadgroup: .init(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
            encoder.endEncoding(); _ = try AppearanceValidation.finish(command)
            let values = output.contents().bindMemory(to: Float.self, capacity: pixels.count * 24)
            for index in pixels.indices {
                let result = (0..<24).map { values[index * 24 + $0] }
                let status = Int(result[4].rounded())
                if name == "inside-opaque", status == 5 { unsupportedInside += 1 }
                else if status >= 4 { badStatus += 1 }
                if !result.allSatisfy({ $0.isFinite }) { badStatus += 1 }
                if status == 1 && height > 0 {
                    largestResidual = max(largestResidual, abs(result[20]))
                    largestNormError = max(largestNormError, abs(result[21] - 1))
                    if result[16] > 0.8 * uniforms.diskOuterRadius { taperedHits += 1 }
                    if result[17] >= 0 { upperHits += 1 } else { lowerHits += 1 }
                }
                cases.append(["id": "\(name)-\(index)", "group": name, "spin": Double(spin), "cameraDistance": Double(distance), "cameraPitch": Double(pitch), "cameraYaw": Double(uniforms.cameraYaw), "fov": Double(uniforms.verticalFOV), "resolution": [1440, 960], "pixel": [Double(pixels[index].x), Double(pixels[index].y)], "diskInner": Double(uniforms.diskInnerRadius), "diskOuter": 30, "heightScale": Double(height), "corrugation": Double(corrugation), "tolerance": Double(uniforms.integrationTolerance), "maxStep": Double(uniforms.maxStep), "result": result.map(Double.init)])
            }
        }
        report.check(badStatus == 0, "Finite-surface probe rays complete with finite diagnostics", details: "\(cases.count) rays; unresolved/nonfinite=\(badStatus)")
        report.check(unsupportedInside == 4, "Observer inside opaque material is explicitly unsupported, not misclassified as vacuum", details: "\(unsupportedInside)/4 rays report diagnostic status 5")
        report.check(upperHits > 0 && lowerHits > 0 && taperedHits > 0, "Opaque intersections cover upper, lower, and tapered outer surfaces", details: "upper \(upperHits), lower \(lowerHits), outer-taper \(taperedHits)")
        let grazing = cases.filter { ($0["group"] as? String) == "grazing" }
        let grazingFine = cases.filter { ($0["group"] as? String) == "grazing-fine" }
        var grazingStatusMismatch = 0, grazingPositionDifference = 0.0
        for (coarse, fine) in zip(grazing, grazingFine) {
            let a = coarse["result"] as! [Double], b = fine["result"] as! [Double]
            if a[4] != b[4] { grazingStatusMismatch += 1 }
            if a[4] == 1 && b[4] == 1 { grazingPositionDifference = max(grazingPositionDifference, abs(a[5] - b[5]) / max(1, abs(b[5]))) }
        }
        report.check(grazingStatusMismatch == 0 && grazingPositionDifference < 0.0001, "Targeted silhouette rays remain stable when the maximum integration step is quartered", details: "\(grazing.count) pairs; classification differences \(grazingStatusMismatch); maximum relative radius difference \(grazingPositionDifference)")
        report.check(largestResidual < 0.002, "GPU first-hit coordinates lie on the finite photosphere", details: "maximum signed-volume residual=\(largestResidual) M")
        report.check(largestNormError < 2e-5, "GPU off-plane circular emitter four-velocity is timelike and normalized", details: "maximum |−u.u−1|=\(largestNormError)")
        let scale0 = DiskGeometry.heightScale(for: model, multiplier: 0)
        let scaleHalf = DiskGeometry.heightScale(for: model, multiplier: 0.5)
        let scale2 = DiskGeometry.heightScale(for: model, multiplier: 2)
        report.check(scale0 == 0 && scaleHalf >= 0 && scaleHalf <= heightScale && heightScale <= scale2, "Photosphere height scale is nonnegative and monotonic in thickness control")
        var allHeightsValid = true
        let inner = DiskPhysics.isco(spin: model.spin)
        for radialIndex in 0...100 {
            let radius = inner * exp(Double(radialIndex) / 100 * log(30 / inner))
            for azimuthIndex in 0..<32 {
                let value = DiskGeometry.height(radius: radius, azimuth: Double(azimuthIndex) * 2 * .pi / 32, innerRadius: inner, outerRadius: 30, heightScale: Double(heightScale), corrugation: 0.08)
                allHeightsValid = allHeightsValid && value.isFinite && value >= 0
            }
        }
        report.check(allHeightsValid, "Photosphere surface stays finite and nonnegative across radius and azimuth")
        let cappedScale = DiskGeometry.heightScale(for: model, multiplier: 1000)
        var largestAspect = 0.0
        for azimuthIndex in 0..<256 {
            let rho = 2.25 * inner
            let h = DiskGeometry.height(radius: rho, azimuth: Double(azimuthIndex) * 2 * .pi / 256, innerRadius: inner, outerRadius: 30, heightScale: Double(cappedScale), corrugation: 0.08)
            largestAspect = max(largestAspect, h / rho)
        }
        report.check(largestAspect <= 0.200001 && cappedScale >= heightScale, "Geometric guardrail bounds the maximum supported aspect ratio", details: "sampled maximum half-height/rho=\(largestAspect)")
        let renderMetrics = try renderComparison(device: device, queue: queue, library: library, settings: &settings, model: model, heightScale: heightScale, outputDirectory: outputDirectory, report: &report)
        try validateEdgeCoverage(device: device, queue: queue, library: library, heightScale: heightScale, report: &report)
        try GPUVerification.write(["device": device.name, "uniformStride": MemoryLayout<Uniforms>.stride, "heightScale": heightScale, "checks": report.checks, "cases": cases, "renders": renderMetrics], to: "\(outputDirectory)/thickness-gpu-validation.json")
        let failures = report.checks.filter { !($0["passed"] as! Bool) }.count
        print("\(report.checks.count - failures)/\(report.checks.count) finite-photosphere GPU checks passed; independent binary64 comparison is separate")
        if failures > 0 { throw GPUVerification.failure("Finite photosphere GPU checks failed") }
    }

    static func renderComparison(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary, settings: inout RenderSettings, model: DiskModel, heightScale: Float, outputDirectory: String, report: inout AppearanceValidation.Report) throws -> [[String: Any]] {
        let disk = DiskPhysics.radialTable(for: model), spectrum = DiskPhysics.spectralTable(count: 4096)
        let diskBuffer = device.makeBuffer(bytes: disk.values, length: disk.values.count * 16, options: .storageModeShared)!
        let spectralBuffer = device.makeBuffer(bytes: spectrum.values, length: spectrum.values.count * 16, options: .storageModeShared)!
        let trace = try device.makeComputePipelineState(function: library.makeFunction(name: "traceGeometry")!)
        let shade = try device.makeComputePipelineState(function: library.makeFunction(name: "shadeGeometry")!)
        let flow = try DiskFlow(device: device, library: library), camera = try CameraResponse(device: device, library: library)
        let refinement = try GeometryRefinement(device: device, library: library)
        var flowTexture: MTLTexture!
        for _ in 0..<60 {
            let command = queue.makeCommandBuffer()!
            flowTexture = flow.encode(command: command, deltaTime: 1 / 60, spin: Float(model.spin), innerRadius: disk.innerRadius, outerRadius: disk.outerRadius, speed: 1, quality: 1)
            _ = try AppearanceValidation.finish(command)
        }
        let width = 1440, height = 960, samples = 4
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .shaderWrite]
        let radiance = device.makeTexture(descriptor: descriptor)!
        descriptor.textureType = .type2DArray; descriptor.arrayLength = samples
        let mapping = device.makeTexture(descriptor: descriptor)!
        let edgeDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint, width: 1, height: 1, mipmapped: false)
        edgeDescriptor.storageMode = .shared; edgeDescriptor.usage = .shaderRead
        let noEdges = device.makeTexture(descriptor: edgeDescriptor)!, emptyHits = device.makeBuffer(length: 16, options: .storageModeShared)!
        var sentinel: UInt32 = .max
        noEdges.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &sentinel, bytesPerRow: 4)
        var uniforms = Uniforms()
        uniforms.resolution = .init(UInt32(width), UInt32(height)); uniforms.samples = UInt32(samples); uniforms.steps = 8192
        uniforms.integrationTolerance = 3e-7; uniforms.maxStep = 0.012
        let pose = CameraState()
        uniforms.cameraYaw = pose.yaw; uniforms.cameraPitch = pose.pitch; uniforms.observerRadius = pose.radius; uniforms.verticalFOV = pose.fov
        uniforms.diskInnerRadius = disk.innerRadius; uniforms.diskOuterRadius = disk.outerRadius; uniforms.spin = Float(model.spin)
        uniforms.diskTableCount = UInt32(disk.values.count); uniforms.diskLogRadiusMin = disk.logRadiusMin; uniforms.diskLogRadiusStep = disk.logRadiusStep
        uniforms.temperatureTableCount = UInt32(spectrum.values.count); uniforms.temperatureLogMin = spectrum.logTemperatureMin; uniforms.temperatureLogStep = spectrum.logTemperatureStep
        uniforms.massTimeSeconds = Float(model.gravitationalTimeSeconds)
        uniforms.flowLogRadiusMin = log(disk.innerRadius); uniforms.flowLogRadiusSpan = log(disk.outerRadius / disk.innerRadius)
        uniforms.appearanceMode = 1; uniforms.materialStrength = settings.materialStrength; uniforms.paletteTemperature = settings.paletteTemperature; uniforms.flowEnabled = 1
        uniforms.edgeSamples = 0; uniforms.edgeCapacity = 0
        var results = [[String: Any]](), priorPixels = [SIMD4<Float>](), finiteHDR = [SIMD4<Float>]()
        for (name, extent) in [("thin", Float(0)), ("finite", heightScale), ("finite-aa", heightScale), ("finite-aa-overflow", heightScale)] {
            uniforms.diskHeightScale = extent; uniforms.diskCorrugation = 0
            let antialias = name.hasPrefix("finite-aa"), overflow = name == "finite-aa-overflow"
            uniforms.edgeSamples = antialias ? 16 : 0
            uniforms.edgeCapacity = overflow ? 1 : antialias ? UInt32(width * height * 3 / 100) : 0
            refinement.prepare(width: width, height: height, samples: Int(uniforms.edgeSamples), capacity: Int(uniforms.edgeCapacity))
            let command = queue.makeCommandBuffer()!, geometry = command.makeComputeCommandEncoder()!
            geometry.setComputePipelineState(trace); geometry.setTexture(mapping, index: 0); geometry.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            geometry.dispatchThreads(.init(width: width, height: height, depth: samples), threadsPerThreadgroup: .init(width: trace.threadExecutionWidth, height: 4, depth: 1)); geometry.endEncoding()
            let edgeCounter = refinement.encode(command: command, mapping: mapping, uniforms: uniforms)
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(shade); encoder.setTexture(mapping, index: 0); encoder.setTexture(flowTexture, index: 1); encoder.setTexture(radiance, index: 2); encoder.setTexture(antialias ? refinement.lookup : noEdges, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0); encoder.setBuffer(diskBuffer, offset: 0, index: 1); encoder.setBuffer(spectralBuffer, offset: 0, index: 2); encoder.setBuffer(antialias ? refinement.hits : emptyHits, offset: 0, index: 3)
            encoder.dispatchThreads(.init(width: width, height: height, depth: 1), threadsPerThreadgroup: .init(width: shade.threadExecutionWidth, height: 4, depth: 1)); encoder.endEncoding()
            let display = camera.encode(command: command, source: radiance, settings: settings)
            let milliseconds = try AppearanceValidation.finish(command)
            let pixels = try AppearanceValidation.read(display, device: device, queue: queue)
            let linear = try AppearanceValidation.read(radiance, device: device, queue: queue)
            let unresolved = linear.filter { $0.w < 0 }.count
            if unresolved > 0 {
                let coordinates = linear.indices.filter { linear[$0].w < 0 }.prefix(16).map { "(\($0 % width),\($0 / width))" }
                print("Unresolved \(name) capture pixels: \(coordinates.joined(separator: ", "))")
            }
            report.check(AppearanceValidation.finiteDisplay(pixels) && unresolved == 0, "\(name.capitalized) 1440×960 capture has finite color and resolved rays", details: "unresolved pixels=\(unresolved)")
            try AppearanceValidation.savePNG(pixels, width: width, height: height, path: "\(outputDirectory)/photosphere-\(name).png")
            let edgePixels = edgeCounter.map { Int($0.contents().load(as: UInt32.self)) } ?? 0
            results.append(["name": name, "heightScale": extent, "width": width, "height": height, "samples": samples, "edgeSamples": uniforms.edgeSamples, "edgePixels": edgePixels, "gpuMilliseconds": milliseconds, "unresolvedPixels": unresolved])
            if name == "finite" {
                finiteHDR = linear
                var changed = 0
                for index in pixels.indices {
                    let difference = pixels[index] - priorPixels[index]
                    let magnitude = abs(difference.x) + abs(difference.y) + abs(difference.z)
                    if magnitude > 0.01 { changed += 1 }
                }
                report.check(changed > width * height / 100, "Finite geometry changes the rendered silhouette and self-occlusion", details: "\(changed) changed display pixels")
            }
            if antialias && !overflow {
                report.check(edgePixels > 0 && edgePixels <= Int(uniforms.edgeCapacity), "Edge-specific geodesic supersampling finds boundaries without exhausting sparse capacity", details: "\(edgePixels) marked edge pixels; capacity \(uniforms.edgeCapacity); 16 extra samples per edge")
                var changed = 0
                for index in pixels.indices {
                    let difference = pixels[index] - priorPixels[index]
                    let magnitude = abs(difference.x) + abs(difference.y) + abs(difference.z)
                    if magnitude > 0.001 { changed += 1 }
                }
                report.check(changed > 0, "Edge supersampling contributes to the final captured image", details: "\(changed) changed display pixels")
            }
            if overflow {
                var changed = 0
                for index in linear.indices {
                    let difference = linear[index] - finiteHDR[index]
                    if abs(difference.x) + abs(difference.y) + abs(difference.z) > 1e-7 { changed += 1 }
                }
                report.check(edgePixels > 1 && changed <= 1, "Sparse edge-capacity overflow safely retains original samples outside the allocated slot", details: "\(edgePixels) edges requested; capacity=1; \(changed) HDR pixels changed")
            }
            priorPixels = pixels
        }
        // Restore the normal sparse map after the deliberately undersized
        // overflow test; subsequent timings contain no geodesic reconstruction.
        uniforms.edgeSamples = 16; uniforms.edgeCapacity = UInt32(width * height * 3 / 100)
        refinement.prepare(width: width, height: height, samples: 16, capacity: Int(uniforms.edgeCapacity))
        let rebuild = queue.makeCommandBuffer()!
        _ = refinement.encode(command: rebuild, mapping: mapping, uniforms: uniforms)
        _ = try AppearanceValidation.finish(rebuild)
        var cachedTimes = [Double]()
        for frame in 0..<13 {
            let command = queue.makeCommandBuffer()!
            flowTexture = flow.encode(command: command, deltaTime: 1 / 60, spin: Float(model.spin), innerRadius: disk.innerRadius, outerRadius: disk.outerRadius, speed: 1, quality: 1)
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(shade)
            encoder.setTexture(mapping, index: 0); encoder.setTexture(flowTexture, index: 1); encoder.setTexture(radiance, index: 2); encoder.setTexture(refinement.lookup, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setBuffer(diskBuffer, offset: 0, index: 1); encoder.setBuffer(spectralBuffer, offset: 0, index: 2); encoder.setBuffer(refinement.hits, offset: 0, index: 3)
            encoder.dispatchThreads(.init(width: width, height: height, depth: 1), threadsPerThreadgroup: .init(width: shade.threadExecutionWidth, height: 4, depth: 1)); encoder.endEncoding()
            _ = camera.encode(command: command, source: radiance, settings: settings)
            let elapsed = try AppearanceValidation.finish(command)
            if frame > 0 { cachedTimes.append(elapsed) }
        }
        let median = cachedTimes.sorted()[cachedTimes.count / 2]
        results.append(["name": "cached-finite-aa-animation", "width": width, "height": height, "samples": samples, "edgeSamples": 16, "medianGPUms": median, "description": "Actual fluid evolution, cached finite-surface shading and camera response; excludes transfer-map construction and presentation"])
        print("Cached finite photosphere + 16-sample edges + evolving fluid + camera: \(median) ms median")
        return results
    }

    static func validateEdgeCoverage(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary, heightScale: Float, report: inout AppearanceValidation.Report) throws {
        let diagnosticSource = #"""
        kernel void denseCoverage(texture2d<float,access::write> output [[texture(0)]],
                                  constant Uniforms& u [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
            if(any(p>=u.resolution)) return;
            float count=0.; bool failed=false;
            for(uint y=0;y<8;y++) for(uint x=0;x<8;x++) {
                RayResult ray=followRay(float2(p)+(float2(x,y)+.5)/8.,u,true);
                count+=ray.status==1 ? 1. : 0.; failed|=ray.status>=4;
            }
            output.write(float4(count/64.,0.,0.,failed ? -1. : 1.),p);
        }
        kernel void cachedCoverage(texture2d_array<float,access::read> mapping [[texture(0)]],
                                   texture2d<uint,access::read> lookup [[texture(1)]],
                                   texture2d<float,access::write> output [[texture(2)]],
                                   constant Uniforms& u [[buffer(0)]],device const float4* hits [[buffer(1)]],
                                   uint2 p [[thread_position_in_grid]]) {
            if(any(p>=u.resolution)) return;
            uint slot=u.edgeSamples>0 ? lookup.read(p).x : 0;
            uint count=slot>0 ? u.edgeSamples : u.samples; float covered=0.; bool failed=false;
            for(uint j=0;j<count;j++) {
                float4 hit=slot>0 ? hits[(slot-1)*u.edgeSamples+j] : mapping.read(p,j);
                covered+=hit.x>0. ? 1. : 0.; failed|=hit.x<=-4.;
            }
            output.write(float4(covered/float(count),0.,0.,failed ? -1. : 1.),p);
        }
        """#
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let testLibrary = try device.makeLibrary(source: ShaderSource.code + diagnosticSource, options: options)
        let dense = try device.makeComputePipelineState(function: testLibrary.makeFunction(name: "denseCoverage")!)
        let summarize = try device.makeComputePipelineState(function: testLibrary.makeFunction(name: "cachedCoverage")!)
        let trace = try device.makeComputePipelineState(function: library.makeFunction(name: "traceGeometry")!)
        let refinement = try GeometryRefinement(device: device, library: library)
        let width = 192, height = 128
        var u = Uniforms(); let camera = CameraState()
        u.resolution = .init(UInt32(width), UInt32(height)); u.samples = 4; u.steps = 8192; u.integrationTolerance = 3e-7; u.maxStep = 0.012
        u.observerRadius = camera.radius; u.cameraYaw = camera.yaw; u.cameraPitch = camera.pitch; u.verticalFOV = camera.fov
        u.diskInnerRadius = Float(DiskPhysics.isco(spin: Double(u.spin))); u.diskOuterRadius = 30; u.diskHeightScale = heightScale
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        d.storageMode = .private; d.usage = [.shaderRead, .shaderWrite]
        let reference = device.makeTexture(descriptor: d)!, baseline = device.makeTexture(descriptor: d)!, refined = device.makeTexture(descriptor: d)!
        d.textureType = .type2DArray; d.arrayLength = Int(u.samples)
        let mapping = device.makeTexture(descriptor: d)!
        func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, depth: Int = 1) {
            encoder.dispatchThreads(.init(width: width, height: height, depth: depth), threadsPerThreadgroup: .init(width: pipeline.threadExecutionWidth, height: 4, depth: 1))
        }
        let command = queue.makeCommandBuffer()!, geometry = command.makeComputeCommandEncoder()!
        geometry.setComputePipelineState(trace); geometry.setTexture(mapping, index: 0); geometry.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        dispatch(geometry, trace, depth: 4); geometry.endEncoding()
        func summarizeCoverage(_ texture: MTLTexture) {
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(summarize); encoder.setTexture(mapping, index: 0); encoder.setTexture(refinement.lookup, index: 1); encoder.setTexture(texture, index: 2)
            encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0); encoder.setBuffer(refinement.hits, offset: 0, index: 1)
            dispatch(encoder, summarize); encoder.endEncoding()
        }
        summarizeCoverage(baseline)
        u.edgeSamples = 16; u.edgeCapacity = UInt32(width * height)
        refinement.prepare(width: width, height: height, samples: 16, capacity: width * height)
        _ = refinement.encode(command: command, mapping: mapping, uniforms: u)
        summarizeCoverage(refined)
        let referenceEncoder = command.makeComputeCommandEncoder()!
        referenceEncoder.setComputePipelineState(dense); referenceEncoder.setTexture(reference, index: 0); referenceEncoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        dispatch(referenceEncoder, dense); referenceEncoder.endEncoding(); _ = try AppearanceValidation.finish(command)
        let target = try AppearanceValidation.read(reference, device: device, queue: queue)
        let low = try AppearanceValidation.read(baseline, device: device, queue: queue)
        let high = try AppearanceValidation.read(refined, device: device, queue: queue)
        var lowError = 0.0, highError = 0.0, edgeCount = 0, unresolved = 0
        for i in target.indices {
            if target[i].w < 0 || low[i].w < 0 || high[i].w < 0 { unresolved += 1 }
            if target[i].x > 0 && target[i].x < 1 {
                lowError += pow(Double(low[i].x - target[i].x), 2)
                highError += pow(Double(high[i].x - target[i].x), 2)
                edgeCount += 1
            }
        }
        let baselineRMSE = sqrt(lowError / Double(max(1, edgeCount))), refinedRMSE = sqrt(highError / Double(max(1, edgeCount)))
        report.check(unresolved == 0 && edgeCount > 0 && refinedRMSE < baselineRMSE * 0.85, "Production edge sampling reduces silhouette coverage error against a denser 64-ray reference", details: "\(edgeCount) partially covered pixels at192×128; 4-ray RMSE \(baselineRMSE), sparse16-ray RMSE \(refinedRMSE); unresolved \(unresolved)")
    }
}
