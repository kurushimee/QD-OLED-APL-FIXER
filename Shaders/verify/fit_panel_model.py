"""Fits the 27M2N6500's dimming to every measured window and writes the panel include.

The windows are every row of abl_curve.csv and the dense white windows of the measurement before it,
bc0684f^:abl_curve.csv, the same panel measured at 1% steps through the steep part of the curve.

Usage:
    python fit_panel_model.py           print the fit and write Shaders/PanelModel_27M2N6500.fxh
    python fit_panel_model.py --check   fail when the include doesn't match a fresh fit or the fit breaks a rule
"""

import csv
import io
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from scipy.optimize import least_squares

ROOT = Path(__file__).resolve().parents[2]
MEASUREMENTS = ROOT / "abl_curve.csv"
DENSE_WHITE_REVISION = "bc0684f^:abl_curve.csv"
INCLUDE = ROOT / "Shaders" / "PanelModel_27M2N6500.fxh"

EDID_PEAK_NITS = 50.0 * 2.0 ** (139 / 32)
REFERENCE_WINDOW = 2.0
# Feedback-tuned response, not measured panel timing. Rising load still flashed dim at 40 ms; halve attack again.
# Release at 5 ms still flashed dim, while 10 ms flashed bright; bisect that bracket.
PANEL_DIM_SECONDS = 0.03
PANEL_UNDIM_SECONDS = 0.00125

# Smoothing widths of the curve's two corners, the flat end in % load and the knee in log2 load
FLAT_SMOOTH_TAU = 0.1
KNEE_SMOOTH_TAU = 0.04

# Rules --check enforces
MAX_ELASTICITY = 0.95
MAX_MEAN_ERROR_PERCENT = 0.5
MAX_CURVATURE_STEP = 0.1

BT2020_LUMA = np.array([0.2627, 0.6780, 0.0593])

# Linear RGB to the panel's native primaries, DCI-P3 with a D65 white
REC709_TO_PANEL = np.array([
    [0.822462, 0.177538, 0.000000],
    [0.033194, 0.966806, 0.000000],
    [0.017083, 0.072397, 0.910520]])
BT2020_TO_PANEL = np.array([
    [1.343578, -0.282180, -0.061399],
    [-0.065297, 1.075788, -0.010490],
    [0.002822, -0.019598, 1.016777]])

# Flat end (% load), knee load (%), knee compensation, tail power, green and blue load weights
PARAM_START = (3.16, 10.3, 2.19, 0.244, 0.93, 0.91)
PARAM_LOWER = (2.0, 6.0, 1.5, 0.05, 0.6, 0.6)
PARAM_UPPER = (4.5, 14.0, 3.0, 0.6, 1.0, 1.0)


def pq_encode(nits):
    m1, m2 = 2610 / 16384, 2523 / 4096 * 128
    c1, c2, c3 = 3424 / 4096, 2413 / 4096 * 32, 2392 / 4096 * 32
    y = (np.clip(np.asarray(nits, dtype=float), 0.0, 10000.0) / 10000) ** m1
    return ((c1 + c2 * y) / (1 + c3 * y)) ** m2


def pq_to_nits(code_10bit):
    m1, m2 = 2610 / 16384, 2523 / 4096 * 128
    c1, c2, c3 = 3424 / 4096, 2413 / 4096 * 32, 2392 / 4096 * 32
    e = (np.asarray(code_10bit, dtype=float) / 1023) ** (1 / m2)
    return 10000 * (np.maximum(e - c1, 0) / (c2 - c3 * e)) ** (1 / m1)


def signal_peak_nits():
    """Brightest 10-bit PQ code the panel shows without clipping, in nits"""
    return float(pq_to_nits(np.floor(1023 * pq_encode(EDID_PEAK_NITS))))


# Compensation curve

def smooth_max0(x, tau):
    return 0.5 * (x + np.sqrt(x * x + tau * tau))


def smooth_ramp(x):
    """0 at and below 0, x at and above FLAT_SMOOTH_TAU, and a quintic between that leaves both ends with a zero
    second derivative, so the curve is smooth where it starts"""
    tau = FLAT_SMOOTH_TAU
    t = np.clip(np.asarray(x, dtype=float) / tau, 0.0, 1.0)
    return np.where(np.asarray(x) >= tau, x, tau * t * t * t * (6 + t * (-8 + 3 * t)))


