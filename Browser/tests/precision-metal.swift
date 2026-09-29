import Foundation
import Metal

// Execute Naga's translation of the production WGSL with Metal fast math both
// enabled and disabled. This tests the arithmetic backend; it is not a browser
// API or presentation test. The Node driver assigns only entry-point bindings.
let arguments = CommandLine.arguments
guard arguments.count == 5 else { fatalError("metal-source cases reference fast|safe") }
let source = try String(contentsOfFile: arguments[1], encoding: .utf8)
let casesDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[2]))) as! [String: Any]
let referenceDocument = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[3]))) as! [String: Any]
let cases = casesDocument["cases"] as! [[String: Any]]
let references = Dictionary(uniqueKeysWithValues: (referenceDocument["cases"] as! [[String: Any]]).map { ($0["id"] as! String, $0["result"] as! [Double]) })
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
let options = MTLCompileOptions()
options.fastMathEnabled = arguments[4] == "fast"
let library = try device.makeLibrary(source: source, options: options)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "validateKerr")!)
let arithmeticPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "wideArithmeticValidation")!)
var seed: UInt32 = 0x183da265
func random() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double(seed)/4294967296 }
func randomFloat() -> Float { Float((random()<0.5 ? -1 : 1)*(1+random())*pow(2, floor(random()*71)-35)) }
var arithmeticInputs = [SIMD4<Float>]()
for i in 0..<4096 {
    let a = randomFloat(), b = i % 7 == 0 ? -a : randomFloat()
    let al = Float(Double(a)*(random()-0.5)*pow(2,-24)), bl = Float(Double(b)*(random()-0.5)*pow(2,-24))
    arithmeticInputs.append(SIMD4<Float>(a,al,b,bl))
}
let arithmeticInput = device.makeBuffer(bytes: &arithmeticInputs, length: arithmeticInputs.count*16, options: .storageModeShared)!
let arithmeticOutput = device.makeBuffer(length: arithmeticInputs.count*16, options: .storageModeShared)!
let arithmeticCommand = queue.makeCommandBuffer()!, arithmeticEncoder = arithmeticCommand.makeComputeCommandEncoder()!
arithmeticEncoder.setComputePipelineState(arithmeticPipeline)
arithmeticEncoder.setBuffer(arithmeticInput, offset:0, index:0); arithmeticEncoder.setBuffer(arithmeticOutput, offset:0, index:1)
arithmeticEncoder.dispatchThreads(MTLSize(width:arithmeticInputs.count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:64,height:1,depth:1))
arithmeticEncoder.endEncoding(); arithmeticCommand.commit(); arithmeticCommand.waitUntilCompleted()
if let error=arithmeticCommand.error { throw error }
let arithmeticValues=arithmeticOutput.contents().bindMemory(to:SIMD4<Float>.self,capacity:arithmeticInputs.count)
var maximumArithmeticError=0.0
for (index,input) in arithmeticInputs.enumerated() {
    let a=Double(input.x)+Double(input.y), b=Double(input.z)+Double(input.w), value=arithmeticValues[index]
    guard value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite else {
        fatalError("Non-finite compensated arithmetic output at case \(index)")
    }
    let sum=Double(value.x)+Double(value.y), product=Double(value.z)+Double(value.w)
    maximumArithmeticError=max(maximumArithmeticError,abs(sum-(a+b))/max(abs(a),abs(b)),abs(product-a*b)/abs(a*b))
}
var failures = [[String: Any]]()
var maximumConstantsError = 0.0
for item in cases {
    func number(_ key: String, _ fallback: Double) -> Float { Float((item[key] as? NSNumber)?.doubleValue ?? fallback) }
    var uniforms = [UInt32](repeating: 0, count: 44)
    func put(_ offset: Int, _ value: Float) { uniforms[offset / 4] = value.bitPattern }
    let resolution = item["resolution"] as! [Int]
    let pixel = item["pixel"] as! [Double]
    uniforms[0] = UInt32(resolution[0]); uniforms[1] = UInt32(resolution[1])
    let spin = number("spin", 0)
    put(12, spin); put(20, number("cameraYaw", 0.17)); put(24, number("cameraPitch", 0.28))
    put(28, number("cameraDistance", 36)); put(44, number("cameraDistance", 36))
    uniforms[8] = UInt32(number("steps", 4096)); uniforms[9] = 1
    put(48, number("fov", Double.pi / 4)); put(52, number("tolerance", 2e-6)); put(56, number("maxStep", 0.02))
    let a = (item["spin"] as? NSNumber)?.doubleValue ?? 0, z1 = 1 + cbrt(1 - a*a) * (cbrt(1+a) + cbrt(1-a)), z2 = sqrt(3*a*a + z1*z1)
    put(60, Float(3 + z2 - sqrt((3-z1)*(3+z1+2*z2)))); put(64, number("diskOuter", 30))
    put(112, number("lookYaw", 0)); put(116, number("lookPitch", 0))
    var point = SIMD4<Float>(Float(pixel[0]), Float(pixel[1]), 0, 0)
    var sizes: [UInt32] = [0, 0, 0, 16, 64]
    let output = device.makeBuffer(length: 64, options: .storageModeShared)!
    let command = queue.makeCommandBuffer()!, encoder = command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBytes(&uniforms, length: 176, index: 0)
    encoder.setBytes(&point, length: 16, index: 1)
    encoder.setBuffer(output, offset: 0, index: 2)
    encoder.setBytes(&sizes, length: 20, index: 3)
    encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    if let error = command.error { throw error }
    let pointer = output.contents().bindMemory(to: Float.self, capacity: 16)
    let values = (0..<16).map { Double(pointer[$0]) }, expected = references[item["id"] as! String]!
    for index in 0..<3 { maximumConstantsError = max(maximumConstantsError, abs(values[index]-expected[index])/max(1,abs(expected[index]))) }
    if !values.allSatisfy({ $0.isFinite }) || values[4] != expected[4] {
        failures.append(["id":item["id"]!, "expected":expected[4], "actual":values[4],
                         "radius":values[5], "accepted":values[12], "rejected":values[13], "invariant":values[11]])
    }
}
let result: [String: Any] = ["device":device.name, "fastMath":options.fastMathEnabled,
                            "rays":cases.count, "matched":cases.count-failures.count,
                            "maximumConstantsError":maximumConstantsError, "failures":failures,
                            "arithmeticCases":arithmeticInputs.count,"maximumArithmeticRelativeError":maximumArithmeticError]
let json = try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
print(String(decoding:json,as:UTF8.self))
if !failures.isEmpty || maximumConstantsError >= 5e-5 || !maximumArithmeticError.isFinite || maximumArithmeticError >= pow(2,-44) { exit(1) }
