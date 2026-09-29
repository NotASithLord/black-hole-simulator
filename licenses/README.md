# Browser WebAssembly runtime notices

The prebuilt `Browser/public/core.wasm` contains statically linked routines from
WASI libc. Keep this directory and `THIRD_PARTY_NOTICES.md` with redistributions
of that binary, including the static browser build. These notices do not grant
a license to this project's original source code, which is covered separately
by the root MIT `LICENSE` file.

## Exact provenance

- Compiler release: [WASI SDK 33](https://github.com/WebAssembly/wasi-sdk/tree/wasi-sdk-33).
- That release pins WASI libc to
  [`161b3195fc2558d2b1ba3eb9ffae3b2b47407623`](https://github.com/WebAssembly/wasi-libc/tree/161b3195fc2558d2b1ba3eb9ffae3b2b47407623).
- The SDK archive is integrity-pinned by `Browser/tools/build-wasm.mjs`.
- A link-map audit reproduced the distributed module byte-for-byte on
  2026-09-28. Its SHA-256 was
  `6c1243eab54d4b3a3d845b71dcae5b326537ee4aa4e7430b97fa98ac84a7a5e1`.

The linked runtime object files were `fmin-fmax.c`, `cbrt.c`, `exp.c`,
`expm1.c`, `log.c`, `exp_data.c`, `log_data.c`, `__math_xflow.c`,
`__math_uflow.c`, `__math_oflow.c`, `__math_divzero.c`, `__math_invalid.c`,
and `exit.c`. The `exit.c` contribution was the dummy/destructor-call support,
not a WASI system-call dependency. The binary has no host imports.

## Retained terms

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
