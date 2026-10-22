// EOTF Boost for DWM — scRGB desktop path, ported from Shaders/EOTF_BoostMod2.0_27M2N6500.fx.
//
// The algorithm and output match the ReShade shader at its current defaults. Only the scRGB input
// path is kept (DWM composes into FP16 scRGB); the PQ-input branch, the fast-PQ decode table, the
// OSD, the debug graph, the calibration LUT, and every runtime uniform are removed, their values
// baked below. ReShade intrinsics are replaced with plain HLSL: tex2Dstore -> RWTexture store,
// tex2Dfetch -> Load, atomicAdd/atomicMax -> InterlockedAdd/Max, barrier -> GroupMemoryBarrierWithGroupSync.
//
// Five stages, same sync boundaries as the source:
//   1  CS_Setup          frame setup and rolling-row clear
//   2  CS_Build          full-frame row histogram build (reads the clean copy)
//   3  CS_Reduce         global histogram reduction
//   4  CS_Solve          scene levels, response solve, smoothing, boost curves
//   5  VS_Boost/PS_Boost fullscreen boost (clean copy -> back buffer)
//
// The source's skipped-frame pause detection used ReShade's frame counter, which does not exist
// here; the host raises ResetFlag instead (on enable, prime, and mode change) to drop stale rows
// and smoothing history.
//
// DWM also stops presenting while the screen is static, where a game keeps presenting the same frame.
// The host passes that gap apart from the one-frame step, and the smoothing first converges toward
// the previous run's targets over the gap, as the ReShade passes would on the repeated frames.

// Baked defaults (ReShade uniform values).
static const float APLReferenceWhiteNits        = 1060.0;
static const float PanelPeakNits                = 1060.0;
static const float CompensationFreezeAPLPercent = 50.0;
static const float ShoulderSpanPQ               = 0.30;
static const float TransitionSpeed              = 0.25;   // APL smoothing time, seconds
static const float SIGNAL_REFERENCE_NITS        = 80.0;   // scRGB 1.0

// Full-frame histogram layout. Each 16x16 group processes one 32x32 pixel tile.
#define APL_FFH_TILE_SIZE        32
#define APL_FFH_THREADS_X        16
#define APL_FFH_THREADS_Y        16
#define APL_FFH_PIXELS_X          2
#define APL_FFH_PIXELS_Y          2
#define APL_FFH_LUMA_BINS        64
#define APL_FFH_COLOR_RATIO_BINS  4
#define APL_FFH_MAX_BINS        256
#define APL_FFH_BLOCK_W          16
#define APL_FFH_BLOCK_H          16
#define APL_FFH_REDUCE_THREADS   64
#define APL_SETUP_THREADS       256

// Fine bins for the scene maxima: 1/32 octave from 128 to 2048 nits, luma first, then brightest channel.
// They sit in extra columns of the count textures, next to each row's histogram block, one per
// histogram bin so the passes clear, build and reduce them alongside it.
#define APL_TOP_MIN_EXPONENT      9
#define APL_TOP_OCTAVES           4
#define APL_TOP_SUB_BITS          5
#define APL_TOP_BINS            (APL_TOP_OCTAVES << APL_TOP_SUB_BITS)
#define APL_TOP_SLOTS           (2 * APL_TOP_BINS)

// Packed value: pixel count in the upper bits, summed bin position in the lower bits.
#define APL_FFH_PACK_COUNT_SHIFT  20
#define APL_FFH_PACK_OFFSET_MASK  ((1 << APL_FFH_PACK_COUNT_SHIFT) - 1)
#define APL_FFH_PACK_OFFSET_SCALE 1023
#define APL_FFH_PACK_ONE_COUNT    (1 << APL_FFH_PACK_COUNT_SHIFT)

#define APL_FFH_TILE_COUNT_X ((BUFFER_WIDTH  + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)
#define APL_FFH_TILE_COUNT_Y ((BUFFER_HEIGHT + APL_FFH_TILE_SIZE - 1) / APL_FFH_TILE_SIZE)

#define APL_FFH_ROW_HIST_TEX_W  APL_FFH_BLOCK_W
#define APL_FFH_ROW_TEX_H       (APL_FFH_TILE_COUNT_Y * APL_FFH_BLOCK_H)

#define APL_FULLFRAME_ROLLING_PHASES 6
#define APL_FFH_ROLLING_ROW_SLOTS ((APL_FFH_TILE_COUNT_Y + APL_FULLFRAME_ROLLING_PHASES - 1) / APL_FULLFRAME_ROLLING_PHASES)
#define APL_FFH_ROW_META_COUNT_BITS 20
#define APL_FFH_ROW_META_COUNT_MASK ((1 << APL_FFH_ROW_META_COUNT_BITS) - 1)


cbuffer BoostCB : register(b0)
{
    float FrameTime;   // ms, at most one refresh period: this frame's smoothing step
    float GapTime;     // ms the previous frame stayed on screen beyond that step
    uint  ResetFlag;   // 1 = resume after a pause: drop stale rows and smoothing history
    float _cbpad;
    uint  BufferWidthPx;   // target back-buffer size; sets the histogram geometry
    uint  BufferHeightPx;
    float LitFraction;     // share of the native panel the buffer covers; the rest is black bars
    float _cbpad2;
};

#define BUFFER_WIDTH  int(BufferWidthPx)
#define BUFFER_HEIGHT int(BufferHeightPx)


// Fixed constants carried over from the source.
static const float OUTLIER_HIGHLIGHT_CONTRAST    = 0.25;   // PQ contrast at the scene max
static const float HIGHLIGHT_PEAK_LIGHT_FRACTION = 1.0 / 256.0;
static const float SCENE_MAX_PIXELS              = 64.0;   // brightest pixels the scene maxima log-average over
static const float SMOOTHING_HALVING_GAIN_GAP    = 0.08;   // log2 gain gap that halves the smoothing time
static const float KNEE_TRANSITION_PQ            = 0.04;   // PQ width of the slope ease at the knee
static const int   KNEE_SEARCH_STEPS             = 24;


// -------- color and transfer helpers --------

