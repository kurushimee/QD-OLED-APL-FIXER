"""Replays boosted frames through the panel model and reports how far what the panel shows lands from the PQ target.

Usage:
    python eotf_check.py <source.png> <boosted.png> [<boosted.png> ...]
    python eotf_check.py --suite [--space hdr10|scrgb|both] [--effect path.fx]

Frames are 16-bit PQ BT.2020 PNGs, like RenderEffect's input and output. The panel shows each pixel's sent level over
the compensation at its filtered load: the frame mean of each pixel's brightest weighted subpixel drive in the panel's
native primaries, with assumed slow dimming and immediate release on a lower load. A single
frame is replayed at its steady state, its own load. The panel's static tracking only enters the load, since the boost
doesn't change it.

--suite builds synthetic frames, runs the effect on them through RenderEffect and checks:
    static       nothing sent past the signal peak, the curve rises, a dim frame shows exact, the overlays stay under
                 the peak
    temporal     fixed patches stay within a quarter code of target on every frame after a load change
    tab switch   a white-to-black cut leaves no residual boost on the very first dark frame, including a quick return
    frame rate   the same change at 60 and 240 fps shows the same at the same moments
    midtones     a bright highlight at 5 to 20% coverage leaves the patches exact
    outlier      one 4000 nit pixel moves no other level by more than half a code
    breathing    a highlight sweeping 300 to 900 nits moves a fixed lamp without jumps
    whiteout     a snowfield sweeping 50 to 95% coverage moves the gain without jumps
"""

import argparse
import math
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

import fit_panel_model as model_fit

HERE = Path(__file__).resolve().parent
INCLUDE = HERE.parent / "PanelModel_27M2N6500.fxh"
EFFECT = HERE.parent / "EOTF_BoostMod3.1_27M2N6500.fx"
RENDER_EFFECT = HERE / "build" / "bin" / "Release" / "RenderEffect.exe"

LEVEL_BANDS = [0.0, 1.0, 10.0, 50.0, 100.0, 203.0, 400.0, 700.0, 10000.0]
# A dither spreads a pixel by up to a code, so means wobble by a few hundredths of one
MONOTONE_TOLERANCE_CODES = 0.25
PEAK_TOLERANCE = 1.001

PATCH_TOLERANCE_CODES = 0.25
OUTLIER_TOLERANCE_CODES = 0.5
DIM_FRAME_MAX_ERROR_STOPS = 0.001
# A step counts as a jump when it's this many times the typical step, plus a floor for rounding
JUMP_FACTOR = 3.0

FRAME_WIDTH = 976
FRAME_HEIGHT = 540
FRAME_MS = {"60 fps": 1000.0 / 60.0, "240 fps": 1000.0 / 240.0}
SEQUENCE_SECONDS = 0.5


# ---------------------------------------------------------------------------------------------------------------------
# Panel model, read from the include the shader compiles
# ---------------------------------------------------------------------------------------------------------------------

def include_constants():
    text = INCLUDE.read_text()
    scalars = {name: float(value) for name, value in re.findall(r"static const float (\w+)\s*=\s*([-\d.]+);", text)}
    vectors = {name: tuple(float(v) for v in values.split(","))
               for name, values in re.findall(r"static const float\d (\w+)\s*=\s*float\d\(([^)]*)\);", text)}
    arrays = {name: tuple(float(v) for v in values.split(","))
              for name, values in re.findall(r"static const float (\w+)\[\w+\]\s*=\s*\{([^}]*)\};", text)}
    return scalars, vectors, arrays


