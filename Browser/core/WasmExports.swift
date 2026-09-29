// ABI 1 adapter only: every equation and table calculation lives in the shared
// Sources/BlackHolePhysics module, also compiled by the native application.
// Fixed linear-memory arena [110592, 256824). build-wasm.mjs verifies the linked
// static data + 64KiB stack end below this arena. No allocator or memory growth.
private let arenaBase = 110592
private let spectralAddress = arenaBase + 65536
private let factorsAddress = arenaBase + 98304
private let preparationAddress = arenaBase + 131072
private let metadataAddress = arenaBase + 146144

private var tables = DiskTableBuilder(
    radial: .init(start: UnsafeMutablePointer<SIMD4<Float>>(bitPattern: arenaBase), count: 4096),
    spectral: .init(start: UnsafeMutablePointer<SIMD4<Float>>(bitPattern: spectralAddress), count: 2048),
    radialFactors: .init(start: UnsafeMutablePointer<Double>(bitPattern: factorsAddress), count: 4096),
    spectralPreparation: .init(start: UnsafeMutablePointer<SIMD4<Double>>(bitPattern: preparationAddress), count: 471),
    metadata: .init(start: UnsafeMutablePointer<Double>(bitPattern: metadataAddress), count: 11))
private var sourceClock = SharedSourceClock()

@_cdecl("abi_version") public func abiVersion() -> Int32 { 1 }
@_cdecl("radial_ptr") public func radialPointer() -> Int32 { Int32(arenaBase) }
@_cdecl("spectral_ptr") public func spectralPointer() -> Int32 { Int32(spectralAddress) }
@_cdecl("metadata_ptr") public func metadataPointer() -> Int32 { Int32(metadataAddress) }
@_cdecl("radial_count") public func radialCount() -> Int32 { 4096 }
@_cdecl("spectral_count") public func spectralCount() -> Int32 { 2048 }

@_cdecl("init_model")
public func initializeModel(_ spin: Double, _ massSolar: Double, _ accretion: Double,
                            _ outerRadius: Double, _ thickness: Double) -> Int32 {
    let model = DiskModel(spin: spin, massSolar: massSolar,
                          accretionSolarMassesPerYear: accretion, outerRadius: outerRadius)
    return tables.initializeModel(model: model, thicknessMultiplier: thickness) ? 0 : 1
}
@_cdecl("init_spectrum")
public func initializeSpectrum() -> Int32 { tables.initializeSpectrum() }
@_cdecl("isco")
public func innermostOrbit(_ spin: Double) -> Double { SharedDiskPhysics.isco(spin: spin) }
@_cdecl("orbital_period")
public func orbitalPeriod(_ radius: Double, _ spin: Double, _ massSolar: Double) -> Double {
    SharedDiskPhysics.orbitalPeriod(radius: radius, spin: spin, massSolar: massSolar)
}
@_cdecl("advance_clock")
public func advanceClock(_ elapsed: Double, _ rate: Double, _ active: Int32) -> Double {
    sourceClock.advance(elapsed: elapsed, rate: rate, active: active != 0)
    return sourceClock.seconds
}
@_cdecl("clock_seconds") public func clockSeconds() -> Double { sourceClock.seconds }
@_cdecl("reset_clock") public func resetClock() { sourceClock.reset() }
@_cdecl("adaptive_scale")
public func adaptiveScale(_ current: Double, _ measuredMS: Double, _ budgetMS: Double,
                          _ minimum: Double, _ maximum: Double) -> Double {
    SharedDiskPhysics.adaptiveScale(current: current, measuredMS: measuredMS,
        budgetMS: budgetMS, minimum: minimum, maximum: maximum)
}
