#!/usr/bin/env python3
# Parity check for boost.hlsl against Shaders/EOTF_BoostMod3.1_27M2N6500.fx at its default settings.
#
# Renders synthetic frames through the hook's pipeline (RenderFrame) and through the shader on an scRGB back buffer
# the way ReShade runs it (RenderEffect), and fails when a channel differs by a quarter of a 10-bit PQ code or more
# and by half an FP16 step of its pixel or more. The two compilers round floats differently, which can flip a buffer
# value by one step, and on a saturated color that step is many PQ codes for a channel near black.
# It also checks that the geometry in pipeline.h matches boost.hlsl, that the settle runs and seconds there cover
# the in-frame solve and the slowest ease the smoothing period allows, that a bright field covering most of the
# screen keeps full compensation, so the gain doesn't fall away as the load climbs, that both paths leave a frame
# needing no gain untouched, and that the brightest content lands on the signal peak.
# Needs both renderers built, see CLAUDE.md. Run: python parity_check.py

import math
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent.parent
PIPELINE_SOURCE = ROOT / "DwmBoost" / "hook" / "pipeline.h"
BOOST_SOURCE = ROOT / "DwmBoost" / "hook" / "boost.hlsl"
PANEL_MODEL_SOURCE = ROOT / "Shaders" / "PanelModel_27M2N6500.fxh"
SHADER_SOURCE = ROOT / "Shaders" / "EOTF_BoostMod3.1_27M2N6500.fx"
RENDER_FRAME = ROOT / "DwmBoost" / "build" / "bin" / "Release" / "RenderFrame.exe"
RENDER_EFFECT = ROOT / "Shaders" / "verify" / "build" / "bin" / "Release" / "RenderEffect.exe"

# The frames are sized so the last row and column of histogram tiles are partial.
FRAME_WIDTH = 976
FRAME_HEIGHT = 540
MAX_DIFF_CODES = 0.25
MAX_DIFF_FP16_STEPS = 0.5

PQ_M1, PQ_M2 = 0.1593017578125, 78.84375
PQ_C1, PQ_C2, PQ_C3 = 0.8359375, 18.8515625, 18.6875

SCRGB_NITS = 80.0
FP16_MANTISSA_BITS = 10
FP16_SMALLEST_NORMAL = 2.0 ** -14
REC2020_TO_REC709 = np.array([
    [1.660490296, -0.587639106, -0.072851598],
    [-0.124549970, 1.132899922, -0.008347964],
    [-0.018151119, -0.100578724, 1.118729878]])


def nits_to_pq(nits):
    lm1 = np.power(np.clip(np.asarray(nits, dtype=np.float64) / 10000.0, 0.0, 1.0), PQ_M1)
    return np.power((PQ_C1 + PQ_C2 * lm1) / (1.0 + PQ_C3 * lm1), PQ_M2)


def pq_to_nits(pq):
    vp = np.power(np.clip(np.asarray(pq, dtype=np.float64), 0.0, 1.0), 1.0 / PQ_M2)
    return np.power(np.maximum(vp - PQ_C1, 0.0) / (PQ_C2 - PQ_C3 * vp), 1.0 / PQ_M1) * 10000.0


def blank(nits=0.0):
    return np.full((FRAME_HEIGHT, FRAME_WIDTH, 3), nits, dtype=np.float64)


def window(background_nits, window_nits, area):
    frame = blank(background_nits)
    side_y = int(round(FRAME_HEIGHT * math.sqrt(area)))
    side_x = int(round(FRAME_WIDTH * math.sqrt(area)))
    top, left = (FRAME_HEIGHT - side_y) // 2, (FRAME_WIDTH - side_x) // 2
    frame[top:top + side_y, left:left + side_x] = window_nits
    return frame


def horizontal_ramp(levels):
    return np.repeat(np.repeat(levels[None, :, None], FRAME_HEIGHT, axis=0), 3, axis=2)


def pq_ramp():
    return horizontal_ramp(pq_to_nits(np.linspace(0.0, 1.0, FRAME_WIDTH)))


def primary_bars(nits):
    frame = blank()
    colors = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1), (1, 0, 1), (1, 1, 1)]
    width = FRAME_WIDTH // len(colors)
    for index, color in enumerate(colors):
        frame[:, index * width:(index + 1) * width] = np.array(color) * nits
    return frame


