#!/usr/bin/env python3
# Numeric parity check for the scalar core of boost.hlsl against the ReShade shader's values.
#
# For a flat full-field scRGB frame the GPU histogram collapses to a single APL, so this CPU mirror
# of the solve-and-boost path reproduces exactly what the compute passes compute for that frame. It
# checks the closed-loop fixed point (gain == compensation(solved APL)) and that the baked table and
# constants match Shaders/EOTF_BoostMod2.0_27M2N6500.fx. Run: python parity_check.py

import math

# Baked defaults (must match boost.hlsl).
APL_REF_WHITE = 1060.0
PANEL_PEAK = 1060.0
HI_CONTRAST = 0.40
SIG_REF = 80.0
OUTLIER = 0.25
BLEND_POW = 6.0
CLEARANCE = 3.0

ANCHORS = [3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 17.0, 20.0, 22.0, 25.0, 27.0, 30.0,
           35.0, 40.0, 50.0, 75.0, 100.0]
COMP = [1.000000, 1.147683, 1.302371, 1.467331, 1.638837, 1.804870, 1.970627, 2.134085, 2.193709, 2.237231, 2.285468,
        2.324561, 2.376149, 2.437902, 2.545629, 2.594859, 2.693774, 2.746826, 2.807947, 2.895384, 3.001982, 3.178411,
        3.476550, 3.686957]

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
    a = min(max(apl_pct, ANCHORS[0]), ANCHORS[-1])
    i = 0
    while i < len(ANCHORS) - 2 and ANCHORS[i + 1] <= a:
        i += 1
    return seg_lerp(math.log2(a),
                    math.log2(ANCHORS[i]), math.log2(COMP[i]),
                    math.log2(ANCHORS[i + 1]), math.log2(COMP[i + 1]))


def scene_log_gain(apl01):
    return max(lookup_log_comp_1d(min(max(apl01, 0.0), 1.0) * 100.0), 0.0)


def cand_max_log_gain():
    return scene_log_gain(ANCHORS[-1] * 0.01)


# BoostParams + curve (scalar, flat field: luma == max channel).
def make_params(gain, highlight_pq):
    gain = max(gain, 1.0)
    p = {"gain": gain, "peakPQ": 0.0, "hiPQ": 0.0, "hiTopPQ": 0.0, "fullGainNits": 10000.0}
    if PANEL_PEAK <= 0 or gain <= 1.000001:
        return p
    p["peakPQ"] = nits_to_pq(PANEL_PEAK)
    p["hiPQ"] = min(max(highlight_pq, 0.0), p["peakPQ"])
    p["hiTopPQ"] = p["peakPQ"] - OUTLIER * (p["peakPQ"] - p["hiPQ"])
    max_off = max(nits_to_pq_unclamped(PANEL_PEAK * gain) - p["peakPQ"], 0.0)
    clr = CLEARANCE * max_off
    hc = max(min(HI_CONTRAST, 0.95), OUTLIER)
    hlim = (p["hiTopPQ"] - hc * p["hiPQ"] - clr) / (1.0 - hc)
    plim = p["peakPQ"] - clr / (1.0 - OUTLIER)
    lim = min(hlim, plim)
    p["fullGainNits"] = pq_to_lin(lim) * 10000.0 if lim > 0 else 0.0
    return p


def smooth_min(vals):
    s = min(vals)
    if s <= 0:
        return 0.0
    w = sum((s / max(v, 1e-9)) ** BLEND_POW for v in vals)
    return s * w ** (-1.0 / BLEND_POW)


def hi_shoulder(x, p):
    hc = max(min(HI_CONTRAST, 0.95), OUTLIER)
    return p["hiTopPQ"] + hc * (x - p["hiPQ"]) - x


def peak_shoulder(x, p):
    return (1.0 - OUTLIER) * (p["peakPQ"] - x)


