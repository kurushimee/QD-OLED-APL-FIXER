#!/usr/bin/env python3
# Numeric parity check for boost.hlsl against the ReShade shader's values.
#
# A CPU mirror of the histogram, the curve solve, the boost and its detail step. It checks that the baked table
# matches the measured peaks, that from an unboosted frame the gain reaches the closed-loop solve within the host's
# settle runs, that the boost never darkens and rises with the level, that through cuts and flashes every frame is
# compensated for the dimming the panel applies to it, that the curve keeps the full gain up to the knee, stays
# exact while nothing on screen needs the room above it, never falls below the fixed shoulder and moves no level
# for one added pixel, that the detail step keeps its bounds, that the null test's curve checks carry the loads
# the boost settles on, and that the settle runs in present_hook.cpp cover the slowest gain convergence the table
# allows. Run: python parity_check.py

import math
import re
from pathlib import Path

# Baked defaults (must match boost.hlsl).
APL_REF_WHITE = 1060.0
PANEL_PEAK = 1060.0
HIGHLIGHT_CONTRAST = 0.25
KNEE_TRANSITION = 0.04
CURVE_CELLS = 512
CURVE_SOLVE_STEPS = 32
SINGLE_PRIMARY_LOAD = 0.75

SCREEN_PIXELS = 2560 * 1440

ROOT = Path(__file__).resolve().parent.parent.parent
HOOK_SOURCE = ROOT / "DwmBoost" / "hook" / "present_hook.cpp"
NULL_TEST_SOURCE = ROOT / "Shaders" / "ABL_NullTest.fx"

# (log2 APL percent, log2 compensation) per anchor.
APL_ANCHORS = [(1.584963, 0.000000), (2.000000, 0.198724), (2.321928, 0.381141), (2.584963, 0.553194),
               (2.807355, 0.712673), (3.000000, 0.851895), (3.169925, 0.978654), (3.321928, 1.093618),
               (3.459432, 1.133372), (3.584963, 1.161714), (3.700440, 1.192490), (3.807355, 1.216959),
               (3.906891, 1.248625), (4.087463, 1.285640), (4.321928, 1.348022), (4.459432, 1.375656),
               (4.643856, 1.429629), (4.754888, 1.457765), (4.906891, 1.489516), (5.129283, 1.533755),
               (5.321928, 1.585916), (5.643856, 1.668306), (6.228819, 1.797656), (6.643856, 1.882430)]

# Rec.2020 to the panel's own primaries.
TO_PANEL = ((1.215214748, -0.179592899, -0.035621849),
            (-0.033322071, 1.046218857, -0.012896786),
            (-0.008296491, -0.018309355, 1.026605846))

PQ_M1, PQ_M2 = 0.1593017578125, 78.84375
PQ_C1, PQ_C2, PQ_C3 = 0.8359375, 18.8515625, 18.6875


def pq_to_lin(v):
    v = min(max(v, 0.0), 1.0)
    vp = v ** (1.0 / PQ_M2)
    num = max(vp - PQ_C1, 0.0)
    den = PQ_C2 - PQ_C3 * vp
    return (num / max(den, 1e-6)) ** (1.0 / PQ_M1)


def lin_to_pq_unclamped(l):
    lm1 = max(l, 0.0) ** PQ_M1
    return ((PQ_C1 + PQ_C2 * lm1) / (1.0 + PQ_C3 * lm1)) ** PQ_M2


def lin_to_pq(l):
    return lin_to_pq_unclamped(min(max(l, 0.0), 1.0))


def nits_to_pq(n):
    return lin_to_pq(n / 10000.0)


def nits_to_pq_unclamped(n):
    return lin_to_pq_unclamped(n / 10000.0)


def pq_to_nits(v):
    return pq_to_lin(v) * 10000.0


def seg_lerp(x, x0, y0, x1, y1):
    t = 0.0 if x1 <= x0 else min(max((x - x0) / (x1 - x0), 0.0), 1.0)
    return y0 + (y1 - y0) * t


def lookup_log_comp_1d(apl_pct):
    x = min(max(math.log2(max(apl_pct, 1e-6)), APL_ANCHORS[0][0]), APL_ANCHORS[-1][0])
    i = 0
    while i < len(APL_ANCHORS) - 2 and APL_ANCHORS[i + 1][0] <= x:
        i += 1
    (x0, y0), (x1, y1) = APL_ANCHORS[i], APL_ANCHORS[i + 1]
    return seg_lerp(x, x0, y0, x1, y1)


def scene_log_gain(apl01):
    return max(lookup_log_comp_1d(min(max(apl01, 0.0), 1.0) * 100.0), 0.0)


