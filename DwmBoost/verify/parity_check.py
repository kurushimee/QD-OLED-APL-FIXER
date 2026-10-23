#!/usr/bin/env python3
# Numeric parity check for the scalar core of boost.hlsl against the ReShade shader's values.
#
# For a flat full-field scRGB frame the GPU histogram collapses to a single APL, so this CPU mirror
# of the solve-and-boost path follows what the compute passes compute for that frame. It checks that
# the baked table matches the measured peaks, that the solved APL is the APL the boost produces at the
# solved gain, and that the boost never darkens and rises with the level. Run: python parity_check.py

import math

# Baked defaults (must match boost.hlsl).
APL_REF_WHITE = 1060.0
PANEL_PEAK = 1060.0
SHOULDER_SPAN = 0.30
OUTLIER = 0.25
KNEE_TRANSITION = 0.04
KNEE_SEARCH_STEPS = 24

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


# Boost curve (scalar). On a flat field the max channel equals luma, so the channel curve never binds and
# the luma curve alone sets the boost.
def gain_map_pq(pq, gain):
    return nits_to_pq_unclamped(pq_to_lin(pq) * 10000.0 * gain)


def shoulder_compression(u, knee_u, contrast, outlier_start_u, outlier_scale):
    t = max(u - knee_u, 0.0)
    bulk = t * t / (2.0 * KNEE_TRANSITION) if t < KNEE_TRANSITION else t - 0.5 * KNEE_TRANSITION
    v = max(u - outlier_start_u, 0.0)
    return (1.0 - contrast) * bulk + outlier_scale * v * v


def outlier_ramp_scale(contrast, outlier_start_u, max_u):
    return (contrast - OUTLIER) / (2.0 * max(max_u - outlier_start_u, 1e-6))


def max_fitting_contrast(peak_pq, highlight_u, max_u):
    span = max_u - highlight_u
    return (peak_pq - 0.5 * KNEE_TRANSITION - 0.5 * OUTLIER * span) / (0.5 * (max_u + highlight_u) - 0.5 * KNEE_TRANSITION)


def solve_knee_u(peak_pq, highlight_u, max_u, contrast):
    lo, hi = 0.0, peak_pq
    for _ in range(KNEE_SEARCH_STEPS):
        mid = 0.5 * (lo + hi)
        start = max(highlight_u, mid)
        compression = shoulder_compression(max_u, mid, contrast, start, outlier_ramp_scale(contrast, start, max_u))
        if max_u - compression <= peak_pq:
            lo = mid
        else:
            hi = mid
    return lo


def make_curve(gain, highlight_pq, max_pq, contrast):
    c = {"gain": max(gain, 1.0), "peakPQ": 1.0, "kneeNits": 10000.0, "kneeU": 1.0, "contrast": 1.0,
         "outlierStartU": 1.0, "outlierScale": 0.0, "maxU": 1.0}
    if PANEL_PEAK <= 0 or c["gain"] <= 1.000001:
        return c
    c["peakPQ"] = nits_to_pq(PANEL_PEAK)
    max_pq = min(max(max_pq, 0.0), c["peakPQ"])
    c["maxU"] = gain_map_pq(max_pq, c["gain"])
    highlight_u = gain_map_pq(min(max(highlight_pq, 0.0), max_pq), c["gain"])
    c["kneeU"] = c["peakPQ"]
    if c["maxU"] > c["peakPQ"]:
        fitting = min(contrast, max_fitting_contrast(c["peakPQ"], highlight_u, c["maxU"]))
        c["contrast"] = max(fitting, OUTLIER)
        c["kneeU"] = solve_knee_u(c["peakPQ"], highlight_u, c["maxU"], c["contrast"])
    c["outlierStartU"] = max(highlight_u, c["kneeU"])
    c["outlierScale"] = outlier_ramp_scale(c["contrast"], c["outlierStartU"], c["maxU"])
    c["kneeNits"] = pq_to_lin(c["kneeU"]) * 10000.0 / c["gain"]
    return c


def make_luma_curve(gain, level_pq):
    peak_pq = nits_to_pq(PANEL_PEAK)
    contrast = 1.0 - (gain_map_pq(min(level_pq, peak_pq), gain) - peak_pq) / SHOULDER_SPAN
    return make_curve(gain, level_pq, level_pq, contrast)