@dataclass(frozen=True)
class PanelModel:
    curve: tuple
    weights: np.ndarray
    tracking: model_fit.Tracking
    peak_nits: float
    signal_peak_nits: float
    load_peak_nits: float
    dim_seconds: float
    undim_seconds: float

    @staticmethod
    def from_include():
        scalars, vectors, arrays = include_constants()
        knee = vectors["PANEL_KNEE_POINT"]
        peak = model_fit.EDID_PEAK_NITS
        return PanelModel(
            curve=(scalars["PANEL_FLAT_END_LOAD"], knee[0], knee[1], scalars["PANEL_TAIL_EXPONENT"]),
            weights=np.array(vectors["PANEL_SUBPIXEL_WEIGHTS"]),
            tracking=model_fit.Tracking(arrays["PANEL_TRACKING_NITS"], arrays["PANEL_TRACKING_SHARE"]),
            peak_nits=peak,
            signal_peak_nits=scalars["PANEL_SIGNAL_PEAK_NITS"],
            load_peak_nits=peak,
            dim_seconds=scalars["PANEL_DIM_SECONDS"],
            undim_seconds=scalars["PANEL_UNDIM_SECONDS"])

    def compensation(self, load_percent):
        return float(model_fit.compensation(self.curve, load_percent))

    def frame_load_percent(self, rec2020_nits):
        drive = np.clip(np.einsum("ij,hwj->hwi", model_fit.BT2020_TO_PANEL, rec2020_nits), 0.0, self.peak_nits)
        shown = drive * self.tracking.factor(drive)
        load = (shown * self.weights).max(axis=2)
        return 100.0 * float(load.mean()) / self.load_peak_nits

    def filter_alphas(self, frame_ms):
        """Shares of the way the panel moves toward a higher load and toward a lower one over one frame"""
        seconds = min(max(frame_ms, 1.0), 250.0) / 1000.0
        def alpha(response_seconds):
            return 1.0 - math.exp(-seconds / response_seconds) if response_seconds > 0.0 else 1.0
        return alpha(self.dim_seconds), alpha(self.undim_seconds)

    def panel_loads(self, frames, start_load, frame_ms):
        """Filtered load the panel sits at on each frame of a sequence, from the load it held before"""
        dim_alpha, undim_alpha = self.filter_alphas(frame_ms)
        loads, state = [], start_load
        for frame in frames:
            load = self.frame_load_percent(frame)
            state += (dim_alpha if load > state else undim_alpha) * (load - state)
            loads.append(state)
        return loads


PANEL = PanelModel.from_include()


# ---------------------------------------------------------------------------------------------------------------------
# Frames
# ---------------------------------------------------------------------------------------------------------------------

def nits_to_pq(nits):
    return model_fit.pq_encode(nits)


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


def read_nits(path):
    return pq_to_nits(read_png16(path))


def write_frame(path, nits):
    codes = np.round(nits_to_pq(nits) * 65535.0).astype(np.uint16)
    cv2.imwrite(str(path), codes[:, :, ::-1])


def ten_bit_nits(nits):
    """What an HDR10 back buffer holds for a frame"""
    return pq_to_nits(np.round(nits_to_pq(nits) * 1023) / 1023)


def codes_of(nits):
    return 1023.0 * nits_to_pq(nits)


# ---------------------------------------------------------------------------------------------------------------------
# Single frames at their steady state
# ---------------------------------------------------------------------------------------------------------------------

def report(source_nits, boosted_nits, label):
    load = PANEL.frame_load_percent(boosted_nits)
    shown = boosted_nits / PANEL.compensation(load)

    source_level = source_nits.max(axis=2)
    shown_level = shown.max(axis=2)
    target_level = np.minimum(source_level, PANEL.peak_nits)
    lit = source_level > 0.01
    error = np.zeros_like(source_level)
    error[lit] = shown_level[lit] / target_level[lit] - 1.0
    log_error = float(np.mean(np.abs(np.log2(np.maximum(shown_level[lit], 1e-6) / target_level[lit])))) if lit.any() else 0.0

    print(f"\n{label}: load {PANEL.frame_load_percent(source_nits):.1f}% raw, {load:.1f}% boosted, "
          f"compensation {PANEL.compensation(load):.3f}")
    print(f"  mean |error| {100 * np.mean(np.abs(error[lit])) if lit.any() else 0.0:.2f}%, "
          f"pixel-weighted log2 error {log_error:.4f}")
    for low, high in zip(LEVEL_BANDS, LEVEL_BANDS[1:]):
        band = lit & (source_level >= low) & (source_level < high)
        if band.any():
            print(f"  source {low:6.0f} to {high:6.0f} nits: {100 * band.mean():5.1f}% of pixels, "
                  f"mean error {100 * error[band].mean():+6.2f}%, worst {100 * np.abs(error[band]).max():6.2f}%")

    failures = static_failures(source_level[lit], boosted_nits, nits_to_pq(boosted_nits.max(axis=2))[lit])
    print(f"  sent peak {boosted_nits.max():.1f} nits")
    for failure in failures:
        print(f"  FAIL {failure}")
    return log_error, failures


