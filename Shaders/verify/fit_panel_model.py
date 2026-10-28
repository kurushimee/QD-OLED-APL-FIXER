"""Fits the 27M2N6500's dimming to every row of abl_curve.csv and writes the panel include.

Usage:
    python fit_panel_model.py           print the fit and write Shaders/PanelModel_27M2N6500.fxh
    python fit_panel_model.py --check   fail when the include doesn't match a fresh fit
"""

import csv
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from scipy.optimize import least_squares

ROOT = Path(__file__).resolve().parents[2]
MEASUREMENTS = ROOT / "abl_curve.csv"
INCLUDE = ROOT / "Shaders" / "PanelModel_27M2N6500.fxh"

EDID_PEAK_NITS = 50.0 * 2.0 ** (139 / 32)
BT2020_LUMA = np.array([0.2627, 0.6780, 0.0593])
REFERENCE_WINDOW = 2.0
MAX_ELASTICITY = 0.95

# Knee model parameters: flat end (% load), linear slope (compensation per %), knee (% load), power
KNEE_START = (3.0, 0.16, 10.0, 0.25)
KNEE_LOWER = (2.0, 0.01, 6.0, 0.05)
KNEE_UPPER = (4.5, 0.5, 14.0, 0.6)
LOAD_PEAK_BOUNDS = (900.0, 1200.0)


def nits_to_pq_code(nits):
    m1, m2 = 2610 / 16384, 2523 / 4096 * 128
    c1, c2, c3 = 3424 / 4096, 2413 / 4096 * 32, 2392 / 4096 * 32
    y = (nits / 10000) ** m1
    return 1023 * ((c1 + c2 * y) / (1 + c3 * y)) ** m2


def signal_peak_nits():
    """Brightest 10-bit PQ code the panel shows without clipping, in nits"""
    return float(pq_to_nits(np.floor(nits_to_pq_code(EDID_PEAK_NITS))))


def pq_to_nits(code_10bit):
    m1, m2 = 2610 / 16384, 2523 / 4096 * 128
    c1, c2, c3 = 3424 / 4096, 2413 / 4096 * 32, 2392 / 4096 * 32
    e = (np.asarray(code_10bit, dtype=float) / 1023) ** (1 / m2)
    return 10000 * (np.maximum(e - c1, 0) / (c2 - c3 * e)) ** (1 / m1)


@dataclass(frozen=True)
class Window:
    pattern: str
    codes: tuple
    area: float
    dimming: float
    dimming_with_glare: float

    def levels(self, load_peak_nits):
        return np.minimum(pq_to_nits(self.codes), load_peak_nits) / load_peak_nits


def read_windows():
    with open(MEASUREMENTS, newline="") as f:
        rows = [row for row in csv.DictReader(f) if row["pattern"] != "black"]

    references = {}
    for row in rows:
        if float(row["window_percent"]) == REFERENCE_WINDOW:
            references[pattern_key(row)] = float(row["relative_with_glare"])

    return [
        Window(
            pattern=f"{row['pattern']} {row['r']}",
            codes=(int(row["r"]), int(row["g"]), int(row["b"])),
            area=float(row["window_percent"]),
            dimming=float(row["self_relative"]),
            dimming_with_glare=float(row["relative_with_glare"]) / references[pattern_key(row)],
        )
        for row in rows
        if float(row["window_percent"]) > REFERENCE_WINDOW
    ]


def pattern_key(row):
    return (row["pattern"], row["r"], row["g"], row["b"])


# Load models map a window and a load peak to the frame load in percent

def brightest_channel(window, load_peak, weights=(1.0, 1.0, 1.0)):
    return window.area * np.max(np.asarray(weights) * window.levels(load_peak))


def shader_2_mix(window, load_peak):
    levels = window.levels(load_peak)
    brightest_share = (3 * 0.75 - 1) / 2
    return window.area * (levels.mean() + brightest_share * (levels.max() - levels.mean()))


def channel_sum(window, load_peak):
    return window.area * window.levels(load_peak).mean()


