import Foundation
import Metal

/// Standalone GPU checks for the optional reduced material-flow model.
/// Run ./verify-flow.sh; no app launch or display is required.
@main struct FlowValidation {
    struct Parameters {
        var size: SIMD2<UInt32>
        var dt: Float = 1/60
        var time: Float = 0
        var logInner: Float = log(2.7998)
        var logSpan: Float = log(30/2.7998)
        var spin: Float = 0.82
        var innerOmega: Float = 1/(pow(2.7998,1.5)+0.82)
    }
    static var checks = [[String: Any]]()
    static func check(_ name: String, _ passed: Bool, _ details: [String: Any] = [:]) {
        var item = details; item["name"] = name; item["passed"] = passed
        checks.append(item)
        print("\(passed ? "PASS" : "FAIL") \(name)")
    }
    static func finish(_ command: MTLCommandBuffer) throws {
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
    }
    static func read(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [Float] {
        let row = texture.width*8
        let buffer = texture.device.makeBuffer(length: row*texture.height, options: .storageModeShared)!
        let command = queue.makeCommandBuffer()!, blit = command.makeBlitCommandEncoder()!
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x:0,y:0,z:0),
                  sourceSize: .init(width:texture.width,height:texture.height,depth:1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: row, destinationBytesPerImage: row*texture.height)
        blit.endEncoding(); try finish(command)
        let halfs = buffer.contents().bindMemory(to: UInt16.self, capacity: texture.width*texture.height*4)
        return (0..<(texture.width*texture.height*4)).map { Float(Float16(bitPattern: halfs[$0])) }
    }
    static func stats(_ values: [Float], width: Int) -> [String: Double] {
        let height = values.count/(width*4), n = width*height
        var minimum = Double.infinity, maximum = -Double.infinity, sum = 0.0, sq = 0.0, divSq = 0.0, maxVelocity = 0.0, wallVelocity = 0.0
        for j in 0..<height { for i in 0..<width {
            let k=(j*width+i)*4, left=(j*width+(i+width-1)%width)*4
            let density = Double(values[k]); minimum=min(minimum,density); maximum=max(maximum,density)
            sum += density; sq += density*density
            maxVelocity = max(maxVelocity,Double(max(abs(values[k+1]),abs(values[k+2]))))
            let bottom = j>0 ? values[((j-1)*width+i)*4+2] : 0
            let divergence = Double((values[k+1]-values[left+1]+values[k+2]-bottom)*Float(height))
            divSq += divergence*divergence
            if j == height-1 { wallVelocity=max(wallVelocity,Double(abs(values[k+2]))) }
        }}
        let mean=sum/Double(n)
        return ["dyeMinimum":minimum,"dyeMaximum":maximum,"dyeMean":mean,
                "dyeStandardDeviation":sqrt(max(0,sq/Double(n)-mean*mean)),
                "maximumVelocityComponent":maxVelocity,"maximumRadialBoundaryVelocity":wallVelocity,
                "divergenceRMS":sqrt(divSq/Double(n))]
    }
    static func run(_ flow: DiskFlow, queue: MTLCommandQueue, dt: Float, quality: Int,
                    speed: Float = 1) throws -> (MTLTexture, Double) {
        let command = queue.makeCommandBuffer()!
        let texture = flow.encode(command: command, deltaTime: dt, spin:0.82,
                                  innerRadius:2.7998, outerRadius:30, speed:speed, quality:quality)
        try finish(command)
        return (texture,(command.gpuEndTime-command.gpuStartTime)*1000)
    }
    static func projection(device: MTLDevice, queue: MTLCommandQueue, width: Int) throws -> [String:Double] {
        let options=MTLCompileOptions(); options.fastMathEnabled=false
        let library=try device.makeLibrary(source: DiskFlow.metalSource,options:options)
        let divergencePipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"diskFlowDivergence")!)
        let pressurePipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"diskFlowPressure")!)
        let projectPipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"diskFlowProject")!)
        let height=width/2, h=1.0/Double(height)
        func texture(_ format: MTLPixelFormat)->MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
            d.storageMode = .shared; d.usage = [.shaderRead,.shaderWrite]
            return device.makeTexture(descriptor:d)!
        }
        let input=texture(.rgba16Float), output=texture(.rgba16Float), pressure=[texture(.r32Float),texture(.r32Float)], divergence=texture(.r32Float)
        // Pure discrete pressure gradient: periodic x, Neumann radial pressure.
        // Its exact projected velocity is zero if Poisson is fully converged.
        func potential(_ i:Int,_ j:Int)->Double {
            let x=(Double((i+width)%width)+0.5)*h, y=(Double(min(height-1,max(0,j)))+0.5)*h
            return 0.0004*sin(16*Double.pi*x)*cos(12*Double.pi*y)
        }
        var inputHalfs=[UInt16](repeating:0,count:width*height*4)
        for j in 0..<height { for i in 0..<width {
            let k=(j*width+i)*4
            inputHalfs[k]=Float16(0.5).bitPattern
            inputHalfs[k+1]=Float16((potential(i+1,j)-potential(i,j))/h).bitPattern
            inputHalfs[k+2]=Float16((potential(i,j+1)-potential(i,j))/h).bitPattern
        }}
        input.replace(region: MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:&inputHalfs,bytesPerRow:width*8)
        var p=Parameters(size:.init(UInt32(width),UInt32(height)))
        let command=queue.makeCommandBuffer()!
        func dispatch(_ pipeline: MTLComputePipelineState,_ textures:[MTLTexture]) {
            let encoder=command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline); encoder.setBytes(&p,length:MemoryLayout<Parameters>.stride,index:0)
            for (i,t) in textures.enumerated(){encoder.setTexture(t,index:i)}
            encoder.dispatchThreads(.init(width:width,height:height,depth:1),threadsPerThreadgroup:.init(width:16,height:8,depth:1))
            encoder.endEncoding()
        }
        dispatch(divergencePipeline,[input,divergence,pressure[0]])
        let iterations=width==256 ? 16:24
        for i in 0..<iterations {dispatch(pressurePipeline,[pressure[i%2],divergence,pressure[1-i%2]])}
        dispatch(projectPipeline,[input,pressure[iterations%2],output])
        try finish(command)
        let before=stats(inputHalfs.map{Float(Float16(bitPattern:$0))},width:width)
        let after=stats(try read(output,queue:queue),width:width)
        return ["divergenceRMSBefore":before["divergenceRMS"]!,"divergenceRMSAfter":after["divergenceRMS"]!,
                "divergenceReductionRatio":after["divergenceRMS"]!/before["divergenceRMS"]!,
                "velocityBefore":before["maximumVelocityComponent"]!,"velocityAfter":after["maximumVelocityComponent"]!,
                "iterations":Double(iterations)]
    }
    static func main() throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {fatalError("Metal unavailable")}
        check("Metal parameter layout",MemoryLayout<Parameters>.stride==32)
        var measurements=[[String:Any]]()
        for quality in [0,1] {
            let width=quality==0 ? 256:512
            let flow=try DiskFlow(device:device)
            let initialTexture=try run(flow,queue:queue,dt:0,quality:quality).0
            let initial=try read(initialTexture,queue:queue)
            let initialStats=stats(initial,width:width)
            check("\(width) initialized MAC curl approximately divergence-free",initialStats["divergenceRMS"]!<0.001,initialStats)
            var timings=[Double](), latest=initialTexture
            for frame in 0..<120 {
                let result=try run(flow,queue:queue,dt:1/60,quality:quality)
                latest=result.0; if frame>=10 {timings.append(result.1)}
            }
            let final=try read(latest,queue:queue), finalStats=stats(final,width:width)
            check("\(width) finite dye and velocity",final.allSatisfy{$0.isFinite})
            check("\(width) dye and velocity within safety bounds",finalStats["dyeMinimum"]!>=0 && finalStats["dyeMaximum"]!<=1 && finalStats["maximumVelocityComponent"]!<=0.25,finalStats)
            check("\(width) impermeable radial boundary",finalStats["maximumRadialBoundaryVelocity"]!==0)
            let delta=stride(from:0,to:final.count,by:4).reduce(0.0){$0+Double(abs(final[$1]-initial[$1]))}/Double(width*width/2)
            check("\(width) persistent dye evolves",delta>0.01,["meanAbsoluteDyeChange":delta])
            let paused=try read(run(flow,queue:queue,dt:0,quality:quality).0,queue:queue)
            check("\(width) zero timestep preserves state",paused==final)
            let stopped=try read(run(flow,queue:queue,dt:1,quality:quality,speed:0).0,queue:queue)
            check("\(width) zero speed preserves state",stopped==final)
            let replay=try DiskFlow(device:device)
            var replayTexture=try run(replay,queue:queue,dt:0,quality:quality).0
            for _ in 0..<120 {replayTexture=try run(replay,queue:queue,dt:1/60,quality:quality).0}
            check("\(width) deterministic replay",try read(replayTexture,queue:queue)==final)
            let cappedA=try DiskFlow(device:device), cappedB=try DiskFlow(device:device)
            let a=try read(run(cappedA,queue:queue,dt:1000,quality:quality).0,queue:queue)
            let b=try read(run(cappedB,queue:queue,dt:1/15,quality:quality).0,queue:queue)
            check("\(width) delayed frames bounded to 1/15 second",a==b)
            let projected=try projection(device:device,queue:queue,width:width)
            check("\(width) production projection reduces divergence",projected["divergenceReductionRatio"]!<0.8 && projected["velocityAfter"]!<projected["velocityBefore"]!,projected)
            var measurement:[String:Any]=["width":width,"height":width/2,"medianGPUMilliseconds":timings.sorted()[timings.count/2],
                                         "meanGPUMilliseconds":timings.reduce(0,+)/Double(timings.count),"frames":120,"simulationSeconds":2]
            measurement["initial"]=initialStats; measurement["evolved"]=finalStats; measurement["projection"]=projected
            measurements.append(measurement)
        }
        let passed=checks.allSatisfy{($0["passed"] as? Bool)==true}
        let output=CommandLine.arguments.count>1 ? CommandLine.arguments[1]:"outputs/flow-validation.json"
        let report:[String:Any]=["device":device.name,"passed":passed,"checks":checks,"measurements":measurements,
                               "model":"Reduced flat-strip incompressible Navier–Stokes with prescribed Keplerian shear and artistic forcing; not GRMHD.",
                               "precision":"Float arithmetic, half state storage, float pressure; finite Jacobi projection."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
        print("\(checks.count) flow checks; \(passed ? "all passed" : "FAILURES") → \(output)")
        if !passed {exit(1)}
    }
}
