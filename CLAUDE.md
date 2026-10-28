# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ABL compensation for the Philips Evnia 27M2N6500 QD-OLED in HDR Peak 1000 mode. Each frame's APL is measured, the gain that cancels the panel's dimming comes from a measured table, and the frame is boosted and tonemapped under the panel peak. `README.md` explains the algorithm in detail and is the user-facing spec, so keep it in step with behavior changes. The project has three parts:

- `Shaders/EOTF_BoostMod2.0_27M2N6500.fx` is the main ReShade shader for games, and the one the README documents
- `DwmBoost/` runs the same compensation desktop-wide by hooking `dwm.exe`, and its output has to match the 2.0 shader at its default settings
- `Shaders/ABL_NullTest.fx` is a by-eye test pattern that checks the compensation against the real panel

`Shaders/EOTF_BoostMod3.0.fx` is a separate line, the upstream v8.18.7.15 shader with local tweaks. It has its own algorithm, nothing else mirrors it, and the README doesn't cover it

`research.md` is a reading list on panel load models, the Samsung controller, timing and tonemapping. `abl_curve.csv` is the raw measurement the compensation table comes from

## Things that have to stay in sync

- The `APL_ANCHORS` compensation table (log2 APL percent, log2 compensation) has copies in the 2.0 shader, `DwmBoost/hook/boost.hlsl` and `DwmBoost/verify/parity_check.py`
- `boost.hlsl` mirrors the 2.0 shader's math. A change to one usually needs the same change in the other and in the CPU mirror in `parity_check.py`, whose baked constants at the top must match `boost.hlsl`
- `DwmBoost/hook/pipeline.h` holds the histogram and curve geometry, which must match `boost.hlsl`, and the settle frame and second counts. `parity_check.py` reads `pipeline.h` and `ABL_NullTest.fx` directly and checks the settle counts still cover the slowest convergence and smoothing ease
- `DwmBoost/hook/boost_bytecode.h` is generated from `boost.hlsl` by `compile_shaders.cmd` during the CMake build. Never edit it by hand, and commit the regenerated file with any `boost.hlsl` change
- `DwmBoost/shared/ipc.h` is the contract between the tray app and the hook DLL (exported function names, init status codes, named shared objects)

## Commands

Everything builds with MSVC only, and there's no test framework. Verification is the parity check plus the two GPU renderers

Build DwmBoost (needs the Windows 10 SDK for `fxc`), from `DwmBoost/`:

```bash
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

This puts `DwmBoost.exe`, `DwmBoostHook.dll` and `RenderFrame.exe` in `build/bin/Release`

Run the CPU parity check, from `DwmBoost/verify/`:

```bash
python parity_check.py
```

Run the hook's GPU pipeline on a saved 16-bit PQ BT.2020 PNG (like a ReShade HDR screenshot) until the gain settles:

```bash
RenderFrame source.png boosted.png
```

Build and run a ReShade effect on a saved frame the way ReShade 6.8 runs it in a D3D11 game, from `Shaders/verify/` (CMake fetches ReShade's effect compiler and `ReShade.fxh`):

```bash
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
build/bin/Release/RenderEffect ../EOTF_BoostMod2.0_27M2N6500.fx hdr10 source.png out.png -D NAME=VALUE uniform=value
```

`scrgb` in place of `hdr10` runs it on an FP16 scRGB back buffer. After editing `DwmBoost/app/icon.svg`, run `python make_icons.py` in `DwmBoost/app/` (needs `resvg-py` and Pillow) to regenerate the committed `.ico` files

## DwmBoost architecture

- `app/main.cpp` is the tray host. It injects `DwmBoostHook.dll` into `dwm.exe`, calls its exports on remote threads, writes the config into shared memory, handles the hotkeys and the autostart task, and nudges a static desktop with a 1 px window so DWM keeps composing until the gain settles
- `hook/locate.cpp` finds `dwmcore.dll` internals by byte patterns pinned to Windows 11 build 26200 and later. Every pattern must match exactly once, or init refuses
- `hook/flip_disable.cpp` patches DWM to force composition while the boost is on (this disables VRR) and reverts it on disable
- `hook/present_hook.cpp` hooks present with MinHook and runs the pipeline only on the 27M2N6500. The present path reads a config mirror in atomics that a watcher thread fills, never the shared memory itself
- `hook/pipeline.cpp` runs the D3D11 passes from `boost.hlsl` (`CS_Setup`, `CS_Build`, `CS_Reduce`, `CS_Solve`, then `VS_Boost` and `PS_Boost`) and is shared with `RenderFrame`

The hook DLL links the static CRT (`/MT`) because it lives inside `dwm.exe`. MinHook is vendored under `third_party/` and stays untouched

## Implementation plans

Feature and tool work starts in `plans/` and follows [plans/README.md](plans/README.md)
