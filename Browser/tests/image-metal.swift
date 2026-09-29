import Foundation
import Metal

// Run unmodified Naga-translated production trace/shade bodies against actual
// Swift-WASM source tables and the browser host's 176-byte uniform snapshots.
// No browser, camera-response pass, UI automation, or performance claim.
let arguments=CommandLine.arguments
guard arguments.count==3 else { fatalError("fixture-directory fast|safe") }
let directory=URL(fileURLWithPath:arguments[1],isDirectory:true)
func data(_ name:String) throws -> Data { try Data(contentsOf:directory.appendingPathComponent(name)) }
let fixture=try JSONSerialization.jsonObject(with:data("fixtures.json")) as! [String:Any]
let configurations=fixture["configurations"] as! [[String:Any]]
guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else {fatalError("Metal unavailable")}
let options=MTLCompileOptions();options.fastMathEnabled=arguments[2]=="fast"
let library=try device.makeLibrary(source:String(decoding:data("image.metal"),as:UTF8.self),options:options)
let trace=try device.makeComputePipelineState(function:library.makeFunction(name:"traceGeometry")!)
let shade=try device.makeComputePipelineState(function:library.makeFunction(name:"shadeGeometry")!)
func buffer(_ bytes:Data) -> MTLBuffer {
    bytes.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)! }
}
func words(_ bytes:Data) -> [UInt32] {
    precondition(bytes.count==176)
    return bytes.withUnsafeBytes { raw in
        (0..<44).map { raw.loadUnaligned(fromByteOffset:$0*4,as:UInt32.self) }
    }
}
func complete(_ command:MTLCommandBuffer) throws {
    command.commit();command.waitUntilCompleted()
    if let error=command.error {throw error}
    precondition(command.status == .completed)
}
func statistics(_ pixels:[Float]) -> [String:Any] {
    var finiteValues=0,lit=0,unresolved=0,sum=0.0,peak=0.0
    for index in stride(from:0,to:pixels.count,by:4) {
        for channel in 0..<4 {if pixels[index+channel].isFinite {finiteValues+=1}}
        let luminance=0.2126*Double(pixels[index])+0.7152*Double(pixels[index+1])+0.0722*Double(pixels[index+2])
        if luminance>1e-6 {lit+=1}
        if pixels[index+3]<0 {unresolved+=1}
        sum+=max(0,luminance);peak=max(peak,Double(pixels[index]),Double(pixels[index+1]),Double(pixels[index+2]))
    }
    return ["values":pixels.count,"finiteValues":finiteValues,"litPixels":lit,"unresolvedPixels":unresolved,
            "meanLuminance":sum/Double(pixels.count/4),"peak":peak]
}
func difference(_ first:[Float],_ last:[Float]) -> [String:Any] {
    var absolute=0.0,baseline=0.0,maximum=0.0,changed=0
    for index in stride(from:0,to:first.count,by:4) {
        var pixelChanged=false
        for channel in 0..<3 {
            let a=Double(first[index+channel]),b=Double(last[index+channel]),delta=abs(a-b)
            let normalized=delta/max(1,abs(a),abs(b))
            absolute+=delta;baseline+=abs(a);maximum=max(maximum,normalized)
            if normalized>1e-5 {pixelChanged=true}
        }
        if pixelChanged {changed+=1}
    }
    return ["normalizedL1":absolute/max(1e-20,baseline),"maxNormalized":maximum,"changedPixels":changed]
}
let spectrum=buffer(try data("spectrum.bin"))
var reports=[[String:Any]](),allPassed=true
for configuration in configurations {
    let id=configuration["id"] as! String,width=configuration["width"] as! Int,height=configuration["height"] as! Int
    let samples=configuration["samples"] as! Int,zeroUnresolved=configuration["zeroUnresolved"] as! Bool
    let geometryBytes=width*height*samples*16
    let geometry=device.makeBuffer(length:geometryBytes,options:.storageModeShared)!
    memset(geometry.contents(),0,geometryBytes)
    let disk=buffer(try data("\(id)-disk.bin"))
    var sizes:[UInt32]=[UInt32(geometryBytes),UInt32(disk.length),UInt32(spectrum.length),0,0]
    let initial=try words(data("\(id)-0.bin"))
    precondition(initial[0]==UInt32(width)&&initial[1]==UInt32(height)&&initial[9]==UInt32(samples))
    // Exact browser 8x8x1 workgroups, bounded eight-row strips, one immutable
    // camera/model snapshot. Geometry samples stay interleaved exactly as WGSL.
    for row in stride(from:0,to:height,by:8) {
        var uniforms=initial;uniforms[27]=Float(row).bitPattern
        let command=queue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(trace)
        encoder.setBytes(&uniforms,length:176,index:0);encoder.setBuffer(geometry,offset:0,index:1)
        encoder.setBytes(&sizes,length:20,index:2)
        encoder.dispatchThreadgroups(MTLSize(width:(width+7)/8,height:1,depth:samples),
            threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
        encoder.endEncoding();try complete(command)
    }
    let records=geometry.contents().bindMemory(to:SIMD4<Float>.self,capacity:width*height*samples)
    var invalidRecords=0,unresolvedRays=0,emittingRays=0
    for index in 0..<(width*height*samples) {
        let value=records[index]
        if !value.x.isFinite || !value.y.isFinite || !value.z.isFinite || !value.w.isFinite || value.x==0 {invalidRecords+=1}
        if value.x <= -4 {unresolvedRays+=1}
        if value.x>0 {emittingRays+=1}
    }
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false)
    descriptor.storageMode = .shared;descriptor.usage = [.shaderWrite]
    let texture=device.makeTexture(descriptor:descriptor)!
    var images=[[Float]]()
    for time in [0,8000] {
        var uniforms=try words(data("\(id)-\(time).bin"))
        let command=queue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(shade)
        encoder.setBytes(&uniforms,length:176,index:0);encoder.setBuffer(geometry,offset:0,index:1)
        encoder.setBuffer(disk,offset:0,index:2);encoder.setBuffer(spectrum,offset:0,index:3)
        encoder.setTexture(texture,index:0);encoder.setBytes(&sizes,length:20,index:4)
        encoder.dispatchThreadgroups(MTLSize(width:(width+7)/8,height:(height+7)/8,depth:1),
            threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
        encoder.endEncoding();try complete(command)
        var half=[UInt16](repeating:0,count:width*height*4)
        half.withUnsafeMutableBytes {texture.getBytes($0.baseAddress!,bytesPerRow:width*8,
            from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)}
        images.append(half.map {Float(Float16(bitPattern:$0))})
    }
    let first=statistics(images[0]),last=statistics(images[1]),motion=difference(images[0],images[1])
    let finite=first["finiteValues"] as! Int==width*height*4 && last["finiteValues"] as! Int==width*height*4
    let emitting=first["litPixels"] as! Int>100 && last["litPixels"] as! Int>100 && first["meanLuminance"] as! Double>1e-5
    let moving=motion["changedPixels"] as! Int>10 && motion["normalizedL1"] as! Double>1e-5
    let resolved = !zeroUnresolved || (unresolvedRays==0 && first["unresolvedPixels"] as! Int==0 && last["unresolvedPixels"] as! Int==0)
    let passed=finite&&emitting&&moving&&resolved&&invalidRecords==0;allPassed = allPassed && passed
    reports.append(["id":id,"width":width,"height":height,"samples":samples,"passed":passed,
                    "finite":finite,"emitting":emitting,"moving":moving,"requiredResolved":resolved,
                    "invalidGeometryRecords":invalidRecords,"unresolvedRays":unresolvedRays,"emittingRays":emittingRays,
                    "traceCount":1,"shadedFrames":2,"first":first,"last":last,"motion":motion])
}
let result:[String:Any]=["scope":"Native Naga-to-Metal production HDR regression; not browser validation or a performance benchmark",
    "device":device.name,"fastMath":options.fastMathEnabled,"passed":allPassed,"cases":reports,
    "shaderSHA256":fixture["shaderSHA256"]!,"wasmSHA256":fixture["wasmSHA256"]!]
let json=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
print(String(decoding:json,as:UTF8.self))
if !allPassed {exit(1)}
