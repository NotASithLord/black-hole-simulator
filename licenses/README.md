# Browser WebAssembly runtime notices

The prebuilt `Browser/public/core.wasm` contains compiler-specialized Swift
standard-library/Embedded Swift support and statically linked WASI libc math
routines. Keep this directory and `THIRD_PARTY_NOTICES.md` with redistributions
of that binary, including the static browser build. These notices do not grant
a license to this project's original source code, which is covered separately
by the root MIT `LICENSE` file.

## Exact provenance

- Compiler release: [Swift 6.4.0](https://github.com/swiftlang/swift/tree/swift-6.4.0-RELEASE),
  using Embedded Swift with whole-module optimization and no heap allocation.
- The official macOS package is signed by Swift Open Source, notarized by Apple,
  and integrity-pinned by `Browser/tools/build-wasm.mjs`. Its SHA-256 is
  `8fd03185b98fe27f54a54631c2449decf75d5b466ce8e34abbd414141063c6aa`.
- `SWIFT-LICENSE.txt` is an unchanged copy of the license distributed in that
  package. It matches the [Swift 6.4.0 release license](https://github.com/swiftlang/swift/blob/swift-6.4.0-RELEASE/LICENSE.txt)
  with SHA-256 `770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55`.
- Linker and math library release: [WASI SDK 33](https://github.com/WebAssembly/wasi-sdk/tree/wasi-sdk-33).
  That release pins WASI libc to
  [`161b3195fc2558d2b1ba3eb9ffae3b2b47407623`](https://github.com/WebAssembly/wasi-libc/tree/161b3195fc2558d2b1ba3eb9ffae3b2b47407623).
- Both toolchain archive digests are pinned by `Browser/tools/build-wasm.mjs`.
- [`Browser/public/core-build.json`](../Browser/public/core-build.json) records
  the current binary SHA-256, all shared Swift/ABI source hashes, sanitized
  compiler/linker arguments, fixed memory layout, and linked runtime objects.
  The builder emits this manifest together with the verified module. No local
  user paths, machine names, timestamps, or author metadata are included.

The linked runtime object files are `cbrt.c`, `exp.c`,
`expm1.c`, `log.c`, `exp_data.c`, `log_data.c`, `__math_xflow.c`,
`__math_uflow.c`, `__math_oflow.c`, `__math_divzero.c`, `__math_invalid.c`,
and `exit.c`. The `exit.c` contribution was the dummy/destructor-call support,
not a WASI system-call dependency. The binary has no host imports.

## Retained terms

- `SWIFT-LICENSE.txt`: Apache License 2.0 with Swift's Runtime Library Exception,
  unchanged from the official package. Swift's compiler-specialized standard
  library and support routines are unmodified upstream code. The Embedded Swift
  runtime identifies its copyright as Apple Inc. and the Swift project authors;
  see the [release source](https://github.com/swiftlang/swift/blob/swift-6.4.0-RELEASE/stdlib/public/core/EmbeddedRuntime.swift).
- `WASI-LIBC-LICENSE.txt`: upstream multi-license overview, unchanged.
- `WASI-LIBC-MIT.txt`: upstream MIT option for WASI libc and its changes.
  This distribution selects that option where WASI libc offers a choice.
- `MUSL-COPYRIGHT.txt`: the complete upstream musl copyright and permission file.
- `MUSL-MATH-NOTICES.txt`: verbatim Sun Microsystems and Arm notices from the
  linked math source files, with source paths and immutable links.

The CIE data embedded by the physics core retains its separate CC BY-SA 4.0
terms described in `THIRD_PARTY_NOTICES.md`; it is not relicensed under MIT.
Compiler toolchains and the development-only shader validator are not included
in the distributed application. Recheck the link map and applicable notices if
the compiler, runtime, or physics core's library dependencies change.