def noise(seed):
    pq = np.random.default_rng(seed).uniform(0.0, 0.8, (FRAME_HEIGHT, FRAME_WIDTH, 3))
    return pq_to_nits(pq)


FRAMES = {
    "black": lambda: blank(),
    "gray_100": lambda: blank(100.0),
    "white_full": lambda: blank(1000.0),
    "window_10": lambda: window(0.0, 1000.0, 0.10),
    "window_25_on_gray": lambda: window(20.0, 1000.0, 0.25),
    "highlights_on_gray": lambda: window(150.0, 4000.0, 0.02),
    "pq_ramp": pq_ramp,
    "primaries_500": lambda: primary_bars(500.0),
    "noise": lambda: noise(7),
}


def write_frame(path, nits):
    codes = np.round(nits_to_pq(nits) * 65535.0).astype(np.uint16)
    cv2.imwrite(str(path), codes[:, :, ::-1])


def read_codes(path):
    return cv2.imread(str(path), cv2.IMREAD_UNCHANGED)[:, :, ::-1] / 65535.0 * 1023.0


# Nits between neighboring FP16 values at the pixel's largest scRGB channel. Each Rec.2020 channel mixes the
# Rec.709 ones with weights summing to 1, so one step there moves it by at most this.
def fp16_step_nits(rec2020_nits):
    scrgb = np.abs(np.einsum("ij,hwj->hwi", REC2020_TO_REC709, rec2020_nits) / SCRGB_NITS).max(axis=2)
    exponent = np.floor(np.log2(np.maximum(scrgb, FP16_SMALLEST_NORMAL)))
    return np.exp2(exponent - FP16_MANTISSA_BITS) * SCRGB_NITS


# Per channel, how far each output is past both tolerances, as a share of the closer one. Under 1 passes.
def mismatch(hook_codes, shader_codes):
    hook_nits = pq_to_nits(hook_codes / 1023.0)
    nits_share = np.abs(hook_nits - pq_to_nits(shader_codes / 1023.0)) / (MAX_DIFF_FP16_STEPS * fp16_step_nits(hook_nits)[..., None])
    code_share = np.abs(hook_codes - shader_codes) / MAX_DIFF_CODES
    return np.minimum(code_share, nits_share)


def run(command):
    result = subprocess.run([str(part) for part in command], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"{Path(command[0]).name} failed:\n{result.stdout}{result.stderr}")


def effect_codes(source, space, output, *settings):
    run([RENDER_EFFECT, SHADER_SOURCE, space, source, output, *settings])
    return read_codes(output)


def hook_codes(source, output):
    run([RENDER_FRAME, source, output])
    return read_codes(output)


def compare_frames(folder):
    failures = 0
    for name, make in FRAMES.items():
        source = folder / f"{name}.png"
        hook_out = folder / f"{name}_hook.png"
        shader_out = folder / f"{name}_shader.png"
        write_frame(source, make())
        run([RENDER_FRAME, source, hook_out])
        run([RENDER_EFFECT, SHADER_SOURCE, "scrgb", source, shader_out])

        hook_codes, shader_codes = read_codes(hook_out), read_codes(shader_out)
        diff = np.abs(hook_codes - shader_codes)
        worst = mismatch(hook_codes, shader_codes).max()
        ok = worst < 1.0
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name:20s} max {diff.max():.3f} codes, mean {diff.mean():.5f}, "
              f"worst {worst:.2f} of the tolerance")
    return failures


# A smooth cyan to white gradient over most of the screen, like a bright out of focus background, beside a dim blue
# band. Its spread of bright levels once made warps read a stale load and the pick fall to gain 1.
def cyan_gradient(top_nits):
    x = np.linspace(0.0, 1.0, FRAME_WIDTH)
    level = top_nits * (0.25 + 0.75 * np.sqrt(np.clip(1.0 - np.abs(x - 0.35) / 0.5, 0.0, 1.0)))
    frame = np.repeat(np.stack([0.5 * level, level, level], axis=1)[None, :, :], FRAME_HEIGHT, axis=0)
    frame[:, x >= 0.85] = np.array([0.0, 0.3, 1.0]) * 20.0
    return frame


