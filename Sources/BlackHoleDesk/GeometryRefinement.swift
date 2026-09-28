import Metal

/// Extra geodesics only at image/occlusion boundaries. Sparse storage keeps
/// sixteen edge samples from multiplying the full-frame transfer-map memory.
final class GeometryRefinement {
    private let device: MTLDevice
    private let mark: MTLComputePipelineState
    private let refine: MTLComputePipelineState
    private let neutralLookup: MTLTexture
    private let neutralHits: MTLBuffer
    private var pixelList: MTLBuffer?
    private var allocationKey = ""
    private(set) var lookup: MTLTexture
    private(set) var hits: MTLBuffer

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        mark = try device.makeComputePipelineState(function: library.makeFunction(name: "markGeometryEdges")!)
        refine = try device.makeComputePipelineState(function: library.makeFunction(name: "refineGeometryEdges")!)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint, width: 1, height: 1, mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead, .shaderWrite]
        neutralLookup = device.makeTexture(descriptor: d)!
        var zero: UInt32 = 0
        neutralLookup.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        neutralHits = device.makeBuffer(length: 16, options: .storageModeShared)!
        lookup = neutralLookup; hits = neutralHits
    }

    @discardableResult
    func prepare(width: Int, height: Int, samples: Int, capacity: Int) -> Bool {
        let key = "\(width),\(height),\(samples),\(capacity)"
        guard key != allocationKey else { return false }; allocationKey = key
        guard samples > 0 && capacity > 0 else {
            lookup = neutralLookup; hits = neutralHits; pixelList = nil; return true
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint, width: width, height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
        lookup = device.makeTexture(descriptor: d)!
        hits = device.makeBuffer(length: capacity * samples * 16, options: .storageModePrivate)!
        pixelList = device.makeBuffer(length: capacity * 8, options: .storageModePrivate)!
        return true
    }

    /// Returns a per-build counter; retaining it in the completion callback is
    /// race-free even if another map build is already queued. GPU clear avoids
    /// CPU writes into a resource that an in-flight command could still read.
    func encode(command: MTLCommandBuffer, mapping: MTLTexture, uniforms: Uniforms) -> MTLBuffer? {
        guard uniforms.edgeSamples > 0, uniforms.edgeCapacity > 0, let pixelList else { return nil }
        var u = uniforms
        let counter = device.makeBuffer(length: 4, options: .storageModeShared)!
        let clear = command.makeBlitCommandEncoder()!
        clear.fill(buffer: counter, range: 0..<4, value: 0); clear.endEncoding()
        let markEncoder = command.makeComputeCommandEncoder()!
        markEncoder.label = "Find thin arcs and occlusion edges"
        markEncoder.setComputePipelineState(mark)
        markEncoder.setTexture(mapping, index: 0); markEncoder.setTexture(lookup, index: 1)
        markEncoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        markEncoder.setBuffer(pixelList, offset: 0, index: 1); markEncoder.setBuffer(counter, offset: 0, index: 2)
        markEncoder.dispatchThreads(.init(width: Int(u.resolution.x), height: Int(u.resolution.y), depth: 1), threadsPerThreadgroup: .init(width: mark.threadExecutionWidth, height: 4, depth: 1))
        markEncoder.endEncoding()
        let refineEncoder = command.makeComputeCommandEncoder()!
        refineEncoder.label = "Stratified supersampling of cached edges"
        refineEncoder.setComputePipelineState(refine)
        refineEncoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        refineEncoder.setBuffer(pixelList, offset: 0, index: 1); refineEncoder.setBuffer(hits, offset: 0, index: 2)
        refineEncoder.setBuffer(counter, offset: 0, index: 3)
        refineEncoder.dispatchThreads(.init(width: Int(u.edgeCapacity), height: Int(u.edgeSamples), depth: 1), threadsPerThreadgroup: .init(width: refine.threadExecutionWidth, height: 1, depth: 1))
        refineEncoder.endEncoding()
        return counter
    }
}
