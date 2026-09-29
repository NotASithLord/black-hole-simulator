# Black Hole Desk

A real-time black-hole simulator for macOS and the browser, with Kerr gravitational
lensing, an animated accretion disk and cinematic lighting.

The native app uses Swift and Metal, including a desktop wallpaper mode. The browser
version uses WebAssembly and WebGPU, with lightweight defaults and adaptive quality.

## Run on macOS

Requires Apple Silicon, macOS 14+ and Apple Command Line Tools. From the repository root:

```sh
bash build.sh --run
```

Builds and opens `outputs/BlackHoleDesk.app`. The app is signed for local use, not notarized.

## Run in a browser

Requires Node.js 18+ and a browser with WebGPU and hardware acceleration:

```sh
node Browser/tools/build.mjs
node Browser/tools/serve.mjs
```

Open [localhost:8765](http://127.0.0.1:8765/). There is no WebGL fallback.
The browser build is also deployable to any HTTPS static host.

## Controls

Drag to orbit, right-drag to look around, scroll to zoom, and use `W A S D Q E`
to move. `R` resets the camera; `H` toggles the HUD. On macOS,
`Shift–Command–W` toggles wallpaper mode.

The controls panel adjusts quality, disk rotation, time-lapse, exposure and glow.

## Physics and presentation

Light paths follow Kerr spacetime. Scientific mode uses a thermal thin disk;
Radiant adds art-directed material and photographic effects. This is a visualization
of a physical model—not a full relativistic fluid simulation. No film assets are used.

See the [native guide](docs/NATIVE_APP.md), [browser guide](Browser/README.md),
[physics details](docs/DISK_MODEL.md) and [performance notes](Browser/PERFORMANCE.md).
Latest cross-browser GPU validation is still pending.

## Tests

```sh
npm --prefix Browser test  # Offline browser checks
bash verify.sh            # Native checks; requires a Metal-capable Mac
```

## License

Original code is [MIT licensed](LICENSE). Third-party components retain their own
licenses, including the CIE dataset's CC BY-SA 4.0 license. See
[third-party notices](THIRD_PARTY_NOTICES.md).