float GetLuma709(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float Max3(float3 v)
{
    return max(max(v.r, v.g), v.b);
}

// Channel limits are judged in Rec.2020, the gamut of the HDR10 signal the panel receives.
float3 Rec709ToRec2020(float3 rgb)
{
    return float3(
        dot(rgb, float3(0.6274040, 0.3292820, 0.0433136)),
        dot(rgb, float3(0.0690970, 0.9195400, 0.0113612)),
        dot(rgb, float3(0.0163916, 0.0880132, 0.8955950))
    );
}

static const float PQ_M1 = 0.1593017578125;
static const float PQ_M2 = 78.84375;
static const float PQ_C1 = 0.8359375;
static const float PQ_C2 = 18.8515625;
static const float PQ_C3 = 18.6875;

float PQToLinearBT2100(float v)
{
    float vp = pow(saturate(v), 1.0 / PQ_M2);
    float num = max(vp - PQ_C1, 0.0);
    float den = PQ_C2 - PQ_C3 * vp;
    return pow(num / max(den, 1e-6), 1.0 / PQ_M1);
}

// Monotonic above 1.0, so gain offsets stay ordered past 10000 nits.
float LinearToPQBT2100Unclamped(float linearValue)
{
    float Lm1 = pow(max(linearValue, 0.0), PQ_M1);
    return pow((PQ_C1 + PQ_C2 * Lm1) / (1.0 + PQ_C3 * Lm1), PQ_M2);
}

float LinearToPQBT2100(float linearValue)
{
    return LinearToPQBT2100Unclamped(saturate(linearValue));
}

float NitsToPQ(float nits)          { return LinearToPQBT2100(nits / 10000.0); }
float NitsToPQUnclamped(float nits) { return LinearToPQBT2100Unclamped(nits / 10000.0); }


// -------- boost curve --------

// Full gain up to the knee. Above it, every level keeps the same share of its PQ contrast up to the
// scene highlight peak, then eases to the outlier contrast and reaches the panel peak at the scene
// maximum. Levels named U are PQ codes after the full gain.
struct BoostCurve
{
    float gain;
    float peakPQ;
    float kneeNits;
    float kneeU;
    float contrast;
    float highlightU;
    float maxU;
};

// PQ code of a source PQ code after the full gain.
float GainMapPQ(float pq, float gain)
{
    return NitsToPQUnclamped(PQToLinearBT2100(pq) * 10000.0 * gain);
}

// How far the shoulder sits below the full gain at u. One ramp from the knee eases the slope to the
// curve's contrast; a second from the highlight peak eases it on to the outlier contrast.
float ShoulderCompressionPQ(float u, float kneeU, float highlightU, float maxU, float contrast)
{
    float t = max(u - kneeU, 0.0);
    float bulk = (t < KNEE_TRANSITION_PQ)
        ? t * t / (2.0 * KNEE_TRANSITION_PQ)
        : t - 0.5 * KNEE_TRANSITION_PQ;

    float outlierStart = max(highlightU, kneeU);
    float outlierSpan = max(maxU - outlierStart, 1e-6);
    float v = clamp(u - outlierStart, 0.0, outlierSpan);

    return (1.0 - contrast) * bulk + (contrast - OUTLIER_HIGHLIGHT_CONTRAST) * v * v / (2.0 * outlierSpan);
}

// Highest contrast whose shoulder still ends on the panel peak with the knee at black.
float MaxFittingContrast(float peakPQ, float highlightU, float maxU)
{
    float outlierSpan = maxU - highlightU;
    return (peakPQ - 0.5 * KNEE_TRANSITION_PQ - 0.5 * OUTLIER_HIGHLIGHT_CONTRAST * outlierSpan) /
        (0.5 * (maxU + highlightU) - 0.5 * KNEE_TRANSITION_PQ);
}

// Highest knee whose shoulder ends on the panel peak at the scene maximum.
float SolveKneeU(float peakPQ, float highlightU, float maxU, float contrast)
{
    float lo = 0.0;
    float hi = peakPQ;

    [loop]
    for (int i = 0; i < KNEE_SEARCH_STEPS; ++i)
    {
        float mid = 0.5 * (lo + hi);

        if (maxU - ShoulderCompressionPQ(maxU, mid, highlightU, maxU, contrast) <= peakPQ)
            lo = mid;
        else
            hi = mid;
    }

    return lo;
}

BoostCurve MakeBoostCurve(float gain, float highlightPQ, float maxPQ, float contrast)
{
    BoostCurve curve;
    curve.gain = max(gain, 1.0);
    curve.peakPQ = 1.0;
    curve.kneeNits = 10000.0;
    curve.kneeU = 1.0;
    curve.contrast = 1.0;
    curve.highlightU = 1.0;
    curve.maxU = 1.0;

    if (PanelPeakNits <= 0.0 || curve.gain <= 1.000001)
        return curve;

    curve.peakPQ = NitsToPQ(PanelPeakNits);
    maxPQ = clamp(maxPQ, 0.0, curve.peakPQ);
    curve.maxU = GainMapPQ(maxPQ, curve.gain);
    curve.highlightU = GainMapPQ(clamp(highlightPQ, 0.0, maxPQ), curve.gain);

    // When the whole boosted scene fits, the knee sits where the gain reaches the panel peak.
    curve.kneeU = curve.peakPQ;

    if (curve.maxU > curve.peakPQ)
    {
        float fittingContrast = min(contrast, MaxFittingContrast(curve.peakPQ, curve.highlightU, curve.maxU));
        curve.contrast = max(fittingContrast, OUTLIER_HIGHLIGHT_CONTRAST);
        curve.kneeU = SolveKneeU(curve.peakPQ, curve.highlightU, curve.maxU, curve.contrast);
    }

    curve.kneeNits = PQToLinearBT2100(curve.kneeU) * 10000.0 / curve.gain;
    return curve;
}

// Spreads the boosted scene's overshoot of the panel peak over the shoulder span, so a small overshoot
// costs each highlight level a little contrast and a large one costs more.
float GetHighlightContrast(float gain, float maxPQ)
{
    float peakPQ = NitsToPQ(PanelPeakNits);
    float overshootPQ = GainMapPQ(min(maxPQ, peakPQ), gain) - peakPQ;
    return 1.0 - overshootPQ / ShoulderSpanPQ;
}

// Scene levels in PQ: x = highlight peak, y = luma maximum, z = brightest channel maximum.
BoostCurve MakeLumaBoostCurve(float gain, float3 scenePQ)
{
    return MakeBoostCurve(gain, scenePQ.x, scenePQ.y, GetHighlightContrast(gain, scenePQ.y));
}

BoostCurve MakeChannelBoostCurve(float gain, float3 scenePQ)
{
    return MakeBoostCurve(gain, scenePQ.z, scenePQ.z, OUTLIER_HIGHLIGHT_CONTRAST);
}

// Texture layout: row 0 holds gain and peak; each curve then takes a knee row and a highlight row.
float4 PackBoostCurveGlobals(BoostCurve curve)
{
    return float4(curve.gain, curve.peakPQ, 0.0, 0.0);
}

float4 PackBoostCurveKnee(BoostCurve curve)
{
    return float4(curve.kneeNits, curve.kneeU, curve.contrast, 0.0);
}

float4 PackBoostCurveHighlight(BoostCurve curve)
{
    return float4(curve.highlightU, curve.maxU, 0.0, 0.0);
}

BoostCurve UnpackBoostCurve(float4 globals, float4 knee, float4 highlight)
{
    BoostCurve curve;
    curve.gain = globals.x;
    curve.peakPQ = globals.y;
    curve.kneeNits = knee.x;
    curve.kneeU = knee.y;
    curve.contrast = knee.z;
    curve.highlightU = highlight.x;
    curve.maxU = highlight.y;
    return curve;
}

float Remap01(float x, float a, float b)
{
    return saturate((x - a) / max(b - a, 1e-6));
}

float SegmentLerp(float x, float x0, float y0, float x1, float y1)
{
    return lerp(y0, y1, Remap01(x, x0, x1));
}

// Measured APL anchors of the compensation table.
static const int APL_ANCHOR_COUNT = 7;

static const float APL_ANCHOR_POINTS[APL_ANCHOR_COUNT] =
{
    2.000000, 5.000000, 10.000000, 25.000000, 50.000000, 75.000000, 100.000000
};

// 1D compensation: the 1060 nit peak at 2% APL divided by the peak at each anchor,
// measured by TFTCentral on the Dell Alienware AW2725DF (same panel, HDR Peak 1000, FW M2B102).
static const float COMP_APL_1D[APL_ANCHOR_COUNT] =
{
    1.000000, // 2%   (1060 nits)
    1.362468, // 5%   (778 nits)
    2.217573, // 10%  (478 nits)
    2.796834, // 25%  (379 nits)
    3.322884, // 50%  (319 nits)
    3.680556, // 75%  (288 nits)
    3.925926  // 100% (270 nits)
};

int FindAPLAnchorIndex(float aplPct)
{
    int idx = 0;
    [unroll]
    for (int i = 0; i < APL_ANCHOR_COUNT - 1; ++i)
        idx += int(step(APL_ANCHOR_POINTS[i + 1], aplPct));
    return min(idx, APL_ANCHOR_COUNT - 2);
}

float ApplyCompensationFreezeAPL(float aplPct)
{
    float freezeAPL = CompensationFreezeAPLPercent;
    if (freezeAPL > 0.0)
        aplPct = min(aplPct, freezeAPL);
    return aplPct;
}

float LookupMeasuredComp1D(float aplPct)
{
    float lookupAPL = ApplyCompensationFreezeAPL(aplPct);
    float clampedAPL = clamp(lookupAPL, APL_ANCHOR_POINTS[0], APL_ANCHOR_POINTS[APL_ANCHOR_COUNT - 1]);
    int a0 = FindAPLAnchorIndex(clampedAPL);
    int a1 = min(a0 + 1, APL_ANCHOR_COUNT - 1);

    return SegmentLerp(
        clampedAPL,
        APL_ANCHOR_POINTS[a0], COMP_APL_1D[a0],
        APL_ANCHOR_POINTS[a1], COMP_APL_1D[a1]
    );
}

float ComputeTemporalBlendFactor(float smoothingSeconds, float elapsedMs)
{
    if (smoothingSeconds <= 1e-6)
        return 1.0;

    float dtSeconds = max(elapsedMs, 0.0) * 0.001;
    return saturate(1.0 - exp(-dtSeconds / max(smoothingSeconds, 1e-6)));
}

float ComputeSceneLogGainFromAPL(float currentAPL)
{
    float aplPct = saturate(currentAPL) * 100.0;
    return log2(max(LookupMeasuredComp1D(aplPct), 1.0));
}

// Shrinks while the gain trails its target by a large step, and grows back toward TransitionSpeed at the
// same pace afterwards, so the end of a big change does not slow down again.
float ComputeSmoothingTime(float previousSmoothingTime, float targetAPL, float smoothedAPL, float elapsedMs)
{
    float relaxedTime = lerp(previousSmoothingTime, TransitionSpeed, ComputeTemporalBlendFactor(TransitionSpeed, elapsedMs));
    float gainGap = abs(ComputeSceneLogGainFromAPL(targetAPL) - ComputeSceneLogGainFromAPL(smoothedAPL));
    float gapRatio = gainGap / SMOOTHING_HALVING_GAIN_GAP;
    return min(relaxedTime, TransitionSpeed * exp2(-gapRatio * gapRatio));
}

float ComputeCandidateMaxLogGain()
{
    return ComputeSceneLogGainFromAPL(APL_ANCHOR_POINTS[APL_ANCHOR_COUNT - 1] * 0.01);
}

float SceneGainFromLogGain(float sceneLogGain)
{
    return exp2(max(sceneLogGain, 0.0));
}

// Response-node candidates at gMax/3, 2*gMax/3, and gMax.
float CandidateGain(int candidateIndex, float gMax)
{
    return SceneGainFromLogGain(gMax * float(candidateIndex) / 3.0);
}

// Curve in signal nits: full gain up to the knee, then the shoulder.
float ApplyBoostCurveToNits(float nits, BoostCurve curve)
{
    float safeNits = max(nits, 0.0);

    if (safeNits <= curve.kneeNits)
        return safeNits * curve.gain;

    if (safeNits >= PanelPeakNits)
        return safeNits;

    float u = NitsToPQUnclamped(safeNits * curve.gain);
    float y = curve.peakPQ;

    if (u < curve.maxU)
        y = min(u - ShoulderCompressionPQ(u, curve.kneeU, curve.highlightU, curve.maxU, curve.contrast), curve.peakPQ);

    return max(PQToLinearBT2100(y) * 10000.0, safeNits);
}

// One scale for all channels. Luma follows its curve; the channel curve then keeps the brightest channel
// under the panel peak, but never compresses it below what the luma curve gives the same level.
float ComputeBoostScale(float lumaNits, float maxChannelNits, BoostCurve lumaCurve, BoostCurve channelCurve)
{
    float lumaScale = ApplyBoostCurveToNits(lumaNits, lumaCurve) / max(lumaNits, 1e-6);

    if (maxChannelNits <= channelCurve.kneeNits)
        return lumaScale;

    float channelNits = max(
        ApplyBoostCurveToNits(maxChannelNits, channelCurve),
        ApplyBoostCurveToNits(maxChannelNits, lumaCurve));

    return min(lumaScale, channelNits / maxChannelNits);
}

float3 ApplyBoostFromPrecomputedParams(float3 color, BoostCurve lumaCurve, BoostCurve channelCurve)
{
    if (lumaCurve.gain <= 1.000001)
        return color;

    float lumaNits = GetLuma709(color) * SIGNAL_REFERENCE_NITS;
    if (lumaNits <= 1e-6)
        return color;

    float maxChannelNits = Max3(Rec709ToRec2020(color)) * SIGNAL_REFERENCE_NITS;
    return color * ComputeBoostScale(lumaNits, maxChannelNits, lumaCurve, channelCurve);
}

// Scalar response used by live APL analysis.
float ComputePostBoostNitsForSample(float lumaNits, float maxChannelNits, BoostCurve lumaCurve, BoostCurve channelCurve)
{
    if (lumaNits <= 1e-6)
        return 0.0;

    return lumaNits * ComputeBoostScale(lumaNits, max(maxChannelNits, lumaNits), lumaCurve, channelCurve);
}

float ComputePostBoostMetricForSample(float lumaNits, float maxChannelNits, BoostCurve lumaCurve, BoostCurve channelCurve)
{
    return saturate(
        ComputePostBoostNitsForSample(lumaNits, maxChannelNits, lumaCurve, channelCurve) /
        max(APLReferenceWhiteNits, 1.0)
    );
}

// Interpolate APL response at four log-gain nodes.
float EvaluateDisplayAPLResponseFromLogNodes(float4 logA, float logGain, float gainToNodeScale)
{
    float t = clamp(logGain * gainToNodeScale, 0.0, 3.0);
    float logEst;

    if (t <= 1.0)
        logEst = lerp(logA.x, logA.y, t);
    else if (t <= 2.0)
        logEst = lerp(logA.y, logA.z, t - 1.0);
    else
        logEst = lerp(logA.z, logA.w, t - 2.0);

    return saturate(exp2(logEst));
}

// Solve gain = compensation(APL response) with ten bisection steps.
float SolveClosedLoopDisplayAPLFromResponseNodes(float rawAPL, float3 responseNodes, float gMax)
{
    float safeRawAPL = saturate(rawAPL);
    if (safeRawAPL <= 1e-6)
        return 0.0;
    if (gMax <= 1e-6)
        return safeRawAPL;

    float4 logA = log2(max(float4(safeRawAPL, responseNodes), 1e-6));
    float gainToNodeScale = 3.0 / gMax;

    float lo = 0.0;
    float hi = gMax;

    float aplLo = safeRawAPL;
    float fLo = clamp(ComputeSceneLogGainFromAPL(aplLo), 0.0, gMax);
    if (fLo <= 1e-6)
        return aplLo;

    float aplHi = saturate(responseNodes.z);
    float fHi = clamp(ComputeSceneLogGainFromAPL(aplHi), 0.0, gMax) - gMax;
    if (fHi >= -1e-6)
        return aplHi;

    [loop]
    for (int i = 0; i < 10; ++i)
    {
        float mid = 0.5 * (lo + hi);
        float aplMid = EvaluateDisplayAPLResponseFromLogNodes(logA, mid, gainToNodeScale);
        float fMid = clamp(ComputeSceneLogGainFromAPL(aplMid), 0.0, gMax) - mid;
        if (fMid > 0.0)
            lo = mid;
        else
            hi = mid;
    }

    float solvedGain = 0.5 * (lo + hi);
    return EvaluateDisplayAPLResponseFromLogNodes(logA, solvedGain, gainToNodeScale);
}


// -------- histogram quantization and binning --------

int APL_QuantizeNitsQ4(float nits)
{
    return (int)floor(clamp(nits, 0.0, 10000.0) * 4.0 + 0.5);
}

int APL_QuantizeMaxNits2(float nits)
{
    return (int)floor(clamp(nits, 0.0, 10000.0) * 0.5 + 0.5);
}

int APL_HistogramLumaBin64(int lumaQ4)
{
    if (lumaQ4 <= 0) return 0;
    int exponent = firstbithigh(lumaQ4);
    int subBin = (exponent >= 2) ? ((lumaQ4 >> (exponent - 2)) & 3) : 0;
    return min(exponent * 4 + subBin, APL_FFH_LUMA_BINS - 1);
}

int APL_HistogramColorRatioBin(int lumaQ4, int maxQ4)
{
    int safeLumaQ4 = max(lumaQ4, 1);
    int ratioBin = 0;
    ratioBin += (maxQ4 >= safeLumaQ4 * 2) ? 1 : 0;
    ratioBin += (maxQ4 >= safeLumaQ4 * 4) ? 1 : 0;
    ratioBin += (maxQ4 >= safeLumaQ4 * 8) ? 1 : 0;
    return min(ratioBin, APL_FFH_COLOR_RATIO_BINS - 1);
}

void APL_HistogramLumaBinBoundsQ4(int lumaBin, out int lowerQ4, out int upperQ4)
{
    lowerQ4 = 0;
    upperQ4 = 0;

    int exponent = lumaBin >> 2;
    int subBin = lumaBin & 3;

    if (exponent < 2)
    {
        lowerQ4 = (exponent == 0) ? 0 : (1 << exponent);
        upperQ4 = (1 << (exponent + 1)) - 1;
    }
    else
    {
        int stepQ4 = 1 << (exponent - 2);
        lowerQ4 = (1 << exponent) + subBin * stepQ4;
        upperQ4 = lowerQ4 + stepQ4 - 1;
    }

    upperQ4 = min(upperQ4, 40000);
    lowerQ4 = min(lowerQ4, upperQ4);
}

int APL_EncodeWithinBinOffset10(int lumaQ4, int lumaBin)
{
    int lowerQ4 = 0;
    int upperQ4 = 0;
    APL_HistogramLumaBinBoundsQ4(lumaBin, lowerQ4, upperQ4);

    uint rangeQ4 = uint(upperQ4 - lowerQ4);
    if (rangeQ4 == 0u)
        return 0;

    uint positionQ4 = uint(clamp(lumaQ4, lowerQ4, upperQ4) - lowerQ4);
    uint numerator = positionQ4 * uint(APL_FFH_PACK_OFFSET_SCALE);
    uint offset10 = (numerator + (rangeQ4 >> 1)) / rangeQ4;
    return int(min(offset10, uint(APL_FFH_PACK_OFFSET_SCALE)));
}

float APL_ReconstructMeanLumaQ4(int binIndex, float pixelCount, float offsetSum10)
{
    int lumaBin = binIndex / APL_FFH_COLOR_RATIO_BINS;
    int lowerQ4 = 0;
    int upperQ4 = 0;
    APL_HistogramLumaBinBoundsQ4(lumaBin, lowerQ4, upperQ4);
    float rangeQ4 = float(upperQ4 - lowerQ4);

    if (pixelCount <= 0.0 || rangeQ4 <= 0.0)
        return float(lowerQ4);

    float meanOffset10 = offsetSum10 / pixelCount;
    return float(lowerQ4) + rangeQ4 * (meanOffset10 / float(APL_FFH_PACK_OFFSET_SCALE));
}

int2 APL_HistogramBlockCoord(int binIndex)
{
    return int2(binIndex % APL_FFH_BLOCK_W, binIndex / APL_FFH_BLOCK_W);
}

int2 APL_RowHistogramCoord(int rowIndex, int binIndex)
{
    int2 binCoord = APL_HistogramBlockCoord(binIndex);
    return int2(binCoord.x, rowIndex * APL_FFH_BLOCK_H + binCoord.y);
}

int2 APL_GlobalTopCoord(int topSlot)
{
    return int2(APL_FFH_BLOCK_W + topSlot / APL_FFH_BLOCK_H, topSlot % APL_FFH_BLOCK_H);
}

int2 APL_RowTopCoord(int rowIndex, int topSlot)
{
    return APL_GlobalTopCoord(topSlot) + int2(0, rowIndex * APL_FFH_BLOCK_H);
}

// Fine bin of a quantized level for the scene maxima, or -1 below the fine range.
int APL_TopBin(int levelQ4)
{
    if (levelQ4 < (1 << APL_TOP_MIN_EXPONENT))
        return -1;

    int exponent = firstbithigh(levelQ4);
    if (exponent >= APL_TOP_MIN_EXPONENT + APL_TOP_OCTAVES)
        return APL_TOP_BINS - 1;

    int subBin = (levelQ4 >> (exponent - APL_TOP_SUB_BITS)) & ((1 << APL_TOP_SUB_BITS) - 1);
    return ((exponent - APL_TOP_MIN_EXPONENT) << APL_TOP_SUB_BITS) + subBin;
}

void APL_TopBinBoundsQ4(int topBin, out int lowerQ4, out int upperQ4)
{
    int exponent = APL_TOP_MIN_EXPONENT + (topBin >> APL_TOP_SUB_BITS);
    int subBin = topBin & ((1 << APL_TOP_SUB_BITS) - 1);
    int stepQ4 = 1 << (exponent - APL_TOP_SUB_BITS);
    lowerQ4 = (1 << exponent) + subBin * stepQ4;
    upperQ4 = lowerQ4 + stepQ4 - 1;
}

int APL_GetNextRollingPhase(int currentPhase)
{
    int nextPhase = currentPhase + 1;
    return (nextPhase < APL_FULLFRAME_ROLLING_PHASES) ? nextPhase : 0;
}

int APL_DecodeStoredRollingPhase(float storedPhase)
{
    return clamp(int(floor(storedPhase + 0.5)), 0, APL_FULLFRAME_ROLLING_PHASES - 1);
}

int APL_GetPhysicalRowFromDispatchSlot(int dispatchRowSlot, int rollingPhase)
{
    return rollingPhase + dispatchRowSlot * APL_FULLFRAME_ROLLING_PHASES;
}

int APL_GetExpectedRowPixelCount(int rowIndex)
{
    int rowStartY = rowIndex * APL_FFH_TILE_SIZE;
    int rowHeight = clamp(BUFFER_HEIGHT - rowStartY, 0, APL_FFH_TILE_SIZE);
    return BUFFER_WIDTH * rowHeight;
}

int APL_GetExpectedTilePixelCount(int tileX, int rowIndex)
{
    int tileStartX = tileX * APL_FFH_TILE_SIZE;
    int tileStartY = rowIndex * APL_FFH_TILE_SIZE;
    int tileWidth = clamp(BUFFER_WIDTH - tileStartX, 0, APL_FFH_TILE_SIZE);
    int tileHeight = clamp(BUFFER_HEIGHT - tileStartY, 0, APL_FFH_TILE_SIZE);
    return tileWidth * tileHeight;
}

// scRGB signal only, so the rolling signature is fixed; a single constant keeps row validity simple.
int APL_GetRollingHistogramSignature()
{
    return clamp(int(SIGNAL_REFERENCE_NITS + 0.5), 1, 200) * 2;
}


// =====================================================================================
// Pass 1: frame setup and rolling-row clear.
// SRV  t0 = APLInstant   t1 = APL (smoothed)
// UAV  u0 = RowHistCount u1 = RowHistOffset10 u2 = RowHistMaxNits u3 = RowMeta u4 = APLPrev
// =====================================================================================
Texture2D<float4>   Setup_APLInstant : register(t0);
Texture2D<float4>   Setup_APL        : register(t1);
RWTexture2D<int>    Setup_RowCount   : register(u0);
RWTexture2D<int>    Setup_RowOffset  : register(u1);
RWTexture2D<int>    Setup_RowMaxNits : register(u2);
RWTexture2D<int>    Setup_RowMeta    : register(u3);
RWTexture2D<float4> Setup_APLPrev    : register(u4);

groupshared int APL_SetupRollingPhase;
groupshared int APL_SetupResumedAfterPause;

[numthreads(APL_SETUP_THREADS, 1, 1)]
void CS_Setup(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);

    if (localIndex == 0)
    {
        float4 instantData = Setup_APLInstant.Load(int3(0, 0, 0));
        bool resumedAfterPause = (ResetFlag != 0u);
        APL_SetupRollingPhase = APL_DecodeStoredRollingPhase(instantData.b);
        APL_SetupResumedAfterPause = resumedAfterPause ? 1 : 0;

        float4 previousState = (float4)0.0;
        float4 previousMaxima = (float4)0.0;
        if (!resumedAfterPause)
        {
            previousState = Setup_APL.Load(int3(0, 0, 0));
            previousMaxima = Setup_APL.Load(int3(1, 0, 0));

            // APLInstant keeps the previous run's targets: g = display APL, a = highlight PQ, texel 1 = scene maxima PQ.
            // Texel 1 of the smoothed state carries the smoothing time in z.
            float gapSmoothingTime = ComputeSmoothingTime(previousMaxima.z, instantData.g, previousState.r, GapTime);
            float gapAlpha = ComputeTemporalBlendFactor(gapSmoothingTime, GapTime);
            previousState.r = lerp(previousState.r, instantData.g, gapAlpha);
            previousState.g = lerp(previousState.g, instantData.a, gapAlpha);
            previousMaxima.xy = lerp(previousMaxima.xy, Setup_APLInstant.Load(int3(1, 0, 0)).xy, gapAlpha);
            previousMaxima.z = gapSmoothingTime;
        }

        // Layout: smoothed APL, this run's rolling phase, history flag, smoothed highlight PQ.
        Setup_APLPrev[int2(0, 0)] = float4(previousState.r, float(APL_SetupRollingPhase), previousState.b, previousState.g);
        Setup_APLPrev[int2(1, 0)] = previousMaxima;
    }
    GroupMemoryBarrierWithGroupSync();

    int totalEntries = APL_FFH_ROLLING_ROW_SLOTS * APL_FFH_MAX_BINS;
    int signature = APL_GetRollingHistogramSignature();

    [loop]
    for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += APL_SETUP_THREADS)
    {
        bool rebuiltThisFrame = (rowIndex % APL_FULLFRAME_ROLLING_PHASES) == APL_SetupRollingPhase;
        if (APL_SetupResumedAfterPause != 0 && !rebuiltThisFrame)
            Setup_RowMeta[int2(0, rowIndex)] = 0;
    }

    [loop]
    for (int entry = localIndex; entry < totalEntries; entry += APL_SETUP_THREADS)
    {
        int rowSlot = entry / APL_FFH_MAX_BINS;
        int binIndex = entry - rowSlot * APL_FFH_MAX_BINS;
        int rowIndex = APL_GetPhysicalRowFromDispatchSlot(rowSlot, APL_SetupRollingPhase);
        if (rowIndex < APL_FFH_TILE_COUNT_Y)
        {
            int2 coord = APL_RowHistogramCoord(rowIndex, binIndex);
            Setup_RowCount[coord] = 0;
            Setup_RowOffset[coord] = 0;
            Setup_RowMaxNits[coord] = 0;
            Setup_RowCount[APL_RowTopCoord(rowIndex, binIndex)] = 0;
            if (binIndex == 0)
                Setup_RowMeta[int2(0, rowIndex)] = signature << APL_FFH_ROW_META_COUNT_BITS;
        }
    }
}


