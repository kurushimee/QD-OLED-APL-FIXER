/*
    ABL Null Test

    Replaces the frame with a pattern for checking EOTF Boost 3.1's compensation
    by eye. A grid of nine gray patches sits in the middle of a wide black gap,
    and the rest of the screen switches between two loads once a second. The
    middle patch keeps its level in both states. In state B the others change by
    2% steps in reading order, from four steps dimmer at the top left to four
    steps brighter at the bottom right, starting one frame after the switch. The
    panel dims every patch alike, so the one that holds still reads off how much
    more the panel dims state B than the panel model expects, and the middle one
    holds still when the model is right. The frame rate has to stay at or under
    the refresh rate, as with G-Sync and a frame cap, so each frame is one
    refresh.

    Loads follow the panel model in PanelModel_27M2N6500.fxh: the frame mean of
    each pixel's brightest channel in linear BT.2020, over the load peak.

    Model checks run with the boost off. Both states carry the same load, 5%, so
    a still patch other than the middle one means the panel weighs that content
    differently. The window check gathers the load into one square at the panel
    peak. The color checks show BT.2020's primaries and a pastel red halfway
    between its red and white, each with its brightest channel at the gray's
    level, which loads the panel like the gray under the model.

    The panel latency check also runs with the boost off. The rest of the
    screen switches between 3% and 10% load, and a black band across the middle
    holds a row of patches. Each patch is brightened by the model's compensation
    for the load of a frame further back, from the left the current frame, then
    1, 2, 3 and 4 frames earlier. The panel dims every patch alike, so the patch
    whose delay matches the frames the panel's dimming lags behind holds still
    through both switches, while every other patch blinks for as many frames as
    its delay is off.

    Curve checks run with the boost on. Each state's raw load is the one the
    boost settles on the named out load for, the out load over its compensation,
    since every fill sits under the ceiling. The patches get the full gain, and
    the still patch reads off how far the compensation at state B's load is off
    from state A's. The boost eases its gain over its smoothing period after
    each switch, so the patches settle a moment after the fill does. The
    fill's 10-bit code moves the raw load slightly, and just under the model's
    knee the boost turns that into a few percent of out load, so the out loads
    are approximate. The check reads true either way, since the boost follows
    the load it sees.

    The bright window check also runs with the boost on, with 150 nit patches.
    Both states carry the same raw load, 8%. In state B half of that light
    gathers into a 900 nit window left of the gap, as when a bright highlight
    comes into view, and the shoulder rolls the window off under the ceiling.
    Its twin runs the same pattern with the boost off, where both states load
    the panel the same under the model, so it tells a window that loads the
    panel more than its light apart from a curve error between the two out
    loads.

    The shadow check runs with the boost on, with 1 nit patches over the out
    loads 3% and 50%. The boost lifts dark levels by the same gain as the rest,
    so the middle patch holds still when the panel dims near-black as much as
    brighter levels.

    The low end check runs with the boost off over 1% and 3% load. The model is
    flat up to PANEL_COMP_FLAT_END, about 3.2%, so the middle patch holds still
    when the panel doesn't dim between them.

    Goes above the boost in the effect list. Writes scRGB when ReShade reports
    an scRGB back buffer and PQ otherwise, as the boost's input does.
*/

#include "ReShade.fxh"
#include "PanelModel_27M2N6500.fxh"

#ifndef BUFFER_COLOR_SPACE
    #define BUFFER_COLOR_SPACE 0
#endif


uniform int Test <
    ui_type = "combo";
    ui_items = "Gray vs window at the peak (boost off)\0Gray vs red (boost off)\0Gray vs green (boost off)\0Gray vs blue (boost off)\0Gray vs pastel red (boost off)\0Panel latency (boost off)\0Out load 3% vs 6% (boost on)\0Out load 6% vs 10% (boost on)\0Out load 8% vs 12% (boost on)\0Out load 10% vs 25% (boost on)\0Out load 25% vs 50% (boost on)\0Out load 50% vs 80% (boost on)\0Bright window, 150 nit patches (boost on)\0Bright window, 150 nit patches (boost off)\0Shadow, 1 nit patches, out load 3% vs 50% (boost on)\0Low end, load 1% vs 3% (boost off)\0";
    ui_label = "Test";
> = 0;

uniform int FrameCount < source = "framecount"; >;
uniform float Timer < source = "timer"; >;