def cand_max_log_gain():
    return APL_ANCHORS[-1][1]


def luma2020(rgb):
    return 0.2627 * rgb[0] + 0.6780 * rgb[1] + 0.0593 * rgb[2]


def panel_load_nits(rgb):
    channels = [max(sum(m * c for m, c in zip(row, rgb)), 0.0) for row in TO_PANEL]
    mean = sum(channels) / 3.0
    return mean + (max(channels) - mean) * (3.0 * SINGLE_PRIMARY_LOAD - 1.0) * 0.5


# Histogram, as CS_Build bins each pixel and CS_Solve reads each bin back.
def luma_bin(luma_q4):
    if luma_q4 <= 0:
        return 0
    exponent = luma_q4.bit_length() - 1
    sub_bin = ((luma_q4 >> (exponent - 2)) & 3) if exponent >= 2 else 0
    return min(exponent * 4 + sub_bin, 63)


def ratio_bin(luma_q4, max_q4):
    safe = max(luma_q4, 1)
    return min(int(max_q4 >= 2 * safe) + int(max_q4 >= 4 * safe) + int(max_q4 >= 8 * safe), 3)


def luma_bin_bounds_q4(bin_index):
    exponent, sub_bin = bin_index >> 2, bin_index & 3
    if exponent < 2:
        lower = 0 if exponent == 0 else (1 << exponent)
        upper = (1 << (exponent + 1)) - 1
    else:
        step = 1 << (exponent - 2)
        lower = (1 << exponent) + sub_bin * step
        upper = lower + step - 1
    upper = min(upper, 40000)
    return min(lower, upper), upper


