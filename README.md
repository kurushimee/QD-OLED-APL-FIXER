# DwmBoost with EOTF Boost v8.18.7.15

DwmBoost runs the EOTF Boost shader on the **whole Windows 11 desktop** by hooking the desktop compositor (`dwm.exe`) and boosting each composed frame, the way [DesktopLUT](https://github.com/sup3rflyer/DesktopLUT) and the `dwm_lut` family do for desktop color calibration.

The shader is `EOTF_BoostMod3.0.fx` (EOTF Boost v8.18.7.15, calibrated for third-generation TB400 QD-OLED panels). It offsets the automatic brightness limiter (ABL) of the panel: it measures the average picture level (APL) of each frame with a rolling full-frame histogram, solves the APL the panel sees after the boost, smooths it over time, and raises the HDR signal by the measured compensation for that APL, scaled by the boost strength. A PQ highlight roll-off fades the added boost out toward the roll-off target.

## The shader in DWM

[`DwmBoost/hook/boost.hlsl`](DwmBoost/hook/boost.hlsl) holds the shader's code unchanged. A short shim maps ReShade's intrinsics onto plain D3D11 (`tex2Dfetch` to `Load`, `tex2Dstore` to a UAV write, storage atomics to `Interlocked` operations, `barrier` to a group sync), the hook's clean copy of the composed desktop stands in for ReShade's back buffer, and the frame time is measured between runs. The debug graph, the calibration LUT and the tooltips are off in the settings below, so they are left out.

The settings are baked in as constants:

| Setting | Value |
|---|---|
| Enable EOTF Boost | On |
| APL Input Mode | scRGB Normalized |
| APL Reference White (nits) | 150 |
| Compensation Freeze APL % | 80.0 |
| Global APL Boost Strength | 0.25 |
| Enable Per-APL Boost Strength | On |
| APL 3% / 5% / 7% / 10% Boost Strength | 0.25 / 0.25 / 0.26 / 0.26 |
| APL 14% / 18% / 22% / 25% Boost Strength | 0.27 / 0.27 / 0.28 / 0.28 |
| APL 35% / 50% Boost Strength | 0.30 / 0.55 |
| Boost Roll-Off Target (nits) | 800 |
| Boost Roll-Off Shape | 1.20 |
| APL Smoothing Time (s) | 0.50 |
| Preserve Color by Reducing Boost | On |
| scRGB Signal Reference (nits) | 150 |
| Show APL Stats | Off |
| OSD Brightness | 0.50 |

| Preprocessor definition | Value |
|---|---|
| `APL_FULLFRAME_ROLLING_PHASES` | 6 |
| `ENABLE_APL_GRAPH` | 0 |
| `ENABLE_UI_TOOLTIPS` | 0 |
| `PER_APL_BOOST_STRENGTH_ENABLE` | 1 |
| `PQHDRLUT_ENABLE` | 0 |

## Using it

While the effect is on it forces DWM composition, which **disables variable refresh rate (VRR)**, so it is turned off for gaming. It applies to the monitor with HDR enabled; other monitors are left untouched.

A tray app injects a hook into `dwm.exe` and keeps it resident. Toggling is instant and reversible:

- **Ctrl+Alt+Shift+End** turns the boost on.
- **Ctrl+Alt+Shift+Home** turns it off, which reverts the composition patches so VRR returns.
- The tray menu has **Enable**, **Disable**, **Install autostart task** (an elevated logon task, no per-launch prompt), and **Quit**. Quit ejects the hook cleanly.

On a static desktop DWM stops composing, so the app nudges the monitor once per refresh with a 1 px corner window after each change, then stops. The histogram takes 6 runs to cover a new frame, and the smoothed APL then closes its gap with a 0.5 s time constant, so the nudging lasts about 3.5 seconds, until the gain is within half a 10-bit PQ code of where it settles.

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