static const float REFERENCE_PATCH_NITS = 60.0;
static const float SCRGB_REFERENCE_NITS = 80.0;
static const float PATCH_HALF_HEIGHT    = 0.035;    // fractions of the screen height
static const float GAP_HALF_HEIGHT      = 0.24;
static const float STATE_MS             = 1000.0;

// Brightness step between neighbouring grid patches, about the smallest change the eye catches at a switch.
static const float GRID_STEP    = 1.02;
static const int   GRID_SIDE    = 3;
static const int   GRID_PATCHES = GRID_SIDE * GRID_SIDE;

static const int   MODEL_CHECK_COUNT   = 5;
static const int   PASTEL_CHECK        = 4;
static const float MODEL_CHECK_LOAD    = 0.05;
static const int   LATENCY_CHECK       = 5;
static const int   FIRST_CURVE_CHECK   = 6;
static const int   BRIGHT_WINDOW_CHECK = 12;
static const int   BRIGHT_LOAD_CHECK   = 13;    // the bright window pattern with the boost off
static const int   SHADOW_CHECK        = 14;
static const int   LOW_END_CHECK       = 15;

static const float BRIGHT_CHECK_LOAD  = 0.08;
static const float BRIGHT_PATCH_NITS  = 150.0;
static const float BRIGHT_WINDOW_NITS = 900.0;

static const float  SHADOW_PATCH_NITS      = 1.0;
static const float2 LOW_END_CHECK_RAW_LOAD = float2(0.01, 0.03);

static const float2 LATENCY_CHECK_RAW_LOAD = float2(0.03, 0.10);
static const int    LATENCY_PATCH_COUNT    = 5;

// Out loads of each curve check's two states.
static const float2 CURVE_CHECK_OUT_LOAD[6] =
{
    float2(0.03, 0.06),
    float2(0.06, 0.10),
    float2(0.08, 0.12),
    float2(0.10, 0.25),
    float2(0.25, 0.50),
    float2(0.50, 0.80)
};

static const float3x3 REC2020_TO_REC709 = float3x3(
     1.660490296, -0.587639106, -0.072851598,
    -0.124549970,  1.132899922, -0.008347964,
    -0.018151119, -0.100578724,  1.118729878);


// The frame of the last switch times two, plus the state it switched to, so the states of the frames before it are
// known too.
texture TexSwitch
{
    Width = 1;
    Height = 1;
    Format = R32I;
};
sampler2D<int> SamplerSwitch
{
    Texture = TexSwitch;
    MinFilter = POINT;
    MagFilter = POINT;
    MipFilter = POINT;
};
storage2D<int> StorageSwitch
{
    Texture = TexSwitch;
};


float3 NitsToPQ(float3 nits)
{
    float3 Lm1 = pow(saturate(nits / 10000.0), 0.1593017578125);
    return pow((0.8359375 + 18.8515625 * Lm1) / (1.0 + 18.6875 * Lm1), 78.84375);
}

float3 EncodeRec2020Nits(float3 nits)
{
#if BUFFER_COLOR_SPACE == 2
    return mul(REC2020_TO_REC709, nits) / SCRGB_REFERENCE_NITS;
#else
    return NitsToPQ(nits);
#endif
}

// The raw load the boost settles on an out load for, when everything on screen sits under the ceiling.
float RawLoadForOutLoad(float outLoad)
{
    return outLoad / PanelCompensation(100.0 * outLoad);
}


[shader("compute")]
void CS_RecordSwitch()
{
    int state = int(Timer / STATE_MS) & 1;

    if ((tex2Dfetch(StorageSwitch, int2(0, 0)) & 1) != state)
        tex2Dstore(StorageSwitch, int2(0, 0), FrameCount * 2 + state);
}

// Right for every frame since the switch before the last one, which a one second state covers.
bool IsStateB(int frame)
{
    int record = tex2Dfetch(SamplerSwitch, int2(0, 0));
    bool stateB = (record & 1) != 0;
    return (frame >= record / 2) ? stateB : !stateB;
}


int HalfSidePixels(float halfHeight)
{
    return int(round(halfHeight * BUFFER_HEIGHT));
}

int PatchHalfSide()
{
    return HalfSidePixels(PATCH_HALF_HEIGHT);
}

bool InsideSquare(int2 pixel, int2 center, int halfSide)
{
    int2 offset = pixel - center;
    return all(offset >= -halfSide) && all(offset < halfSide);
}

