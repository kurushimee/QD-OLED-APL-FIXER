#!/usr/bin/env python3
# Numeric parity check for the scalar core of boost.hlsl against the ReShade shader's values.
#
# For a flat full-field scRGB frame the GPU histogram collapses to a single APL, so this CPU mirror
# of the solve-and-boost path follows what the compute passes compute for that frame. It checks that
# the baked table matches the measured peaks, that from an unboosted frame the gain reaches the
# closed-loop solve within the host's settle runs, that the boost never darkens and rises with the
# level, that through cuts and flashes every frame is compensated for the dimming the panel applies to
# it, that the shoulder keeps the full gain up to the knee and puts the panel peak signal on the panel
# peak, and that the settle runs in present_hook.cpp cover the slowest gain convergence the table
# allows. Run: python parity_check.py

import math
import re
from pathlib import Path

# Baked defaults (must match boost.hlsl).
APL_REF_WHITE = 1060.0
PANEL_PEAK = 1060.0
HIGHLIGHT_CONTRAST = 0.25
KNEE_TRANSITION = 0.04

HOOK_SOURCE = Path(__file__).resolve().parent.parent / "hook" / "present_hook.cpp"

# (log2 APL percent, log2 compensation) per anchor.
APL_ANCHORS = [(1.584963, 0.000000), (2.000000, 0.198724), (2.321928, 0.381141), (2.584963, 0.553194),
               (2.807355, 0.712673), (3.000000, 0.851895), (3.169925, 0.978654), (3.321928, 1.093618),
               (3.459432, 1.133372), (3.584963, 1.161714), (3.700440, 1.192490), (3.807355, 1.216959),
               (3.906891, 1.248625), (4.087463, 1.285640), (4.321928, 1.348022), (4.459432, 1.375656),
               (4.643856, 1.429629), (4.754888, 1.457765), (4.906891, 1.489516), (5.129283, 1.533755),
               (5.321928, 1.585916), (5.643856, 1.668306), (6.228819, 1.797656), (6.643856, 1.882430)]

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


# Boost curve (scalar). On a flat gray field the brightest channel equals luma, so the one curve sets the boost.
def gain_map_pq(pq, gain):
    return nits_to_pq_unclamped(pq_to_lin(pq) * 10000.0 * gain)


def shoulder_compression(u, knee_u):
    t = max(u - knee_u, 0.0)
    eased = t * t / (2.0 * KNEE_TRANSITION) if t < KNEE_TRANSITION else t - 0.5 * KNEE_TRANSITION
    return (1.0 - HIGHLIGHT_CONTRAST) * eased


def make_curve(gain):
    c = {"gain": max(gain, 1.0), "peakPQ": 1.0, "kneeNits": 10000.0, "kneeU": 1.0}
    if PANEL_PEAK <= 0 or c["gain"] <= 1.000001:
        return c
    c["peakPQ"] = nits_to_pq(PANEL_PEAK)
    max_u = gain_map_pq(c["peakPQ"], c["gain"])
    eased = (max_u - c["peakPQ"]) / (1.0 - HIGHLIGHT_CONTRAST)
    if eased < 0.5 * KNEE_TRANSITION:
        span = math.sqrt(2.0 * KNEE_TRANSITION * eased)
    else:
        span = eased + 0.5 * KNEE_TRANSITION
    c["kneeU"] = max_u - span
    c["kneeNits"] = pq_to_lin(c["kneeU"]) * 10000.0 / c["gain"]
    return c


def boost_curve_nits(nits, c):
    n = max(nits, 0.0)
    if n <= c["kneeNits"]:
        return n * c["gain"]
    if n >= PANEL_PEAK:
        return n
    u = nits_to_pq_unclamped(n * c["gain"])
    y = min(u - shoulder_compression(u, c["kneeU"]), c["peakPQ"])
    return max(pq_to_lin(y) * 10000.0, n)


def post_boost_metric(luma_nits, c):
    if luma_nits <= 1e-6:
        return 0.0
    return min(max(boost_curve_nits(luma_nits, c) / max(APL_REF_WHITE, 1.0), 0.0), 1.0)


def raw_apl(level_nits):
    return min(max(level_nits / max(APL_REF_WHITE, 1.0), 0.0), 1.0)


def solve_flat_field(level_nits):
    """Settled state for a flat full-field frame at level_nits, where the gain is the compensation for the APL it
    shows. The compensation rises slower than the log gain, so bisection finds the one settled gain."""
    lo, hi = 0.0, cand_max_log_gain()
    for _ in range(40):
        mid = 0.5 * (lo + hi)
        if scene_log_gain(post_boost_metric(level_nits, make_curve(2.0 ** mid))) > mid:
            lo = mid
        else:
            hi = mid
    gain = 2.0 ** (0.5 * (lo + hi))
    return raw_apl(level_nits), post_boost_metric(level_nits, make_curve(gain)), gain


