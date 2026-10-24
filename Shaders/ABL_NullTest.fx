/*
    ABL Null Test

    Replaces the frame with a pattern for checking the ABL compensation by eye.
    A 60 nit gray reference patch sits in the middle of a wide black gap, and
    the rest of the screen switches between two loads every 720 frames, 3
    seconds at 240 fps, with a small dim mark under the patch while state B is
    on. The patch holds still when the panel dims both loads the same, or when
    the boost cancels the change exactly. The frame rate has to stay at or
    under the refresh rate, as with G-Sync and a frame cap, so each frame is
    one refresh.

    Model checks run with the boost off. Both states carry the same load, 5%
    APL, so a pulse means the panel weighs that content differently. The color
    checks show the panel's own primaries from its EDID and a pastel red
    halfway between its red and white, each at the level the boost's load
    model says loads the panel like the gray.

    The panel latency check also runs with the boost off. The rest of the
    screen switches between 3% and 10% APL, and a black band across the middle
    holds a row of patches. Each patch is brightened by the measured
    compensation for the load of a frame further back, from the left the
    current frame, then 1, 2, 3 and 4 frames earlier. The panel dims every
    patch alike, so the patch whose delay matches the frames the panel's
    dimming lags behind holds still through both switches, while every other
    patch blinks for as many frames as its delay is off.

    Curve checks run with the boost on. Each state's raw load is the one the
    boost settles on the named out APL for. The patch sits below the shoulder
    at every gain, so it gets the full gain, and a check holds still when the
    boost cancels the panel's dimming at both loads and through each switch.

    The bright window check also runs with the boost on, with a 150 nit patch.
    Both states carry the same raw load, 8% APL. In state B half of that light
    gathers into a 900 nit window left of the gap, as when a bright highlight
    comes into view. The patch holds still when the highlight leaves the lower
    levels alone. The curve lands the window on the panel peak, so state B
    shows about 14% out APL against about 21% in state A, and the 10% vs 25%
    curve check has to hold first.

    The shadow check runs with the boost on, with a 1 nit patch over the loads
    of out APL 3% and 50%. The boost lifts dark levels by the same gain as the
    rest, so the patch holds still when the panel dims near-black as much as
    brighter levels.

    The low end check runs with the boost off over 1% and 3% APL. The measured
    table starts at 3% and treats lower loads as undimmed, so the patch holds
    still when the panel does not dim between them.

    Goes above the boost in the effect list. Writes scRGB when ReShade reports
    an scRGB back buffer and PQ otherwise, as the boost's automatic input does.
*/

#include "ReShade.fxh"

#ifndef BUFFER_COLOR_SPACE
    #define BUFFER_COLOR_SPACE 0
#endif


uniform int Test <
    ui_type = "combo";
    ui_items = "Gray vs white window (boost off)\0Gray vs red (boost off)\0Gray vs green (boost off)\0Gray vs blue (boost off)\0Gray vs pastel red (boost off)\0Panel latency (boost off)\0Out APL 3% vs 6% (boost on)\0Out APL 6% vs 10% (boost on)\0Out APL 8% vs 12% (boost on)\0Out APL 10% vs 25% (boost on)\0Out APL 25% vs 50% (boost on)\0Out APL 50% vs 80% (boost on)\0Bright window, 150 nit patch (boost on)\0Shadow, 1 nit patch, out APL 3% vs 50% (boost on)\0Low end, APL 1% vs 3% (boost off)\0";
    ui_label = "Test";
> = 0;

uniform int FrameCount < source = "framecount"; >;


static const float REFERENCE_PATCH_NITS = 60.0;
static const float REFERENCE_WHITE_NITS = 1060.0;   // the boost's APL reference white
static const float SCRGB_REFERENCE_NITS = 80.0;
static const float MARKER_NITS          = 10.0;
static const float PATCH_HALF_HEIGHT    = 0.07;     // fractions of the screen height
static const float GAP_HALF_HEIGHT      = 0.24;
static const float MARKER_HALF_HEIGHT   = 0.006;
static const int   FRAMES_PER_STATE     = 720;

