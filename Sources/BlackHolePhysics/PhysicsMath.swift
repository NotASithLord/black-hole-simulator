// The numerical model is shared unchanged by native Swift and Embedded Swift.
// Only the standard mathematical-function linkage differs by platform. The
// WebAssembly target links the ordinary, IEEE-preserving WASI libm statically.
// Swift's IEEE squareRoot intrinsic maps directly to native/WASM hardware sqrt,
// avoiding an otherwise unnecessary external call in the quadrature hot loop.
@inline(__always) func physicsSqrt(_ value: Double) -> Double { value.squareRoot() }

#if arch(wasm32)
@_extern(c, "cbrt") func physicsCbrt(_ value: Double) -> Double
@_extern(c, "log") func physicsLog(_ value: Double) -> Double
@_extern(c, "exp") func physicsExp(_ value: Double) -> Double
@_extern(c, "expm1") func physicsExpm1(_ value: Double) -> Double
@_extern(c, "pow") func physicsPow(_ value: Double, _ exponent: Double) -> Double
#elseif canImport(Darwin)
import Darwin
@inline(__always) func physicsCbrt(_ value: Double) -> Double { Darwin.cbrt(value) }
@inline(__always) func physicsLog(_ value: Double) -> Double { Darwin.log(value) }
@inline(__always) func physicsExp(_ value: Double) -> Double { Darwin.exp(value) }
@inline(__always) func physicsExpm1(_ value: Double) -> Double { Darwin.expm1(value) }
@inline(__always) func physicsPow(_ value: Double, _ exponent: Double) -> Double { Darwin.pow(value, exponent) }
#else
import Glibc
@inline(__always) func physicsCbrt(_ value: Double) -> Double { Glibc.cbrt(value) }
@inline(__always) func physicsLog(_ value: Double) -> Double { Glibc.log(value) }
@inline(__always) func physicsExp(_ value: Double) -> Double { Glibc.exp(value) }
@inline(__always) func physicsExpm1(_ value: Double) -> Double { Glibc.expm1(value) }
@inline(__always) func physicsPow(_ value: Double, _ exponent: Double) -> Double { Glibc.pow(value, exponent) }
#endif
