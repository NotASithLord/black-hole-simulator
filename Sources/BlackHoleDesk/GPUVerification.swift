import AppKit
import Metal

enum GPUVerification {
    static func context() throws -> (MTLDevice,MTLCommandQueue,MTLLibrary) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw failure("Metal unavailable") }
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        return (device,queue,try device.makeLibrary(source:ShaderSource.code + "\n" + CameraResponse.metalSource,options:options))
    }
    static func failure(_ message:String)->NSError { NSError(domain:"PhysicsValidation",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    static func validate(input:String,output:String) throws {
        let (device,queue,library) = try context()
        try validateAccumulation(device:device,queue:queue,library:library)
        let pipeline = try device.makeComputePipelineState(function:library.makeFunction(name:"validateKerr")!)
        let data = try Data(contentsOf:URL(fileURLWithPath:input))
        let document = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let cases = document["cases"] as! [[String:Any]]
        var results = [[String:Any]]()
        for item in cases {
            func number(_ key:String,_ fallback:Double)->Float { Float((item[key] as? NSNumber)?.doubleValue ?? fallback) }
            var uniforms = Uniforms()
            let size = item["resolution"] as! [Int]; let pixel = item["pixel"] as! [Double]
            uniforms.resolution = .init(UInt32(size[0]),UInt32(size[1]))
            uniforms.spin = number("spin",0); uniforms.observerRadius = number("cameraDistance",36)
            uniforms.cameraPitch = number("cameraPitch",0.28); uniforms.cameraYaw = number("cameraYaw",0.17)
            uniforms.verticalFOV = number("fov",Double.pi/4)
            uniforms.lookYaw = number("lookYaw",0); uniforms.lookPitch = number("lookPitch",0)
            uniforms.diskInnerRadius = Float(DiskPhysics.isco(spin:Double(uniforms.spin)))
            uniforms.diskOuterRadius = number("diskOuter",30)
            uniforms.integrationTolerance = number("tolerance",2e-6); uniforms.steps = UInt32(number("steps",4096))
            uniforms.maxStep = number("maxStep",0.02)
            var ray = SIMD4<Float>(Float(pixel[0]),Float(pixel[1]),0,0)
            let outputBuffer = device.makeBuffer(length:64,options:.storageModeShared)!
            var count:UInt32 = 1
            let command = queue.makeCommandBuffer()!; let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&uniforms,length:MemoryLayout<Uniforms>.stride,index:0)
            encoder.setBytes(&ray,length:16,index:1); encoder.setBuffer(outputBuffer,offset:0,index:2)
            encoder.setBytes(&count,length:4,index:3)
            encoder.dispatchThreads(.init(width:1,height:1,depth:1),threadsPerThreadgroup:.init(width:1,height:1,depth:1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            let floats = outputBuffer.contents().bindMemory(to:Float.self,capacity:16)
            var result = item
            result["result"] = (0..<16).map { floats[$0].isFinite ? Double(floats[$0]) : -1e30 }
            result["gpuMS"] = (command.gpuEndTime-command.gpuStartTime)*1000
            results.append(result)
        }
        try write(["device":device.name,"uniformStride":MemoryLayout<Uniforms>.stride,"temporalChecksPassed":4,"cases":results],to:output)
        print("Validated \(results.count) GPU rays on \(device.name) -> \(output)")
    }
    static func validateAccumulation(device:MTLDevice,queue:MTLCommandQueue,library:MTLLibrary) throws {
        let pipeline = try device.makeComputePipelineState(function:library.makeFunction(name:"accumulate")!)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:1,height:1,mipmapped:false)
        descriptor.usage = [.shaderRead,.shaderWrite]; descriptor.storageMode = .shared
        let current = device.makeTexture(descriptor:descriptor)!, previous = device.makeTexture(descriptor:descriptor)!, output = device.makeTexture(descriptor:descriptor)!
        let region = MTLRegionMake2D(0,0,1,1)
        var history = SIMD4<Float>(repeating:0)
        let cases:[(SIMD4<Float>,UInt32,SIMD4<Float>)] = [
            (.init(1,2,3,1),0,.init(1,2,3,1)),
            (.init(0,0,0,-1),1,.init(1,2,3,1)),
            (.init(3,4,5,1),2,.init(2,3,4,2)),
            (.init(0,0,0,-1),0,.init(0,0,0,0))]
        for (value,count,expected) in cases {
            var value = value; var count = count
            current.replace(region:region,mipmapLevel:0,withBytes:&value,bytesPerRow:16)
            previous.replace(region:region,mipmapLevel:0,withBytes:&history,bytesPerRow:16)
            let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline); encoder.setTexture(current,index:0); encoder.setTexture(previous,index:1); encoder.setTexture(output,index:2)
            encoder.setBytes(&count,length:4,index:0)
            encoder.dispatchThreads(.init(width:1,height:1,depth:1),threadsPerThreadgroup:.init(width:1,height:1,depth:1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            output.getBytes(&history,bytesPerRow:16,from:region,mipmapLevel:0)
            guard history == expected else { throw failure("Progressive sample rejection/reset regression: \(history), expected \(expected)") }
        }
        print("PASS 4 production-GPU temporal accumulation checks")
    }
    static func benchmark(output:String) throws {
        let (device,queue,library) = try context()
        let pipeline = try device.makeComputePipelineState(function:library.makeFunction(name:"traceKerr")!)
        let model = DiskModel(spin:0.82,accretionSolarMassesPerYear:0.1,outerRadius:30)
        let disk = DiskPhysics.radialTable(for:model,count:4096); let spectrum = DiskPhysics.spectralTable(count:4096)
        let diskBuffer = device.makeBuffer(bytes:disk.values,length:disk.values.count*16,options:.storageModeShared)!
        let spectralBuffer = device.makeBuffer(bytes:spectrum.values,length:spectrum.values.count*16,options:.storageModeShared)!
        var reports = [[String:Any]]()
        for (name,width,height,spp,tolerance,maxStep) in [("auto",1120,800,1,Float(2e-6),Float(0.025)),("max",2240,1600,2,Float(3e-7),Float(0.012))] {
            var u = Uniforms(); u.resolution = .init(UInt32(width),UInt32(height)); u.samples = UInt32(spp)
            u.steps = 8192; u.integrationTolerance = tolerance; u.maxStep = maxStep
            u.diskInnerRadius = disk.innerRadius; u.diskOuterRadius = disk.outerRadius
            u.diskTableCount = UInt32(disk.values.count); u.diskLogRadiusMin = disk.logRadiusMin; u.diskLogRadiusStep = disk.logRadiusStep
            u.temperatureTableCount = UInt32(spectrum.values.count); u.temperatureLogMin = spectrum.logTemperatureMin; u.temperatureLogStep = spectrum.logTemperatureStep
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:width,height:height,mipmapped:false)
            descriptor.usage = [.shaderRead,.shaderWrite]; descriptor.storageMode = .shared
            let texture = device.makeTexture(descriptor:descriptor)!
            var durations = [Double]()
            for frame in 0..<5 {
                u.frame = UInt32(frame)
                let command = queue.makeCommandBuffer()!; let encoder = command.makeComputeCommandEncoder()!
                encoder.setComputePipelineState(pipeline); encoder.setTexture(texture,index:0)
                encoder.setBytes(&u,length:MemoryLayout<Uniforms>.stride,index:0)
                encoder.setBuffer(diskBuffer,offset:0,index:1); encoder.setBuffer(spectralBuffer,offset:0,index:2)
                encoder.dispatchThreads(.init(width:width,height:height,depth:1),threadsPerThreadgroup:.init(width:pipeline.threadExecutionWidth,height:4,depth:1))
                encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                if let error = command.error { throw error }
                if frame>0 { durations.append((command.gpuEndTime-command.gpuStartTime)*1000) }
            }
            var pixels = [Float](repeating:0,count:width*height*4)
            texture.getBytes(&pixels,bytesPerRow:width*16,from:.init(origin:.init(x:0,y:0,z:0),size:.init(width:width,height:height,depth:1)),mipmapLevel:0)
            var unresolved = 0, nonfinite = 0
            for i in stride(from:0,to:pixels.count,by:4) {
                if pixels[i+3]<0 { unresolved += 1 }
                if !pixels[i].isFinite || !pixels[i+1].isFinite || !pixels[i+2].isFinite { nonfinite += 1 }
            }
            let median = durations.sorted()[durations.count/2]
            reports.append(["mode":name,"width":width,"height":height,"samples":spp,"gpuMilliseconds":median,"tolerance":tolerance,"unresolvedPixels":unresolved,"nonfinitePixels":nonfinite,"totalPixels":width*height])
            print("\(name): \(width)x\(height), \(spp)spp, \(median)ms; unresolved \(unresolved), nonfinite \(nonfinite)")
            if name == "max" {
                try savePNG(pixels: pixels,width:width,height:height,exposure:u.exposure,path:URL(fileURLWithPath:output).deletingLastPathComponent().appendingPathComponent("physical-render.png").path)
            }
        }
        try write(["device":device.name,"measurements":reports],to:output)
    }
    static func savePNG(pixels:[Float],width:Int,height:Int,exposure:Float,path:String) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32)!
        let bytes = bitmap.bitmapData!
        for i in 0..<width*height {
            let peak = Double(max(pixels[i*4],max(pixels[i*4+1],pixels[i*4+2]))*exposure)
            for channel in 0..<3 {
                let value = max(0,Double(pixels[i*4+channel]*exposure))
                let mapped = value/(1+max(0,peak))
                let srgb = mapped <= 0.0031308 ? mapped*12.92 : 1.055*pow(mapped,1/2.4)-0.055
                bytes[i*4+channel] = UInt8(min(255,max(0,srgb*255)))
            }
            bytes[i*4+3] = 255
        }
        try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))
    }
    static func write(_ value:Any,to path:String) throws {
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
    }
}