def run_frames(levels, last_disp=None):
    """Mirror CS_Solve over consecutive flat-field frames, starting settled on the first level unless the last
    frame's display APL is given. Each frame's gain is the compensation for the display APL of the frame before
    it, and its own display APL is measured at that gain."""
    if last_disp is None:
        last_disp = solve_flat_field(levels[0])[1]
    gains = []
    for level in levels:
        gain = 2.0 ** scene_log_gain(last_disp)
        gains.append(gain)
        last_disp = post_boost_metric(level, make_curve(gain))
    return gains


def smallest_10bit_step():
    """Smallest relative luminance step between 10-bit PQ codes up to the panel peak."""
    peak_code = int(nits_to_pq(PANEL_PEAK) * 1023)
    return min(pq_to_lin((code + 1) / 1023) / pq_to_lin(code / 1023) - 1.0 for code in range(1, peak_code))


def host_settle_runs():
    return int(re.search(r"SETTLE_RUNS = (\d+);", HOOK_SOURCE.read_text()).group(1))


def shown_brightness_errors(levels, gains):
    """Each frame's shown level over its source level, minus 1, on a panel that dims a frame for the load the
    boost really produced on the frame before it."""
    errors = []
    for n in range(1, len(levels)):
        prev_load = post_boost_metric(levels[n - 1], make_curve(gains[n - 1]))
        shown = boost_curve_nits(levels[n], make_curve(gains[n]))
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
        raw, disp, gain = solve_flat_field(level)
        settled = run_frames([level] * (settle_runs + 1), last_disp=raw)[-1]
        error = abs(math.log2(settled / gain))
        print(f"  {level:9.0f}  {raw*100:7.2f}  {disp*100:9.2f}  {gain:6.3f}  {(2.0 ** error - 1.0) * 100:10.3f}%")
        if error > tolerance:
            print(f"FAIL settling at {level} nits: gain {settled:.4f} after {settle_runs} runs vs solve {gain:.4f}")
            fails += 1

    # 3. Boost never darkens and is monotonic in level.
    prev = -1.0
    for level in range(1, 1061, 10):
        raw, disp, gain = solve_flat_field(float(level))
        out = boost_curve_nits(float(level), make_curve(gain))
        if out < float(level) - 1e-3:
            print(f"FAIL darkening at {level} nits: out {out:.2f}")
            fails += 1
        if out < prev - 1e-3:
            print(f"FAIL not monotonic at {level} nits: out {out:.2f} after {prev:.2f}")
            fails += 1
        prev = out
    print("\nmonotonic / no-darkening check: passed" if fails == 0 else "")

    # 4. Shadow/midtone gain is the full table gain below the shoulder (mid-gray is fully restored).
    raw, disp, gain = solve_flat_field(80.0)   # scRGB 1.0 flat field
    p = make_curve(gain)
    mid_out = boost_curve_nits(20.0, p)
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
        gains = run_frames(levels)
        worst = max(abs(e) for e in shown_brightness_errors(levels, gains))
        settled = solve_flat_field(levels[-1])[2]
        drift = gains[-1] / settled - 1.0
        print(f"  {name:22s}  {worst * 100:8.3f}%           {drift * 100:+.3f}%")
        if worst > 0.01 or abs(drift) > 0.005:
            print(f"FAIL {name}: worst frame error {worst:.4f}, settled gain off by {drift:.4f}")
            fails += 1

    # 6. The shoulder depends on the gain alone. Every level up to the knee keeps the full gain, the curve rises
    # without passing the panel peak, and the panel peak signal lands on the panel peak.
    print("\n  gain   knee(nits)  ceiling(nits)")
    for gain in (1.1, 1.2, 1.5, 2.0, 2.5, 3.0, 2.0 ** cand_max_log_gain()):
        c = make_curve(gain)
        print(f"  {gain:5.3f}  {c['kneeNits']:10.1f}  {PANEL_PEAK / gain:13.1f}")

        for level in (0.25 * c["kneeNits"], 0.5 * c["kneeNits"], c["kneeNits"]):
            if abs(boost_curve_nits(level, c) - level * gain) > 1e-6 * level * gain:
                print(f"FAIL gain {gain:.3f}: {level:.1f} nits below the knee misses the full gain")
                fails += 1

        top = boost_curve_nits(PANEL_PEAK * (1.0 - 1e-9), c)
        if abs(top - PANEL_PEAK) > 0.01:
            print(f"FAIL gain {gain:.3f}: panel peak signal shows at {top:.2f} nits")
            fails += 1

        prev = 0.0
        for level in range(1, int(PANEL_PEAK)):
            out = boost_curve_nits(float(level), c)
            if out < prev - 1e-3 or out > PANEL_PEAK + 1e-3:
                print(f"FAIL gain {gain:.3f}: {level} nits shows at {out:.2f} after {prev:.2f}")
                fails += 1
                break
            prev = out

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

    print("\nALL CHECKS PASSED" if fails == 0 else f"\n{fails} CHECK(S) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