def log2_compensation(curve, load):
    """Flat at 1 up to the flat end, linear in load up to the knee, and a power law above it. The ramp leaves 1
    smoothly, and the ramp and the tail meet through a smooth max in log2 compensation scaled so its width is
    KNEE_SMOOTH_TAU in log2 load, so the curve is smooth everywhere."""
    flat_end, knee_load, knee_comp, power = curve
    load = np.clip(np.asarray(load, dtype=float), 1e-4, 100.0)
    slope = (knee_comp - 1) / (knee_load - flat_end)
    ramp = 1 + slope * smooth_ramp(load - flat_end)
    log_ramp = np.log2(ramp)
    log_tail = np.log2(knee_comp) + power * np.log2(load / knee_load)
    ramp_power = slope * knee_load / knee_comp
    corner = ramp_power - power
    return log_tail - corner * smooth_max0((log_tail - log_ramp) / corner, KNEE_SMOOTH_TAU)


def compensation(curve, load):
    return np.maximum(np.exp2(log2_compensation(curve, load)), 1.0)


def elasticity(curve, load):
    """Log slope of the compensation against load"""
    h = 1e-4
    load = np.asarray(load, dtype=float)
    up, down = load * np.exp(h), load * np.exp(-h)
    return (np.log(compensation(curve, up)) - np.log(compensation(curve, down))) / (2 * h)


# Measured windows

@dataclass(frozen=True)
class Window:
    pattern: str
    codes: tuple
    area: float
    dimming: float


@dataclass(frozen=True)
class Tracking:
    """Level the panel shows, without dimming, over the level it's sent, at the 2% gray windows. It's 1 at the
    peak, held below the dimmest gray, and runs linearly in PQ between the points."""
    nits: tuple
    shown_share: tuple

    def factor(self, nits):
        nits = np.clip(np.asarray(nits, dtype=float), 0.0, EDID_PEAK_NITS)
        return np.interp(pq_encode(nits), pq_encode(np.array(self.nits)), np.array(self.shown_share))


def read_rows():
    with open(MEASUREMENTS, newline="") as f:
        return [row for row in csv.DictReader(f) if row["pattern"] != "black"]


def read_tracking(rows):
    grays = sorted((float(row["signal_nits"]), float(row["relative"]) * EDID_PEAK_NITS / float(row["signal_nits"]))
                   for row in rows if row["pattern"] == "gray" and float(row["window_percent"]) == REFERENCE_WINDOW)
    nits = tuple(n for n, _ in grays) + (EDID_PEAK_NITS,)
    shares = tuple(s for _, s in grays) + (1.0,)
    return Tracking(nits, shares)


def read_dense_white(measured_areas):
    text = subprocess.run(["git", "show", DENSE_WHITE_REVISION], cwd=ROOT, capture_output=True, text=True,
                          check=True).stdout
    return [
        Window("white 1023", (1023, 1023, 1023), float(row["apl_percent"]), float(row["relative"]))
        for row in csv.DictReader(io.StringIO(text))
        if float(row["apl_percent"]) not in measured_areas
    ]


def read_windows(rows):
    measured = [
        Window(f"{row['pattern']} {row['r']}", (int(row["r"]), int(row["g"]), int(row["b"])),
               float(row["window_percent"]), float(row["self_relative"]))
        for row in rows
    ]
    white_areas = {w.area for w in measured if w.pattern == "white 1023"}
    return measured + read_dense_white(white_areas)


# Load models map a window's codes to the brightest weighted channel the panel drives, relative to its peak

def panel_levels(window, tracking, matrix=BT2020_TO_PANEL):
    drive = np.clip(matrix @ pq_to_nits(window.codes), 0.0, EDID_PEAK_NITS)
    return drive * tracking.factor(drive) / EDID_PEAK_NITS


def native_weighted(window, tracking, weights):
    return window.area * np.max(np.asarray(weights) * panel_levels(window, tracking))


def native_signal_level(window, tracking, weights):
    drive = np.clip(BT2020_TO_PANEL @ pq_to_nits(window.codes), 0.0, EDID_PEAK_NITS) / EDID_PEAK_NITS
    return window.area * np.max(np.asarray(weights) * drive)


def bt2020_brightest(window, tracking, weights):
    levels = np.clip(pq_to_nits(window.codes), 0.0, EDID_PEAK_NITS)
    return window.area * np.max(levels * tracking.factor(levels)) / EDID_PEAK_NITS


