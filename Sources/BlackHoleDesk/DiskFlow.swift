import Foundation
import Metal

/// A deliberately reduced, artistic material model: incompressible 2D flow on
/// a flat periodic strip mapped to (azimuth, log radius), NOT GRMHD. The Kerr
/// ray tracer and thermal disk are independent of this optional simulation.
final class DiskFlow {
    private struct Parameters {
        var size: SIMD2<UInt32>
        var dt: Float
        var time: Float
        var logInner: Float
        var logSpan: Float
        var spin: Float
        var innerOmega: Float
    }

    private let device: MTLDevice
    private let initializePipeline: MTLComputePipelineState
    private let advectPipeline: MTLComputePipelineState
    private let divergencePipeline: MTLComputePipelineState
    private let pressurePipeline: MTLComputePipelineState
    private let projectPipeline: MTLComputePipelineState
    private var state: [MTLTexture] = []
    private var pressure: [MTLTexture] = []
    private var divergence: MTLTexture?
    private var stateIndex = 0
    /// Intrinsic perturbation/source clock, distinct from calibrated bulk orbit.
    private var time: Float = 0
    private var orbitalPhase: Double = 0
    private var width = 0
    private var initialized = false
    private var modelKey = ""
    /// Most recent encode dropped elapsed time to preserve bounded work.
    private(set) var timeWasClamped = false
    /// Display seconds discarded by the substep cap over this solver instance.
    private(set) var droppedDisplayTimeSeconds: Double = 0