// =====================================================================================
// Pass 2: decode source pixels and accumulate row histograms.
// SRV  t0 = CleanCopy  t1 = APLPrev
// UAV  u0 = RowHistCount u1 = RowHistOffset10 u2 = RowHistMaxNits u3 = RowMeta
// =====================================================================================
Texture2D<float4> Build_CleanCopy : register(t0);
Texture2D<float4> Build_APLPrev   : register(t1);
RWTexture2D<int>  Build_RowCount   : register(u0);
RWTexture2D<int>  Build_RowOffset  : register(u1);
RWTexture2D<int>  Build_RowMaxNits : register(u2);
RWTexture2D<int>  Build_RowMeta    : register(u3);

groupshared int APL_TilePackedCountLuma[APL_FFH_MAX_BINS];
groupshared int APL_TileMaxNits[APL_FFH_MAX_BINS];
groupshared int APL_TileTopCount[APL_TOP_SLOTS];
groupshared int APL_BuildRollingPhase;

void APL_DecodePackedFullFrameSample(int2 pixel, out int binIndex, out int packedContribution, out int maxNits2, out int lumaTopBin, out int channelTopBin, out int valid)
{
    binIndex = 0;
    packedContribution = 0;
    maxNits2 = 0;
    lumaTopBin = -1;
    channelTopBin = -1;
    valid = 0;

    if (pixel.x < 0 || pixel.y < 0 || pixel.x >= BUFFER_WIDTH || pixel.y >= BUFFER_HEIGHT)
        return;

    float3 color = Build_CleanCopy.Load(int3(pixel, 0)).rgb;
    float sceneNits = max(GetLuma709(color) * SIGNAL_REFERENCE_NITS, 0.0);
    float maxChannelNits = max(Max3(Rec709ToRec2020(color)), 0.0) * SIGNAL_REFERENCE_NITS;

    int lumaQ4 = APL_QuantizeNitsQ4(sceneNits);
    int maxQ4 = APL_QuantizeNitsQ4(maxChannelNits);
    int lumaBin = APL_HistogramLumaBin64(lumaQ4);
    binIndex = lumaBin * APL_FFH_COLOR_RATIO_BINS + APL_HistogramColorRatioBin(lumaQ4, maxQ4);

    int offset10 = APL_EncodeWithinBinOffset10(lumaQ4, lumaBin);
    packedContribution = APL_FFH_PACK_ONE_COUNT + offset10;
    maxNits2 = APL_QuantizeMaxNits2(maxChannelNits);
    lumaTopBin = APL_TopBin(lumaQ4);
    channelTopBin = APL_TopBin(maxQ4);
    valid = 1;
}