static const int   MODEL_CHECK_COUNT = 5;
static const int   PASTEL_CHECK      = 4;
static const float MODEL_CHECK_APL   = 0.05;
static const int   LATENCY_CHECK     = 5;
static const int   FIRST_CURVE_CHECK = 6;
static const int   BRIGHT_WINDOW_CHECK = 12;
static const int   SHADOW_CHECK      = 13;
static const int   LOW_END_CHECK     = 14;

static const float BRIGHT_CHECK_APL   = 0.08;
static const float BRIGHT_PATCH_NITS  = 150.0;
static const float BRIGHT_WINDOW_NITS = 900.0;

static const float  SHADOW_PATCH_NITS     = 1.0;
static const float2 LOW_END_CHECK_RAW_APL = float2(0.01, 0.03);

// The boost's load model, a pure panel primary loading the panel this share of white at the same channel level.
static const float SINGLE_PRIMARY_LOAD = 0.75;

static const float2 LATENCY_CHECK_RAW_APL     = float2(0.03, 0.10);
static const float  LATENCY_PATCH_HALF_HEIGHT = 0.035;
static const int    LATENCY_PATCH_COUNT       = 5;

// The boost's measured compensation from 3% to 10% APL, as log2 APL in percent and log2 gain.
static const int    COMP_ANCHOR_COUNT = 8;
static const float2 COMP_ANCHORS[COMP_ANCHOR_COUNT] =
{
    float2(1.584963, 0.000000),
    float2(2.000000, 0.198724),
    float2(2.321928, 0.384513),
    float2(2.584963, 0.559800),
    float2(2.807355, 0.720276),
    float2(3.000000, 0.860765),
    float2(3.169925, 0.988072),
    float2(3.321928, 1.104405)
};

// Raw APL of each curve check's two states, which the boost settles on out APL 3/6, 6/10, 8/12, 10/25, 25/50
// and 50/80%. Every fill sits below the ceiling, so each is the out APL over its compensation.
static const float2 CURVE_CHECK_RAW_APL[6] =
{
    float2(0.0300000, 0.0407038),
    float2(0.0407038, 0.0465094),
    float2(0.0440528, 0.0531849),
    float2(0.0465094, 0.0919340),
    float2(0.0919340, 0.1550000),
    float2(0.1550000, 0.2226900)
};


// The panel's own primaries from its EDID, with D65 white, as the boost counts the load.
float3 PanelToRec2020(float3 rgb)
{
    return float3(
        dot(rgb, float3(0.8270154, 0.1424982, 0.0304865)),
        dot(rgb, float3(0.0264286, 0.9605869, 0.0129845)),
        dot(rgb, float3(0.0071549, 0.0182835, 0.9745616))
    );
}

float3 PanelToRec709(float3 rgb)
{
    return float3(
        dot(rgb, float3( 1.3571998, -0.3291954, -0.0280044)),
        dot(rgb, float3(-0.0731239,  1.0703479,  0.0027760)),
        dot(rgb, float3(-0.0096648, -0.0787469,  1.0884117))
    );
}

float3 NitsToPQ(float3 nits)
{
    float3 Lm1 = pow(saturate(nits / 10000.0), 0.1593017578125);
    return pow((0.8359375 + 18.8515625 * Lm1) / (1.0 + 18.6875 * Lm1), 78.84375);
}

float3 EncodePanelNits(float3 nits)
{
#if BUFFER_COLOR_SPACE == 2
    return PanelToRec709(nits) / SCRGB_REFERENCE_NITS;
#else
    return NitsToPQ(PanelToRec2020(nits));
#endif
}

float Max3(float3 v)
{
    return max(v.x, max(v.y, v.z));
}

// Load of a panel-space color as a share of white's at the same brightest channel level.
float ModelLoad(float3 color)
{
    float brightestShare = (3.0 * SINGLE_PRIMARY_LOAD - 1.0) * 0.5;
    return lerp(dot(color, 1.0 / 3.0), Max3(color), brightestShare) / Max3(color);
}

float LookupLogComp(float apl)
{
    float logAPL = clamp(log2(apl * 100.0), COMP_ANCHORS[0].x, COMP_ANCHORS[COMP_ANCHOR_COUNT - 1].x);
    float logComp = 0.0;

    [unroll]
    for (int i = 0; i < COMP_ANCHOR_COUNT - 1; ++i)
    {
        float2 p0 = COMP_ANCHORS[i];
        float2 p1 = COMP_ANCHORS[i + 1];

        if (logAPL >= p0.x)
            logComp = lerp(p0.y, p1.y, saturate((logAPL - p0.x) / (p1.x - p0.x)));
    }

    return logComp;
}