// Load light of a gray square, its brightest channel times its pixels.
float SquareLight(float nits, int halfSide)
{
    return nits * 4.0 * halfSide * halfSide;
}

float ScreenLight(float rawLoad)
{
    return rawLoad * PANEL_LOAD_PEAK_NITS * BUFFER_WIDTH * BUFFER_HEIGHT;
}

bool IsBrightWindowTest()
{
    return Test == BRIGHT_WINDOW_CHECK || Test == BRIGHT_LOAD_CHECK;
}

float PatchNits()
{
    if (IsBrightWindowTest())
        return BRIGHT_PATCH_NITS;

    return (Test == SHADOW_CHECK) ? SHADOW_PATCH_NITS : REFERENCE_PATCH_NITS;
}

// The panel dims a frame for the load of the frame before it, so the patches change a frame after the load does.
bool GridInStateB()
{
    return IsStateB(FrameCount - 1);
}

// GRID_STEP per patch in reading order, away from the middle patch.
float GridFactor(int patch, bool stateB)
{
    return stateB ? pow(GRID_STEP, patch - GRID_PATCHES / 2) : 1.0;
}

int2 GridPatchCenter(int patch)
{
    int2 cell = int2(patch % GRID_SIDE, patch / GRID_SIDE) - GRID_SIDE / 2;
    return int2(BUFFER_WIDTH, BUFFER_HEIGHT) / 2 + cell * 3 * PatchHalfSide();
}

float GridLight()
{
    bool stateB = GridInStateB();
    float light = 0.0;

    [unroll]
    for (int patch = 0; patch < GRID_PATCHES; ++patch)
        light += SquareLight(PatchNits() * GridFactor(patch, stateB), PatchHalfSide());

    return light;
}

float3 GridNits(int2 pixel)
{
    bool stateB = GridInStateB();
    float nits = 0.0;

    [unroll]
    for (int patch = 0; patch < GRID_PATCHES; ++patch)
    {
        if (InsideSquare(pixel, GridPatchCenter(patch), PatchHalfSide()))
            nits = PatchNits() * GridFactor(patch, stateB);
    }

    return nits.xxx;
}

// Light the load area carries for a raw load, with the grid's share taken out.
float LoadLight(float rawLoad)
{
    return ScreenLight(rawLoad) - GridLight();
}

float LoadPixels()
{
    float gapSide = 2.0 * HalfSidePixels(GAP_HALF_HEIGHT);
    return BUFFER_WIDTH * BUFFER_HEIGHT - gapSide * gapSide;
}

float FillNits(float rawLoad)
{
    return LoadLight(rawLoad) / LoadPixels();
}

// The model check's light gathered into one square at the panel peak, left of the gap, against a gray fill of the
// same light.
float3 WindowCheckNits(int2 pixel, bool stateB)
{
    float light = LoadLight(MODEL_CHECK_LOAD);
    int halfSide = int(round(0.5 * sqrt(light / PANEL_SIGNAL_PEAK_NITS)));
    float windowNits = light / (4.0 * halfSide * halfSide);

    bool inWindow = InsideSquare(pixel, int2(BUFFER_WIDTH / 5, BUFFER_HEIGHT / 2), halfSide);
    return stateB ? (inWindow ? windowNits.xxx : 0.0.xxx) : FillNits(MODEL_CHECK_LOAD).xxx;
}

// Each color's brightest channel sits at the gray's level, so it loads the panel like the gray when the model is right.
float3 ColorCheckNits(bool stateB)
{
    float grayNits = FillNits(MODEL_CHECK_LOAD);
    bool pastel = Test == PASTEL_CHECK;
    float3 color = pastel ? float3(1.0, 0.5, 0.5) : float3(Test == 1 ? 1.0 : 0.0, Test == 2 ? 1.0 : 0.0, Test == 3 ? 1.0 : 0.0);
    return stateB ? color * grayNits : grayNits.xxx;
}

// Raw loads of the two states of a check that fills the load area with gray.
float2 FillCheckRawLoad()
{
    if (Test == LOW_END_CHECK)
        return LOW_END_CHECK_RAW_LOAD;

    float2 outLoad = (Test == SHADOW_CHECK)
        ? float2(CURVE_CHECK_OUT_LOAD[0].x, CURVE_CHECK_OUT_LOAD[4].y)
        : CURVE_CHECK_OUT_LOAD[clamp(Test - FIRST_CURVE_CHECK, 0, 5)];

    return float2(RawLoadForOutLoad(outLoad.x), RawLoadForOutLoad(outLoad.y));
}