void APL_AtomicAddMergedTileSample(int binIndex, int packedContribution, int maxNits2, int valid)
{
    if (valid == 0)
        return;
    InterlockedAdd(APL_TilePackedCountLuma[binIndex], packedContribution);
    InterlockedAdd(APL_TileMaxNits[binIndex], maxNits2);
}

void APL_AtomicAddTopSample(int lumaTopBin, int channelTopBin)
{
    if (lumaTopBin >= 0)
        InterlockedAdd(APL_TileTopCount[lumaTopBin], 1);
    if (channelTopBin >= 0)
        InterlockedAdd(APL_TileTopCount[APL_TOP_BINS + channelTopBin], 1);
}

[numthreads(APL_FFH_THREADS_X, APL_FFH_THREADS_Y, 1)]
void CS_Build(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    uint localIndex = threadID.y * APL_FFH_THREADS_X + threadID.x;

    if (localIndex == 0)
    {
        APL_BuildRollingPhase = APL_DecodeStoredRollingPhase(Build_APLPrev.Load(int3(0, 0, 0)).g);
    }

    if (localIndex < APL_FFH_MAX_BINS)
    {
        APL_TilePackedCountLuma[localIndex] = 0;
        APL_TileMaxNits[localIndex] = 0;
        APL_TileTopCount[localIndex] = 0;
    }
    GroupMemoryBarrierWithGroupSync();

    int physicalRow = APL_GetPhysicalRowFromDispatchSlot(int(groupID.y), APL_BuildRollingPhase);
    bool validPhysicalRow = physicalRow < APL_FFH_TILE_COUNT_Y;

    if (validPhysicalRow)
    {
        int2 pixelBase = int2(int(groupID.x) * APL_FFH_TILE_SIZE, physicalRow * APL_FFH_TILE_SIZE) + int2(threadID.xy) * int2(APL_FFH_PIXELS_X, APL_FFH_PIXELS_Y);

        int b0, p0, m0, l0, c0, v0;
        int b1, p1, m1, l1, c1, v1;
        int b2, p2, m2, l2, c2, v2;
        int b3, p3, m3, l3, c3, v3;
        APL_DecodePackedFullFrameSample(pixelBase + int2(0, 0), b0, p0, m0, l0, c0, v0);
        APL_DecodePackedFullFrameSample(pixelBase + int2(1, 0), b1, p1, m1, l1, c1, v1);
        APL_DecodePackedFullFrameSample(pixelBase + int2(0, 1), b2, p2, m2, l2, c2, v2);
        APL_DecodePackedFullFrameSample(pixelBase + int2(1, 1), b3, p3, m3, l3, c3, v3);

        APL_AtomicAddTopSample(l0, c0);
        APL_AtomicAddTopSample(l1, c1);
        APL_AtomicAddTopSample(l2, c2);
        APL_AtomicAddTopSample(l3, c3);

        if (v1 != 0 && v0 != 0 && b1 == b0) { p0 += p1; m0 += m1; v1 = 0; }
        if (v2 != 0 && v0 != 0 && b2 == b0) { p0 += p2; m0 += m2; v2 = 0; }
        if (v2 != 0 && v1 != 0 && b2 == b1) { p1 += p2; m1 += m2; v2 = 0; }
        if (v3 != 0 && v0 != 0 && b3 == b0) { p0 += p3; m0 += m3; v3 = 0; }
        if (v3 != 0 && v1 != 0 && b3 == b1) { p1 += p3; m1 += m3; v3 = 0; }
        if (v3 != 0 && v2 != 0 && b3 == b2) { p2 += p3; m2 += m3; v3 = 0; }

        APL_AtomicAddMergedTileSample(b0, p0, m0, v0);
        APL_AtomicAddMergedTileSample(b1, p1, m1, v1);
        APL_AtomicAddMergedTileSample(b2, p2, m2, v2);
        APL_AtomicAddMergedTileSample(b3, p3, m3, v3);
    }
    GroupMemoryBarrierWithGroupSync();

    if (validPhysicalRow && localIndex < APL_FFH_MAX_BINS)
    {
        int packedValue = APL_TilePackedCountLuma[localIndex];
        int count = packedValue >> APL_FFH_PACK_COUNT_SHIFT;
        if (count > 0)
        {
            int offsetSum10 = packedValue & APL_FFH_PACK_OFFSET_MASK;
            int2 rowCoord = APL_RowHistogramCoord(physicalRow, int(localIndex));
            InterlockedAdd(Build_RowCount[rowCoord], count);
            InterlockedAdd(Build_RowOffset[rowCoord], offsetSum10);
            InterlockedAdd(Build_RowMaxNits[rowCoord], APL_TileMaxNits[localIndex]);
        }

        int topCount = APL_TileTopCount[localIndex];
        if (topCount > 0)
            InterlockedAdd(Build_RowCount[APL_RowTopCoord(physicalRow, int(localIndex))], topCount);
    }

    if (validPhysicalRow && localIndex == 0)
    {
        int tilePixelCount = APL_GetExpectedTilePixelCount(int(groupID.x), physicalRow);
        if (tilePixelCount > 0)
            InterlockedAdd(Build_RowMeta[int2(0, physicalRow)], tilePixelCount);
    }
}


