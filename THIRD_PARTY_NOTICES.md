# CIE color-matching data

`Sources/BlackHoleDesk/CIE1931.swift` and `Browser/core/cie1931.h` embed the complete
471-row dataset. The compiled browser core, `Browser/public/core.wasm`, includes
the C representation:

CIE 2019, *Colour-matching functions of CIE 1931 standard colorimetric observer*, International Commission on Illumination (CIE), Vienna, AT. DOI: [10.25039/CIE.DS.xvudnb9b](https://doi.org/10.25039/CIE.DS.xvudnb9b).

Source: [official CIE dataset](https://cie.co.at/datatable/cie-1931-colour-matching-functions-2-degree-observer). [Official metadata and license](https://files.cie.co.at/Publications-datasets/CIE_xyz_1931_2deg.csv_metadata.json).

The CIE dataset is licensed under [Creative Commons Attribution-ShareAlike 4.0 International](https://creativecommons.org/licenses/by-sa/4.0/). Its adapted representations in `CIE1931.swift` and `cie1931.h` are distributed under that same license. The changes are CSV-to-Swift and CSV-to-C formatting only: wavelengths, values, and the complete 1 nm interval from 360 to 830 nm are preserved. CIE does not endorse this application. Preserve this attribution and the dataset's license when redistributing the compiled browser core.

Original CSV MD5: `17cca777db64b17170f06f67ce9d3ab7`.

Original CSV SHA-256: `fa663e3535a7e0763a745993a1f0a192eb0275ac46ad2d1befd7626841e713c1`.

## Filmic response fit

`Sources/BlackHoleDesk/CameraResponse.swift` and `Browser/src/camera.wgsl` adapt the rational curve coefficients published by Krzysztof Narkowicz in [ACES Filmic Tone Mapping Curve](https://knarkowicz.wordpress.com/2016/01/06/aces-filmic-tone-mapping-curve/), 6 January 2016. The author offers that fit under CC0 or MIT; this project uses the CC0 option. The adaptation applies the curve to luminance and adds separate gamut compression. It is not an implementation or certification of the full ACES color-management system.

The lens and fluid code is an original implementation of documented numerical approaches. No Interstellar film imagery, textures, measured lens data, or other film assets are included.

## Compiled WebAssembly runtime

`Browser/public/core.wasm` includes statically linked WASI libc and musl math
routines from WASI SDK 33, whose WASI libc revision is
[`161b3195fc2558d2b1ba3eb9ffae3b2b47407623`](https://github.com/WebAssembly/wasi-libc/tree/161b3195fc2558d2b1ba3eb9ffae3b2b47407623).
The MIT option is used for the WASI libc portions and changes that offer it;
the included musl, Arm, and Sun Microsystems notices remain applicable to
their respective portions. Full permission/disclaimer texts, math notices,
and the audited linked-object list are retained in [licenses/](licenses/README.md).
Preserve that directory and this notice with the prebuilt core and deployed
browser application. The compiler toolchain itself is not distributed.
