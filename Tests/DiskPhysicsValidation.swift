import Foundation

/// Independent scalar checks of the production radial and spectral lookup code.
/// Build with DiskPhysics.swift and CIE1931.swift; no GPU or SwiftUI required.
@main
struct DiskPhysicsValidation {
    static var checks = 0
    static var failures = 0
    static func check(_ condition: Bool, _ label: String, _ details: String = "") {
        checks += 1
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL") \(label) \(details)")
    }
    static func relative(_ a: Double, _ b: Double) -> Double { abs(a - b) / max(1e-30, abs(b)) }

    static func main() {
        check(relative(DiskPhysics.isco(spin: 0), 6) < 1e-14, "Schwarzschild ISCO=6M")
        check(relative(DiskPhysics.isco(spin: 0.998), 1.2369706551751847) < 1e-12, "Kerr a*=0.998 ISCO reference")
        check(DiskPhysics.isco(spin: -0.9999) > 8.999, "Retrograde ISCO tends to9M")
        let model = DiskModel(spin: 0)
        check(relative(model.nominalEfficiency, 1 - sqrt(8.0 / 9)) < 1e-12, "Schwarzschild binding efficiency")

        var maxFluxError = 0.0
        for radius in [6.01, 6.1, 8, 12, 25, 80, 1000] {
            let x = sqrt(radius), x0 = sqrt(6.0), s3 = sqrt(3.0)
            // Analytic integral for a=0, derived independently by substitution
            // x=sqrt(r): integral (1-3/(x²-3))dx, evaluated at sqrt(6)..sqrt(r).
            let analytic = x - x0 - s3 / 2 * log(((x - s3) * (x0 + s3)) / ((x + s3) * (x0 - s3)))
            let logStep = log(radius / 6) / 256
            var numeric = 0.0
            for i in 0..<256 {
                numeric += DiskPhysics.fluxIntegral(from: 6 * exp(Double(i) * logStep), to: 6 * exp(Double(i + 1) * logStep), spin: 0)
            }
            maxFluxError = max(maxFluxError, relative(numeric, analytic))
        }
        check(maxFluxError < 1e-8, "Page–Thorne integral vs analytic Schwarzschild", "max relative error=\(maxFluxError)")

        var maxOrbitError = 0.0
        for a in [-0.9, 0, 0.82, 0.998] {
            for factor in [1.1, 2, 8] {
                let r = DiskPhysics.isco(spin: a) * factor
                let h = r * 1e-5
                let center = DiskPhysics.circularOrbit(radius: r, spin: a)
                let plus = DiskPhysics.circularOrbit(radius: r + h, spin: a)
                let minus = DiskPhysics.circularOrbit(radius: r - h, spin: a)
                let dE = (plus.energy - minus.energy) / (2 * h)
                maxOrbitError = max(maxOrbitError, relative(dE, center.omega * center.angularMomentumDerivative))
                check(relative(center.energy - center.omega * center.angularMomentum, 1 / center.ut) < 1e-12, "Circular four-velocity normalization", "a*=\(a), r=\(r)")
            }
        }
        check(maxOrbitError < 2e-7, "dE/dr = Omega dL/dr", "max relative error=\(maxOrbitError)")

        let base = DiskPhysics.radialTable(for: DiskModel(spin: 0.82), count: 2048)
        let highMdot = DiskPhysics.radialTable(for: DiskModel(spin: 0.82, accretionSolarMassesPerYear: 0.16), count: 2048)
        let highMass = DiskPhysics.radialTable(for: DiskModel(spin: 0.82, massSolar: 400_000_000), count: 2048)
        check(base.values.first!.x == 0 && base.values.first!.y == 0, "Exact zero-torque ISCO flux")
        check(base.values.allSatisfy { $0.x.isFinite && $0.x >= 0 && $0.y >= 0 }, "Finite nonnegative radial temperatures and fluxes")
        check(relative(Double(highMdot.peakTemperature / base.peakTemperature), 2) < 1e-6, "T scales as Mdot^(1/4)")
        check(relative(Double(highMass.peakTemperature / base.peakTemperature), 0.5) < 1e-6, "T scales as mass^(-1/2) at fixed physical Mdot")
        print("Default a*=0.82 peak T=\(base.peakTemperature) K; t_g=\(model.gravitationalTimeSeconds) s")

        for spin in [0.0, 0.82, 0.998] {
            let extended = DiskModel(spin: spin, outerRadius: 100_000)
            let table = DiskPhysics.radialTable(for: extended, count: 16_384)
            let scale = extended.accretionKilogramsPerSecond * pow(DiskPhysics.speedOfLight, 2) / (4 * Double.pi * pow(extended.gravitationalRadiusMeters, 2))
            let logMin = log(DiskPhysics.isco(spin: spin))
            let step = (log(extended.outerRadius) - logMin) / Double(table.values.count - 1)
            var emittedEnergy = 0.0
            for index in table.values.indices {
                let r = exp(logMin + Double(index) * step)
                let weight = index == 0 || index == table.values.count - 1 ? 0.5 : 1.0
                let energy = DiskPhysics.circularOrbit(radius: r, spin: spin).energy
                emittedEnergy += weight * r * r * Double(table.values[index].y) / scale * energy * step
            }
            // At finite Rout the missing outer disk luminosity tends to 3/(2R).
            let residual = abs(emittedEnergy + 1.5 / extended.outerRadius - extended.nominalEfficiency)
            check(residual < 2e-7, "Disk energy conservation (includes all emitted photons)", "a*=\(spin), |L/Mdotc² + tail - efficiency|=\(residual)")
        }

        check(CIE1931.samples.count == 471 && CIE1931.samples.first!.x == 360 && CIE1931.samples.last!.x == 830, "CIE data complete at1nm")
        var sums = SIMD3<Double>(repeating: 0)
        for v in CIE1931.samples { sums += SIMD3(v.y, v.z, v.w) }
        check(relative(sums.x, 106.865469489595) < 1e-12 && relative(sums.y, 106.8569171011719) < 1e-12 && relative(sums.z, 106.892251278636) < 1e-12, "Official CIE metadata column sums")
        let xyz = DiskPhysics.blackbodyXYZ(temperature: 2856)
        let total = xyz.x + xyz.y + xyz.z
        let x = xyz.x / total, y = xyz.y / total
        check(abs(x - 0.44757) < 8e-5 && abs(y - 0.40745) < 8e-5, "2856K blackbody chromaticity near Illuminant A", "xy=(\(x),\(y))")

        var maxShiftError = 0.0
        for g in [0.25, 0.7, 1.5, 3.0] {
            for wavelength in [400e-9, 550e-9, 700e-9] {
                // I_lambda,obs(lambda) = g^5 I_lambda,em(g*lambda).
                // This equals B_lambda(lambda,g*T); g^3 is for I_nu only.
                let shifted = pow(g, 5) * DiskPhysics.planckRadiance(wavelength: g * wavelength, temperature: 20_000)
                let effective = DiskPhysics.planckRadiance(wavelength: wavelength, temperature: g * 20_000)
                maxShiftError = max(maxShiftError, relative(shifted, effective))
            }
        }
        check(maxShiftError < 1e-12, "Liouville redshift equals blackbody at g*T", "max relative error=\(maxShiftError)")
        let spectral = DiskPhysics.spectralTable()
        check(spectral.values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }, "Finite spectral LUT across300..10^7K")
        var maxSpectralError = 0.0
        let referenceY = DiskPhysics.blackbodyXYZ(temperature: 10_000).y
        for temperature in [1000.0, 2856, 6500, 10_000, 37_000, 100_000, 1_000_000] {
            let coordinate = (log(temperature) - Double(spectral.logTemperatureMin)) / Double(spectral.logTemperatureStep)
            let index = Int(floor(coordinate))
            let fraction = Float(coordinate - Double(index))
            let interp = spectral.values[index] * (1 - fraction) + spectral.values[index + 1] * fraction
            let actual = DiskPhysics.blackbodyXYZ(temperature: temperature).y / referenceY
            maxSpectralError = max(maxSpectralError, relative(Double(interp.w), actual))
        }
        check(maxSpectralError < 0.002, "Interpolated spectral luminance", "max relative error=\(maxSpectralError)")
        print("\(checks - failures)/\(checks) checks passed")
        if failures > 0 { exit(1) }
    }
}