def channel_sum(window, tracking, weights):
    return window.area * panel_levels(window, tracking).mean()


def luminance(window, tracking, weights):
    levels = np.clip(pq_to_nits(window.codes), 0.0, EDID_PEAK_NITS)
    return window.area * float(BT2020_LUMA @ (levels * tracking.factor(levels))) / EDID_PEAK_NITS


@dataclass(frozen=True)
class Fit:
    label: str
    curve: tuple
    weights: tuple
    tracking: Tracking
    load_model: object = native_weighted

    def load(self, window):
        return self.load_model(window, self.tracking, self.weights)

    def errors_percent(self, windows):
        measured = np.array([w.dimming for w in windows])
        predicted = 1 / compensation(self.curve, [self.load(w) for w in windows])
        return 100 * (measured / predicted - 1)


def fit(windows, tracking, label, load_model=native_weighted, fit_weights=True):
    log_dimming = np.log([w.dimming for w in windows])
    count = 6 if fit_weights else 4

    def unpack(x):
        weights = (1.0, x[4], x[5]) if fit_weights else (1.0, 1.0, 1.0)
        return Fit(label, tuple(x[:4]), weights, tracking, load_model)

    def residuals(x):
        model = unpack(x)
        return -np.log(compensation(model.curve, [model.load(w) for w in windows])) - log_dimming

    result = least_squares(residuals, PARAM_START[:count], bounds=(PARAM_LOWER[:count], PARAM_UPPER[:count]))
    return unpack(result.x)


def leave_one_out(windows, refit):
    errors = []
    for i, held_out in enumerate(windows):
        model = refit(windows[:i] + windows[i + 1:])
        errors.append(model.errors_percent([held_out])[0])
    return np.array(errors)


def rms(errors):
    return float(np.sqrt(np.mean(np.square(errors))))


def print_comparison(windows, tracking):
    print(f"{'load model':58s} {'mean':>6s} {'rms':>6s} {'worst':>6s} {'held out':>9s}")
    candidates = [
        ("BT.2020 luminance", dict(load_model=luminance, fit_weights=False)),
        ("panel channel sum", dict(load_model=channel_sum, fit_weights=False)),
        ("brightest BT.2020 channel", dict(load_model=bt2020_brightest, fit_weights=False)),
        ("brightest panel channel, weighted, signal level", dict(load_model=native_signal_level)),
        ("brightest panel channel, unweighted", dict(fit_weights=False)),
        ("brightest panel channel, weighted", dict()),
    ]
    for label, options in candidates:
        model = fit(windows, tracking, label, **options)
        held_out = leave_one_out(windows, lambda subset: fit(subset, tracking, label, **options))
        errors = model.errors_percent(windows)
        print(f"{label:58s} {np.mean(np.abs(errors)):5.2f}% {rms(errors):5.2f}% {np.max(np.abs(errors)):5.2f}% "
              f"{rms(held_out):8.2f}%")


def print_rows(model, windows):
    print(f"\nper window, {model.label}")
    for window, error in zip(windows, model.errors_percent(windows)):
        print(f"  {window.pattern:15s} {window.area:5.0f}%  load {model.load(window):6.2f}%  "
              f"dimming {window.dimming:.4f}  error {error:+5.2f}%")


def print_model(model):
    flat_end, knee_load, knee_comp, power = model.curve
    print(f"\nflat to {flat_end:.4f}%, knee at {knee_load:.4f}% and {knee_comp:.5f}, power {power:.5f}, "
          f"weights {model.weights[1]:.5f} {model.weights[2]:.5f}")
    loads = [3, 4, 5, 7, 10, 15, 25, 50, 100]
    print("compensation  " + "  ".join(f"{l}%:{c:.3f}" for l, c in zip(loads, compensation(model.curve, loads))))
    grid = np.linspace(0.5, 100, 4000)
    print(f"peak elasticity {np.max(elasticity(model.curve, grid)):.3f}, lowest full-compensation ceiling "
          f"{EDID_PEAK_NITS / compensation(model.curve, 100.0):.1f} nits")


# Rules

def curvature_step(curve):
    """Largest change between neighbors of the curve's second log derivative on a fine grid, as a share of its
    largest value. A kink in the curve or its slope shows up as a jump."""
    x = np.linspace(np.log2(0.5), np.log2(100.0), 40001)
    y = log2_compensation(curve, np.exp2(x))
    second = np.diff(y, 2) / (x[1] - x[0]) ** 2
    return float(np.max(np.abs(np.diff(second))) / np.max(np.abs(second)))


