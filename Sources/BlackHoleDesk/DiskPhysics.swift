// Native collection adapters around the same Swift numerical core compiled to WASM.
#if canImport(BlackHolePhysics)
import BlackHolePhysics
typealias DiskModel = BlackHolePhysics.DiskModel
typealias DiskPhysics = BlackHolePhysics.SharedDiskPhysics
typealias DiskTableBuilder = BlackHolePhysics.DiskTableBuilder
typealias SharedSourceClock = BlackHolePhysics.SharedSourceClock
typealias CIE1931 = BlackHolePhysics.CIE1931
#else
typealias DiskPhysics = SharedDiskPhysics
#endif

struct DiskRadialTable {
    /// T_eff[K], flux[W/m² per face], orbital frequency[inverse M], u^t.
    let values: [SIMD4<Float>]
    let innerRadius: Float
    let outerRadius: Float
    let logRadiusMin: Float
    let logRadiusStep: Float
    let peakTemperature: Float
}

struct DiskSpectralTable {
    /// Linear sRGB and CIE Y in one fixed 10,000 K luminance reference unit.
    let values: [SIMD4<Float>]
    let logTemperatureMin: Float
    let logTemperatureStep: Float
}

extension DiskPhysics {
    static func radialTable(for model: DiskModel, count: Int = 4096) -> DiskRadialTable {
        precondition(count >= 2)
        var values = [SIMD4<Float>](repeating: .zero, count: count)
        var factors = [Double](repeating: 0, count: count)
        var metadata = [Double](repeating: 0, count: 11)
        values.withUnsafeMutableBufferPointer { radial in
            factors.withUnsafeMutableBufferPointer { factors in
                metadata.withUnsafeMutableBufferPointer { metadata in
                    var builder = DiskTableBuilder(radial: radial,
                        spectral: .init(start: nil, count: 0), radialFactors: factors,
                        spectralPreparation: .init(start: nil, count: 0), metadata: metadata)
                    precondition(builder.initializeModel(model: model, thicknessMultiplier: 0),
                                 "Invalid physical disk model")
                }
            }
        }
        return DiskRadialTable(values: values, innerRadius: Float(metadata[0]),
            outerRadius: Float(metadata[1]), logRadiusMin: Float(metadata[2]),
            logRadiusStep: Float(metadata[3]), peakTemperature: Float(metadata[4]))
    }

    static func spectralTable(count: Int = 2048) -> DiskSpectralTable {
        precondition(count >= 2)
        var values = [SIMD4<Float>](repeating: .zero, count: count)
        var preparation = [SIMD4<Double>](repeating: .zero, count: 471)
        var metadata = [Double](repeating: 0, count: 11)
        values.withUnsafeMutableBufferPointer { spectral in
            preparation.withUnsafeMutableBufferPointer { preparation in
                metadata.withUnsafeMutableBufferPointer { metadata in
                    var builder = DiskTableBuilder(radial: .init(start: nil, count: 0),
                        spectral: spectral, radialFactors: .init(start: nil, count: 0),
                        spectralPreparation: preparation, metadata: metadata)
                    precondition(builder.initializeSpectrum() == 0)
                }
            }
        }
        return DiskSpectralTable(values: values, logTemperatureMin: Float(metadata[5]),
                                 logTemperatureStep: Float(metadata[6]))
    }
}