// =====================================================================================
// Pass 3: reduce valid persistent rows into one global histogram.
// SRV  t0 = RowHistCount t1 = RowHistOffset10 t2 = RowHistMaxNits t3 = RowMeta
// UAV  u0 = GlobalHistCount u1 = GlobalHistOffset10 u2 = GlobalHistMaxNits
// =====================================================================================
Texture2D<int>      Reduce_RowCount   : register(t0);
Texture2D<int>      Reduce_RowOffset  : register(t1);
Texture2D<int>      Reduce_RowMaxNits : register(t2);
Texture2D<int>      Reduce_RowMeta    : register(t3);
RWTexture2D<int>    Reduce_GlobalCount   : register(u0);
RWTexture2D<float>  Reduce_GlobalOffset  : register(u1);
RWTexture2D<float>  Reduce_GlobalMaxNits : register(u2);

groupshared int   APL_ReduceCount[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceOffset10[APL_FFH_REDUCE_THREADS];
groupshared float APL_ReduceMaxNits[APL_FFH_REDUCE_THREADS];
groupshared int   APL_ReduceTopCount[APL_FFH_REDUCE_THREADS];

bool APL_IsRowValid(int rowIndex, int expectedSignature)
{
    int rowMeta = Reduce_RowMeta.Load(int3(0, rowIndex, 0));
    int rowCount = rowMeta & APL_FFH_ROW_META_COUNT_MASK;
    int rowSignature = rowMeta >> APL_FFH_ROW_META_COUNT_BITS;
    return (rowCount == APL_GetExpectedRowPixelCount(rowIndex)) && (rowSignature == expectedSignature);
}

#define APL_REDUCE_ROW_STAGE(S) \
    if (localIndex < S) { \
        APL_ReduceCount[localIndex] += APL_ReduceCount[localIndex + S]; \
        APL_ReduceOffset10[localIndex] += APL_ReduceOffset10[localIndex + S]; \
        APL_ReduceMaxNits[localIndex] += APL_ReduceMaxNits[localIndex + S]; \
        APL_ReduceTopCount[localIndex] += APL_ReduceTopCount[localIndex + S]; \
    } \
    GroupMemoryBarrierWithGroupSync();

[numthreads(APL_FFH_REDUCE_THREADS, 1, 1)]
void CS_Reduce(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);
    int2 localBinCoord = int2(groupID.xy);
    int binIndex = localBinCoord.y * APL_FFH_BLOCK_W + localBinCoord.x;
    int expectedSignature = APL_GetRollingHistogramSignature();

    int countSum = 0;
    float offsetSum10 = 0.0;
    float maxSumNits = 0.0;
    int topCountSum = 0;

    [loop]
    for (int rowIndex = localIndex; rowIndex < APL_FFH_TILE_COUNT_Y; rowIndex += APL_FFH_REDUCE_THREADS)
    {
        if (APL_IsRowValid(rowIndex, expectedSignature))
        {
            int2 sourceCoord = APL_RowHistogramCoord(rowIndex, binIndex);
            countSum += Reduce_RowCount.Load(int3(sourceCoord, 0));
            offsetSum10 += float(Reduce_RowOffset.Load(int3(sourceCoord, 0)));
            maxSumNits += float(Reduce_RowMaxNits.Load(int3(sourceCoord, 0)));
            topCountSum += Reduce_RowCount.Load(int3(APL_RowTopCoord(rowIndex, binIndex), 0));
        }
    }

    APL_ReduceCount[localIndex] = countSum;
    APL_ReduceOffset10[localIndex] = offsetSum10;
    APL_ReduceMaxNits[localIndex] = maxSumNits;
    APL_ReduceTopCount[localIndex] = topCountSum;
    GroupMemoryBarrierWithGroupSync();

    APL_REDUCE_ROW_STAGE(32)
    APL_REDUCE_ROW_STAGE(16)
    APL_REDUCE_ROW_STAGE(8)
    APL_REDUCE_ROW_STAGE(4)
    APL_REDUCE_ROW_STAGE(2)
    APL_REDUCE_ROW_STAGE(1)

    if (localIndex == 0)
    {
        Reduce_GlobalCount[localBinCoord] = APL_ReduceCount[0];
        Reduce_GlobalOffset[localBinCoord] = APL_ReduceOffset10[0];
        Reduce_GlobalMaxNits[localBinCoord] = APL_ReduceMaxNits[0];
        Reduce_GlobalCount[APL_GlobalTopCoord(binIndex)] = APL_ReduceTopCount[0];
    }
}