def static_failures(source_level, boosted_nits, boosted_pq_level):
    failures = []
    sent_peak = boosted_nits.max()
    if sent_peak > PANEL.signal_peak_nits * PEAK_TOLERANCE:
        failures.append(f"sends {sent_peak:.1f} nits past the {PANEL.signal_peak_nits:.1f} nit signal peak")
    if not curve_rises(source_level, 1023 * boosted_pq_level):
        failures.append("the curve falls somewhere")
    return failures


def curve_rises(source_level, boosted_codes):
    """Compares each source level's mean output in 10-bit codes"""
    if source_level.size == 0:
        return True
    order = np.argsort(source_level, kind="stable")
    levels, outputs = source_level[order], boosted_codes[order]
    _, starts, counts = np.unique(levels, return_index=True, return_counts=True)
    means = np.add.reduceat(outputs, starts) / counts
    running_max = np.maximum.accumulate(means)
    return bool(np.all(means[1:] + MONOTONE_TOLERANCE_CODES >= running_max[:-1]))


# ---------------------------------------------------------------------------------------------------------------------
# Suite scenes
# ---------------------------------------------------------------------------------------------------------------------

# Two reference patches at fixed spots on the left, 60 and 150 nits, which every scene keeps.
PATCHES = {60.0: (slice(200, 260), slice(40, 100)), 150.0: (slice(280, 340), slice(40, 100))}
CONTENT_LEFT = 140


def blank(nits=0.0):
    return np.full((FRAME_HEIGHT, FRAME_WIDTH, 3), nits, dtype=np.float64)


def with_patches(frame):
    for nits, (rows, cols) in PATCHES.items():
        frame[rows, cols] = nits
    return frame


def scene(background_nits):
    return with_patches(blank(background_nits))


def window(frame, nits, area, center=(0.5, 0.6)):
    side = int(round(math.sqrt(area * FRAME_WIDTH * FRAME_HEIGHT)))
    top = int(center[0] * FRAME_HEIGHT - side / 2)
    left = int(center[1] * FRAME_WIDTH - side / 2)
    frame[max(top, 0):top + side, max(left, CONTENT_LEFT):left + side] = nits
    return with_patches(frame)


def sky(top_nits=800.0, cover=0.4):
    frame = blank(60.0)
    rows = int(FRAME_HEIGHT * cover)
    gradient = np.linspace(top_nits, top_nits / 2, rows)[:, None, None]
    frame[:rows, CONTENT_LEFT:] = gradient
    ground = np.linspace(50.0, 200.0, FRAME_WIDTH - CONTENT_LEFT)[None, :, None]
    frame[rows:, CONTENT_LEFT:] = ground
    return with_patches(frame)


def snowfield(cover):
    rng = np.random.default_rng(3)
    frame = blank(15.0)
    columns = CONTENT_LEFT + int((FRAME_WIDTH - CONTENT_LEFT) * cover)
    texture = 500.0 + 150.0 * rng.random((FRAME_HEIGHT, columns - CONTENT_LEFT, 1))
    frame[:, CONTENT_LEFT:columns] = texture
    return with_patches(frame)


def game():
    frame = blank(0.0)
    x = np.linspace(0.0, 1.0, FRAME_WIDTH)[None, :, None]
    y = np.linspace(0.0, 1.0, FRAME_HEIGHT)[:, None, None]
    frame[:] = 20.0 + 60.0 * x * (1.0 - y)
    frame[100:130, 600:640] = 900.0
    frame[300:340, 400:460] = 400.0 * np.array([1.0, 0.6, 0.2])
    return with_patches(frame)