    init(device: MTLDevice, library: MTLLibrary? = nil) throws {
        self.device = device
        let flowLibrary: MTLLibrary
        if let library, library.makeFunction(name: "diskFlowInitialize") != nil {
            flowLibrary = library
        } else {
            let options = MTLCompileOptions()
            options.fastMathEnabled = false
            flowLibrary = try device.makeLibrary(source: Self.metalSource, options: options)
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = flowLibrary.makeFunction(name: name) else {
                throw NSError(domain: "DiskFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(name)"])
            }
            return try device.makeComputePipelineState(function: function)
        }
        initializePipeline = try pipeline("diskFlowInitialize")
        advectPipeline = try pipeline("diskFlowAdvect")
        divergencePipeline = try pipeline("diskFlowDivergence")
        pressurePipeline = try pipeline("diskFlowPressure")
        projectPipeline = try pipeline("diskFlowProject")
        precondition(MemoryLayout<Parameters>.stride == 32)
    }

    /// Enqueue only in cinematic mode. All calls must use one ordered command
    /// queue; returned resources may be sampled after this call in that command.
    /// Output R=dye [0,1], G/B=staggered perturbation velocity, A=0. UV uses
    /// fract(phi/2pi) and normalized log radius, with periodic U / clamped V.
    /// A non-nil orbitalAngularRate is the desired inner-edge angular velocity
    /// in radians per display second, normally playbackRate*Omega_ISCO/t_g.
    /// In that calibrated mode speed affects perturbations only; speed=0 still
    /// allows prescribed bulk rotation. Nil preserves the original API's
    /// 0.055 inner turns per animation second with speed scaling all evolution.
    /// This dye remains an instantaneous, reduced artistic fluid proxy; a
    /// calibrated mean orbit does not supply a retarded turbulent history.
    func encode(command: MTLCommandBuffer, deltaTime: Float, spin: Float,
                innerRadius: Float, outerRadius: Float, speed: Float,
                quality: Int, orbitalAngularRate: Float? = nil) -> MTLTexture {
        let desiredWidth = quality > 0 ? 512 : 256
        let safeInner = innerRadius.isFinite ? max(1.001, innerRadius) : 3
        let safeOuter = outerRadius.isFinite ? max(safeInner * 1.01, outerRadius) : 30
        let safeSpin = spin.isFinite ? min(0.998, max(-0.998, spin)) : 0
        let key = "\(safeInner)|\(safeOuter)|\(safeSpin)"
        if width != desiredWidth {
            width = desiredWidth
            state = (0..<2).map { makeTexture(format: .rgba16Float, label: "Disk flow state \($0)") }
            pressure = (0..<2).map { makeTexture(format: .r32Float, label: "Disk flow pressure \($0)") }
            divergence = makeTexture(format: .r32Float, label: "Disk flow divergence")
            initialized = false
        }
        if key != modelKey { initialized = false; modelKey = key }
        let calibrated = orbitalAngularRate != nil
        let safeSpeed = speed.isFinite ? min(4, max(0, speed)) : 0
        let elapsed = deltaTime.isFinite ? max(0, deltaTime) : 0
        let legacyClockScale: Float = calibrated ? 1 : safeSpeed
        let requestedDuration = elapsed * legacyClockScale
        let duration = min(1.0 / 15.0, requestedDuration)
        timeWasClamped = requestedDuration > duration + 1e-7
        if timeWasClamped, legacyClockScale > 0 {
            droppedDisplayTimeSeconds += Double((requestedDuration - duration) / legacyClockScale)
        }
        let angularRate: Float
        if let orbitalAngularRate {
            angularRate = orbitalAngularRate.isFinite ? max(0, orbitalAngularRate) : 0
        } else {
            angularRate = 2 * .pi * 0.055
        }
        let perturbationSpeed: Float = calibrated ? safeSpeed : 1
        let steps = duration > 0 ? max(1, Int(ceil(duration * 60))) : 0
        var parameters = Parameters(size: .init(UInt32(width), UInt32(width / 2)),
                                    dt: steps > 0 ? duration / Float(steps) : 0,
                                    time: time, logInner: log(safeInner),
                                    logSpan: log(safeOuter / safeInner), spin: safeSpin,
                                    innerOmega: 1 / (pow(safeInner, 1.5) + safeSpin))
        if !initialized {
            stateIndex = 0; time = 0; orbitalPhase = 0; parameters.time = 0
            run(initializePipeline, command, &parameters, [state[0]])
            initialized = true
        }
        for _ in 0..<steps {
            parameters.time = time
            let other = 1 - stateIndex
            // x=phi/pi, hence Ux=angularRate/pi * Omega(r)/Omega_ISCO.
            // Extra controls are confined to advection; the original 32-byte
            // parameter ABI remains intact for independent projection tests.
            let control = SIMD4<Float>(angularRate / (.pi * parameters.innerOmega),
                                       perturbationSpeed, Float(orbitalPhase), 0)
            run(advectPipeline, command, &parameters, [state[stateIndex], state[other]], controls: control)
            // Clear pressure while calculating the divergence of the advected
            // field. Separate encoders give explicit producer/consumer order.
            run(divergencePipeline, command, &parameters, [state[other], divergence!, pressure[0]])
            var pressureIndex = 0
            for _ in 0..<(quality > 0 ? 24 : 16) {
                run(pressurePipeline, command, &parameters,
                    [pressure[pressureIndex], divergence!, pressure[1 - pressureIndex]])
                pressureIndex = 1 - pressureIndex
            }
            run(projectPipeline, command, &parameters, [state[other], pressure[pressureIndex], state[stateIndex]])
            time += parameters.dt * perturbationSpeed
            orbitalPhase += Double(parameters.dt) * Double(angularRate)
        }
        return state[stateIndex]
    }

    private func makeTexture(format: MTLPixelFormat, label: String) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: width / 2, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(descriptor: descriptor) else { fatalError("Unable to allocate small disk flow textures") }
        texture.label = label
        return texture
    }

    private func run(_ pipeline: MTLComputePipelineState, _ command: MTLCommandBuffer,
                     _ parameters: inout Parameters, _ textures: [MTLTexture],
                     controls: SIMD4<Float>? = nil) {
        guard let encoder = command.makeComputeCommandEncoder() else { fatalError("Unable to encode disk flow") }
        encoder.label = pipeline.label ?? "Disk material fluid step"
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        if var controls { encoder.setBytes(&controls, length: 16, index: 1) }
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        let groupWidth = pipeline.threadExecutionWidth
        let groupHeight = min(8, max(1, pipeline.maxTotalThreadsPerThreadgroup / groupWidth))
        encoder.dispatchThreads(MTLSize(width: width, height: width / 2, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: groupWidth, height: groupHeight, depth: 1))
        encoder.endEncoding()
    }

    static let metalSource = #"""
#include <metal_stdlib>
using namespace metal;
struct DiskFlowParameters {
    uint2 size;
    float dt, time, logInner, logSpan, spin, innerOmega;
};
constant float dfPi = 3.14159265358979323846f;
constexpr sampler dfSampler(coord::normalized, s_address::repeat, t_address::clamp_to_edge, filter::linear);