def within_bin_offset10(luma_q4, bin_index):
    lower, upper = luma_bin_bounds_q4(bin_index)
    span = upper - lower
    if span == 0:
        return 0
    position = min(max(luma_q4, lower), upper) - lower
    return min((position * 1023 + (span >> 1)) // span, 1023)


def quantize(nits, scale):
    return int(math.floor(min(max(nits, 0.0), 10000.0) * scale + 0.5))


def histogram(pixels):
    """pixels: (count, Rec.2020 nits) pairs. Returns each bin's count, mean luma, luma spread, mean brightest channel,
    mean load and luma bounds in nits."""
    sums = {}
    for count, rgb in pixels:
        luma_q4 = quantize(luma2020(rgb), 4.0)
        max_q4 = quantize(max(rgb), 4.0)
        lb = luma_bin(luma_q4)
        offset = within_bin_offset10(luma_q4, lb)
        s = sums.setdefault(lb * 4 + ratio_bin(luma_q4, max_q4), [0, 0, 0, 0, 0.0])
        s[0] += count
        s[1] += offset * count
        s[2] += offset * offset * count
        s[3] += quantize(max(rgb), 0.5) * count
        s[4] += panel_load_nits(rgb) * count

    bins = []
    for index, (count, offset_sum, offset_sq_sum, max_sum, load_sum) in sums.items():
        lower, upper = luma_bin_bounds_q4(index // 4)
        offset_to_nits = (upper - lower) / 1023.0 * 0.25
        mean_offset = offset_sum / count
        luma = lower * 0.25 + mean_offset * offset_to_nits
        spread = math.sqrt(max(offset_sq_sum / count - mean_offset * mean_offset, 0.0)) * offset_to_nits
        bins.append({"count": count, "luma": luma, "spread": spread, "max": max(max_sum / count * 2.0, luma),
                     "load": load_sum / count, "lower": lower * 0.25, "upper": upper * 0.25})
    return bins


# Fixed shoulder: full gain up to the knee, then the slope eases to the highlight contrast and the panel peak
# signal lands on the panel peak. It places the knee and is the floor the curve never goes under.
def shoulder_compression(u, knee_u):
    t = max(u - knee_u, 0.0)
    eased = t * t / (2.0 * KNEE_TRANSITION) if t < KNEE_TRANSITION else t - 0.5 * KNEE_TRANSITION
    return (1.0 - HIGHLIGHT_CONTRAST) * eased


def make_curve(gain):
    c = {"gain": max(gain, 1.0), "peakPQ": 1.0, "kneeNits": 10000.0, "kneeU": 1.0, "maxU": 1.0}
    if PANEL_PEAK <= 0 or c["gain"] <= 1.000001:
        return c
    c["peakPQ"] = nits_to_pq(PANEL_PEAK)
    c["maxU"] = nits_to_pq_unclamped(PANEL_PEAK * c["gain"])
    eased = (c["maxU"] - c["peakPQ"]) / (1.0 - HIGHLIGHT_CONTRAST)
    if eased < 0.5 * KNEE_TRANSITION:
        span = math.sqrt(2.0 * KNEE_TRANSITION * eased)
    else:
        span = eased + 0.5 * KNEE_TRANSITION
    c["kneeU"] = c["maxU"] - span
    c["kneeNits"] = pq_to_nits(c["kneeU"]) / c["gain"]
    return c


def fixed_shoulder_nits(level, fixed):
    n = max(level, 0.0)
    if n <= fixed["kneeNits"]:
        return n * fixed["gain"]
    if n >= PANEL_PEAK:
        return n
    u = nits_to_pq_unclamped(n * fixed["gain"])
    return max(pq_to_nits(min(u - shoulder_compression(u, fixed["kneeU"]), fixed["peakPQ"])), n)


def full_gain_pq(nits, c):
    """PQ code after the full gain, inside the curve's range. Signals at the panel peak pass through, so they sit at
    its top."""
    if nits >= PANEL_PEAK:
        return c["maxU"]
    return min(nits_to_pq_unclamped(nits * c["gain"]), c["maxU"])


def bin_span(b):
    """Brightest-channel span of a bin, uniform with the bin's mean and spread and inside its luma bounds."""
    half = math.sqrt(3.0) * b["spread"]
    ratio = b["max"] / max(b["luma"], 1e-6)
    return ratio * max(b["luma"] - half, b["lower"]), ratio * min(b["luma"] + half, b["upper"])


def build_curve(gain, bins):
    """The curve over [knee, maxU] in CURVE_CELLS cells, solved from this frame's histogram at this frame's gain."""
    c = make_curve(gain)
    c["phase"] = "identity"
    if c["kneeU"] >= c["maxU"]:
        return c
    knee_u, peak, cells = c["kneeU"], c["peakPQ"], CURVE_CELLS
    width = (c["maxU"] - knee_u) / cells
    c["width"] = width
    nodes_u = [knee_u + j * width for j in range(cells + 1)]

    total = sum(b["count"] for b in bins)
    share = [0.0] * cells
    top_u = -1.0
    for b in bins:
        lo, hi = bin_span(b)
        ua, uz = full_gain_pq(lo, c), full_gain_pq(hi, c)
        if uz <= knee_u:
            continue
        top_u = max(top_u, uz)
        s = b["count"] / total
        if uz - ua < 1e-6:
            share[min(int((uz - knee_u) / width), cells - 1)] += s
            continue
        for i in range(max(int((ua - knee_u) / width), 0), min(int((uz - knee_u) / width), cells - 1) + 1):
            overlap = min(nodes_u[i + 1], uz) - max(nodes_u[i], ua)
            if overlap > 0.0:
                share[i] += s * overlap / (uz - ua)
    c["share"] = share
    c["topU"] = top_u

    # Nothing needs the room above the ceiling, so every level stays exact.
    if top_u <= peak:
        c["phase"] = "fits"
        c["nodes"] = nodes_u
        return c

    top = min(int((top_u - knee_u) / width), cells - 1)
    length = [width if i < top else (top_u - nodes_u[top] if i == top else 0.0) for i in range(cells)]
    filled = [s > 0.0 for s in share]
    centers = [knee_u + (i + 0.5) * width for i in range(cells)]
    cap = [1.0 - (1.0 - HIGHLIGHT_CONTRAST) * min(max((u - peak) / KNEE_TRANSITION, 0.0), 1.0) for u in centers]

    slope = [cap[i] if filled[i] else 1.0 for i in range(cells)]
    need = knee_u + sum(s * n for s, n in zip(slope, length)) - peak
    gap_total = sum(length[i] for i in range(cells) if not filled[i])

    if need <= gap_total:
        # Empty levels give up their room from the top down, which moves only what sits above them.
        c["phase"] = "gaps"
        gap_above = 0.0
        for i in range(cells - 1, -1, -1):
            if not filled[i] and length[i] > 0.0:
                slope[i] = 1.0 - min(max(need - gap_above, 0.0), length[i]) / length[i]
                gap_above += length[i]
    else:
        # Filled levels share the room by screen share, eased over the knee transition.
        c["phase"] = "share"
        density = [share[i] / width if filled[i] else 0.0 for i in range(cells)]
        reach = int(0.5 * KNEE_TRANSITION / width)
        sum_density, sum_filled = [0.0], [0]
        for i in range(cells):
            sum_density.append(sum_density[-1] + density[i])
            sum_filled.append(sum_filled[-1] + int(filled[i]))
        smooth = []
        for i in range(cells):
            a, z = max(i - reach, 0), min(i + reach + 1, cells)
            smooth.append((sum_density[z] - sum_density[a]) / max(sum_filled[z] - sum_filled[a], 1))
        knee_ease = [max(1.0 - (u - knee_u) / KNEE_TRANSITION, 0.0) for u in centers]

        def slopes(lam):
            return [max(knee_ease[i], min(cap[i], lam * smooth[i])) if filled[i] else 0.0 for i in range(cells)]

        lam_lo, lam_hi = 0.0, max(cap[i] / smooth[i] for i in range(cells) if filled[i])
        for _ in range(CURVE_SOLVE_STEPS):
            lam = 0.5 * (lam_lo + lam_hi)
            if knee_u + sum(s * n for s, n in zip(slopes(lam), length)) > peak:
                lam_hi = lam
            else:
                lam_lo = lam
        slope = slopes(lam_lo)

    # The top cell keeps its slope across the whole cell, so the brightest content lands on the panel peak.
    nodes = [knee_u]
    for i in range(cells):
        nodes.append(nodes[-1] + (slope[i] * width if i <= top else 0.0))
    c["nodes"] = [max(y, u - shoulder_compression(u, knee_u)) for y, u in zip(nodes, nodes_u)]
    return c


def curve_pq(u, c):
    if c["phase"] == "identity" or u <= c["kneeU"]:
        return u
    x = (min(u, c["maxU"]) - c["kneeU"]) / c["width"]
    i = min(int(x), CURVE_CELLS - 1)
    y0, y1 = c["nodes"][i], c["nodes"][i + 1]
    return min(y0 + (y1 - y0) * (x - i), c["peakPQ"])


def curve_output_nits(nits, y, c):
    """Signal nits for a level whose curve output is PQ code y."""
    n = max(nits, 0.0)
    if n <= c["kneeNits"]:
        return n * c["gain"]
    if n >= PANEL_PEAK:
        return n
    return max(pq_to_nits(min(y, c["peakPQ"])), n)


def boost_scale(luma, brightest, c):
    luma_scale = curve_output_nits(luma, curve_pq(full_gain_pq(luma, c), c), c) / max(luma, 1e-6)
    if brightest <= c["kneeNits"]:
        return luma_scale
    return min(luma_scale, curve_output_nits(brightest, curve_pq(full_gain_pq(brightest, c), c), c) / brightest)


def boost_nits(nits, c):
    return nits * boost_scale(nits, nits, c) if nits > 1e-6 else 0.0


def display_apl(bins, c):
    total = sum(b["count"] for b in bins)
    load = 0.0
    for b in bins:
        scale = boost_scale(b["luma"], b["max"], c) if b["luma"] > 1e-6 else 1.0
        load += min(max(b["load"] * scale / APL_REF_WHITE, 0.0), 1.0) * b["count"]
    return min(load / total, 1.0)


def raw_apl(bins):
    total = sum(b["count"] for b in bins)
    return min(sum(min(b["load"] / APL_REF_WHITE, 1.0) * b["count"] for b in bins) / total, 1.0)


# Detail step: above the knee a pixel keeps its own PQ contrast around the curve output of its neighborhood, where
# only neighbors above the knee count.
DETAIL_WEIGHTS = ((1, 2, 1), (2, 4, 2), (1, 2, 1))


def detail_boost_scale(image, x, y, c):
    rgb = image[y][x]
    luma, brightest = luma2020(rgb), max(rgb)
    if luma <= 1e-6:
        return 1.0
    if brightest <= c["kneeNits"]:
        return boost_scale(luma, brightest, c)

    weight_sum = base_luma = base_max = 0.0
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            ny = min(max(y + dy, 0), len(image) - 1)
            nx = min(max(x + dx, 0), len(image[0]) - 1)
            n = image[ny][nx]
            if max(n) <= c["kneeNits"]:
                continue
            w = DETAIL_WEIGHTS[dy + 1][dx + 1]
            weight_sum += w
            base_luma += w * full_gain_pq(luma2020(n), c)
            base_max += w * full_gain_pq(max(n), c)
    base_luma /= weight_sum
    base_max /= weight_sum

    y_luma = curve_pq(base_luma, c) + full_gain_pq(luma, c) - base_luma
    y_max = curve_pq(base_max, c) + full_gain_pq(brightest, c) - base_max
    return min(curve_output_nits(luma, y_luma, c) / luma, curve_output_nits(brightest, y_max, c) / brightest)


# Scenes.
def gray(nits):
    return (nits, nits, nits)


def scene(parts):
    """parts: (screen share, low nits, high nits) gray ramps, log spaced, over black."""
    pixels = []
    for share, lo, hi in parts:
        steps = 1 if lo == hi else 200
        for k in range(steps):
            level = lo if steps == 1 else lo * (hi / lo) ** ((k + 0.5) / steps)
            pixels.append((share * SCREEN_PIXELS / steps, gray(level)))
    rest = SCREEN_PIXELS - sum(c for c, _ in pixels)
    if rest > 0.5:
        pixels.append((rest, gray(0.0)))
    return [(int(round(c)), rgb) for c, rgb in pixels if round(c) > 0]


def flat_bins(level):
    return histogram([(SCREEN_PIXELS, gray(level))])


def null_test_pattern(raw, patch_nits, window=False):
    """ABL_NullTest's patch check at 2560x1440: a patch in a black gap, the rest filled to the raw load, or with half
    the fill's light gathered into a 900 nit window."""
    patch, gap = 2 * round(0.07 * 1440), 2 * round(0.24 * 1440)
    load_pixels = SCREEN_PIXELS - gap * gap
    light = raw * APL_REF_WHITE * SCREEN_PIXELS - patch_nits * patch * patch
    pixels = [(patch * patch, gray(patch_nits)), (gap * gap - patch * patch, gray(0.0))]
    if not window:
        return pixels + [(load_pixels, gray(light / load_pixels))]
    side = 2 * round(0.5 * math.sqrt(0.5 * light / 900.0))
    rest = (light - 900.0 * side * side) / (load_pixels - side * side)
    return pixels + [(side * side, gray(900.0)), (load_pixels - side * side, gray(rest))]


def run_frames(bins_per_frame, last_disp=None, start_gain=None):
    """Mirror CS_Solve over consecutive frames. Each frame's gain is the compensation for the display APL of the
    frame before it, and its own display APL is measured through the curve it gets."""
    if start_gain is not None:
        last_disp = None
    elif last_disp is None:
        last_disp = solve_settled(bins_per_frame[0])[1]
    gains, curves = [], []
    for bins in bins_per_frame:
        gain = start_gain if last_disp is None else 2.0 ** scene_log_gain(last_disp)
        c = build_curve(gain, bins)
        gains.append(gain)
        curves.append(c)
        last_disp = display_apl(bins, c)
    return gains, curves


def solve_settled(bins):
    """Settled state of a still frame, where the gain is the compensation for the APL it shows. The compensation rises
    slower than the log gain, so bisection finds the one settled gain."""
    lo, hi = 0.0, cand_max_log_gain()
    for _ in range(40):
        mid = 0.5 * (lo + hi)
        if scene_log_gain(display_apl(bins, build_curve(2.0 ** mid, bins))) > mid:
            lo = mid
        else:
            hi = mid
    gain = 2.0 ** (0.5 * (lo + hi))
    c = build_curve(gain, bins)
    return raw_apl(bins), display_apl(bins, c), gain, c


def smallest_10bit_step():
    """Smallest relative luminance step between 10-bit PQ codes up to the panel peak."""
    peak_code = int(nits_to_pq(PANEL_PEAK) * 1023)
    return min(pq_to_lin((code + 1) / 1023) / pq_to_lin(code / 1023) - 1.0 for code in range(1, peak_code))


def host_settle_runs():
    return int(re.search(r"SETTLE_RUNS = (\d+);", HOOK_SOURCE.read_text()).group(1))


def null_test_curve_loads():
    text = NULL_TEST_SOURCE.read_text()
    table = re.search(r"CURVE_CHECK_RAW_APL\[\d+\]\s*=\s*\{(.*?)\};", text, re.S).group(1)
    return [(float(a), float(b)) for a, b in re.findall(r"float2\(([\d.]+),\s*([\d.]+)\)", table)]


def shown_brightness_errors(levels, gains, curves):
    """Each frame's shown level over its source level, minus 1, on a panel that dims a frame for the load the
    boost really produced on the frame before it."""
    errors = []
    for n in range(1, len(levels)):
        prev_load = display_apl(flat_bins(levels[n - 1]), curves[n - 1])
        shown = boost_nits(levels[n], curves[n])
        errors.append(shown * 2.0 ** -scene_log_gain(prev_load) / levels[n] - 1.0)
    return errors


def main():
    fails = 0

    # 1. Baked table matches the measurements (compensation = 1060-nit peak / peak at APL).
    apls = [3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17, 20, 22, 25, 27, 30, 35, 40, 50, 75, 100]
    peaks = [1060.0, 923.6, 813.9, 722.4, 646.8, 587.3, 537.9, 496.7, 483.2, 473.8, 463.8, 456.0, 446.1, 434.8, 416.4,
             408.5, 393.5, 385.9, 377.5, 366.1, 353.1, 333.5, 304.9, 287.5]
    for (log_apl, log_comp), apl, peak in zip(APL_ANCHORS, apls, peaks):
        if abs(log_apl - math.log2(apl)) > 1e-6 or abs(log_comp - math.log2(1060.0 / peak)) > 1e-6:
            print(f"FAIL table {apl}%: baked ({log_apl:.6f}, {log_comp:.6f}) vs measured")
            fails += 1
    print("table check: baked APL_ANCHORS matches the measured peaks")

    # 2. From an unboosted frame, the frame loop reaches the closed-loop solve within the host's settle runs, to
    # under half the smallest 10-bit PQ step.
    settle_runs = host_settle_runs()
    tolerance = math.log2(1.0 + 0.5 * smallest_10bit_step())
    print(f"\n  level(nits)  rawAPL%  solvedAPL%   gain   gain error after {settle_runs} runs")
    for level in (20, 60, 150, 230, 300, 530, 795, 1060):
        bins = flat_bins(level)
        raw, disp, gain, _ = solve_settled(bins)
        settled = run_frames([bins] * (settle_runs + 1), last_disp=raw)[0][-1]
        error = abs(math.log2(settled / gain))
        print(f"  {level:9.0f}  {raw*100:7.2f}  {disp*100:9.2f}  {gain:6.3f}  {(2.0 ** error - 1.0) * 100:10.3f}%")
        if error > tolerance:
            print(f"FAIL settling at {level} nits: gain {settled:.4f} after {settle_runs} runs vs solve {gain:.4f}")
            fails += 1

    # 3. On a flat field the boost never darkens and shows the full gain up to the panel's limit, to under half
    # the smallest 10-bit step. The histogram keeps the brightest channel in 2 nit steps, which is what is left.
    step_tolerance = 0.5 * smallest_10bit_step()
    worst = 0.0
    for level in range(1, 1061, 10):
        _, _, gain, c = solve_settled(flat_bins(float(level)))
        out = boost_nits(float(level), c)
        exact = min(level * gain, PANEL_PEAK) if level < PANEL_PEAK else float(level)
        worst = max(worst, abs(out / exact - 1.0))
        if out < float(level) - 1e-3 or abs(out / exact - 1.0) > step_tolerance:
            print(f"FAIL flat field at {level} nits: out {out:.2f}, exact {exact:.2f}")
            fails += 1
    print(f"\nflat field check: worst miss of the full gain or the panel peak {worst * 100:.3f}%")

    # 4. Shadow/midtone gain is the full table gain below the knee (mid-gray is fully restored).
    _, _, gain, c = solve_settled(histogram([(SCREEN_PIXELS - 1000, gray(80.0)), (1000, gray(20.0))]))
    mid_out = boost_nits(20.0, c)
    if abs(mid_out - 20.0 * gain) > 0.5:
        print(f"FAIL midtone: 20-nit sample out {mid_out:.3f} vs full-gain {20.0*gain:.3f}")
        fails += 1
    print(f"midtone check: 20-nit sample boosted by full gain {gain:.3f} -> {mid_out:.2f} nits")

    # 5. Through cuts and a two-frame flash, every frame shows its source level on a panel one frame behind, and
    # the gain settles on the closed-loop solve.
    print("\n  sequence                worst frame error   settled gain vs solve")
    sequences = {
        "6% -> 10% out APL": [43.34] * 5 + [49.67] * 40,
        "10% -> 6% out APL": [49.67] * 5 + [43.34] * 40,
        "3% -> 25% out APL": [31.8] * 5 + [98.4] * 40,
        "2-frame flash in 5%": [53.0] * 5 + [74.2] * 2 + [53.0] * 40,
    }
    for name, levels in sequences.items():
        gains, curves = run_frames([flat_bins(level) for level in levels])
        worst = max(abs(e) for e in shown_brightness_errors(levels, gains, curves))
        settled = solve_settled(flat_bins(levels[-1]))[2]
        drift = gains[-1] / settled - 1.0
        print(f"  {name:22s}  {worst * 100:8.3f}%           {drift * 100:+.3f}%")
        if worst > 0.01 or abs(drift) > 0.005:
            print(f"FAIL {name}: worst frame error {worst:.4f}, settled gain off by {drift:.4f}")
            fails += 1

    # 6. On scenes with content above the knee, every level up to the knee keeps the full gain, nothing goes below
    # the source, past the panel peak or under the fixed shoulder, levels rise with the source, the mids stay exact
    # while the room above them is free, one added pixel moves no level by more than half the smallest 10-bit step,
    # and the frame loop settles from any gain within the host's settle runs.
    scenes = {
        "speck over a gap": ([(0.8, 5, 350), (0.001, 900, 1000)], (5, 350)),
        "big sky over a gap": ([(0.85, 20, 250), (0.15, 600, 900)], (20, 250)),
        "band under a speck": ([(0.6, 5, 150), (0.2, 300, 360), (0.002, 900, 1000)], (5, 360)),
        "nothing above the ceiling": ([(1.0, 5, 400)], (5, 400)),
        "bloom past the ceiling": ([(0.9, 20, 420), (0.005, 420, 1000)], None),
        "glow on the mids": ([(0.8, 10, 350), (0.02, 300, 700)], None),
        "bright day": ([(1.0, 50, 1000)], None),
        "band, gap and highlights": ([(0.6, 5, 150), (0.2, 300, 360), (0.05, 700, 1000)], None),
        "sparse mids, dense sky": ([(0.7, 5, 100), (0.01, 150, 400), (0.25, 500, 1000)], None),
        "full screen above the ceiling": ([(1.0, 300, 1060)], None),
    }
    print("\n  scene                           gain   curve     knee   1-pixel move  settle frames from 1.0/2.0/max")
    for name, (parts, exact_range) in scenes.items():
        pixels = scene(parts)
        bins = histogram(pixels)
        _, _, gain, c = solve_settled(bins)
        fixed = make_curve(gain)
        levels = sorted({lo * (hi / lo) ** (k / 60) for _, lo, hi in parts for k in range(61)})
        problems = []

        prev = 0.0
        for level in levels:
            out = boost_nits(level, c)
            if level <= c["kneeNits"] and abs(out - level * gain) > 1e-6 * level * gain:
                problems.append(f"{level:.1f} nits below the knee misses the full gain")
            if out < level - 1e-3 or out > PANEL_PEAK + 1e-3 or out < prev - 1e-3:
                problems.append(f"{level:.1f} nits shows at {out:.2f} after {prev:.2f}")
            if out < fixed_shoulder_nits(level, fixed) * (1.0 - 1e-5):
                problems.append(f"{level:.1f} nits shows under the fixed shoulder")
            if exact_range and exact_range[0] <= level <= exact_range[1] and abs(out / (level * gain) - 1) > 1e-4:
                problems.append(f"{level:.1f} nits misses exact while the room above is free")
            prev = out

        knee_levels = [lv for lv in levels if lv > c["kneeNits"]]
        base = [boost_nits(lv, c) for lv in knee_levels]
        worst_move = 0.0
        for k in range(41):
            speck = c["kneeNits"] * (PANEL_PEAK / c["kneeNits"]) ** (k / 40)
            moved = build_curve(gain, histogram(pixels + [(1, gray(speck))]))
            for lv, out in zip(knee_levels, base):
                worst_move = max(worst_move, abs(boost_nits(lv, moved) / out - 1.0))
        if worst_move > step_tolerance:
            problems.append(f"one pixel moves a level by {worst_move * 100:.3f}%")

        settles = []
        for start in (1.0, 2.0, 2.0 ** cand_max_log_gain()):
            gains = run_frames([bins] * 40, start_gain=start)[0]
            off = [abs(math.log2(g / gain)) for g in gains]
            settles.append(next((i for i in range(len(off)) if max(off[i:]) <= tolerance), None))
        if any(s is None or s > settle_runs for s in settles):
            problems.append(f"frame loop settles after {settles} frames")

        print(f"  {name:30s}  {gain:5.3f}  {c['phase']:8s}  {c['kneeNits']:6.1f}  {worst_move * 100:9.3f}%    {settles}")
        for p in problems:
            print(f"FAIL {name}: {p}")
        fails += len(problems)

    # 7. The host keeps DWM composing for SETTLE_RUNS solves after a content change. Each solve leaves at most the
    # steepest table slope of the gain error, so those solves must take the largest jump, across the whole table,
    # under half the smallest 10-bit PQ step up to the panel peak.
    steepest = max((y1 - y0) / (x1 - x0) for (x0, y0), (x1, y1) in zip(APL_ANCHORS, APL_ANCHORS[1:]))
    span = APL_ANCHORS[-1][1] - APL_ANCHORS[0][1]
    needed = math.ceil(math.log(tolerance / span) / math.log(steepest))
    print(f"\nsettle check: steepest slope {steepest:.4f}, smallest step {smallest_10bit_step() * 100:.2f}%, "
          f"{needed} solves needed, host keeps {settle_runs}")
    if settle_runs != needed:
        print(f"FAIL settle runs: present_hook.cpp keeps {settle_runs}, the table needs {needed}")
        fails += 1

    # 8. Each null test curve check's raw loads are the ones the boost settles on the named out APL for, which with
    # every fill below the ceiling is the out APL over its compensation. The bright window check's patch keeps the
    # full gain in both states.
    named = [(0.03, 0.06), (0.06, 0.10), (0.08, 0.12), (0.10, 0.25), (0.25, 0.50), (0.50, 0.80)]
    print("\n  null test curve check   baked raw APL")
    for (out_a, out_b), (raw_a, raw_b) in zip(named, null_test_curve_loads()):
        for out, raw in ((out_a, raw_a), (out_b, raw_b)):
            expected = out * 2.0 ** -scene_log_gain(out)
            disp = solve_settled(histogram(null_test_pattern(raw, 60.0)))[1]
            if abs(raw - expected) > 2e-7 or abs(disp - out) > 1e-4:
                print(f"FAIL null test out APL {out:.0%}: baked raw {raw:.7f}, expected {expected:.7f}, settles on {disp:.4%}")
                fails += 1
        print(f"  {out_a:4.0%} vs {out_b:4.0%}          {raw_a:.7f} / {raw_b:.7f}")

    bright = {}
    for state in ("A", "B"):
        _, disp, gain, c = solve_settled(histogram(null_test_pattern(0.08, 150.0, window=state == "B")))
        bright[state] = (disp, boost_nits(150.0, c) / gain)
    print(f"  bright window check     out APL {bright['A'][0]:.1%} in state A, {bright['B'][0]:.1%} in state B, "
          f"patch shows {bright['A'][1]:.2f} / {bright['B'][1]:.2f} nits")
    if any(abs(shown / 150.0 - 1.0) > 1e-6 for _, shown in bright.values()):
        print("FAIL bright window check: the patch misses the full gain")
        fails += 1

    # 9. The detail step leaves every pixel up to the knee at the full gain, keeps the brightest channel under the
    # panel peak and every pixel at or over its source, adds no rim where a highlight meets dark pixels, and moves
    # the panel load only slightly.
    _, _, gain, c = solve_settled(histogram(scene([(0.6, 20, 200), (0.1, 500, 900)])))
    size = 12
    texture = [[gray(700.0 * (1.15 if (x + y) % 2 else 0.85)) if 3 <= x < 9 and 3 <= y < 9 else gray(60.0)
                for x in range(size)] for y in range(size)]
    flat_patch = [[gray(700.0) if 3 <= x < 9 and 3 <= y < 9 else gray(0.0) for x in range(size)] for y in range(size)]
    edge = [[gray(450.0 if x < 6 else 900.0) for x in range(size)] for y in range(size)]
    red = [[(900.0, 40.0, 40.0) if 3 <= x < 9 else gray(500.0) for x in range(size)] for y in range(size)]
    problems = []
    for image in (texture, flat_patch, edge, red):
        for y in range(size):
            for x in range(size):
                rgb = image[y][x]
                scale = detail_boost_scale(image, x, y, c)
                if max(rgb) <= c["kneeNits"] and abs(scale - gain) > 1e-9 and luma2020(rgb) > 1e-6:
                    problems.append(f"pixel {rgb} up to the knee misses the full gain")
                if max(rgb) * scale > PANEL_PEAK * (1 + 1e-6) and max(rgb) < PANEL_PEAK:
                    problems.append(f"pixel {rgb} passes the panel peak")
                if scale < 1.0 - 1e-9:
                    problems.append(f"pixel {rgb} falls under its source")
    for y in range(size):
        for x in range(size):
            if flat_patch[y][x][0] > 0 and abs(detail_boost_scale(flat_patch, x, y, c) - boost_scale(700.0, 700.0, c)) > 1e-9:
                problems.append(f"flat patch pixel ({x}, {y}) differs from the curve, a rim")
    overshoot = max(abs(detail_boost_scale(edge, x, 6, c) / boost_scale(edge[6][x][0], edge[6][x][0], c) - 1.0)
                    for x in range(size))
    plain_load = sum(panel_load_nits(texture[y][x]) * boost_scale(luma2020(texture[y][x]), max(texture[y][x]), c)
                     for y in range(size) for x in range(size))
    detail_load = sum(panel_load_nits(texture[y][x]) * detail_boost_scale(texture, x, y, c)
                      for y in range(size) for x in range(size))
    print(f"\ndetail check: edge overshoot {overshoot * 100:.2f}%, load moves {(detail_load / plain_load - 1) * 100:+.3f}% "
          f"on a textured highlight")
    for p in sorted(set(problems)):
        print(f"FAIL detail: {p}")
    fails += len(set(problems))

    print("\nALL CHECKS PASSED" if fails == 0 else f"\n{fails} CHECK(S) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
