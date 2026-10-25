# DwmBoost with EOTF Boost v8.18.7.15

DwmBoost runs the EOTF Boost shader on the **whole Windows 11 desktop** by hooking the desktop compositor (`dwm.exe`) and boosting each composed frame, the way [DesktopLUT](https://github.com/sup3rflyer/DesktopLUT) and the `dwm_lut` family do for desktop color calibration.

The shader is `EOTF_BoostMod3.0.fx` (EOTF Boost v8.18.7.15, calibrated for third-generation TB400 QD-OLED panels). It undoes the automatic brightness limiter (ABL) of the panel with one gain for the whole frame, the measured compensation at the load the boosted frame puts on the panel, where the load is the mean luminance over the panel peak. A rolling full-frame histogram of each pixel's brightest channel measures the frame, a bisection finds the gain that matches its own load, and the gain is smoothed in log2 over time.

A frame boosted this way can show at most the panel peak divided by the gain in any channel. The boost scales each pixel by the tone curve of its brightest channel, so colors keep their channel ratios and no channel passes the peak. Frames that fit under that ceiling show at their source levels. Frames that don't get a shoulder that starts at BT.2390's knee for a source mastered to the panel peak and shown under the ceiling, and the range above the knee is shared out by the frame's own histogram from the ceiling down (Ward Larson, Rushmeier and Piatko 1997), each histogram bin getting no more contrast than the source has.

## The shader in DWM

[`DwmBoost/hook/boost.hlsl`](DwmBoost/hook/boost.hlsl) holds the shader's code unchanged. A short shim maps ReShade's intrinsics onto plain D3D11 (`tex2Dfetch` to `Load`, `tex2Dstore` to a UAV write, storage atomics to `Interlocked` operations, `barrier` to a group sync), the hook's clean copy of the composed desktop stands in for ReShade's back buffer, and the frame time is measured between runs. DWM composes in scRGB, so `BUFFER_COLOR_SPACE` is 2. The debug graph, the calibration LUT and the tooltips are off in the settings below, so they are left out.

The settings are baked in as constants:

| Setting | Value |
|---|---|
| Enable EOTF Boost | On |
| APL Smoothing Time (s) | 0.50 |
| Show APL Stats | Off |
| OSD Brightness | 0.50 |

| Preprocessor definition | Value |
|---|---|
| `APL_FULLFRAME_ROLLING_PHASES` | 6 |
| `ENABLE_APL_GRAPH` | 0 |
| `ENABLE_UI_TOOLTIPS` | 0 |
| `PQHDRLUT_ENABLE` | 0 |

## Using it

While the effect is on it forces DWM composition, which **disables variable refresh rate (VRR)**, so it is turned off for gaming. It applies to the monitor with HDR enabled; other monitors are left untouched.

A tray app injects a hook into `dwm.exe` and keeps it resident. Toggling is instant and reversible:

- **Ctrl+Alt+Shift+End** turns the boost on.
- **Ctrl+Alt+Shift+Home** turns it off, which reverts the composition patches so VRR returns.
- The tray menu has **Enable**, **Disable**, **Install autostart task** (an elevated logon task, no per-launch prompt), and **Quit**. Quit ejects the hook cleanly.

On a static desktop DWM stops composing, so the app nudges the monitor once per refresh with a 1 px corner window after each change, then stops. The histogram takes 6 runs to cover a new frame, and the smoothed gain then closes its gap with a 0.5 s time constant, so the nudging lasts about 3 seconds, until the gain is within half a 10-bit PQ code of where it settles.

The tool injects only into Windows 11 25H2 (build 26200 or later) and refuses to inject if any `dwmcore.dll` byte pattern it relies on is missing or ambiguous, which also guards against a future Windows update changing the compositor.

## Building

The build needs CMake, Ninja or Visual Studio 2022, the MSVC toolchain, and the Windows 10 SDK (for `fxc`). From `DwmBoost/`:

```bash
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

This produces `DwmBoost.exe` and `DwmBoostHook.dll` in `build/bin`. Keep the two together. The build regenerates `hook/boost_bytecode.h` from [`hook/boost.hlsl`](DwmBoost/hook/boost.hlsl) with `fxc`. The executable and tray icons are rendered from [`app/icon.svg`](DwmBoost/app/icon.svg) into the committed `.ico` files; after editing the svg, run `python make_icons.py` in `app/` (needs `resvg-py` and Pillow). MinHook (BSD-2) is vendored under `DwmBoost/third_party/minhook/` with its license.

## Credits

The shader builds on earlier work:

- [DespairArdor/QD-OLED-APL-FIXER](https://github.com/DespairArdor/QD-OLED-APL-FIXER) is the original APL compensation shader.
- [mspeedo/QD-OLED-APL-FIXER](https://github.com/mspeedo/QD-OLED-APL-FIXER) modeled it on measurements of the Samsung Odyssey OLED G8 (G85SB) in Peak 1000 mode and added the rolling full-frame histogram.
- [shansolox/QD-OLED-APL-FIXER](https://github.com/shansolox/QD-OLED-APL-FIXER) added the color-preserving boost and versions for the Aorus FO32U/2/2P and other TB400 QD-OLED monitors.

The DWM hook under `DwmBoost/` is written from scratch to keep the MIT license. [DesktopLUT](https://github.com/sup3rflyer/DesktopLUT) (GPL-3.0) was read for facts and design — the compositor functions involved, the vtable walk, the clean-copy and static-desktop settling approach — but none of its source is copied.

## License

This project uses the MIT License. See [LICENSE](LICENSE).