def luminance(window, load_peak):
    return window.area * float(BT2020_LUMA @ window.levels(load_peak))


def knee_compensation(params, load):
    flat_end, slope, knee, power = params
    load = np.asarray(load, dtype=float)
    linear = 1 + slope * np.clip(load - flat_end, 0, None)
    knee_comp = 1 + slope * (knee - flat_end)
    upper = knee_comp * (np.maximum(load, knee) / knee) ** power
    return np.where(load <= knee, linear, upper)


def knee_elasticity(params, load):
    flat_end, slope, knee, power = params
    load = np.asarray(load, dtype=float)
    linear = slope * load / knee_compensation(params, load)
    return np.where(load <= flat_end, 0.0, np.where(load <= knee, linear, power))


@dataclass(frozen=True)
class Fit:
    label: str
    load_peak: float
    params: tuple
    weights: tuple = (1.0, 1.0, 1.0)
    load_model: object = brightest_channel

    def load(self, window):
        if self.load_model is brightest_channel:
            return brightest_channel(window, self.load_peak, self.weights)
        return self.load_model(window, self.load_peak)

    def errors_percent(self, windows, glare=False):
        measured = np.array([w.dimming_with_glare if glare else w.dimming for w in windows])
        predicted = 1 / knee_compensation(self.params, [self.load(w) for w in windows])
        return 100 * (measured / predicted - 1)


def fit_knee(windows, label, load_model=brightest_channel, load_peak=EDID_PEAK_NITS,
             fit_peak=False, fit_weights=False, glare=False):
    log_dimming = np.log([w.dimming_with_glare if glare else w.dimming for w in windows])

    def unpack(x):
        peak = x[0] if fit_peak else load_peak
        weights = (1.0, x[-6], x[-5]) if fit_weights else (1.0, 1.0, 1.0)
        return peak, tuple(x[-4:]), weights

    start, lower, upper = list(KNEE_START), list(KNEE_LOWER), list(KNEE_UPPER)
    if fit_weights:
        start, lower, upper = [1.0, 1.0] + start, [0.6, 0.6] + lower, [1.0, 1.0] + upper
    if fit_peak:
        start, lower, upper = [load_peak] + start, [LOAD_PEAK_BOUNDS[0]] + lower, [LOAD_PEAK_BOUNDS[1]] + upper

    def residuals(x):
        fit = Fit(label, *unpack(x), load_model=load_model)
        loads = [fit.load(w) for w in windows]
        return -np.log(knee_compensation(fit.params, loads)) - log_dimming

    result = least_squares(residuals, start, bounds=(lower, upper))
    return Fit(label, *unpack(result.x), load_model=load_model)


def leave_one_out(windows, refit):
    errors = []
    for i, held_out in enumerate(windows):
        fit = refit(windows[:i] + windows[i + 1:])
        errors.append(fit.errors_percent([held_out])[0])
    return np.array(errors)


def rms(errors):
    return float(np.sqrt(np.mean(np.square(errors))))


def print_comparison(windows):
    print(f"{'load model':58s} {'rms':>6s} {'worst':>6s} {'held out':>9s}")
    candidates = [
        ("brightest channel, BT.2020 luminance", dict(load_model=luminance)),
        ("channel sum", dict(load_model=channel_sum)),
        ("2.0's mix of mean and brightest channel", dict(load_model=shader_2_mix)),
        ("brightest channel, load peak at the EDID", dict()),
        ("brightest channel, weighted", dict(fit_weights=True)),
        ("brightest channel, load peak fitted", dict(fit_peak=True)),
    ]
    for label, options in candidates:
        fit = fit_knee(windows, label, **options)
        held_out = leave_one_out(windows, lambda subset: fit_knee(subset, label, **options))
        errors = fit.errors_percent(windows)
        print(f"{label:58s} {rms(errors):5.2f}% {np.max(np.abs(errors)):5.2f}% {rms(held_out):8.2f}%")


