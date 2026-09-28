import Foundation
import Metal

/// Standalone production-GPU regressions for physically calibrated bulk flow.
/// Kept separate from the unchanged legacy API tests in FlowValidation.swift.
@main struct FlowCalibrationValidation {
    static var checks = [[String: Any]]()
    static func check(_ name: String, _ passed: Bool, details: [String: Any] = [:]) {
        var entry = details; entry["name"] = name; entry["passed"] = passed
        checks.append(entry)
        print("\(passed ? "PASS" : "FAIL") \(name)")
    }
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain:"FlowCalibrationValidation",code:1,userInfo:[NSLocalizedDescriptionKey:"Metal unavailable"])
        }
        let flow = try DiskFlow(device:device)
        let width = 256, height = 128, steps = 60, harmonic = 5
        let inner: Float = 2.8001413, outer: Float = 30, spin: Float = 0.82
        let massSolar = 100_000_000.0, playbackRate = 1000.0
        // Independent SI conversion; the production solver receives only an
        // angular rate and does not know the mass or playback multiplier.
        let gravitationalTime = 6.67430e-11 * massSolar * 1.98847e30 / pow(299_792_458.0,3)
        let innerOmega = 1 / (pow(Double(inner),1.5) + Double(spin))
        let angularRate = Float(playbackRate * innerOmega / gravitationalTime)
        let dt: Float = 1/60

        func advance(_ duration: Float, rate: Float) throws -> MTLTexture {
            let command = queue.makeCommandBuffer()!
            let texture = flow.encode(command:command,deltaTime:duration,spin:spin,innerRadius:inner,
                                      outerRadius:outer,speed:0,quality:0,orbitalAngularRate:rate)
            command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            return texture
        }
        func readDye(_ texture: MTLTexture) throws -> [Float] {
            let command = queue.makeCommandBuffer()!, rowBytes = texture.width*8
            let buffer = device.makeBuffer(length:rowBytes*texture.height,options:.storageModeShared)!
            let blit = command.makeBlitCommandEncoder()!
            blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),
                      sourceSize:.init(width:texture.width,height:texture.height,depth:1),to:buffer,
                      destinationOffset:0,destinationBytesPerRow:rowBytes,destinationBytesPerImage:rowBytes*texture.height)
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            let bits = buffer.contents().bindMemory(to:UInt16.self,capacity:texture.width*texture.height*4)
            return (0..<(texture.width*texture.height)).map{Float(Float16(bitPattern:bits[$0*4]))}
        }
        func mode(_ values: [Float], row: Int) -> (phase: Double, amplitude: Double) {
            var real = 0.0, imaginary = 0.0
            for i in 0..<width {
                let phi = 2 * Double.pi * (Double(i)+0.5) / Double(width)
                let value = Double(values[row*width+i])
                real += value*cos(Double(harmonic)*phi)
                imaginary -= value*sin(Double(harmonic)*phi)
            }
            return (atan2(imaginary,real),hypot(real,imaginary)/Double(width))
        }

        let initialTexture = try advance(0,rate:angularRate)
        let initial = try readDye(initialTexture)
        var finalTexture = initialTexture
        for _ in 0..<steps { finalTexture = try advance(dt,rate:angularRate) }
        let evolved = try readDye(finalTexture)
        check("Calibrated production dye remains finite and bounded",evolved.allSatisfy{$0.isFinite && $0 >= 0 && $0 <= 1})
        check("Ordinary frame steps do not report dropped time",!flow.timeWasClamped && flow.droppedDisplayTimeSeconds == 0)
        var measurements = [[String:Any]]()
        for row in [16,64,112] {
            let y = (Double(row)+0.5)/Double(height)
            let radius = exp(log(Double(inner))+y*log(Double(outer)/Double(inner)))
            let omega = 1/(pow(radius,1.5)+Double(spin))
            let omegaRatio = omega/innerOmega
            let actualDuration = Double(dt)*Double(steps)
            let expectedAngle = Double(angularRate)*omegaRatio*actualDuration
            let initialMode = mode(initial,row:row), finalMode = mode(evolved,row:row)
            let measuredPhase = (finalMode.phase-initialMode.phase).remainder(dividingBy:2*Double.pi)
            let expectedPhase = -Double(harmonic)*expectedAngle
            let residual = (measuredPhase-expectedPhase).remainder(dividingBy:2*Double.pi)
            let measurement: [String:Any] = [
                "row":row,"radiusM":radius,"kerrOmegaInverseM":omega,"omegaRatio":omegaRatio,
                "expectedRotationRadians":expectedAngle,"measuredRotationRadians":-measuredPhase/Double(harmonic),
                "expectedHarmonicPhaseRadians":expectedPhase,"measuredHarmonicPhaseRadians":measuredPhase,
                "harmonicPhaseResidualRadians":residual,"initialHarmonicAmplitude":initialMode.amplitude,
                "finalHarmonicAmplitude":finalMode.amplitude]
            // Bilinear advection and half state storage introduce measurable
            // dissipation/phase error; this is not a spectral-exact transport
            // solver. Tolerance is 0.006 rad in the underlying material angle.
            check("Calibrated Kerr differential rotation at row \(row), with zero turbulence",
                  initialMode.amplitude > 0.005 && finalMode.amplitude > 0.005 && abs(residual)<0.03,
                  details:measurement)
            measurements.append(measurement)
        }
        let stoppedBefore = try readDye(advance(0,rate:0))
        let stoppedAfter = try readDye(advance(1/30,rate:0))
        check("Zero bulk rate plus zero turbulence preserves dye exactly",stoppedBefore==stoppedAfter)
        _ = try advance(1,rate:angularRate)
        let discarded = flow.droppedDisplayTimeSeconds
        check("Long frames expose the clamp flag",flow.timeWasClamped)
        check("Dropped display time accounts for the bounded step",abs(discarded-14.0/15)<1e-5,
              details:["requestedDisplaySeconds":1.0,"maximumSimulatedDisplaySeconds":1.0/15,"droppedDisplaySeconds":discarded])
        _ = try advance(0,rate:angularRate)
        check("Clamp flag resets per call while cumulative dropped time persists",!flow.timeWasClamped && flow.droppedDisplayTimeSeconds==discarded)

        let passed = checks.allSatisfy{($0["passed"] as? Bool)==true}
        let output = CommandLine.arguments.count>1 ? CommandLine.arguments[1] : "outputs/flow-calibration-validation.json"
        let report: [String:Any] = [
            "device":device.name,"passed":passed,"checks":checks,"measurements":measurements,
            "width":width,"height":height,"steps":steps,"displaySeconds":Double(dt)*Double(steps),
            "massSolar":massSolar,"spin":Double(spin),"innerRadiusM":Double(inner),"outerRadiusM":Double(outer),
            "gravitationalTimeSeconds":gravitationalTime,"playbackRate":playbackRate,
            "innerAngularRateRadiansPerDisplaySecond":Double(angularRate),"turbulenceSpeed":0,
            "fourierHarmonic":harmonic,"harmonicPhaseToleranceRadians":0.03,
            "scope":"Tests prescribed Kerr-calibrated bulk advection of the reduced material dye, not GRMHD or retarded turbulent history."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output))
        print("\(checks.count) calibrated flow checks; \(passed ? "all passed" : "FAILURES") → \(output)")
        if !passed { exit(1) }
    }
}