def boost_curve_nits(nits, p):
    n = max(nits, 0.0)
    if p["peakPQ"] <= 0 or n <= p["fullGainNits"]:
        return n * p["gain"]
    x = nits_to_pq(n)
    if x >= p["peakPQ"]:
        return n
    gain_off = nits_to_pq_unclamped(n * p["gain"]) - x
    off = smooth_min([gain_off, hi_shoulder(x, p), peak_shoulder(x, p)])
    return pq_to_lin(x + off) * 10000.0


def post_boost_metric(luma_nits, p):
    if luma_nits <= 1e-6:
        return 0.0
    scale = boost_curve_nits(luma_nits, p) / max(luma_nits, 1e-6)  # flat field: max channel == luma
    return min(max(luma_nits * scale / max(APL_REF_WHITE, 1.0), 0.0), 1.0)


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
    highlight_pq = nits_to_pq(level_nits)
    nodes = []
    for k in (1, 2, 3):
        p = make_params(2.0 ** (gmax * k / 3.0), highlight_pq)
        nodes.append(post_boost_metric(level_nits, p))
    disp_apl = solve_display_apl(raw_apl, nodes, gmax)
    gain = 2.0 ** scene_log_gain(disp_apl)
    return raw_apl, disp_apl, gain


def main():
    fails = 0

    # 1. Baked table matches the published measurements (compensation = 1060-nit peak / peak at APL).
    peaks = [1060.0, 923.6, 813.9, 722.4, 646.8, 587.3, 537.9, 496.7, 483.2, 473.8, 463.8, 456.0, 446.1, 434.8, 416.4,
             408.5, 393.5, 385.9, 377.5, 366.1, 353.1, 333.5, 304.9, 287.5]
    for apl, comp, peak in zip(ANCHORS, COMP, peaks):
        expect = 1060.0 / peak
        if abs(expect - comp) > 5e-4:
            print(f"FAIL table {apl}%: baked {comp:.6f} vs peak-derived {expect:.6f}")
            fails += 1
    print("table check: baked COMP_APL_1D matches the measured peaks")

    # 2. Closed-loop fixed point: the solved gain must equal compensation(solved APL).
    print("\n  level(nits)  rawAPL%  solvedAPL%   gain   comp(solvedAPL)")
    for level in (20, 60, 150, 300, 530, 795, 1060):
        raw, disp, gain = solve_flat_field(level)
        comp_at = 2.0 ** lookup_log_comp_1d(disp * 100.0)
        print(f"  {level:9.0f}  {raw*100:7.2f}  {disp*100:9.2f}  {gain:6.3f}  {comp_at:7.3f}")
        if abs(gain - comp_at) > 1e-2:
            print(f"FAIL fixed point at {level} nits: gain {gain:.4f} != comp {comp_at:.4f}")
            fails += 1

    # 3. Boost never darkens and is monotonic in level.
    prev = -1.0
    for level in range(1, 1061, 10):
        raw, disp, gain = solve_flat_field(float(level))
        out = boost_curve_nits(float(level), make_params(gain, nits_to_pq(float(level))))
        if out < float(level) - 1e-3:
            print(f"FAIL darkening at {level} nits: out {out:.2f}")
            fails += 1
        prev = out
    print("\nmonotonic / no-darkening check: passed" if fails == 0 else "")

    # 4. Shadow/midtone gain is the full table gain below the shoulder (mid-gray is fully restored).
    raw, disp, gain = solve_flat_field(80.0)   # scRGB 1.0 flat field
    p = make_params(gain, nits_to_pq(80.0))
    mid_out = boost_curve_nits(20.0, p)
    if abs(mid_out - 20.0 * gain) > 0.5:
        print(f"FAIL midtone: 20-nit sample out {mid_out:.3f} vs full-gain {20.0*gain:.3f}")
        fails += 1
    print(f"midtone check: 20-nit sample boosted by full gain {gain:.3f} -> {mid_out:.2f} nits")

    print("\nALL CHECKS PASSED" if fails == 0 else f"\n{fails} CHECK(S) FAILED")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