#undef APL_REDUCE_ROW_STAGE


// =====================================================================================
// Pass 4: scene levels, response solve, smoothing, boost curves.
// SRV  t0 = GlobalHistCount t1 = GlobalHistOffset10 t2 = GlobalHistMaxNits t3 = APLPrev
// UAV  u0 = APL u1 = APLInstant u2 = BoostParams
// =====================================================================================
Texture2D<int>      Solve_GlobalCount   : register(t0);
Texture2D<float>    Solve_GlobalOffset  : register(t1);
Texture2D<float>    Solve_GlobalMaxNits : register(t2);
Texture2D<float4>   Solve_APLPrev       : register(t3);
RWTexture2D<float4> Solve_APL         : register(u0);
RWTexture2D<float4> Solve_APLInstant  : register(u1);
RWTexture2D<float4> Solve_BoostParams : register(u2);

groupshared float4 APL_EvalWeightedMetrics[APL_FFH_MAX_BINS];
groupshared float  APL_EvalPixelCount[APL_FFH_MAX_BINS];
groupshared float  APL_EvalBinLight[APL_FFH_MAX_BINS];
groupshared float3 APL_EvalScenePQ;
// Each candidate's curves in the boost-texture layout, five rows per candidate.
groupshared float4 APL_EvalCandidateCurveRows[15];