inline uint2 dfCell(int2 p, uint2 size) {
    return uint2((p.x % int(size.x) + int(size.x)) % int(size.x), clamp(p.y, 0, int(size.y) - 1));
}
inline float2 dfUV(uint2 p, uint2 size) { return (float2(p) + 0.5f) / float2(size); }
// Computational domain [0,2] x [0,1] => equal cell spacing in both axes.
inline float2 dfVelocity(texture2d<float, access::sample> state, float2 uv) {
    float2 d = 0.5f / float2(state.get_width(), state.get_height());
    float u = state.sample(dfSampler, uv - float2(d.x, 0)).y;
    float v = state.sample(dfSampler, uv - float2(0, d.y)).z;
    // Radial walls have no normal flow. Fade only within the half-cell where
    // the implicit bottom face is absent from packed MAC storage.
    v *= smoothstep(0.0f, d.y * 2.0f, uv.y) * smoothstep(0.0f, d.y * 2.0f, 1.0f - uv.y);
    return float2(u, v);
}
inline float dfBackground(float y, constant DiskFlowParameters &p, float4 control) {
    float r = exp(p.logInner + clamp(y, 0.0f, 1.0f) * p.logSpan);
    // control.x = desired inner radians/display-second / (pi*Omega_ISCO).
    // The legacy nil API supplies the original 0.055 turns/animation-second.
    return control.x / (pow(r, 1.5f) + p.spin);
}
inline float dfBackgroundGradient(float y, constant DiskFlowParameters &p, float4 control) {
    float r32 = exp(1.5f * (p.logInner + clamp(y, 0.0f, 1.0f) * p.logSpan));
    return -1.5f * p.logSpan * r32 / (r32 + p.spin) * dfBackground(y, p, control);
}
inline float2 dfTotalVelocity(texture2d<float, access::sample> state, float2 uv,
                              constant DiskFlowParameters &p, float4 control) {
    return control.y * dfVelocity(state, uv) + float2(dfBackground(uv.y, p, control), 0);
}
inline float2 dfDeparture(texture2d<float, access::sample> state, float2 uv,
                          constant DiskFlowParameters &p, float4 control) {
    float2 coordinateScale(0.5f, 1.0f);
    float2 midpoint = uv - 0.5f * p.dt * coordinateScale * dfTotalVelocity(state, uv, p, control);
    float2 departure = uv - p.dt * coordinateScale * dfTotalVelocity(state, midpoint, p, control);
    departure.x = fract(departure.x);
    departure.y = clamp(departure.y, 0.0f, 1.0f);
    return departure;
}
// Deterministic, periodic, multiscale seed/source; the evolving texture itself
// is subsequently advected by the solved velocity field, not regenerated noise.
inline float dfDyeSeed(float2 uv, float t) {
    float x = uv.x * 2.0f * dfPi, y = uv.y;
    float warp = 0.28f * sin(3.0f*x + 11.0f*y) + 0.11f*sin(7.0f*x - 17.0f*y);
    float field = 0.45f*sin(5.0f*x + 15.0f*y + warp + t*0.08f)
                + 0.27f*sin(13.0f*x - 29.0f*y + 2.2f*warp - t*0.11f)
                + 0.17f*sin(29.0f*x + 51.0f*y + 3.0f*warp)
                + 0.11f*sin(61.0f*x - 83.0f*y + 5.0f*warp);
    return clamp(0.5f + 0.58f*field, 0.02f, 0.98f);
}
// Streamfunction vanishes at radial boundaries, giving impermeable walls.
inline float dfStream(float2 uv, float t) {
    float e = sin(dfPi*uv.y); e *= e;
    float x = 2.0f*dfPi*uv.x;
    return e * (0.00048f*sin(4.0f*x + 5.0f*uv.y + 0.23f*t)
              + 0.00019f*sin(9.0f*x - 12.0f*uv.y - 0.17f*t)
              + 0.00008f*sin(17.0f*x + 21.0f*uv.y + 0.09f*t));
}
// Discrete curl at MAC faces: its backward-difference divergence is zero
// (apart from storage rounding), unlike a collocated central-difference grid.
inline float2 dfCurlSeed(float2 uv, constant DiskFlowParameters &p) {
    float2 halfCell = 0.5f/float2(p.size);
    float h = 1.0f/float(p.size.y);
    float2 east = uv + float2(halfCell.x, 0);
    float2 north = uv + float2(0, halfCell.y);
    float u = (dfStream(east + float2(0,halfCell.y), p.time) - dfStream(east - float2(0,halfCell.y), p.time))/h;
    float v = -(dfStream(north + float2(halfCell.x,0), p.time) - dfStream(north - float2(halfCell.x,0), p.time))/h;
    return float2(u,v);
}
kernel void diskFlowInitialize(texture2d<float, access::write> output [[texture(0)]],
                               constant DiskFlowParameters &p [[buffer(0)]], uint2 cell [[thread_position_in_grid]]) {
    if(any(cell >= p.size)) return;
    float2 uv = dfUV(cell,p.size);
    float2 v = dfCurlSeed(uv,p);
    if(cell.y == p.size.y-1) v.y = 0;
    output.write(float4(dfDyeSeed(uv,0),v,0),cell);
}
kernel void diskFlowAdvect(texture2d<float, access::sample> previous [[texture(0)]],
                           texture2d<float, access::write> output [[texture(1)]],
                           constant DiskFlowParameters &p [[buffer(0)]],
                           constant float4 &control [[buffer(1)]], uint2 cell [[thread_position_in_grid]]) {
    if(any(cell >= p.size)) return;
    float2 uv = dfUV(cell,p.size), halfCell = 0.5f/float2(p.size);
    float2 east = uv + float2(halfCell.x,0), north = uv + float2(0,halfCell.y);
    float2 v;
    v.x = dfVelocity(previous,dfDeparture(previous,east,p,control)).x;
    v.y = dfVelocity(previous,dfDeparture(previous,north,p,control)).y;
    float4 center = previous.read(cell);
    float4 left = previous.read(dfCell(int2(cell)+int2(-1,0),p.size));
    float4 right = previous.read(dfCell(int2(cell)+int2(1,0),p.size));
    float4 bottom = previous.read(dfCell(int2(cell)+int2(0,-1),p.size));
    float4 top = previous.read(dfCell(int2(cell)+int2(0,1),p.size));
    // At the lower wall the implicit normal velocity face is zero.
    if(cell.y == 0) bottom.z = 0;
    float invH2 = float(p.size.y*p.size.y);
    float4 laplacian = (left+right+bottom+top-4.0f*center)*invH2;
    float2 force = control.y*(0.35f*dfCurlSeed(uv,p) - 0.08f*center.yz);
    // Perturbation equation includes (v·∇)U from prescribed mean shear.
    force.x -= dfVelocity(previous,east).y * dfBackgroundGradient(east.y,p,control);
    v += p.dt*(force + control.y*0.00002f*laplacian.yz);
    v = clamp(v,float2(-0.25f),float2(0.25f));
    if(cell.y == p.size.y-1) v.y=0;
    float density = previous.sample(dfSampler,dfDeparture(previous,uv,p,control)).x;
    float r = exp(p.logInner + uv.y*p.logSpan);
    float orbitalRatio = 1.0f/((pow(r,1.5f)+p.spin)*p.innerOmega);
    // The source tracks the integrated mean phase, not rate*currentTime, so
    // changing playback speed does not jump its material coordinates.
    float2 seedUV = uv - float2(control.z*orbitalRatio/(2.0f*dfPi),0);
    density += p.dt*control.y*(0.08f*(dfDyeSeed(seedUV,p.time)-density) + 0.000004f*laplacian.x);
    if(!all(isfinite(v))) v=float2(0);
    if(!isfinite(density)) density=0.5f;
    output.write(float4(clamp(density,0.0f,1.0f),v,0),cell);
}
kernel void diskFlowDivergence(texture2d<float, access::read> state [[texture(0)]],
                              texture2d<float, access::write> divergence [[texture(1)]],
                              texture2d<float, access::write> pressure [[texture(2)]],
                              constant DiskFlowParameters &p [[buffer(0)]], uint2 cell [[thread_position_in_grid]]) {
    if(any(cell >= p.size)) return;
    float4 center=state.read(cell);
    float uLeft=state.read(dfCell(int2(cell)+int2(-1,0),p.size)).y;
    float vBottom=cell.y>0?state.read(cell-uint2(0,1)).z:0;
    float div=(center.y-uLeft+center.z-vBottom)*float(p.size.y);
    divergence.write(float4(div),cell);
    pressure.write(float4(0),cell);
}
kernel void diskFlowPressure(texture2d<float, access::read> previous [[texture(0)]],
                            texture2d<float, access::read> divergence [[texture(1)]],
                            texture2d<float, access::write> output [[texture(2)]],
                            constant DiskFlowParameters &p [[buffer(0)]], uint2 cell [[thread_position_in_grid]]) {
    if(any(cell >= p.size)) return;
    float neighbors=previous.read(dfCell(int2(cell)+int2(-1,0),p.size)).x
                   +previous.read(dfCell(int2(cell)+int2(1,0),p.size)).x
                   +previous.read(dfCell(int2(cell)+int2(0,-1),p.size)).x
                   +previous.read(dfCell(int2(cell)+int2(0,1),p.size)).x;
    float h=1.0f/float(p.size.y);
    output.write(float4(0.25f*(neighbors-h*h*divergence.read(cell).x)),cell);
}
kernel void diskFlowProject(texture2d<float, access::read> state [[texture(0)]],
                           texture2d<float, access::read> pressure [[texture(1)]],
                           texture2d<float, access::write> output [[texture(2)]],
                           constant DiskFlowParameters &p [[buffer(0)]], uint2 cell [[thread_position_in_grid]]) {
    if(any(cell>=p.size))return;
    float4 value=state.read(cell);
    float center=pressure.read(cell).x;
    float2 gradient=float2(pressure.read(dfCell(int2(cell)+int2(1,0),p.size)).x-center,
                          pressure.read(dfCell(int2(cell)+int2(0,1),p.size)).x-center)*float(p.size.y);
    value.yz=clamp(value.yz-gradient,float2(-0.25f),float2(0.25f));
    if(cell.y==p.size.y-1)value.z=0;
    if(!all(isfinite(value)))value=float4(0.5f,0,0,0);
    output.write(value,cell);
}
"""#
}
