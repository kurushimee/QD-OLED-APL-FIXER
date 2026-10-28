"""Replays a boosted frame through the fitted panel model and reports how far what the panel
shows lands from the PQ target.

Usage: python eotf_check.py <source.png> <boosted.png> [<boosted.png> ...]

Frames are 16-bit PQ BT.2020 PNGs, like RenderEffect's hdr10 input and output. The panel shows
each frame dimmed by the compensation at the frame's own load, the steady state of a held frame.
"""

import re
import sys
from pathlib import Path

import cv2
import numpy as np

INCLUDE = Path(__file__).resolve().parents[1] / "PanelModel_27M2N6500.fxh"
LEVEL_BANDS = [0.0, 1.0, 10.0, 50.0, 100.0, 203.0, 400.0, 700.0, 10000.0]
# A dither spreads a pixel by up to a code, so means wobble by a few hundredths of one
MONOTONE_TOLERANCE_CODES = 0.25
PEAK_TOLERANCE = 1.001


def panel_constants():
    text = INCLUDE.read_text()
    return {name: float(value) for name, value in re.findall(r"static const float (\w+)\s*=\s*([\d.]+);", text)}


PANEL = panel_constants()


def compensation(load_percent):
    flat_end, slope = PANEL["PANEL_COMP_FLAT_END"], PANEL["PANEL_COMP_SLOPE"]
    knee, power = PANEL["PANEL_COMP_KNEE"], PANEL["PANEL_COMP_POWER"]
    if load_percent <= knee:
        return 1.0 + slope * max(load_percent - flat_end, 0.0)
    return (1.0 + slope * (knee - flat_end)) * (load_percent / knee) ** power


def pq_to_nits(pq):
    m1, m2 = 2610 / 16384, 2523 / 4096 * 128
    c1, c2, c3 = 3424 / 4096, 2413 / 4096 * 32, 2392 / 4096 * 32
    e = np.clip(pq, 0.0, 1.0) ** (1 / m2)
    return 10000 * (np.maximum(e - c1, 0) / (c2 - c3 * e)) ** (1 / m1)


def read_png16(path):
    image = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if image is None or image.dtype != np.uint16 or image.ndim != 3:
        sys.exit(f"{path} isn't a 16-bit RGB PNG")
    return image[:, :, ::-1] / 65535.0


def frame_load_percent(nits):
    levels = np.minimum(nits.max(axis=2), PANEL["PANEL_LOAD_PEAK_NITS"]) / PANEL["PANEL_LOAD_PEAK_NITS"]
    return 100.0 * float(levels.mean())


def report(source_nits, boosted_path):
    boosted_pq = read_png16(boosted_path)
    boosted_nits = pq_to_nits(boosted_pq)
    load = frame_load_percent(boosted_nits)
    shown = boosted_nits / compensation(load)

    source_level = source_nits.max(axis=2)
    shown_level = shown.max(axis=2)
    target_level = np.minimum(source_level, PANEL["PANEL_PEAK_NITS"])
    lit = source_level > 0.01
    error = np.zeros_like(source_level)
    error[lit] = shown_level[lit] / target_level[lit] - 1.0

    print(f"\n{Path(boosted_path).name}: load {frame_load_percent(source_nits):.1f}% raw, {load:.1f}% boosted, "
          f"compensation {compensation(load):.3f}")
    print(f"  mean |error| {100 * np.mean(np.abs(error[lit])):.2f}%, pixel-weighted log2 error "
          f"{np.mean(np.abs(np.log2(np.maximum(shown_level[lit], 1e-6) / target_level[lit]))):.4f}")
    for low, high in zip(LEVEL_BANDS, LEVEL_BANDS[1:]):
        band = lit & (source_level >= low) & (source_level < high)
        if band.any():
            print(f"  source {low:6.0f} to {high:6.0f} nits: {100 * band.mean():5.1f}% of pixels, "
                  f"mean error {100 * error[band].mean():+6.2f}%, worst {100 * np.abs(error[band]).max():6.2f}%")

    failures = []
    sent_peak = boosted_nits.max()
    if sent_peak > PANEL["PANEL_SIGNAL_PEAK_NITS"] * PEAK_TOLERANCE:
        failures.append(f"sends {sent_peak:.1f} nits past the {PANEL['PANEL_SIGNAL_PEAK_NITS']:.1f} nit signal peak")
    if not curve_rises(source_level[lit], 1023 * boosted_pq.max(axis=2)[lit]):
        failures.append("the curve falls somewhere")
    hue_shift = channel_ratio_shift(source_nits[lit], boosted_nits[lit])
    print(f"  sent peak {sent_peak:.1f} nits, worst channel ratio shift {hue_shift:.4f}")
    for failure in failures:
        print(f"  FAIL {failure}")
    return not failures


def curve_rises(source_level, boosted_codes):
    """Compares each source level's mean output in 10-bit codes"""
    order = np.argsort(source_level, kind="stable")
    levels, outputs = source_level[order], boosted_codes[order]
    _, starts, counts = np.unique(levels, return_index=True, return_counts=True)
    means = np.add.reduceat(outputs, starts) / counts
    running_max = np.maximum.accumulate(means)
    return bool(np.all(means[1:] + MONOTONE_TOLERANCE_CODES >= running_max[:-1]))


def channel_ratio_shift(source_rgb, boosted_rgb):
    bright = source_rgb.max(axis=1) > 1.0
    source_ratio = source_rgb[bright] / source_rgb[bright].max(axis=1, keepdims=True)
    boosted_ratio = boosted_rgb[bright] / np.maximum(boosted_rgb[bright].max(axis=1, keepdims=True), 1e-9)
    return float(np.abs(source_ratio - boosted_ratio).max()) if bright.any() else 0.0


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    # The HDR10 back buffer holds 10-bit codes, so that's the source the shader sees
    source_nits = pq_to_nits(np.round(read_png16(sys.argv[1]) * 1023) / 1023)
    passed = all([report(source_nits, path) for path in sys.argv[2:]])
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