def saturated():
    frame = blank(10.0)
    colors = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1), (1, 0, 1)]
    width = (FRAME_WIDTH - CONTENT_LEFT) // len(colors)
    for index, color in enumerate(colors):
        left = CONTENT_LEFT + index * width
        frame[:, left:left + width] = np.array(color) * 300.0
    return with_patches(frame)


def dim():
    frame = blank(0.0)
    frame[:] = np.linspace(0.0, 60.0, FRAME_WIDTH)[None, :, None]
    return frame


# ---------------------------------------------------------------------------------------------------------------------
# Running the effect
# ---------------------------------------------------------------------------------------------------------------------

class Renderer:
    def __init__(self, effect, space, folder):
        self.effect, self.space, self.folder = effect, space, folder
        self.count = 0

    def _path(self, label):
        self.count += 1
        return self.folder / f"{self.count:04d}_{label}.png"

    def _run(self, arguments):
        result = subprocess.run([str(RENDER_EFFECT), str(self.effect), self.space, *map(str, arguments)],
                                capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(f"RenderEffect failed:\n{result.stdout}{result.stderr}")
        return result.stdout

    def source(self, nits, label):
        path = self._path(label)
        write_frame(path, nits)
        return path

    def settled(self, nits, label, *settings):
        source = self.source(nits, label)
        output = self._path(label + "_out")
        self._run([source, output, *settings])
        return read_nits(source), read_nits(output)

    def sequence(self, previous, steps, frame_ms, label):
        """Settles on previous, then runs each (frame, count) step, and returns every output frame"""
        previous_path = self.source(previous, label + "_from")
        paths = [(self.source(frame, f"{label}_{index}"), count) for index, (frame, count) in enumerate(steps)]
        output = self._path(label + "_seq")
        arguments = [paths[0][0], output, "--frame-ms", f"{frame_ms:.6f}", "--from", previous_path,
                     "--frames", paths[0][1]]
        for path, count in paths[1:]:
            arguments += ["--then", path, count]
        self._run(arguments)
        total = sum(count for _, count in steps)
        stem = output.with_suffix("")
        return [read_nits(Path(f"{stem}_{index:04d}.png")) for index in range(total)]

    def after(self, previous, current, frame_ms, frames, label):
        """Read only the last frame of a held transition, without retaining a long sequence in memory."""
        before = self.source(previous, label + "_from")
        source = self.source(current, label)
        output = self._path(label + "_seq")
        self._run([source, output, "--frame-ms", frame_ms, "--from", before, "--frames", frames])
        return read_nits(Path(f"{output.with_suffix('')}_{frames - 1:04d}.png"))


def patch_errors_codes(output_nits, panel_load, space):
    """Each patch's shown level against the signal that actually entered the back buffer."""
    compensation = PANEL.compensation(panel_load)
    errors = {}
    for nits, (rows, cols) in PATCHES.items():
        shown = output_nits[rows, cols].max(axis=2).mean() / compensation
        target_code = float(codes_of(nits))
        if space == "hdr10":
            target_code = round(target_code)
        errors[nits] = float(codes_of(shown) - target_code)
    return errors


def worst_patch_error(errors):
    return max(abs(e) for e in errors.values())


def jumps(values, floor):
    """Steps much larger than the typical step, which a smooth change never makes"""
    steps = np.abs(np.diff(np.asarray(values, dtype=float)))
    if steps.size == 0:
        return 0.0, 0.0
    limit = JUMP_FACTOR * float(np.median(steps)) + floor
    return float(steps.max()), limit


# ---------------------------------------------------------------------------------------------------------------------
# Suite checks
# ---------------------------------------------------------------------------------------------------------------------

def check_static(renderer):
    failures = []
    frames = {"dim": dim(), "game": game(), "sky": sky(), "snow": snowfield(0.9), "saturated": saturated(),
              "window past the peak": window(blank(0.0), 4000.0, 0.10)}
    for name, frame in frames.items():
        source, output = renderer.settled(frame, name.replace(" ", "_"))
        if renderer.space == "hdr10":
            source = ten_bit_nits(source)
        log_error, frame_failures = report(source, output, name)
        if name == "dim" and log_error >= DIM_FRAME_MAX_ERROR_STOPS:
            frame_failures.append(f"dim frame error {log_error:.4f} stops")
        failures += [f"{name}: {f}" for f in frame_failures]

    _, untouched = renderer.settled(scene(10.0), "patch_reference")
    reference_error = worst_patch_error(patch_errors_codes(untouched, PANEL.frame_load_percent(untouched), renderer.space))
    if reference_error > PATCH_TOLERANCE_CODES:
        failures.append(f"untouched reference patches are {reference_error:.3f} codes off")
    print(f"reference patches on an untouched dim frame: {reference_error:.3f} codes off")

    _, overlay = renderer.settled(game(), "overlay", "ShowOSD=1", "OSDBrightness=1")
    if overlay.max() > PANEL.signal_peak_nits * PEAK_TOLERANCE:
        failures.append(f"the stats overlay sends {overlay.max():.1f} nits")
    print(f"\nstats overlay at full brightness sends at most {overlay.max():.1f} nits")
    return failures


def temporal_scenarios(frame_ms):
    count = max(int(round(SEQUENCE_SECONDS * 1000.0 / frame_ms)), 1)
    flash = max(int(round(50.0 / frame_ms)), 1)
    dark = scene(30.0)
    lit = window(scene(30.0), 900.0, 0.05)
    grow = [window(scene(60.0), 500.0, 0.2 * (index + 1) / count) for index in range(count)]
    return {
        "window comes in": (dark, [(lit, count)]),
        "window leaves": (lit, [(dark, count)]),
        "50 ms muzzle flash": (scene(40.0), [(window(scene(40.0), 1000.0, 0.08), flash), (scene(40.0), count)]),
        "area grows over 0.5 s": (scene(60.0), [(frame, 1) for frame in grow]),
        "cut to a bright field": (scene(5.0), [(scene(150.0), count)]),
    }


def replay_sequence(renderer, previous, steps, frame_ms, label):
    _, settled_previous = renderer.settled(previous, label + "_settle")
    outputs = renderer.sequence(previous, steps, frame_ms, label)
    loads = PANEL.panel_loads(outputs, PANEL.frame_load_percent(settled_previous), frame_ms)
    return [patch_errors_codes(output, load, renderer.space) for output, load in zip(outputs, loads)]


def check_temporal(renderer):
    failures = []
    trajectories = {}
    for rate, frame_ms in FRAME_MS.items():
        for name, (previous, steps) in temporal_scenarios(frame_ms).items():
            errors = replay_sequence(renderer, previous, steps, frame_ms, f"{rate}_{name}".replace(" ", "_"))
            worst = max(worst_patch_error(e) for e in errors)
            ok = worst <= PATCH_TOLERANCE_CODES
            failures += [] if ok else [f"{name} at {rate}: patches {worst:.3f} codes off"]
            print(f"{'ok  ' if ok else 'FAIL'} {name} at {rate}: worst patch {worst:.3f} codes over {len(errors)} frames")
            trajectories[(rate, name)] = errors

    for name in temporal_scenarios(FRAME_MS["60 fps"]):
        if name == "area grows over 0.5 s" or name == "50 ms muzzle flash":
            continue
        slow, fast = trajectories[("60 fps", name)], trajectories[("240 fps", name)]
        step = int(round(FRAME_MS["60 fps"] / FRAME_MS["240 fps"]))
        gap = max(abs(slow[k][nits] - fast[(k + 1) * step - 1][nits])
                  for k in range(len(slow)) if (k + 1) * step <= len(fast)
                  for nits in PATCHES)
        ok = gap <= PATCH_TOLERANCE_CODES
        failures += [] if ok else [f"{name}: 60 and 240 fps differ by {gap:.3f} codes"]
        print(f"{'ok  ' if ok else 'FAIL'} {name}: 60 and 240 fps agree within {gap:.3f} codes")
    return failures


def check_midtones(renderer):
    failures = []
    for area in (0.05, 0.10, 0.20):
        _, output = renderer.settled(window(scene(30.0), 900.0, area), f"midtones_{area}")
        worst = worst_patch_error(patch_errors_codes(output, PANEL.frame_load_percent(output), renderer.space))
        ok = worst <= PATCH_TOLERANCE_CODES
        failures += [] if ok else [f"a 900 nit highlight over {area:.0%} moves the patches by {worst:.3f} codes"]
        print(f"{'ok  ' if ok else 'FAIL'} 900 nit highlight over {area:.0%}: patches {worst:.3f} codes off")
    return failures


def check_tab_release(renderer):
    # Deliberately independent of PANEL.undim_seconds: test against immediate physical ABL release. Both dark
    # frames' sent loads remain below the flat end even with the old residual boost, so their compensation is 1.
    # Replaying the shader's own release time here would hide a hardware/model timing mismatch.
    failures = []
    for rate, frame_ms in FRAME_MS.items():
        for dark_nits in (0.0, 1.0):
            dark = scene(dark_nits)
            _, reference = renderer.settled(dark, "dark_reference", "EnableEOTFBoost=0")
            for white_nits in (203.0, 1000.0):
                white = scene(white_nits)
                steps = [(dark, 2), (white, 1), (dark, 2)]
                outputs = renderer.sequence(white, steps, frame_ms, f"tab_release_{rate}_{white_nits:.0f}_{dark_nits:.0f}")
                for index in (0, 1, 3, 4):
                    output = outputs[index]
                    sent_load = PANEL.frame_load_percent(output)
                    if sent_load >= PANEL.curve[0]:
                        failures.append(f"tab release fixture exceeds the flat load: {sent_load:.4f}%")
                    worst = worst_patch_error(patch_errors_codes(output, 0.0, renderer.space))
                    unchanged = np.array_equal(output, reference)
                    ok = worst <= PATCH_TOLERANCE_CODES and unchanged
                    print(f"{'ok  ' if ok else 'FAIL'} {white_nits:.0f} to {dark_nits:.0f} nit tab at {rate}, "
                          f"dark frame {index}: {worst:.3f} codes off, unchanged={unchanged}")
                    if not ok:
                        failures.append(f"{white_nits:.0f} to {dark_nits:.0f} nit tab at {rate}, dark frame {index}: "
                                        f"residual boost {worst:.3f} codes, unchanged={unchanged}")
    return failures


def grouped_code_difference(source, plain, changed, excluded=None):
    """Compare means by source level, so fixed dithering is averaged over like pixels."""
    level = np.round(codes_of(source.max(axis=2))).astype(int)
    mask = np.ones_like(level, dtype=bool)
    if excluded is not None:
        mask[excluded] = False
    plain_codes, changed_codes = codes_of(plain.max(axis=2)), codes_of(changed.max(axis=2))
    worst = 0.0
    for code in np.unique(level[mask]):
        group = mask & (level == code)
        worst = max(worst, abs(float(changed_codes[group].mean() - plain_codes[group].mean())))
    return worst


def check_outlier(renderer):
    failures = []
    cases = [("4000 nit spark", game(), (50, 900), 4000.0),
             ("same level bin", window(scene(30.0), 900.0, 0.08), (270, 585), 1000.0),
             ("same sub-bin", window(scene(30.0), 900.0, 0.08), (270, 585), 920.0)]
    for label, base, position, nits in cases:
        spark = base.copy()
        spark[position] = nits
        source, plain = renderer.settled(base, "outlier_plain")
        _, sparked = renderer.settled(spark, "outlier_spark")
        worst = grouped_code_difference(source, plain, sparked, position)
        ok = worst <= OUTLIER_TOLERANCE_CODES
        print(f"{'ok  ' if ok else 'FAIL'} {label}: one pixel moves other levels by at most {worst:.3f} codes")
        if not ok:
            failures.append(f"{label}: one pixel moves other levels by {worst:.3f} codes")
    return failures


def check_breathing(renderer):
    lamp = (slice(60, 90), slice(800, 830))
    lamp_codes = []
    for nits in np.geomspace(300.0, 900.0, 40):
        frame = window(scene(40.0), nits, 0.08, center=(0.6, 0.5))
        frame[lamp] = 500.0
        _, output = renderer.settled(frame, f"breathing_{nits:.0f}")
        lamp_codes.append(float(codes_of(output[lamp].max(axis=2).mean())))
    # The lamp stays on the ceiling until the moving highlight passes it, then starts to compress. A global median
    # includes that long flat section and mistakes a smooth steep section for a jump. Compare each step with its
    # neighbors instead; the one-nit edge probes below independently bound actual histogram discontinuities.
    steps = np.abs(np.diff(lamp_codes))
    neighbors = np.maximum(np.r_[0.0, steps[:-1]], np.r_[steps[1:], 0.0])
    limits = JUMP_FACTOR * neighbors + PATCH_TOLERANCE_CODES
    worst_index = int(np.argmax(steps / limits))
    largest, limit = float(steps[worst_index]), float(limits[worst_index])
    ok = bool(np.all(steps <= limits))
    print(f"{'ok  ' if ok else 'FAIL'} a highlight sweeping 300 to 900 nits: worst local step {largest:.3f} codes, "
          f"its jump limit is {limit:.3f}")
    failures = [] if ok else [f"the lamp jumps by {largest:.3f} codes, local limit {limit:.3f}"]
    # One-nit probes on either side of coarse histogram edges catch count transfers a broad sweep can miss.
    for edge in (384.0, 448.0, 512.0, 640.0, 768.0):
        codes = []
        for nits in (edge - 1.0, edge):
            frame = window(scene(40.0), nits, 0.08, center=(0.6, 0.5))
            frame[lamp] = 500.0
            _, output = renderer.settled(frame, f"bin_edge_{nits:.0f}")
            codes.append(float(codes_of(output[lamp].max(axis=2).mean())))
        step = abs(codes[1] - codes[0])
        ok = step <= OUTLIER_TOLERANCE_CODES
        print(f"{'ok  ' if ok else 'FAIL'} crossing {edge:.0f} nits moves the lamp by {step:.3f} codes")
        if not ok:
            failures.append(f"crossing {edge:.0f} nits moves the lamp by {step:.3f} codes")
    return failures


def check_settling(renderer):
    failures = []
    frame_ms = FRAME_MS["240 fps"]
    output = renderer.after(scene(10.0), scene(38.0), frame_ms, 480, "load_settle")
    error = worst_patch_error(patch_errors_codes(output, PANEL.frame_load_percent(output), renderer.space))
    ok = error <= PATCH_TOLERANCE_CODES
    print(f"{'ok  ' if ok else 'FAIL'} 10 to 38 nits at 240 fps: patches {error:.3f} codes off after 2 s")
    if not ok:
        failures.append(f"the load filter freezes {error:.3f} codes from the target")

    pipeline = (HERE.parents[1] / "DwmBoost" / "hook" / "pipeline.h").read_text()
    seconds = float(re.search(r"SETTLE_SECONDS\s*=\s*([\d.]+)", pipeline).group(1))
    previous = window(scene(30.0), 10000.0, 0.08)
    current = window(scene(30.0), 500.0, 0.08)
    _, settled = renderer.settled(current, "top_settled")
    output = renderer.after(previous, current, frame_ms, math.ceil(seconds * 1000.0 / frame_ms), "top_release")
    error = grouped_code_difference(current, settled, output)
    ok = error <= OUTLIER_TOLERANCE_CODES
    print(f"{'ok  ' if ok else 'FAIL'} content top after DWM's {seconds:.2f} s deadline: {error:.3f} codes from settled")
    if not ok:
        failures.append(f"DWM's deadline leaves the curve {error:.3f} codes from settled")
    return failures


def check_wide_histogram(renderer):
    failures = []
    reference = None
    for width in (1920, 7680, 16384):
        frame = np.empty((64, width, 3), dtype=np.float64)
        frame[:] = (80.0, 0.0, 0.0)
        frame[:, :width // 16] = 60.0
        _, output = renderer.settled(frame, f"wide_{width}")
        code = float(codes_of(output[32, width // 2].max()))
        if reference is None:
            reference = code
        difference = abs(code - reference)
        ok = difference <= PATCH_TOLERANCE_CODES
        print(f"{'ok  ' if ok else 'FAIL'} {width}-wide histogram: {difference:.3f} codes from the native-width result")
        if not ok:
            failures.append(f"{width}-wide histogram differs by {difference:.3f} codes")
    return failures


def check_null_loads(renderer):
    failures = []
    # Hold the test's clock at each state while retaining its actual passes, geometry and load calculations.
    text = (HERE.parent / "ABL_NullTest.fx").read_text()
    clock = 'uniform float Timer < source = "timer"; >;'
    if clock not in text:
        raise RuntimeError("the null test's timer declaration changed")
    for state in (0, 1):
        effect = renderer.folder / f"null_state_{state}.fx"
        effect.write_text(text.replace(clock, f"static const float Timer = {1000.0 * state:.1f};"))
    shutil.copy(INCLUDE, renderer.folder / INCLUDE.name)
    for test in (0, 1, 2, 3, 4, 14):
        loads = []
        for state in (0, 1):
            effect = renderer.folder / f"null_state_{state}.fx"
            null = Renderer(effect, renderer.space, renderer.folder)
            _, output = null.settled(np.zeros((180, 320, 3)), f"null_{test}_{state}", f"Test={test}")
            loads.append(PANEL.frame_load_percent(output))
        target = 8.0 if test == 14 else 5.0
        error = max(abs(load - target) for load in loads)
        ok = error <= 0.005 * target
        print(f"{'ok  ' if ok else 'FAIL'} null test {test}: loads {loads[0]:.4f}% and {loads[1]:.4f}%, target {target:.1f}%")
        if not ok:
            failures.append(f"null test {test}: loads {loads} instead of {target}%")
    return failures


def check_whiteout(renderer):
    rows, cols = PATCHES[60.0]
    log_gains = []
    for cover in np.linspace(0.5, 0.95, 46):
        _, output = renderer.settled(snowfield(cover), f"whiteout_{cover:.2f}")
        log_gains.append(math.log2(output[rows, cols].max(axis=2).mean() / 60.0))
    largest, limit = jumps(log_gains, math.log2(1.005))
    ok = largest <= limit
    print(f"{'ok  ' if ok else 'FAIL'} a snowfield sweeping 50 to 95% moves the gain from {2 ** log_gains[0]:.3f} to "
          f"{2 ** log_gains[-1]:.3f}, at most {100 * (2 ** largest - 1):.2f}% a step, the jump limit is "
          f"{100 * (2 ** limit - 1):.2f}%")
    return [] if ok else [f"the whiteout gain jumps by {100 * (2 ** largest - 1):.2f}%"]


def run_suite(effect, spaces):
    if not RENDER_EFFECT.exists():
        sys.exit(f"{RENDER_EFFECT} isn't built, see CLAUDE.md")

    failures = []
    for space in spaces:
        print(f"\n===== {space} =====")
        with tempfile.TemporaryDirectory() as folder:
            renderer = Renderer(effect, space, Path(folder))
            for check in (check_static, check_temporal, check_tab_release, check_midtones, check_outlier, check_breathing, check_whiteout,
                          check_settling, check_wide_histogram, check_null_loads):
                print(f"\n--- {check.__name__[len('check_'):]}")
                failures += [f"{space} {f}" for f in check(renderer)]

    print("\nall checks pass" if not failures else "\n" + "\n".join(f"FAIL {f}" for f in failures))
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("frames", nargs="*", help="source.png and one or more boosted.png")
    parser.add_argument("--suite", action="store_true")
    parser.add_argument("--space", choices=["hdr10", "scrgb", "both"], default="both")
    parser.add_argument("--effect", type=Path, default=EFFECT)
    args = parser.parse_args()

    if args.suite:
        spaces = ["hdr10", "scrgb"] if args.space == "both" else [args.space]
        sys.exit(run_suite(args.effect.resolve(), spaces))

    if len(args.frames) < 2:
        parser.error("give a source and at least one boosted frame, or --suite")

    # The HDR10 back buffer holds 10-bit codes, so that's the source the shader sees
    source_nits = ten_bit_nits(read_nits(args.frames[0]))
    results = [report(source_nits, read_nits(path), Path(path).name) for path in args.frames[1:]]
    sys.exit(0 if all(not failures for _, failures in results) else 1)


if __name__ == "__main__":
    main()