#define APL_REDUCE_EVAL_STAGE(S) \
    if (localIndex < S) { \
        APL_EvalWeightedMetrics[localIndex] += APL_EvalWeightedMetrics[localIndex + S]; \
        APL_EvalPixelCount[localIndex] += APL_EvalPixelCount[localIndex + S]; \
    } \
    GroupMemoryBarrierWithGroupSync();

// Light-weighted, so small lights in dark scenes still count as highlights.
float APL_FindHighlightPeakNits()
{
    float totalLight = 0.0;
    [loop]
    for (int binIndex = 0; binIndex < APL_FFH_MAX_BINS; ++binIndex)
        totalLight += APL_EvalBinLight[binIndex];

    if (totalLight <= 0.0)
        return 0.0;

    float lightBudget = totalLight * HIGHLIGHT_PEAK_LIGHT_FRACTION;
    float lightAbove = 0.0;

    [loop]
    for (int lumaBin = APL_FFH_LUMA_BINS - 1; lumaBin >= 0; --lumaBin)
    {
        float binLight = 0.0;
        [unroll]
        for (int ratioBin = 0; ratioBin < APL_FFH_COLOR_RATIO_BINS; ++ratioBin)
            binLight += APL_EvalBinLight[lumaBin * APL_FFH_COLOR_RATIO_BINS + ratioBin];

        if (lightAbove + binLight >= lightBudget)
        {
            int lowerQ4 = 0;
            int upperQ4 = 0;
            APL_HistogramLumaBinBoundsQ4(lumaBin, lowerQ4, upperQ4);

            float depthInBin = saturate((lightBudget - lightAbove) / max(binLight, 1e-6));
            float logUpper = log2(float(upperQ4 + 1));
            float logLower = log2(max(float(lowerQ4), 1.0));
            return exp2(lerp(logUpper, logLower, depthInBin)) * 0.25;
        }

        lightAbove += binLight;
    }

    return 0.0;
}

// Log-average level of the SCENE_MAX_PIXELS brightest pixels of one measure (0 = luma, 1 = brightest
// channel), walked down its fine bins.
float APL_FindSceneMaxNits(int measure)
{
    float pixelsLeft = SCENE_MAX_PIXELS;
    float logSumQ4 = 0.0;

    [loop]
    for (int topBin = APL_TOP_BINS - 1; topBin >= 0; --topBin)
    {
        float count = float(Solve_GlobalCount.Load(int3(APL_GlobalTopCoord(measure * APL_TOP_BINS + topBin), 0)));

        if (count > 0.0 && pixelsLeft > 0.0)
        {
            int lowerQ4 = 0;
            int upperQ4 = 0;
            APL_TopBinBoundsQ4(topBin, lowerQ4, upperQ4);

            // The pixels taken are the top of the bin, spread evenly in log luminance.
            float taken = min(count, pixelsLeft);
            float logLower = log2(float(lowerQ4));
            float logUpper = log2(float(upperQ4 + 1));
            logSumQ4 += taken * (logUpper - 0.5 * (taken / count) * (logUpper - logLower));
            pixelsLeft -= taken;
        }
    }

    // Pixels below the fine range count at its floor, so a few bright pixels pull the maximum only
    // part of the way up.
    logSumQ4 += pixelsLeft * float(APL_TOP_MIN_EXPONENT);
    return exp2(logSumQ4 / SCENE_MAX_PIXELS) * 0.25;
}