def rule_failures(model, windows):
    failures = []
    peak = float(np.max(elasticity(model.curve, np.linspace(0.5, 100, 4000))))
    if peak >= MAX_ELASTICITY:
        failures.append(f"elasticity reaches {peak:.3f}, the gain could stop settling on one fixed point")
    mean = float(np.mean(np.abs(model.errors_percent(windows))))
    if mean >= MAX_MEAN_ERROR_PERCENT:
        failures.append(f"mean error {mean:.2f}% over {len(windows)} windows")
    step = curvature_step(model.curve)
    if step >= MAX_CURVATURE_STEP:
        failures.append(f"the curve's curvature jumps by {step:.2f} of its largest value")
    return failures


def hlsl_matrix(matrix):
    return ",\n    ".join(", ".join(f"{v:9.6f}" for v in row) for row in matrix)


def hlsl_list(values, digits):
    return ", ".join(f"{v:.{digits}f}" for v in values)


def include_text(model):
    flat_end, knee_load, knee_comp, power = model.curve
    tracking = model.tracking
    points = len(tracking.nits)
    return f"""// Generated by Shaders/verify/fit_panel_model.py from abl_curve.csv and {DENSE_WHITE_REVISION}. Don't edit by hand.
// The 27M2N6500's dimming in HDR Peak 1000 mode. A pixel's load is its brightest panel subpixel drive, in the panel's
// native primaries, clamped to the peak, shown at the panel's own tracking and weighted per subpixel. The frame load is
// the mean of that over PANEL_LOAD_PEAK_NITS, in percent. Compensation models a single-pole response toward a
// higher load over PANEL_DIM_SECONDS and toward a lower load over PANEL_UNDIM_SECONDS. These response times are
// tuned from observed transition flashes, not fitted from the steady-state measurements.

#pragma once

static const float EDID_PEAK_NITS         = {EDID_PEAK_NITS:.6f};
static const float PANEL_PEAK_NITS        = EDID_PEAK_NITS;
// Brightest 10-bit PQ code at or under the peak, the top of every boosted frame
static const float PANEL_SIGNAL_PEAK_NITS = {signal_peak_nits():.2f};
static const float PANEL_LOAD_PEAK_NITS   = EDID_PEAK_NITS;

static const float3 PANEL_SUBPIXEL_WEIGHTS = float3({hlsl_list(model.weights, 6)});

static const float3x3 REC709_TO_PANEL = float3x3(
    {hlsl_matrix(REC709_TO_PANEL)});
static const float3x3 BT2020_TO_PANEL = float3x3(
    {hlsl_matrix(BT2020_TO_PANEL)});

// Level the panel shows over the level it's sent, without dimming, linear in PQ between the points
#define PANEL_TRACKING_POINTS {points}
static const float PANEL_TRACKING_NITS[PANEL_TRACKING_POINTS]  = {{ {hlsl_list(tracking.nits, 4)} }};
static const float PANEL_TRACKING_SHARE[PANEL_TRACKING_POINTS] = {{ {hlsl_list(tracking.shown_share, 6)} }};

static const float PANEL_FLAT_END_LOAD    = {flat_end:.6f};
static const float2 PANEL_KNEE_POINT      = float2({knee_load:.6f}, {knee_comp:.6f});
static const float PANEL_TAIL_EXPONENT    = {power:.6f};
static const float PANEL_FLAT_SMOOTH_TAU  = {FLAT_SMOOTH_TAU:.6f};
static const float PANEL_KNEE_SMOOTH_TAU  = {KNEE_SMOOTH_TAU:.6f};

// Assumed temporal response (seconds), toward a higher load and toward a lower one; zero means immediate
static const float PANEL_DIM_SECONDS      = {PANEL_DIM_SECONDS:.6f};
static const float PANEL_UNDIM_SECONDS    = {PANEL_UNDIM_SECONDS:.6f};

float PanelSmoothMax0(float x, float tau)
{{
    return 0.5 * (x + sqrt(x * x + tau * tau));
}}

// 0 at and below 0, x at and above PANEL_FLAT_SMOOTH_TAU, and a quintic between that leaves both ends with a zero
// second derivative, so the curve is smooth where it starts.
float PanelSmoothRamp(float x)
{{
    float t = clamp(x / PANEL_FLAT_SMOOTH_TAU, 0.0, 1.0);
    float curved = PANEL_FLAT_SMOOTH_TAU * t * t * t * (6.0 + t * (-8.0 + 3.0 * t));
    return (x >= PANEL_FLAT_SMOOTH_TAU) ? x : curved;
}}

// Compensation factor, nominal over shown, at a panel load in percent. Flat at 1 below PANEL_FLAT_END_LOAD, linear in
// load up to PANEL_KNEE_POINT and a power law above it, with both corners smooth.
float EvaluatePanelCompensation(float loadPercent)
{{
    float load = clamp(loadPercent, 1e-4, 100.0);
    float slope = (PANEL_KNEE_POINT.y - 1.0) / (PANEL_KNEE_POINT.x - PANEL_FLAT_END_LOAD);
    float ramp = 1.0 + slope * PanelSmoothRamp(load - PANEL_FLAT_END_LOAD);
    float logRamp = log2(ramp);
    float logTail = log2(PANEL_KNEE_POINT.y) + PANEL_TAIL_EXPONENT * log2(load / PANEL_KNEE_POINT.x);
    float corner = slope * PANEL_KNEE_POINT.x / PANEL_KNEE_POINT.y - PANEL_TAIL_EXPONENT;
    float log2Comp = logTail - corner * PanelSmoothMax0((logTail - logRamp) / corner, PANEL_KNEE_SMOOTH_TAU);
    return max(exp2(log2Comp), 1.0);
}}

float PanelNitsToPQ(float nits)
{{
    float y = pow(saturate(nits / 10000.0), 0.1593017578125);
    return pow((0.8359375 + 18.8515625 * y) / (1.0 + 18.6875 * y), 78.84375);
}}

float PanelTrackingShare(float nits)
{{
    float pq = PanelNitsToPQ(nits);
    float share = PANEL_TRACKING_SHARE[0];

    [unroll]
    for (int upper = 1; upper < PANEL_TRACKING_POINTS; ++upper)
    {{
        float lowerPQ = PanelNitsToPQ(PANEL_TRACKING_NITS[upper - 1]);
        float upperPQ = PanelNitsToPQ(PANEL_TRACKING_NITS[upper]);
        float t = saturate((pq - lowerPQ) / (upperPQ - lowerPQ));
        share = (pq > lowerPQ) ? lerp(PANEL_TRACKING_SHARE[upper - 1], PANEL_TRACKING_SHARE[upper], t) : share;
    }}

    return share;
}}

// A pixel's load in nits, from 0 to PANEL_LOAD_PEAK_NITS, for its linear color in the panel's native primaries
float PanelLoadNitsFromPanelRGB(float3 panelNits)
{{
    float3 drive = clamp(panelNits, 0.0, PANEL_PEAK_NITS);
    float3 shown = drive * float3(PanelTrackingShare(drive.r), PanelTrackingShare(drive.g), PanelTrackingShare(drive.b));
    float3 weighted = shown * PANEL_SUBPIXEL_WEIGHTS;
    return max(max(weighted.r, weighted.g), weighted.b);
}}

float PanelLoadNitsFromRec2020(float3 rec2020Nits)
{{
    return PanelLoadNitsFromPanelRGB(mul(BT2020_TO_PANEL, rec2020Nits));
}}

float PanelLoadNitsFromRec709(float3 rec709Nits)
{{
    return PanelLoadNitsFromPanelRGB(mul(REC709_TO_PANEL, rec709Nits));
}}
"""


def main():
    rows = read_rows()
    tracking = read_tracking(rows)
    windows = read_windows(rows)
    model = fit(windows, tracking, "brightest panel channel, weighted")
    failures = rule_failures(model, windows)

    if "--check" in sys.argv:
        if INCLUDE.read_text() != include_text(model):
            failures.append(f"{INCLUDE.name} is stale, run fit_panel_model.py")
        for failure in failures:
            print(f"FAIL {failure}")
        if failures:
            sys.exit(1)
        print(f"{INCLUDE.name} matches the fit, mean error "
              f"{np.mean(np.abs(model.errors_percent(windows))):.2f}% over {len(windows)} windows")
        return

    print_comparison(windows, tracking)
    print_rows(model, windows)
    print_model(model)
    for failure in failures:
        print(f"FAIL {failure}")
    INCLUDE.write_text(include_text(model))
    print(f"\nwrote {INCLUDE.relative_to(ROOT)}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
