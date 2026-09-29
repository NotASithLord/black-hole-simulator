import Foundation

/// Compile against either the archived native sources or the current shared
/// implementation. This captures every uploaded LUT element, not sample pixels.
@main
struct SharedSwiftNativeFixture {
    static func bits(_ values: [SIMD4<Float>]) -> [UInt32] {
        values.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern, $0.w.bitPattern] }
    }

    static func main() throws {
        var cases = [[String: Any]]()
        for spin in [-0.9999, -0.9, 0.0, 0.82, 0.998, 0.9999] {
            for outer in [30.0, 80.0, 100_000.0] {
                for parameters in [[1e7, 0.001, 0.75], [1e8, 0.1, 0.4], [1e9, 1.0, 1.0]] {
                    let model = DiskModel(spin: spin, massSolar: parameters[0],
                                          accretionSolarMassesPerYear: parameters[1], outerRadius: outer)
                    let table = DiskPhysics.radialTable(for: model)
                    cases.append([
                        "parameters": [spin, parameters[0], parameters[1], outer, parameters[2]],
                        "radialBits": bits(table.values),
                        "metadataFloat": [table.innerRadius, table.outerRadius, table.logRadiusMin,
                                          table.logRadiusStep, table.peakTemperature],
                        "physicalDouble": [DiskPhysics.isco(spin: spin), model.gravitationalTimeSeconds,
                                           model.nominalEfficiency, model.nominalEddingtonRatio],
                        "orbitalPeriod": DiskMotion.orbitalPeriod(radius: 12, spin: spin, massSolar: parameters[0]),
                    ])
                }
            }
        }
        let spectrum = DiskPhysics.spectralTable()
        let result: [String: Any] = [
            "schema": 1,
            "cases": cases,
            "spectralBits": bits(spectrum.values),
            "spectralMetadataFloat": [spectrum.logTemperatureMin, spectrum.logTemperatureStep],
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
    }
}