# Every gain past the ceiling sends a bright field to the peak, so its own pixels score alike and the rest of the
# frame needs full compensation.
HIGH_LOAD_FRAMES = {
    "480 nits over 100% on 5 nits": lambda: window(5.0, 480.0, 1.0),
    "800 nits over 95% on 5 nits": lambda: window(5.0, 800.0, 0.95),
    "800 nits over 98% on 100 nits": lambda: window(100.0, 800.0, 0.98),
    "600 nits over 90% on 20 nits": lambda: window(20.0, 600.0, 0.9),
    "cyan gradient to 600 nits": lambda: cyan_gradient(600.0),
    "cyan gradient to 800 nits": lambda: cyan_gradient(800.0),
}
FULL_GAIN_TOLERANCE = 0.99


def render_frame_stats(source, output):
    result = subprocess.run([str(RENDER_FRAME), str(source), str(output)], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"RenderFrame failed:\n{result.stdout}{result.stderr}")
    fields = result.stdout.split()
    return {name: float(value) for name, value in zip(fields[0::2], fields[1::2])}


def check_high_load_gain(folder):
    failures = 0
    for name, make in HIGH_LOAD_FRAMES.items():
        source = folder / "high_load.png"
        write_frame(source, make())
        stats = render_frame_stats(source, folder / "high_load_out.png")
        ok = stats["gain"] >= FULL_GAIN_TOLERANCE * stats["full_gain"]
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {name}, gain {stats['gain']:.3f} of full {stats['full_gain']:.3f}")
    return failures


# Frames under the load where the panel starts dimming. The baseline is each renderer's own run with the boost off,
# since scRGB rounds through FP16 on the way in.
NO_GAIN_FRAMES = {
    "20 nits": lambda: blank(20.0),
    "ramp to 60 nits": lambda: horizontal_ramp(np.linspace(0.0, 60.0, FRAME_WIDTH)),
}


def check_no_gain_untouched(folder):
    failures = 0
    source = folder / "no_gain.png"
    for name, make in NO_GAIN_FRAMES.items():
        write_frame(source, make())
        hdr10_off = effect_codes(source, "hdr10", folder / "no_gain_hdr10_off.png", "EnableEOTFBoost=0")
        scrgb_off = effect_codes(source, "scrgb", folder / "no_gain_scrgb_off.png", "EnableEOTFBoost=0")
        paths = {
            "shader in HDR10": (effect_codes(source, "hdr10", folder / "no_gain_hdr10.png"), hdr10_off),
            "shader in scRGB": (effect_codes(source, "scrgb", folder / "no_gain_scrgb.png"), scrgb_off),
            "hook": (hook_codes(source, folder / "no_gain_hook.png"), scrgb_off),
        }
        for path, (boosted, untouched) in paths.items():
            changed = np.any(boosted != untouched, axis=2).mean() * 100.0
            ok = changed == 0.0
            failures += not ok
            print(f"{'ok  ' if ok else 'FAIL'} {name} through the {path}, {changed:.2f}% of pixels changed")
    return failures


# A window far past the ceiling, whose brightest level the curve tops out at the signal peak. HDR10 without the dither
# sends the peak's code, and scRGB comes within one FP16 step of it.
def check_peak(folder, model_text):
    peak_nits = constant(model_text, "PANEL_SIGNAL_PEAK_NITS")
    peak_code = round(float(nits_to_pq(peak_nits)) * 1023.0)
    source = folder / "peak.png"
    write_frame(source, window(0.0, 4000.0, 0.10))

    hdr10_top = effect_codes(source, "hdr10", folder / "peak_hdr10.png", "EnableDither=0").max()
    hdr10_ok = round(hdr10_top) == peak_code
    print(f"{'ok  ' if hdr10_ok else 'FAIL'} brightest level through the shader in HDR10 at code {hdr10_top:.2f}, "
          f"the peak is {peak_code}")

    fp16_step = fp16_step_nits(np.full((1, 1, 3), peak_nits))[0, 0]
    failures = not hdr10_ok
    for path, codes in (("shader in scRGB", effect_codes(source, "scrgb", folder / "peak_scrgb.png")),
                        ("hook", hook_codes(source, folder / "peak_hook.png"))):
        top_nits = float(pq_to_nits(codes.max() / 1023.0))
        ok = abs(top_nits - peak_nits) <= fp16_step
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} brightest level through the {path} at {top_nits:.2f} nits, "
              f"the peak is {peak_nits:.2f} and an FP16 step {fp16_step:.2f}")
    return failures