bool IsStateB(int frame)
{
    return ((max(frame, 0) / FRAMES_PER_STATE) & 1) != 0;
}


int HalfSidePixels(float halfHeight)
{
    return int(round(halfHeight * BUFFER_HEIGHT));
}

bool InsideSquare(int2 pixel, int2 center, int halfSide)
{
    int2 offset = pixel - center;
    return all(offset >= -halfSide) && all(offset < halfSide);
}

float SquareLight(float nits, int halfSide)
{
    return nits * 4.0 * halfSide * halfSide;
}

float ScreenLight(float rawAPL)
{
    return rawAPL * REFERENCE_WHITE_NITS * BUFFER_WIDTH * BUFFER_HEIGHT;
}

float PatchNits()
{
    if (Test == BRIGHT_WINDOW_CHECK)
        return BRIGHT_PATCH_NITS;

    return (Test == SHADOW_CHECK) ? SHADOW_PATCH_NITS : REFERENCE_PATCH_NITS;
}

// Light the load area carries for a raw APL, with the patch's share taken out.
float LoadLight(float rawAPL)
{
    return ScreenLight(rawAPL) - SquareLight(PatchNits(), HalfSidePixels(PATCH_HALF_HEIGHT));
}

float LoadPixels()
{
    float gapSide = 2.0 * HalfSidePixels(GAP_HALF_HEIGHT);
    return BUFFER_WIDTH * BUFFER_HEIGHT - gapSide * gapSide;
}

float FillNits(float rawAPL)
{
    return LoadLight(rawAPL) / LoadPixels();
}

// The model check's light gathered into one square near reference white, left of the gap, against a gray
// fill of the same light.
float3 WindowCheckNits(int2 pixel, bool stateB)
{
    float light = LoadLight(MODEL_CHECK_APL);
    int halfSide = int(round(0.5 * sqrt(light / REFERENCE_WHITE_NITS)));
    float windowNits = light / (4.0 * halfSide * halfSide);

    bool inWindow = InsideSquare(pixel, int2(BUFFER_WIDTH / 5, BUFFER_HEIGHT / 2), halfSide);
    return stateB ? (inWindow ? windowNits.xxx : 0.0.xxx) : FillNits(MODEL_CHECK_APL).xxx;
}

// Each color loads the panel like the gray when the boost's load model is right.
float3 ColorCheckNits(bool stateB)
{
    float grayNits = FillNits(MODEL_CHECK_APL);
    bool pastel = Test == PASTEL_CHECK;
    float3 color = pastel ? float3(1.0, 0.5, 0.5) : float3(Test == 1 ? 1.0 : 0.0, Test == 2 ? 1.0 : 0.0, Test == 3 ? 1.0 : 0.0);
    return stateB ? color * (grayNits / ModelLoad(color)) : grayNits.xxx;
}

// Raw APL of the two states of a check that fills the load area with gray.
float2 FillCheckRawAPL()
{
    float2 rawAPL = LOW_END_CHECK_RAW_APL;

    if (Test == SHADOW_CHECK)
        rawAPL = float2(CURVE_CHECK_RAW_APL[0].x, CURVE_CHECK_RAW_APL[4].y);
    else if (Test < BRIGHT_WINDOW_CHECK)
        rawAPL = CURVE_CHECK_RAW_APL[Test - FIRST_CURVE_CHECK];

    return rawAPL;
}

float3 FillCheckNits(bool stateB)
{
    float2 rawAPL = FillCheckRawAPL();
    return FillNits(stateB ? rawAPL.y : rawAPL.x).xxx;
}