def print_rows(fit, windows):
    print(f"\nper row, {fit.label}")
    for window, error in zip(windows, fit.errors_percent(windows)):
        print(f"  {window.pattern:15s} {window.area:5.0f}%  load {fit.load(window):6.2f}%  "
              f"dimming {window.dimming:.4f}  error {error:+5.2f}%")


def print_model(fit, windows):
    flat_end, slope, knee, power = fit.params
    print(f"\nload peak {fit.load_peak:.1f} nits, flat to {flat_end:.3f}%, slope {slope:.4f} per %, "
          f"knee {knee:.3f}%, power {power:.4f}")
    loads = [3, 4, 5, 7, 10, 15, 25, 50, 100]
    print("compensation  " + "  ".join(f"{l}%:{c:.3f}" for l, c in zip(loads, knee_compensation(fit.params, loads))))

    glare = fit_knee(windows, "glare kept", fit_peak=True, glare=True)
    shift = 100 * (knee_compensation(glare.params, loads) / knee_compensation(fit.params, loads) - 1)
    print("glare kept shifts compensation by  " + "  ".join(f"{l}%:{s:+.2f}" for l, s in zip(loads, shift)))

    load_grid = np.linspace(0.5, 100, 2000)
    print(f"peak elasticity {np.max(knee_elasticity(fit.params, load_grid)):.3f}, "
          f"lowest full-compensation ceiling {EDID_PEAK_NITS / knee_compensation(fit.params, 100):.1f} nits")


def include_text(fit):
    flat_end, slope, knee, power = fit.params
    return f"""// Generated by Shaders/verify/fit_panel_model.py from abl_curve.csv. Don't edit by hand.
// The 27M2N6500's dimming in HDR Peak 1000 mode. Load is the frame mean of
// min(max(R, G, B), PANEL_LOAD_PEAK_NITS) / PANEL_LOAD_PEAK_NITS in linear light, in percent.

#pragma once

static const float PANEL_PEAK_NITS        = {EDID_PEAK_NITS:.2f};
// Brightest 10-bit PQ code at or under the peak, the top of every boosted frame
static const float PANEL_SIGNAL_PEAK_NITS = {signal_peak_nits():.2f};
static const float PANEL_LOAD_PEAK_NITS   = {fit.load_peak:.2f};
static const float PANEL_COMP_FLAT_END    = {flat_end:.5f};
static const float PANEL_COMP_SLOPE       = {slope:.6f};
static const float PANEL_COMP_KNEE        = {knee:.5f};
static const float PANEL_COMP_POWER       = {power:.6f};

// Compensation that cancels the panel's dimming at a load in percent
float PanelCompensation(float loadPercent)
{{
    float belowKnee = 1.0 + PANEL_COMP_SLOPE * max(loadPercent - PANEL_COMP_FLAT_END, 0.0);
    float kneeComp = 1.0 + PANEL_COMP_SLOPE * (PANEL_COMP_KNEE - PANEL_COMP_FLAT_END);
    float upper = kneeComp * pow(max(loadPercent, PANEL_COMP_KNEE) / PANEL_COMP_KNEE, PANEL_COMP_POWER);
    return loadPercent <= PANEL_COMP_KNEE ? belowKnee : upper;
}}
"""


def check_elasticity(fit):
    peak = float(np.max(knee_elasticity(fit.params, np.linspace(0.5, 100, 2000))))
    if peak >= MAX_ELASTICITY:
        sys.exit(f"elasticity reaches {peak:.3f}, the gain could stop settling on one fixed point")


def main():
    windows = read_windows()
    model = fit_knee(windows, "brightest channel, load peak fitted", fit_peak=True)
    check_elasticity(model)

    if "--check" in sys.argv:
        if INCLUDE.read_text() != include_text(model):
            sys.exit(f"{INCLUDE.name} is stale, run fit_panel_model.py")
        print(f"{INCLUDE.name} matches the fit")
        return

    print_comparison(windows)
    print_rows(model, windows)
    print_model(model, windows)
    INCLUDE.write_text(include_text(model))
    print(f"\nwrote {INCLUDE.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