float3 FillCheckNits(bool stateB)
{
    float2 rawLoad = FillCheckRawLoad();
    return FillNits(stateB ? rawLoad.y : rawLoad.x).xxx;
}

// Half the load's light gathered into one bright square left of the gap, with the rest spread over the fill.
float3 BrightWindowCheckNits(int2 pixel, bool stateB)
{
    float light = LoadLight(BRIGHT_CHECK_LOAD);
    int halfSide = int(round(0.5 * sqrt(0.5 * light / BRIGHT_WINDOW_NITS)));
    float windowPixels = 4.0 * halfSide * halfSide;
    bool inWindow = InsideSquare(pixel, int2(BUFFER_WIDTH / 5, BUFFER_HEIGHT / 2), halfSide);

    float nits = FillNits(BRIGHT_CHECK_LOAD);
    if (stateB)
        nits = inWindow ? BRIGHT_WINDOW_NITS : (light - BRIGHT_WINDOW_NITS * windowPixels) / (LoadPixels() - windowPixels);

    return nits.xxx;
}

float3 PatchCheckNits(int2 pixel, bool stateB)
{
    float3 nits = 0.0.xxx;

    if (InsideSquare(pixel, int2(BUFFER_WIDTH, BUFFER_HEIGHT) / 2, HalfSidePixels(GAP_HALF_HEIGHT)))
        nits = GridNits(pixel);
    else if (Test == 0)
        nits = WindowCheckNits(pixel, stateB);
    else if (Test < MODEL_CHECK_COUNT)
        nits = ColorCheckNits(stateB);
    else if (IsBrightWindowTest())
        nits = BrightWindowCheckNits(pixel, stateB);
    else
        nits = FillCheckNits(stateB);

    return nits;
}

float3 LatencyCheckNits(int2 pixel)
{
    bool stateB = IsStateB(FrameCount);
    int2 center = int2(BUFFER_WIDTH, BUFFER_HEIGHT) / 2;
    int patchHalf = PatchHalfSide();
    int bandHalf = HalfSidePixels(GAP_HALF_HEIGHT);

    float patchLight = 0.0;
    float patchNits = -1.0;

    [unroll]
    for (int framesBack = 0; framesBack < LATENCY_PATCH_COUNT; ++framesBack)
    {
        float2 rawLoad = LATENCY_CHECK_RAW_LOAD;
        float loadPercent = 100.0 * (IsStateB(FrameCount - framesBack) ? rawLoad.y : rawLoad.x);
        float levelNits = REFERENCE_PATCH_NITS * PanelCompensation(loadPercent);
        int2 patchCenter = int2((framesBack + 1) * BUFFER_WIDTH / (LATENCY_PATCH_COUNT + 1), center.y);
        patchLight += SquareLight(levelNits, patchHalf);

        if (InsideSquare(pixel, patchCenter, patchHalf))
            patchNits = levelNits;
    }

    float rawLoad = stateB ? LATENCY_CHECK_RAW_LOAD.y : LATENCY_CHECK_RAW_LOAD.x;
    float fillPixels = BUFFER_WIDTH * (BUFFER_HEIGHT - 2.0 * bandHalf);
    int bandOffset = pixel.y - center.y;

    float nits = (ScreenLight(rawLoad) - patchLight) / fillPixels;
    if (patchNits >= 0.0)
        nits = patchNits;
    else if (bandOffset >= -bandHalf && bandOffset < bandHalf)
        nits = 0.0;

    return nits.xxx;
}


float4 PS_NullTest(float4 position : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    int2 pixel = int2(position.xy);
    float3 nits = (Test == LATENCY_CHECK) ? LatencyCheckNits(pixel) : PatchCheckNits(pixel, IsStateB(FrameCount));
    return float4(EncodeRec2020Nits(nits), 1.0);
}


technique ABL_NullTest <
    ui_tooltip = "Replaces the frame with an ABL test pattern for EOTF Boost 3.1. Goes above the boost in the effect list.";
>
{
    pass
    {
        ComputeShader = CS_RecordSwitch<1, 1, 1>;
        DispatchSizeX = 1;
        DispatchSizeY = 1;
        DispatchSizeZ = 1;
    }

    pass
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_NullTest;
    }
}