[numthreads(APL_FFH_MAX_BINS, 1, 1)]
void CS_Solve(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);

    float4 prevData = Solve_APLPrev.Load(int3(0, 0, 0));
    float4 prevMaxima = Solve_APLPrev.Load(int3(1, 0, 0));
    float hasPrev = (prevData.b > 0.0) ? 1.0 : 0.0;

    // The scene levels feed the curves the solve tests, so they take the smoothing time the previous frame set.
    float sceneAlpha = ComputeTemporalBlendFactor(prevMaxima.z, FrameTime);

    float pixelCount = 0.0;
    float sceneNits = 0.0;
    float maxChannelNits = 0.0;

    int2 binCoord = APL_HistogramBlockCoord(localIndex);
    int pixelCountI = Solve_GlobalCount.Load(int3(binCoord, 0));
    if (pixelCountI > 0)
    {
        pixelCount = float(pixelCountI);
        float offsetSum10 = Solve_GlobalOffset.Load(int3(binCoord, 0));
        float meanLumaQ4 = APL_ReconstructMeanLumaQ4(localIndex, pixelCount, offsetSum10);
        sceneNits = max(meanLumaQ4 * 0.25, 0.0);
        float maxSumNits = Solve_GlobalMaxNits.Load(int3(binCoord, 0));
        maxChannelNits = max((maxSumNits / pixelCount) * 2.0, sceneNits);
    }

    APL_EvalBinLight[localIndex] = sceneNits * pixelCount;
    GroupMemoryBarrierWithGroupSync();

    float3 currentScenePQ = (float3)0.0;
    if (localIndex == 0)
    {
        currentScenePQ = float3(
            NitsToPQ(APL_FindHighlightPeakNits()),
            NitsToPQ(APL_FindSceneMaxNits(0)),
            NitsToPQ(APL_FindSceneMaxNits(1)));
        float3 previousScenePQ = saturate(float3(prevData.a, prevMaxima.xy));

        APL_EvalScenePQ = lerp(
            currentScenePQ,
            lerp(previousScenePQ, currentScenePQ, sceneAlpha),
            hasPrev
        );
    }
    GroupMemoryBarrierWithGroupSync();

    float3 scenePQ = APL_EvalScenePQ;
    float gMax = ComputeCandidateMaxLogGain();

    if (localIndex < 3)
    {
        float gain = CandidateGain(localIndex + 1, gMax);
        BoostCurve lumaCurve = MakeLumaBoostCurve(gain, scenePQ);
        BoostCurve channelCurve = MakeChannelBoostCurve(gain, scenePQ);
        int row = localIndex * 5;
        APL_EvalCandidateCurveRows[row] = PackBoostCurveGlobals(lumaCurve);
        APL_EvalCandidateCurveRows[row + 1] = PackBoostCurveKnee(lumaCurve);
        APL_EvalCandidateCurveRows[row + 2] = PackBoostCurveHighlight(lumaCurve);
        APL_EvalCandidateCurveRows[row + 3] = PackBoostCurveKnee(channelCurve);
        APL_EvalCandidateCurveRows[row + 4] = PackBoostCurveHighlight(channelCurve);
    }
    GroupMemoryBarrierWithGroupSync();

    float4 weighted = (float4)0.0;

    if (pixelCount > 0.0)
    {
        float rawMetric = saturate(sceneNits / max(APLReferenceWhiteNits, 1.0));
        float3 candidateMetrics;
        [unroll]
        for (int k = 0; k < 3; ++k)
        {
            int row = k * 5;
            float4 globals = APL_EvalCandidateCurveRows[row];
            BoostCurve lumaCurve = UnpackBoostCurve(globals, APL_EvalCandidateCurveRows[row + 1], APL_EvalCandidateCurveRows[row + 2]);
            BoostCurve channelCurve = UnpackBoostCurve(globals, APL_EvalCandidateCurveRows[row + 3], APL_EvalCandidateCurveRows[row + 4]);
            candidateMetrics[k] = ComputePostBoostMetricForSample(sceneNits, maxChannelNits, lumaCurve, channelCurve);
        }
        weighted = float4(rawMetric, candidateMetrics) * pixelCount;
    }

    APL_EvalWeightedMetrics[localIndex] = weighted;
    APL_EvalPixelCount[localIndex] = pixelCount;
    GroupMemoryBarrierWithGroupSync();

    APL_REDUCE_EVAL_STAGE(128)
    APL_REDUCE_EVAL_STAGE(64)
    APL_REDUCE_EVAL_STAGE(32)
    APL_REDUCE_EVAL_STAGE(16)
    APL_REDUCE_EVAL_STAGE(8)
    APL_REDUCE_EVAL_STAGE(4)
    APL_REDUCE_EVAL_STAGE(2)
    APL_REDUCE_EVAL_STAGE(1)

    if (localIndex == 0)
    {
        float rawAPL = 0.0;
        float3 responseNodes = (float3)0.0;
        float totalPixelCount = APL_EvalPixelCount[0];

        if (totalPixelCount > 0.0)
        {
            // Black bars add zero light but count as panel area.
            float panelPixelCount = totalPixelCount / clamp(LitFraction, 0.01, 1.0);
            float4 averages = APL_EvalWeightedMetrics[0] / panelPixelCount;
            rawAPL = saturate(averages.r);
            responseNodes = saturate(averages.gba);
        }

        int currentRollingPhase = APL_DecodeStoredRollingPhase(prevData.g);
        int nextRollingPhase = APL_GetNextRollingPhase(currentRollingPhase);

        float currentDisplayAPL = SolveClosedLoopDisplayAPLFromResponseNodes(rawAPL, responseNodes, gMax);
        float smoothingTime = (hasPrev > 0.0)
            ? ComputeSmoothingTime(prevMaxima.z, currentDisplayAPL, saturate(prevData.r), FrameTime)
            : TransitionSpeed;
        float smoothedAPL = lerp(
            currentDisplayAPL,
            lerp(saturate(prevData.r), currentDisplayAPL, ComputeTemporalBlendFactor(smoothingTime, FrameTime)),
            hasPrev
        );

        float sceneLogGain = ComputeSceneLogGainFromAPL(smoothedAPL);

        Solve_APLInstant[int2(0, 0)] = float4(rawAPL, currentDisplayAPL, float(nextRollingPhase), currentScenePQ.x);
        Solve_APLInstant[int2(1, 0)] = float4(currentScenePQ.yz, 0.0, 0.0);
        Solve_APL[int2(0, 0)] = float4(smoothedAPL, scenePQ.x, 1.0, sceneLogGain);
        Solve_APL[int2(1, 0)] = float4(scenePQ.yz, smoothingTime, 0.0);

        float sceneGain = SceneGainFromLogGain(sceneLogGain);
        BoostCurve lumaCurve = MakeLumaBoostCurve(sceneGain, scenePQ);
        BoostCurve channelCurve = MakeChannelBoostCurve(sceneGain, scenePQ);
        Solve_BoostParams[int2(0, 0)] = PackBoostCurveGlobals(lumaCurve);
        Solve_BoostParams[int2(0, 1)] = PackBoostCurveKnee(lumaCurve);
        Solve_BoostParams[int2(0, 2)] = PackBoostCurveHighlight(lumaCurve);
        Solve_BoostParams[int2(0, 3)] = PackBoostCurveKnee(channelCurve);
        Solve_BoostParams[int2(0, 4)] = PackBoostCurveHighlight(channelCurve);
    }
}

#undef APL_REDUCE_EVAL_STAGE


// =====================================================================================
// Pass 5: fullscreen boost. Clean copy -> back buffer.
// SRV  t0 = CleanCopy t1 = APL (smoothed) t2 = BoostParams
// =====================================================================================
Texture2D<float4> Boost_CleanCopy   : register(t0);
Texture2D<float4> Boost_APL         : register(t1);
Texture2D<float4> Boost_BoostParams : register(t2);
SamplerState      Boost_PointSamp   : register(s0);

struct VSOut
{
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
};

VSOut VS_Boost(uint id : SV_VertexID)
{
    VSOut o;
    o.uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(o.uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    return o;
}

float4 PS_Boost(VSOut i) : SV_Target
{
    int2 pixel = int2(i.pos.xy);
    float3 color = Boost_CleanCopy.Load(int3(pixel, 0)).rgb;

    float4 aplData = Boost_APL.Load(int3(0, 0, 0));
    if (aplData.a > 1e-6)
    {
        float4 globals = Boost_BoostParams.Load(int3(0, 0, 0));
        BoostCurve lumaCurve = UnpackBoostCurve(globals, Boost_BoostParams.Load(int3(0, 1, 0)), Boost_BoostParams.Load(int3(0, 2, 0)));
        BoostCurve channelCurve = UnpackBoostCurve(globals, Boost_BoostParams.Load(int3(0, 3, 0)), Boost_BoostParams.Load(int3(0, 4, 0)));
        color = ApplyBoostFromPrecomputedParams(color, lumaCurve, channelCurve);
    }

    return float4(color, 1.0);
}