// Half the load's light gathered into one bright square left of the gap, with the rest spread over the fill.
float3 BrightWindowCheckNits(int2 pixel, bool stateB)
{
    float light = LoadLight(BRIGHT_CHECK_APL);
    int halfSide = int(round(0.5 * sqrt(0.5 * light / BRIGHT_WINDOW_NITS)));
    float windowPixels = 4.0 * halfSide * halfSide;
    bool inWindow = InsideSquare(pixel, int2(BUFFER_WIDTH / 5, BUFFER_HEIGHT / 2), halfSide);

    float nits = FillNits(BRIGHT_CHECK_APL);
    if (stateB)
        nits = inWindow ? BRIGHT_WINDOW_NITS : (light - BRIGHT_WINDOW_NITS * windowPixels) / (LoadPixels() - windowPixels);

    return nits.xxx;
}

float3 PatchCheckNits(int2 pixel, bool stateB)
{
    int2 center = int2(BUFFER_WIDTH, BUFFER_HEIGHT) / 2;
    int patchHalf = HalfSidePixels(PATCH_HALF_HEIGHT);
    int gapHalf = HalfSidePixels(GAP_HALF_HEIGHT);
    int2 markerCenter = center + int2(0, (patchHalf + gapHalf) / 2);

    float3 nits = 0.0.xxx;
    if (InsideSquare(pixel, center, patchHalf))
        nits = PatchNits().xxx;
    else if (stateB && InsideSquare(pixel, markerCenter, HalfSidePixels(MARKER_HALF_HEIGHT)))
        nits = MARKER_NITS.xxx;
    else if (InsideSquare(pixel, center, gapHalf))
        nits = 0.0.xxx;
    else if (Test == 0)
        nits = WindowCheckNits(pixel, stateB);
    else if (Test < MODEL_CHECK_COUNT)
        nits = ColorCheckNits(stateB);
    else if (Test == BRIGHT_WINDOW_CHECK)
        nits = BrightWindowCheckNits(pixel, stateB);
    else
        nits = FillCheckNits(stateB);

    return nits;
}

float3 LatencyCheckNits(int2 pixel)
{
    bool stateB = IsStateB(FrameCount);
    int2 center = int2(BUFFER_WIDTH, BUFFER_HEIGHT) / 2;
    int patchHalf = HalfSidePixels(LATENCY_PATCH_HALF_HEIGHT);
    int bandHalf = HalfSidePixels(GAP_HALF_HEIGHT);
    int2 markerCenter = center + int2(0, (patchHalf + bandHalf) / 2);

    float patchLight = 0.0;
    float patchNits = -1.0;

    [unroll]
    for (int framesBack = 0; framesBack < LATENCY_PATCH_COUNT; ++framesBack)
    {
        float2 rawAPL = LATENCY_CHECK_RAW_APL;
        float levelNits = REFERENCE_PATCH_NITS * exp2(LookupLogComp(IsStateB(FrameCount - framesBack) ? rawAPL.y : rawAPL.x));
        int2 patchCenter = int2((framesBack + 1) * BUFFER_WIDTH / (LATENCY_PATCH_COUNT + 1), center.y);
        patchLight += SquareLight(levelNits, patchHalf);

        if (InsideSquare(pixel, patchCenter, patchHalf))
            patchNits = levelNits;
    }

    float rawAPL = stateB ? LATENCY_CHECK_RAW_APL.y : LATENCY_CHECK_RAW_APL.x;
    float fillPixels = BUFFER_WIDTH * (BUFFER_HEIGHT - 2.0 * bandHalf);
    int bandOffset = pixel.y - center.y;

    float nits = (ScreenLight(rawAPL) - patchLight) / fillPixels;
    if (patchNits >= 0.0)
        nits = patchNits;
    else if (stateB && InsideSquare(pixel, markerCenter, HalfSidePixels(MARKER_HALF_HEIGHT)))
        nits = MARKER_NITS;
    else if (bandOffset >= -bandHalf && bandOffset < bandHalf)
        nits = 0.0;

    return nits.xxx;
}


float4 PS_NullTest(float4 position : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    int2 pixel = int2(position.xy);
    float3 nits = (Test == LATENCY_CHECK) ? LatencyCheckNits(pixel) : PatchCheckNits(pixel, IsStateB(FrameCount));
    return float4(EncodePanelNits(nits), 1.0);
}


technique ABL_NullTest <
    ui_tooltip = "Replaces the frame with an ABL test pattern. Goes above the boost in the effect list.";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_NullTest;
    }
}