def boost_curve_nits(nits, c):
    n = max(nits, 0.0)
    if n <= c["kneeNits"]:
        return n * c["gain"]
    if n >= PANEL_PEAK:
        return n
    u = nits_to_pq_unclamped(n * c["gain"])
    y = c["peakPQ"]
    if u < c["maxU"]:
        y = min(u - shoulder_compression(u, c["kneeU"], c["contrast"], c["outlierStartU"], c["outlierScale"]), y)
    return max(pq_to_lin(y) * 10000.0, n)


def post_boost_metric(luma_nits, c):
    if luma_nits <= 1e-6:
        return 0.0
    return min(max(boost_curve_nits(luma_nits, c) / max(APL_REF_WHITE, 1.0), 0.0), 1.0)


def eval_nodes(logA, log_gain, scale):
    t = min(max(log_gain * scale, 0.0), 3.0)
    if t <= 1.0:
        e = logA[0] + (logA[1] - logA[0]) * t
    elif t <= 2.0:
        e = logA[1] + (logA[2] - logA[1]) * (t - 1.0)
    else:
        e = logA[2] + (logA[3] - logA[2]) * (t - 2.0)
    return min(max(2.0 ** e, 0.0), 1.0)


def solve_display_apl(raw_apl, nodes, gmax):
    r = min(max(raw_apl, 0.0), 1.0)
    if r <= 1e-6:
        return 0.0
    if gmax <= 1e-6:
        return r
    logA = [math.log2(max(v, 1e-6)) for v in [r] + list(nodes)]
    scale = 3.0 / gmax
    lo, hi = 0.0, gmax
    f_lo = min(max(scene_log_gain(r), 0.0), gmax)
    if f_lo <= 1e-6:
        return r
    apl_hi = min(max(nodes[2], 0.0), 1.0)
    if min(max(scene_log_gain(apl_hi), 0.0), gmax) - gmax >= -1e-6:
        return apl_hi
    for _ in range(10):
        mid = 0.5 * (lo + hi)
        apl_mid = eval_nodes(logA, mid, scale)
        if min(max(scene_log_gain(apl_mid), 0.0), gmax) - mid > 0.0:
            lo = mid
        else:
            hi = mid
    return eval_nodes(logA, 0.5 * (lo + hi), scale)


def solve_flat_field(level_nits):
    """Mirror CS_Solve for a flat full-field frame at level_nits."""
    raw_apl = min(max(level_nits / max(APL_REF_WHITE, 1.0), 0.0), 1.0)
    gmax = cand_max_log_gain()
    level_pq = nits_to_pq(level_nits)
    nodes = [post_boost_metric(level_nits, make_luma_curve(2.0 ** (gmax * k / 3.0), level_pq)) for k in (1, 2, 3)]
    disp_apl = solve_display_apl(raw_apl, nodes, gmax)
    gain = 2.0 ** scene_log_gain(disp_apl)
    return raw_apl, disp_apl, gain


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

    # 2. Closed-loop fixed point: the solved APL must be the APL the boost actually produces at the solved gain.
    print("\n  level(nits)  rawAPL%  solvedAPL%   gain   boostedAPL%")
    for level in (20, 60, 150, 300, 530, 795, 1060):
        raw, disp, gain = solve_flat_field(level)
        boosted = post_boost_metric(level, make_luma_curve(gain, nits_to_pq(level)))
        print(f"  {level:9.0f}  {raw*100:7.2f}  {disp*100:9.2f}  {gain:6.3f}  {boosted*100:10.2f}")
        if abs(disp - boosted) > 0.01 * boosted:
            print(f"FAIL fixed point at {level} nits: solved APL {disp:.4f} != boosted APL {boosted:.4f}")
            fails += 1

    # 3. Boost never darkens and is monotonic in level.
    prev = -1.0
    for level in range(1, 1061, 10):
        raw, disp, gain = solve_flat_field(float(level))
        out = boost_curve_nits(float(level), make_luma_curve(gain, nits_to_pq(float(level))))
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
    p = make_luma_curve(gain, nits_to_pq(80.0))
    mid_out = boost_curve_nits(20.0, p)
    if abs(mid_out - 20.0 * gain) > 0.5:
        print(f"FAIL midtone: 20-nit sample out {mid_out:.3f} vs full-gain {20.0*gain:.3f}")
        fails += 1
    print(f"midtone check: 20-nit sample boosted by full gain {gain:.3f} -> {mid_out:.2f} nits")

    print("\nALL CHECKS PASSED" if fails == 0 else f"\n{fails} CHECK(S) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
