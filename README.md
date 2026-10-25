# EOTF Boost for the Philips Evnia 27M2N6500

This ReShade shader offsets the automatic brightness limiter (ABL) of the **Philips Evnia 27M2N6500**, a 27-inch 1440p third-generation QD-OLED monitor, in **HDR Peak 1000** mode.

QD-OLED panels get dimmer when a large part of the screen is bright. On this panel, a small highlight reaches the full peak of about 1000 nits, but a full white screen reaches only about a quarter of it. The shader measures how bright each frame is and raises the HDR signal by the amount the panel is expected to dim, so bright scenes keep their intended brightness. It works much like the "EOTF Boost" option on some MSI QD-OLED monitors.

The shader file is [`Shaders/EOTF_BoostMod2.0_27M2N6500.fx`](Shaders/EOTF_BoostMod2.0_27M2N6500.fx).

## Calibration target

The built-in data matches this setup:

| Setting | Value |
|---|---|
| Monitor | Philips Evnia 27M2N6500 |
| Monitor HDR mode | HDR Peak 1000 |
| Windows HDR | On |
| Peak luminance in the Windows HDR color profile | 1060 nits, the measured peak at 3% APL |

Other monitors and other HDR modes dim in a different way, so on them the shader boosts too much or too little. To use it with another display, replace the measured data as described in [Adapting to another monitor](#adapting-to-another-monitor).

## Requirements

- A game that outputs HDR as either HDR10 (PQ) or scRGB.
- ReShade with its standard shader package, which provides `ReShade.fxh`.
- A game that runs on DirectX 11, DirectX 12, or Vulkan. The shader uses compute shaders, which ReShade does not support on DirectX 9 or 10.
- G-Sync or another VRR mode with a frame cap at or under the refresh rate, and no frame generation. The panel dims each refresh for the load of the refresh before it, and the shader can only follow the frames it processed, so each refresh has to show exactly one of them.

## Installation

1. Install ReShade for the game and include the standard effects package.
2. Copy `EOTF_BoostMod2.0_27M2N6500.fx` into the game's `reshade-shaders\Shaders` folder.
3. Open the ReShade overlay and turn on **EOTF_Boost_1D_APL_LUT**.
4. Move it to the bottom of the effect list, so it works on the final image that the monitor receives.

The default settings match the calibration target, so most setups need no changes.

## How it works

1. **Measure the scene.** The shader builds a brightness histogram of the full frame, every frame, and finds the average picture level (APL) from it. Each pixel counts toward the APL the way it loads the panel, from the panel's own red, green, and blue: partly by its brightest subpixel and partly by the mean of all three, so a pure primary loads the panel 0.75 as much as white at the same channel level and gray loads it at its luma.
2. **Look up the compensation.** A measured table tells how much the panel dims at each APL. For example, at 25% APL the panel reaches only about 37% of its peak, so the scene needs about 2.72 times more signal.
3. **Account for its own boost.** Boosting the image raises the APL, and a higher APL makes the panel dim even more. The shader measures each frame's APL with the boost applied, which is the APL the panel actually sees.
4. **Cancel the dimming the panel applies.** The panel dims each frame for the APL of the frame before it, the last one it has fully received. With **APL Smoothing Time** at 0, the full gain for each frame is the compensation for that APL, so every frame is compensated for exactly the dimming it gets, including the first frame after a cut, except the first frame after a lower gain lets go (step 6). When the boost changes the APL, the gain settles over the next few frames while each of those frames still gets the right brightness. Above 0, that loop keeps running on its own without being shown, and the shown gain eases toward the gain the loop settles on, including the lower gain of step 6. The ease runs on the APL each gain compensates, and its gap shrinks by about two thirds each smoothing time. Brightness changes then come in gradually and move one way, and frames during a change get somewhat more or less than the dimming calls for.
5. **Apply the boost.** Levels at full gain show as bright as they do at 3% APL. The panel cannot show more than its peak divided by the gain, the ceiling, so the boost tonemaps the whole frame into the panel's range. Nothing goes past the panel peak and nothing clips. Every frame the boost curve is fitted to that frame's histogram, which is ready before the boost runs, so the fit adds no delay. The brightest pixel on screen lands on the panel peak. Content the panel can show keeps the full gain where the room allows, and content above the ceiling keeps at most a quarter of its PQ contrast. Each level weighs the detail its pixels would lose if it were flattened against the pixels above it that keeping it would shift down, counting both their shift and the contrast it costs them against the rest of the frame. So the room comes from empty and sparse levels first, from the top down. A small highlight gives up mostly its own contrast, a large one also dims what sits under it, and a few stray pixels move nothing else. A fixed shoulder that depends only on the gain eases from a knee to a quarter of the PQ contrast and lands a 10000-nit signal on the panel peak. Its knee runs from 419 nits at a gain of 1 down to 73 nits at the highest gain of 3.77. The fitted curve never goes under the fixed shoulder or flatter than it, so no two levels ever merge, even across levels nothing on screen uses. Below the knee, nothing ever moves. Above it, levels follow what is on screen. They are exact when nothing needs the room, and they go down to the fixed shoulder's values, never further, when big bright content fills it.
6. **Lower the gain when the frame cannot fit.** When bright content fills most of the screen, most of the picture sits above the ceiling and would keep only a quarter of its contrast. So every frame the boost also fits the curve at lower gains and keeps the gain that costs the frame the least. Each pixel pays for how far it lands under its exact level, for how far its contrast against every other pixel is off, and for the fine detail it loses. A frame that fits keeps the full gain, and a frame like a sunlit snowfield shows dimmer than the full gain everywhere and keeps its shading. When the content stops needing the lower gain, the loop starts again from the gain it showed, so a smoothed change heads straight for the new gain. Without smoothing, that first frame keeps the lower gain and shows dimmer than the panel's dimming calls for.

Luma drives the boost, and all three color channels scale by the same amount, so colors keep their hue. The brightest color channel follows the same curve, which keeps it under the panel peak.

The analysis runs only while the boost or the stats display is on.

## Measured data

The table holds the peak the panel reaches with a full-signal window at each size from 3% to 100% of the screen, where the window size equals the APL. The compensation for each APL equals the 1060-nit peak at 3% APL divided by the peak at that APL.

| APL | Measured peak (nits) | Compensation |
|---:|---:|---:|
| 3% | 1060.0 | 1.000 |
| 4% | 923.6 | 1.148 |
| 5% | 812.0 | 1.305 |
| 6% | 719.1 | 1.474 |
| 7% | 643.4 | 1.647 |
| 8% | 583.7 | 1.816 |
| 9% | 534.4 | 1.984 |
| 10% | 493.0 | 2.150 |
| 11% | 478.8 | 2.214 |
| 12% | 469.8 | 2.256 |
| 13% | 459.8 | 2.305 |
| 14% | 451.7 | 2.347 |
| 15% | 442.4 | 2.396 |
| 17% | 430.6 | 2.462 |
| 20% | 412.3 | 2.571 |
| 22% | 404.0 | 2.624 |
| 25% | 389.8 | 2.719 |
| 27% | 381.5 | 2.779 |
| 30% | 373.2 | 2.840 |
| 35% | 361.7 | 2.931 |
| 40% | 348.1 | 3.045 |
| 50% | 328.6 | 3.226 |
| 75% | 299.2 | 3.543 |
| 100% | 281.2 | 3.770 |

Below 3% APL the gain is 1, and the curve only makes room for content brighter than the panel peak. Between the points, it interpolates the logarithm of the peak against the logarithm of the APL, so the peak follows a power law from one point to the next.

## Settings

| Setting | Default | What it does |
|---|---|---|
| Enable EOTF Boost | On | Turns the brightness compensation on or off. |
| Input Signal | Auto | Picks how to read the game's HDR output: **Auto**, **PQ (HDR10)**, or **scRGB**. Auto follows the format that ReShade reports and falls back to PQ. |
| APL Reference White (nits) | 1060 | Sets the brightness that counts as 100% APL. Keep it at the calibrated peak. A higher value makes scenes read darker, which lowers the boost. |
| Panel Peak (nits) | 1060 | Sets the peak signal the boost tonemaps into. Nothing is shown above it, and brighter content is compressed under it instead of clipped. 0 turns highlight protection off. |
| APL Smoothing Time (s) | 0.5 | Eases the gain toward a new scene's over this time instead of following it exactly from the next frame. 0 turns smoothing off. |
| scRGB Signal Reference (nits) | 80 | Sets the brightness of scRGB value 1.0. It only matters for scRGB games. |
| Show APL Stats | Off | Shows live numbers in the top right corner. |
| Show Compression | Off | While the boost is on, shows the image in gray and tints each pixel that shows dimmer than the full gain would show it, from yellow for a slight cut to red for the deepest. |
| OSD Brightness | 0.5 | Sets the brightness of the stats display and the debug graph. It does not change the image. |

The stats display has three rows:

| Row | Meaning |
|---|---|
| RAW APL | APL of the game's image before the boost. |
| OUT APL | APL that the panel sees after the boost. |
| KNEE NIT | Output level where the curve first leaves the full gain, in nits. It turns orange while that level sits under the panel peak, so some levels the panel could show come out dimmer than the full gain. It reads 0 while the boost holds the whole frame under the full gain. Otherwise it shows the panel peak in gray. |

## Preprocessor definitions

These options are set in the ReShade overlay, in the shader's preprocessor definitions.

| Definition | Default | What it does |
|---|---|---|
| `PQHDRLUT_ENABLE` | 0 | 1 adds a 3D calibration LUT that runs after the boost. |
| `PQHDRLUT_SIZE` | 65 | Sets the edge size of the calibration LUT. |
| `ENABLE_APL_GRAPH` | 0 | 1 adds a debug graph of the boost curve. |
| `ENABLE_UI_TOOLTIPS` | 0 | 1 adds a tooltip to each setting. |

### Calibration LUT

With `PQHDRLUT_ENABLE=1`, the shader loads `PQHDRLUT.cube` from ReShade's texture folders and adds an **Enable PQ HDR LUT** setting. The LUT takes and returns PQ-encoded Rec.2020 values. It runs on the boosted signal, or on the plain signal when the boost is off. For scRGB games, the shader converts the image to PQ Rec.2020 before the LUT and back after it.

### Debug graph

With `ENABLE_APL_GRAPH=1`, the shader can draw a graph of input nits against output nits. It shows the identity line, the measured panel response, the boosted signal, the predicted panel output, and an optional BT.2390-style reference curve. The graph can use either a fixed APL or a measured window size of 100%, 50%, 25%, 15%, or 10%. It is a tuning aid and does not change the image.

The graph's 2D compensation table and window curves come from earlier measurements of the Samsung Odyssey OLED G8 (G85SB), not of the 27M2N6500. The live boost does not use them.

## Null test

[`Shaders/ABL_NullTest.fx`](Shaders/ABL_NullTest.fx) checks the compensation by eye, with no measuring gear. Copy it next to the boost, turn on **ABL_NullTest**, and move it above **EOTF_Boost_1D_APL_LUT** in the effect list so the boost analyzes the pattern. It writes the format ReShade reports, so keep the boost's **Input Signal** on **Auto**. For the checks that run with the boost on, set its **APL Smoothing Time** to 0, since the patches expect the compensation to follow the panel's dimming from the next frame.

The pattern is a grid of nine gray patches inside a wide black gap. The rest of the screen switches once a second between state A, the first content in the test's name, and state B, the second. The middle patch keeps its level in both states. In state B the others change by 2% steps, starting one frame after the switch, when the panel's own dimming follows the load:

| | Left | Middle | Right |
|---|---:|---:|---:|
| **Top** | -7.6% | -5.8% | -3.9% |
| **Middle** | -2.0% | 0 | +2.0% |
| **Bottom** | +4.0% | +6.1% | +8.2% |

The panel dims all nine alike, so the patch that holds still shows how much more the panel dims state B than the model expects, and the middle one holds still when the model is right. Report the patch that holds still, or the two it falls between. A short blink that all nine share at a switch is no reading, so judge which patch keeps its level after it. Watch only the grid, through a paper tube or cupped hands so the rest of the screen is out of view. The eye judges a patch against its surroundings, so with the changing load in view the patches seem to change even when they do not. Keep the frame rate at or under the refresh rate, as G-Sync with a frame cap does, so each frame is one refresh.

| Test | Boost | What it checks |
|---|---|---|
| Gray vs white window | Off | Whether a small bright window loads the panel the same as a dim fill with the same total light. |
| Gray vs red, green, or blue | Off | Whether the panel's own red, green, or blue primary, taken from its EDID, loads it as the boost's load model counts it. |
| Gray vs pastel red | Off | Whether a color halfway between the panel's red and white loads it as the load model counts it, which covers how mixed colors fall between a primary and white. |
| Panel latency | Off | How many frames the panel's dimming lags behind a load change. |
| Out APL 3% vs 6% through 50% vs 80% | On | How far the compensation table is off at one load relative to the other. |
| Bright window, 150 nit patches | On | Whether a bright highlight coming into view leaves lower levels alone. |
| Bright window, 150 nit patches | Off | Whether a near-peak window loads the panel the same as a fill with the same light. |
| Shadow, 1 nit patches, out APL 3% vs 50% | On | Whether the panel dims near-black as much as brighter levels, so shadows get the right gain. |
| Low end, APL 1% vs 3% | Off | Whether the panel holds its peak below 3% APL, where the measured table starts. |

In the model checks with the boost off, both states carry a 5% APL load as the boost counts it, and the RAW APL row of the stats display reads the same in both. The KNEE NIT row there shows what the boost would do if it were on, so it can be ignored. A still patch away from the middle means the panel treats one content as a heavier or lighter load than the boost counts. In the curve checks, the OUT APL row lands on the named loads, and the patches sit below the knee at every gain, so they always get the full gain.

The bright window checks use 150-nit patches, and both states carry the same 8% raw APL. In state B half of that light gathers into a 900-nit window left of the gap, as when a bright sky or lamp comes into view. With the boost on, the curve lands the window on the panel peak, so state B shows about 14% out APL against about 21% in state A. In state A nothing needs the room above the ceiling, and in state B the room comes from the empty levels between the patches and the window, so the patches keep the full gain in both states. With the boost off, both states load the panel the same by the boost's load model. If the middle patch holds still there, a reading away from the middle with the boost on comes from the table between those two out APLs. Otherwise the window loads the panel more or less than its light.

The shadow check uses 1-nit patches over the loads of the 3% and 50% out APL curve checks. The boost lifts near-black by the same gain as everything else, up to 3.77 times, while the measured table comes from bright windows. A still patch on the dimmer side means the panel dims near-black less than bright content, so shadows get too much gain.

The low end check runs with the boost off and switches between 1% and 3% APL. The measured table starts at 3%, and the boost treats every lower load as undimmed. A still patch on the brighter side means the panel already dims between 1% and 3%.

The panel latency check replaces the grid with a row of five in a black band across the middle, while the rest of the screen switches between 3% and 10% APL. Each patch is brightened by the measured compensation for the load of a frame further back, from the left the current frame, then 1, 2, 3, and 4 frames earlier. The panel dims all of them alike, so the patch whose delay matches the frames the panel's dimming lags behind holds still through both switches, while every other patch blinks for as many frames as its delay is off. On this panel the second patch holds still, one frame, which is what the boost is built on. Compare the patches with each other instead of watching one through a tube.

## Adapting to another monitor

The live boost depends on the `APL_ANCHORS` table in the shader. In ascending APL order, each entry holds the base-2 logarithm of an APL in percent and the base-2 logarithm of the compensation at that APL.

To retune the shader for another monitor:

1. Measure the panel's peak brightness at each APL, starting with a window small enough to reach the full peak.
2. Divide the full peak by each measurement to get the compensation values. The first value should be 1.0.
3. Fill the table with log2 of each APL and log2 of its compensation, and set `APL_ANCHOR_COUNT` to the number of entries. `DwmBoost/hook/boost.hlsl` and `DwmBoost/verify/parity_check.py` hold copies of the same table.
4. Set **APL Reference White** and **Panel Peak** to the panel's peak, and use the same peak in the Windows HDR color profile.

## Desktop-wide (DWM) version

The ReShade shader only reaches a game that has ReShade installed. [`DwmBoost/`](DwmBoost) runs the same compensation on the **whole Windows 11 desktop** by hooking the desktop compositor (`dwm.exe`) and boosting each composed frame, the way [DesktopLUT](https://github.com/sup3rflyer/DesktopLUT) and the `dwm_lut` family do for desktop color calibration. It is meant for non-game desktop use; games keep using the ReShade shader. Its output matches the shader at its current default values.

While the effect is on it forces DWM composition, which **disables variable refresh rate (VRR)**, so it is turned off for gaming. It applies only to the Philips 27M2N6500 (the 2560×1440 HDR monitor); other monitors are left untouched.

A tray app injects a hook into `dwm.exe` and keeps it resident. Toggling is instant and reversible:

- **Ctrl+Alt+Shift+End** turns the boost on.
- **Ctrl+Alt+Shift+Home** turns it off, which reverts the composition patches so VRR returns.
- The tray menu has **Enable**, **Disable**, **Install autostart task** (an elevated logon task, no per-launch prompt), and **Quit**. Quit ejects the hook cleanly.

On a static desktop DWM stops composing, so the app nudges the monitor once per refresh with a 1 px corner window for 22 frames and then 4.08 seconds after the last change, then stops. Each frame's gain follows the load of the frame before it within those frames, and the 0.5 second smoothing needs up to 4.08 seconds more to ease in from any APL, so this lets the gain settle on the new content without a game running.

The target panel and its build are pinned: the tool injects only into Windows 11 25H2 (build 26200 or later) and refuses to inject if any `dwmcore.dll` byte pattern it relies on is missing or ambiguous, which also guards against a future Windows update changing the compositor.

### Building

The build needs CMake, Ninja or Visual Studio 2022, the MSVC toolchain, and the Windows 10 SDK (for `fxc`). From `DwmBoost/`:

```bash
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

This produces `DwmBoost.exe` and `DwmBoostHook.dll` in `build/bin`, plus `RenderFrame.exe` for verification. Keep the first two together. The build regenerates `hook/boost_bytecode.h` from [`hook/boost.hlsl`](DwmBoost/hook/boost.hlsl) with `fxc`. The executable and tray icons are rendered from [`app/icon.svg`](DwmBoost/app/icon.svg) into the committed `.ico` files; after editing the svg, run `python make_icons.py` in `app/` (needs `resvg-py` and Pillow). MinHook (BSD-2) is vendored under `DwmBoost/third_party/minhook/` with its license.

### Verification

[`DwmBoost/verify/parity_check.py`](DwmBoost/verify/parity_check.py) mirrors the histogram, the curve fit and the boost on the CPU and checks them against the shader's values. It confirms the baked compensation table matches the measured panel peaks, a flat field gets the full gain up to the panel peak and lands on it above that, and midtones get the full gain. It plays cuts and short flashes frame by frame and confirms that without smoothing every frame gets exactly the dimming the panel applies to it, and that the compensation settles on the fixed point `compensation(APL after boost)` within the app's 22 settle frames, the count the table's steepest step calls for. It confirms the app's 4.08 extra settle seconds are the longest the baked smoothing needs to ease in from any APL, and plays the slowest cut with smoothing at 60 and 240 Hz to see it land within them. It plays cuts with smoothing from a snowfield the gain comes down on to a dark room and a bright sky and back, and confirms the shown gain moves one way. On synthetic scenes, from a lone speck over empty levels to a large bright sky, a snowfield that fills the screen and lamps far past the panel peak, it confirms the curve keeps the full gain up to the knee, stays exact while nothing on screen needs the room above the ceiling, never goes past the panel peak, under the fixed shoulder or flatter than it, pins nothing but the brightest content on the panel peak, moves no level by more than the room one added pixel takes or by half a 10-bit code for ten pixels spread over part of the range, and settles from any starting gain. It also checks that the null test's curve checks carry the loads the boost settles on. Run `python parity_check.py`.

[`DwmBoost/verify/render_frame.cpp`](DwmBoost/verify/render_frame.cpp) builds `RenderFrame.exe`, which runs the hook's own pipeline and shader on the GPU over a saved HDR frame until the gain settles and writes the boosted frame. Both are 16-bit PQ BT.2020 PNGs like ReShade's HDR screenshots. It prints the raw and out APL, the compensation, the gain, the knee, how long the gain took to settle at the primary display's refresh rate and how far it still moves after that, and the GPU time of the whole pipeline and of the solve alone. Run `RenderFrame source.png boosted.png`.

## Credits

This shader builds on earlier work:

- [DespairArdor/QD-OLED-APL-FIXER](https://github.com/DespairArdor/QD-OLED-APL-FIXER) is the original APL compensation shader.
- [mspeedo/QD-OLED-APL-FIXER](https://github.com/mspeedo/QD-OLED-APL-FIXER) modeled it on measurements of the Samsung Odyssey OLED G8 (G85SB) in Peak 1000 mode and added the rolling full-frame histogram.
- [shansolox/QD-OLED-APL-FIXER](https://github.com/shansolox/QD-OLED-APL-FIXER) added the color-preserving boost and versions for the Aorus FO32U/2/2P and other TB400 QD-OLED monitors. This shader starts from its v8.18.7.14F version.

The DWM hook under `DwmBoost/` is written from scratch to keep the MIT license. [DesktopLUT](https://github.com/sup3rflyer/DesktopLUT) (GPL-3.0) was read for facts and design — the compositor functions involved, the vtable walk, the clean-copy and static-desktop settling approach — but none of its source is copied.

## License

This project uses the MIT License. See [LICENSE](LICENSE).