def constant(text, name):
    match = re.search(rf"\b{name}\s*=\s*([^;]+);", text)
    if match is None:
        sys.exit(f"{name} not found")
    return float(eval(match.group(1), {"__builtins__": {}}))


def define(text, name):
    match = re.search(rf"#define\s+{name}\s+(\d+)", text)
    if match is None:
        sys.exit(f"{name} not found")
    return int(match.group(1))


def check_geometry(pipeline, boost):
    pairs = [
        ("TILE_SIZE", "APL_FFH_TILE_SIZE"),
        ("BLOCK_W", "APL_FFH_BLOCK_W"),
        ("BLOCK_H", "APL_FFH_BLOCK_H"),
        ("TONE_CURVE_LUT_SIZE", "TONE_CURVE_LUT_SIZE"),
    ]
    failures = 0
    for host_name, shader_name in pairs:
        host = int(re.search(rf"\b{host_name}\s*=\s*(\d+)", pipeline).group(1))
        shader = define(boost, shader_name)
        ok = host == shader
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {host_name} {host} in pipeline.h, {shader} in boost.hlsl")
    return failures


def compensation(load_percent, model):
    flat_end, slope = model["PANEL_COMP_FLAT_END"], model["PANEL_COMP_SLOPE"]
    knee, power = model["PANEL_COMP_KNEE"], model["PANEL_COMP_POWER"]
    if load_percent <= knee:
        return 1.0 + slope * max(load_percent - flat_end, 0.0)
    return (1.0 + slope * (knee - flat_end)) * (load_percent / knee) ** power


# The ease closes its log gain gap as exp(-t / period), from at most full compensation at a full white frame down to
# half the smallest relative step between 10-bit PQ codes up to the signal peak.
def slowest_ease_seconds(model, period_ms):
    top_code = int(nits_to_pq(model["PANEL_SIGNAL_PEAK_NITS"]) * 1023.0)
    codes = np.arange(1, top_code)
    smallest_step = np.min(pq_to_nits((codes + 1) / 1023.0) / pq_to_nits(codes / 1023.0) - 1.0)
    tolerance = math.log2(1.0 + 0.5 * smallest_step)
    largest_gap = math.log2(compensation(100.0, model))
    return period_ms / 1000.0 * math.log(largest_gap / tolerance)


def check_settle(pipeline, boost, model_text):
    model = {name: constant(model_text, name) for name in
             ["PANEL_SIGNAL_PEAK_NITS", "PANEL_COMP_FLAT_END", "PANEL_COMP_SLOPE", "PANEL_COMP_KNEE", "PANEL_COMP_POWER"]}
    runs = constant(pipeline, "SETTLE_RUNS")
    seconds = constant(pipeline, "SETTLE_SECONDS")
    needed = slowest_ease_seconds(model, constant(boost, "SMOOTHING_PERIOD_MS"))

    runs_ok = runs >= 1
    seconds_ok = seconds >= needed
    print(f"{'ok  ' if runs_ok else 'FAIL'} SETTLE_RUNS {runs:.0f}, the solve finishes within one run")
    print(f"{'ok  ' if seconds_ok else 'FAIL'} SETTLE_SECONDS {seconds:.3f}, the slowest ease needs {needed:.3f}")
    return (not runs_ok) + (not seconds_ok)


def main():
    for tool in (RENDER_FRAME, RENDER_EFFECT):
        if not tool.exists():
            sys.exit(f"{tool} isn't built, see CLAUDE.md")

    pipeline = PIPELINE_SOURCE.read_text()
    boost = BOOST_SOURCE.read_text()
    model = PANEL_MODEL_SOURCE.read_text()
    failures = check_geometry(pipeline, boost)
    failures += check_settle(pipeline, boost, model)

    with tempfile.TemporaryDirectory() as folder:
        failures += check_high_load_gain(Path(folder))
        failures += check_no_gain_untouched(Path(folder))
        failures += check_peak(Path(folder), model)
        failures += compare_frames(Path(folder))

    print("\nall checks pass" if failures == 0 else f"\n{failures} checks failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
