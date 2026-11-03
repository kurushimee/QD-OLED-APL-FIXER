/*
    EOTF Boost 3.1 for the Philips Evnia 27M2N6500 in HDR Peak 1000 mode

    Cancels the panel's automatic brightness limiter with a scene-uniform gain, from a panel model fitted to every
    measured window (PanelModel_27M2N6500.fxh). The algorithm is in EOTF_BoostCore_27M2N6500.fxh, which DwmBoost runs
    too.

    The panel dims a frame by the compensation at its load, the frame mean of each pixel's brightest weighted subpixel
    drive in the panel's native primaries, and follows a change in load with a single-pole response that dims slowly
    and undims almost at once. The gain that
    cancels that dimming at the load the boosted frame itself causes is solved within the frame, so every level the
    panel can show lands on its PQ target on every frame, whatever the frame rate. Midtones keep that full gain unless
    most of the frame can't fit under the ceiling, the signal peak over the gain. Highlights above the ceiling share
    the room under it by the frame's smoothed histogram, and nothing clips.

    Passes:
      1. PQ decode table and row histogram clear
      2. Full-frame row histograms
      3. Global histogram
      4. Gain solve, tone curve and its lookup
      5. Boost, optional calibration LUT, dither and stats

    It goes last in the effect chain, and expects every burn-in protection the monitor's OSD offers to be off.
*/

#include "ReShade.fxh"

#ifndef BUFFER_COLOR_SPACE
    #define BUFFER_COLOR_SPACE 0
#endif

// The back buffer's color space as ReShade reports it: 0 unknown, 1 SDR, 2 scRGB, 3 HDR10 PQ, 4 HLG.
// A game that sends HDR10 through its own API can show up as SDR, and ReShade's own macro can't be
// changed from the preset, so this one can.
#ifndef BOOST_COLOR_SPACE
    #define BOOST_COLOR_SPACE BUFFER_COLOR_SPACE
#endif

// The boost decodes scRGB, and PQ for everything else it accepts. SDR and HLG pass through untouched.
#define BOOST_INPUT_IS_HDR (BOOST_COLOR_SPACE != 1 && BOOST_COLOR_SPACE != 4)

#if !BOOST_INPUT_IS_HDR
    #warning "The back buffer isn't HDR10 or scRGB, so the boost is off. Set BOOST_COLOR_SPACE to 3 if the game sends HDR10 anyway."
#endif

#ifndef PQHDRLUT_ENABLE
    #define PQHDRLUT_ENABLE 0
#endif

#ifndef PQHDRLUT_SIZE
    #define PQHDRLUT_SIZE 65
#endif

#ifndef ENABLE_APL_GRAPH
    #define ENABLE_APL_GRAPH 0
#endif

#ifndef ENABLE_UI_TOOLTIPS
    #define ENABLE_UI_TOOLTIPS 0
#endif

#if ENABLE_UI_TOOLTIPS
    #define UI_TOOLTIP(text) ui_tooltip = text;
#else
    #define UI_TOOLTIP(text)
#endif


// ---------------------------------------------------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------------------------------------------------

uniform bool EnableEOTFBoost <
    ui_label = "Enable EOTF Boost";
    UI_TOOLTIP("Cancels the panel's brightness limiter.")
> = true;

uniform bool ShowOSD <
    ui_label = "Show Stats";
    UI_TOOLTIP("Shows the loads, the full and applied gain, the share of the frame above the ceiling, the ceiling and knee in source nits, and the frame's brightest source level.")
> = false;

uniform float OSDBrightness <
    ui_type = "slider";
    ui_min = 0.01; ui_max = 1.0; ui_step = 0.01;
    ui_label = "OSD Brightness";
    UI_TOOLTIP("Sets the brightness of the stats and the graph, up to 100 nits. It doesn't change the image.")
> = 0.5;

#if PQHDRLUT_ENABLE
uniform bool EnablePQHDRLUT <
    ui_label = "Enable PQ HDR LUT";
    UI_TOOLTIP("Applies PQHDRLUT.cube after the boost, or alone when the boost is off.")
> = true;

uniform int PQHDRLUTInputColorSpace <
    ui_category = "Optional HDR LUT Calibration";
    ui_category_closed = true;
    ui_type = "combo";
    ui_items = "Auto\0HDR10 PQ / Rec.2020\0scRGB / linear Rec.709\0";
    ui_label = "LUT Input Color Space";
    UI_TOOLTIP("The color space the LUT expects. Auto uses the buffer's.")
> = 0;
#endif

#if ENABLE_APL_GRAPH
uniform bool ShowAPLGraph <
    ui_label = "Show Boost Graph";
    UI_TOOLTIP("Shows the identity, the panel's unboosted output, the boosted signal, the predicted output and an optional BT.2390 reference.")
> = true;

uniform bool GraphShowBT2390Reference <
    ui_label = "Graph Shows BT.2390 Reference";
    UI_TOOLTIP("Shows a BT.2390 curve aimed at the live ceiling.")
> = false;

uniform float GraphInputSignalLimitNits <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 4000.0; ui_step = 1.0;
    ui_label = "Graph Input Signal Limit (nits)";
    UI_TOOLTIP("Caps the graph's input signal. 0 turns the cap off.")
> = 0.0;

uniform float GraphAxisMaxNits <
    ui_type = "slider";
    ui_min = 100.0; ui_max = 10000.0; ui_step = 1.0;
    ui_label = "Graph Axis Max (nits)";
    UI_TOOLTIP("The top of both graph axes.")
> = 1000.0;

uniform float GraphOpacity <
    ui_type = "slider";
    ui_min = 0.05; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Graph Opacity";
> = 0.5;

uniform bool GraphUsePQSpace <
    ui_label = "Graph PQ Axes";
    UI_TOOLTIP("Spaces the axes in PQ, with labels in nits.")
> = true;
#endif

uniform int FrameCount < source = "framecount"; >;
uniform float FrameTime < source = "frametime"; >;


// ---------------------------------------------------------------------------------------------------------------------
// Textures the core reads through its hooks
// ---------------------------------------------------------------------------------------------------------------------

#define TONE_CURVE_LUT_ENTRIES 1024

// Shown level in PQ for each 10-bit PQ code, written by the solve.
texture TexToneLUT { Width = TONE_CURVE_LUT_ENTRIES; Height = 1; Format = R32F; };
sampler<float> SamplerToneLUT { Texture = TexToneLUT; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
storage2D<float> StorageToneLUT { Texture = TexToneLUT; };

#define BOOST_TONE_LOOKUP(entry) tex2Dfetch(SamplerToneLUT, int2(entry, 0))

#if PQHDRLUT_ENABLE
texture3D PQHDRLUTTexture < source = "PQHDRLUT.cube"; >
{
    Width = PQHDRLUT_SIZE;
    Height = PQHDRLUT_SIZE;
    Depth = PQHDRLUT_SIZE;
    Format = RGBA32F;
};

sampler3D PQHDRLUTSampler
{
    Texture = PQHDRLUTTexture;
    AddressU = CLAMP;
    AddressV = CLAMP;
    AddressW = CLAMP;
    MagFilter = LINEAR;
    MinFilter = LINEAR;
    MipFilter = POINT;
};

// PQ Rec.2020 in, PQ Rec.2020 out, with each value mapped onto its texel center.
float3 SamplePQHDRLUT(float3 pq)
{
    float3 coordinate = (saturate(pq) * (PQHDRLUT_SIZE - 1.0) + 0.5) / PQHDRLUT_SIZE;
    return tex3Dlod(PQHDRLUTSampler, float4(coordinate, 0.0)).rgb;
}

// The load counts the signal the panel receives, so a gray's level goes through the LUT. The LUT corrects the panel
// toward the target, so what it shows stays put.
#define BOOST_CALIBRATED_LEVEL_NITS(nits) (EnablePQHDRLUT ? Max3(PQToNits(SamplePQHDRLUT(NitsToPQ(nits).xxx))) : (nits))
#endif

#include "EOTF_BoostCore_27M2N6500.fxh"

#if TONE_CURVE_LUT_ENTRIES != TONE_CURVE_LUT_SIZE
    #error "TONE_CURVE_LUT_ENTRIES must match the core's TONE_CURVE_LUT_SIZE"
#endif


// ---------------------------------------------------------------------------------------------------------------------
// State and histogram textures
// ---------------------------------------------------------------------------------------------------------------------

#define HIST_TILE_COUNT_X ((BUFFER_WIDTH  + HIST_TILE_SIZE - 1) / HIST_TILE_SIZE)
#define HIST_TILE_COUNT_Y ((BUFFER_HEIGHT + HIST_TILE_SIZE - 1) / HIST_TILE_SIZE)
#define HIST_ROW_TEX_H (HIST_TILE_COUNT_Y * HIST_BLOCK_H)

// (filtered panel load 0..1, content top PQ, has history, log2 gain), carried from frame to frame.
texture TexBoostState { Width = 1; Height = 1; Format = RGBA32F; };
sampler SamplerBoostState { Texture = TexBoostState; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
storage2D<float4> StorageBoostState { Texture = TexBoostState; };

// The stats: (raw load %, sent load %, filtered panel load %, full log2 gain) and
// (bend start nits, ceiling nits, clipped share, whiteout blend).
texture TexBoostStats { Width = 2; Height = 1; Format = RGBA32F; };
sampler SamplerBoostStats { Texture = TexBoostStats; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
storage2D<float4> StorageBoostStats { Texture = TexBoostStats; };

// (bend start PQ, bend width PQ, ceiling PQ, nits where the lookup takes over).
texture TexToneShape { Width = 1; Height = 1; Format = RGBA32F; };
sampler SamplerToneShape { Texture = TexToneShape; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
storage2D<float4> StorageToneShape { Texture = TexToneShape; };

// Exact PQ decode of every 10-bit code.
#define PQ_CODE_COUNT 1024

texture TexPQDecode { Width = PQ_CODE_COUNT; Height = 1; Format = R32F; };
sampler<float> SamplerPQDecode { Texture = TexPQDecode; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
storage2D<float> StoragePQDecode { Texture = TexPQDecode; };

// Row histograms, one 16x16 block per row of tiles. The count texture has an aux column for the row's brightest level.
texture TexRowCount { Width = HIST_BLOCK_W + 1; Height = HIST_ROW_TEX_H; Format = R32I; };
sampler2D<int> SamplerRowCount { Texture = TexRowCount; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
storage2D<int> StorageRowCount { Texture = TexRowCount; };

texture TexRowOffset { Width = HIST_BLOCK_W; Height = HIST_ROW_TEX_H; Format = R32I; };
sampler2D<int> SamplerRowOffset { Texture = TexRowOffset; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
storage2D<int> StorageRowOffset { Texture = TexRowOffset; };

texture TexRowDriveRatio { Width = HIST_BLOCK_W; Height = HIST_ROW_TEX_H; Format = R32I; };
sampler2D<int> SamplerRowDriveRatio { Texture = TexRowDriveRatio; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
storage2D<int> StorageRowDriveRatio { Texture = TexRowDriveRatio; };

texture TexRowLoadRatio { Width = HIST_BLOCK_W; Height = HIST_ROW_TEX_H; Format = R32I; };
sampler2D<int> SamplerRowLoadRatio { Texture = TexRowLoadRatio; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
storage2D<int> StorageRowLoadRatio { Texture = TexRowLoadRatio; };

// The frame's histogram, with the brightest level in the count texture's aux column.
texture TexGlobalCount { Width = HIST_BLOCK_W + 1; Height = HIST_BLOCK_H; Format = R32I; };
sampler2D<int> SamplerGlobalCount { Texture = TexGlobalCount; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
storage2D<int> StorageGlobalCount { Texture = TexGlobalCount; };

texture TexGlobalSums { Width = HIST_BLOCK_W; Height = HIST_BLOCK_H; Format = RGBA32F; };
sampler2D<float4> SamplerGlobalSums { Texture = TexGlobalSums; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };
storage2D<float4> StorageGlobalSums { Texture = TexGlobalSums; };


// ---------------------------------------------------------------------------------------------------------------------
// Buffer encoding
// ---------------------------------------------------------------------------------------------------------------------

bool NeedsBoost()
{
    return EnableEOTFBoost && BOOST_INPUT_IS_HDR;
}

// Linear nits in Rec.2020, the primaries the panel receives.
float3 DecodeBufferToRec2020Nits(float3 color)
{
#if BOOST_COLOR_SPACE == 2
    return mul(REC709_TO_REC2020, color) * SCRGB_REFERENCE_NITS;
#else
    return PQToNits(color);
#endif
}

float3 EncodeRec2020NitsToBuffer(float3 nits)
{
#if BOOST_COLOR_SPACE == 2
    return mul(REC2020_TO_REC709, nits) / SCRGB_REFERENCE_NITS;
#else
    return NitsToPQ(nits);
#endif
}

#if PQHDRLUT_ENABLE
// 1 is PQ Rec.2020, 2 scRGB, and 0 an SDR or HLG buffer the LUT leaves alone.
int PQHDRLUTInputMode()
{
    if (PQHDRLUTInputColorSpace != 0)
        return PQHDRLUTInputColorSpace;

#if BOOST_COLOR_SPACE == 2
    return 2;
#elif BOOST_INPUT_IS_HDR
    return 1;
#else
    return 0;
#endif
}

float3 ApplyPQHDRLUT(float3 color)
{
    int mode = PQHDRLUTInputMode();
    if (mode == 0)
        return color;

    if (mode == 1)
        return SamplePQHDRLUT(color);

    // scRGB keeps its signed components through the gamut conversion.
    float3 rec2020Nits = max(mul(REC709_TO_REC2020, color * SCRGB_REFERENCE_NITS), 0.0);
    float3 calibratedNits = PQToNits(SamplePQHDRLUT(NitsToPQ(rec2020Nits)));
    return mul(REC2020_TO_REC709, calibratedNits) / SCRGB_REFERENCE_NITS;
}
#endif


// ---------------------------------------------------------------------------------------------------------------------
// Pass 1: PQ decode table and row histogram clear
// ---------------------------------------------------------------------------------------------------------------------

void CS_Setup(uint3 threadID : SV_GroupThreadID)
{
    if (!NeedsBoost())
        return;

    int localIndex = int(threadID.x);

    [unroll]
    for (int slot = 0; slot < PQ_CODE_COUNT / HIST_BINS; ++slot)
    {
        int code = localIndex + slot * HIST_BINS;
        tex2Dstore(StoragePQDecode, int2(code, 0), PQToNits(float(code) / (PQ_CODE_COUNT - 1)));
    }

    [loop]
    for (int rowIndex = 0; rowIndex < HIST_TILE_COUNT_Y; ++rowIndex)
    {
        int2 coord = HistRowCoord(rowIndex, localIndex);
        tex2Dstore(StorageRowCount, coord, 0);
        tex2Dstore(StorageRowOffset, coord, 0);
        tex2Dstore(StorageRowDriveRatio, coord, 0);
        tex2Dstore(StorageRowLoadRatio, coord, 0);

        if (localIndex == 0)
            tex2Dstore(StorageRowCount, HistRowMaxLevelCoord(rowIndex), 0);
    }
}


// ---------------------------------------------------------------------------------------------------------------------
// Pass 2: row histograms
// ---------------------------------------------------------------------------------------------------------------------

float3 DecodePQCodes(float3 pq)
{
    int3 codes = int3(saturate(pq) * (PQ_CODE_COUNT - 1) + 0.5);
    return float3(
        tex2Dfetch(SamplerPQDecode, int2(codes.r, 0)),
        tex2Dfetch(SamplerPQDecode, int2(codes.g, 0)),
        tex2Dfetch(SamplerPQDecode, int2(codes.b, 0)));
}

// A pixel's brightest-channel level in Rec.2020 and its drive in the panel's native primaries.
void DecodeHistogramPixel(int2 pixel, out float3 rec2020Nits, out float3 panelNits)
{
    float3 color = tex2Dfetch(ReShade::BackBuffer, pixel).rgb;
#if BOOST_COLOR_SPACE == 2
    float3 rec709Nits = color * SCRGB_REFERENCE_NITS;
    rec2020Nits = mul(REC709_TO_REC2020, rec709Nits);
    panelNits = mul(REC709_TO_PANEL, rec709Nits);
#else
    rec2020Nits = DecodePQCodes(color);
    panelNits = mul(BT2020_TO_PANEL, rec2020Nits);
#endif
}

void CS_BuildRowHistogram(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.y * HIST_THREADS_X + threadID.x);
    TileClear(localIndex);
    barrier();

    int row = int(groupID.y);
    int2 pixelBase = int2(groupID.xy) * HIST_TILE_SIZE + int2(threadID.xy) * 2;

    float3 rec2020Nits[4];
    float3 panelNits[4];
    bool valid[4];

    [unroll]
    for (int pixel = 0; pixel < 4; ++pixel)
    {
        int2 position = pixelBase + int2(pixel & 1, pixel >> 1);
        valid[pixel] = position.x < BUFFER_WIDTH && position.y < BUFFER_HEIGHT;
        DecodeHistogramPixel(min(position, int2(BUFFER_WIDTH, BUFFER_HEIGHT) - 1), rec2020Nits[pixel], panelNits[pixel]);
    }

    if (NeedsBoost())
        TileAddQuad(rec2020Nits, panelNits, valid, HistRatioScale(BUFFER_WIDTH));
    barrier();

    if (!NeedsBoost())
        return;

    if (localIndex == 0)
        atomicMax(StorageRowCount, HistRowMaxLevelCoord(row), Tile_MaxLevelBits);

    int packedCount = Tile_PackedCount[localIndex];
    int count = packedCount >> HIST_PACK_COUNT_SHIFT;
    if (count > 0)
    {
        int2 coord = HistRowCoord(row, localIndex);
        atomicAdd(StorageRowCount, coord, count);
        atomicAdd(StorageRowOffset, coord, packedCount & HIST_PACK_OFFSET_MASK);
        atomicAdd(StorageRowDriveRatio, coord, Tile_DriveRatio[localIndex]);
        atomicAdd(StorageRowLoadRatio, coord, Tile_LoadRatio[localIndex]);
    }
}


// ---------------------------------------------------------------------------------------------------------------------
// Pass 3: global histogram
// ---------------------------------------------------------------------------------------------------------------------

groupshared int Reduce_Count[HIST_REDUCE_THREADS];
groupshared float3 Reduce_Sums[HIST_REDUCE_THREADS];

void CS_ReduceHistogram(uint3 groupID : SV_GroupID, uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);
    int2 binCoord = int2(groupID.xy);
    int binIndex = binCoord.y * HIST_BLOCK_W + binCoord.x;

    int count = 0;
    float3 sums = 0.0;

    [loop]
    for (int rowIndex = localIndex; rowIndex < HIST_TILE_COUNT_Y; rowIndex += HIST_REDUCE_THREADS)
    {
        int2 coord = HistRowCoord(rowIndex, binIndex);
        count += tex2Dfetch(SamplerRowCount, coord);
        sums += float3(
            tex2Dfetch(SamplerRowOffset, coord),
            tex2Dfetch(SamplerRowDriveRatio, coord),
            tex2Dfetch(SamplerRowLoadRatio, coord));
    }

    Reduce_Count[localIndex] = count;
    Reduce_Sums[localIndex] = sums;
    barrier();

    [unroll]
    for (int stride = HIST_REDUCE_THREADS / 2; stride > 0; stride /= 2)
    {
        if (localIndex < stride)
        {
            Reduce_Count[localIndex] += Reduce_Count[localIndex + stride];
            Reduce_Sums[localIndex] += Reduce_Sums[localIndex + stride];
        }
        barrier();
    }

    if (!NeedsBoost() || localIndex != 0)
        return;

    tex2Dstore(StorageGlobalCount, binCoord, Reduce_Count[0]);
    tex2Dstore(StorageGlobalSums, binCoord, float4(Reduce_Sums[0], 0.0));

    if (binIndex == 0)
    {
        int maxLevelBits = 0;

        [loop]
        for (int maxRow = 0; maxRow < HIST_TILE_COUNT_Y; ++maxRow)
            maxLevelBits = max(maxLevelBits, tex2Dfetch(SamplerRowCount, HistRowMaxLevelCoord(maxRow)));

        tex2Dstore(StorageGlobalCount, HistGlobalMaxLevelCoord(), maxLevelBits);
    }
}


// ---------------------------------------------------------------------------------------------------------------------
// Pass 4: gain solve, tone curve and lookup
// ---------------------------------------------------------------------------------------------------------------------

void CS_Solve(uint3 threadID : SV_GroupThreadID)
{
    int localIndex = int(threadID.x);
    bool active = NeedsBoost();

    SolveInput frame;
    int2 binCoord = HistBlockCoord(localIndex);
    float4 sums = active ? tex2Dfetch(SamplerGlobalSums, binCoord) : 0.0;
    frame.binCount = active ? float(tex2Dfetch(SamplerGlobalCount, binCoord)) : 0.0;
    frame.offsetSum = sums.x;
    frame.driveRatioSum = sums.y;
    frame.loadRatioSum = sums.z;
    frame.maxLevelNits = active ? asfloat(tex2Dfetch(SamplerGlobalCount, HistGlobalMaxLevelCoord())) : 0.0;
    frame.state = active ? tex2Dfetch(StorageBoostState, int2(0, 0)) : 0.0;
    frame.frameTimeMs = FrameTime;
    frame.litFraction = 1.0;
    frame.widthPx = BUFFER_WIDTH;

    SolveOutput result;
    SolveBoost(localIndex, frame, result);

    [unroll]
    for (int slot = 0; slot < TONE_CURVE_LUT_SIZE / HIST_BINS; ++slot)
    {
        int entry = localIndex + slot * HIST_BINS;
        tex2Dstore(StorageToneLUT, int2(entry, 0), ToneCurveLookupEntry(entry));
    }

    if (localIndex != 0)
        return;

    // With the boost off, the history goes, so it starts again from the frame's own load.
    tex2Dstore(StorageBoostState, int2(0, 0), active ? result.state : 0.0);
    tex2Dstore(StorageBoostStats, int2(0, 0), result.loads);
    tex2Dstore(StorageBoostStats, int2(1, 0), result.curve);
    tex2Dstore(StorageToneShape, int2(0, 0), result.shape);
}


// ---------------------------------------------------------------------------------------------------------------------
// Overlay text and graph, drawn in nits
// ---------------------------------------------------------------------------------------------------------------------

// The brightest the overlays get, at OSD Brightness 1.
static const float OVERLAY_PEAK_NITS = 100.0;

// 3x5 glyphs, one bit per cell from the bottom left.
static const int DIGIT_GLYPHS[10] = { 31599, 9362, 29671, 29391, 23497, 31183, 31215, 29257, 31727, 31695 };

float GlyphCell(int glyph, float2 uv)
{
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;

    int x = int(uv.x * 3.0);
    int y = int((1.0 - uv.y) * 5.0);
    return float((glyph >> (x + y * 3)) & 1);
}

float GetPercentSign(float2 uv)
{
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;

    float2 d0 = uv - float2(0.3, 0.25);
    float2 d1 = uv - float2(0.7, 0.75);
    bool slash = abs(uv.x - (1.0 - uv.y)) < 0.15;
    bool circles = (dot(d0, d0) < 0.04) || (dot(d1, d1) < 0.04);
    return (slash || circles) ? 1.0 : 0.0;
}

float GetDecimalPoint(float2 uv)
{
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0)
        return 0.0;

    float y = 1.0 - uv.y;
    return (uv.x > 0.35 && uv.x < 0.65 && y < 0.20) ? 1.0 : 0.0;
}

// The glyph cell's uv for a glyph whose top right corner, or top left with leftAligned, sits at anchor.
float2 GlyphUV(float2 texcoord, float2 anchor, float scale, float aspect, bool leftAligned)
{
    float2 uv = (texcoord - anchor) * float2(aspect, 1.0);
    if (!leftAligned)
        uv.x = -uv.x;
    return uv / scale;
}

float DrawDigit(float2 texcoord, float2 topRight, float scale, float aspect, int digit)
{
    return GlyphCell(DIGIT_GLYPHS[clamp(digit, 0, 9)], GlyphUV(texcoord, topRight, scale, aspect, false));
}

int CountDigits(int value)
{
    int v = max(value, 0);
    if (v >= 10000) return 5;
    if (v >= 1000) return 4;
    if (v >= 100) return 3;
    if (v >= 10) return 2;
    return 1;
}

// A whole number of up to five digits, right-aligned at topRight.
float DrawNumber(float2 texcoord, float2 topRight, float scale, float stepX, float aspect, int value)
{
    int v = clamp(value, 0, 99999);
    int digits = CountDigits(v);
    float mask = 0.0;
    int divisor = 1;

    [unroll]
    for (int place = 0; place < 5; ++place)
    {
        if (place < digits)
            mask += DrawDigit(texcoord, topRight - float2(stepX * place, 0.0), scale, aspect, (v / divisor) % 10);
        divisor *= 10;
    }

    return saturate(mask);
}

// A value with two decimals, right-aligned at topRight.
float DrawFixed2(float2 texcoord, float2 topRight, float scale, float stepX, float aspect, float value)
{
    int hundredths = clamp(int(floor(max(value, 0.0) * 100.0 + 0.5)), 0, 99999);
    float mask = DrawNumber(texcoord, topRight, scale, stepX, aspect, hundredths % 100);
    if (hundredths % 100 < 10)
        mask += DrawDigit(texcoord, topRight - float2(stepX, 0.0), scale, aspect, 0);
    mask += GetDecimalPoint(GlyphUV(texcoord, topRight - float2(stepX * 2.0, 0.0), scale, aspect, false));
    mask += DrawNumber(texcoord, topRight - float2(stepX * 3.0, 0.0), scale, stepX, aspect, hundredths / 100);
    return saturate(mask);
}

#define CHAR_SPACE -1
#define CHAR_A 0
#define CHAR_C 2
#define CHAR_D 3
#define CHAR_E 4
#define CHAR_F 5
#define CHAR_G 6
#define CHAR_I 8
#define CHAR_K 10
#define CHAR_L 11
#define CHAR_N 13
#define CHAR_O 14
#define CHAR_P 15
#define CHAR_R 17
#define CHAR_S 18
#define CHAR_T 19
#define CHAR_U 20
#define CHAR_W 22

int LetterGlyph(int letter)
{
    if (letter == CHAR_A) return 11245;
    if (letter == CHAR_C) return 25166;
    if (letter == CHAR_D) return 15211;
    if (letter == CHAR_E) return 29391;
    if (letter == CHAR_F) return 29385;
    if (letter == CHAR_G) return 25454;
    if (letter == CHAR_I) return 29847;
    if (letter == CHAR_K) return 23277;
    if (letter == CHAR_L) return 4687;
    if (letter == CHAR_N) return 24573;
    if (letter == CHAR_O) return 31599;
    if (letter == CHAR_P) return 15049;
    if (letter == CHAR_R) return 15085;
    if (letter == CHAR_S) return 29671;
    if (letter == CHAR_T) return 29842;
    if (letter == CHAR_U) return 23407;
    if (letter == CHAR_W) return 23421;
    return 0;
}

struct OSDStats
{
    float rawLoadPercent;
    float sentLoadPercent;
    float panelLoadPercent;
    float fullCompensation;
    float gain;
    float clippedPercent;
    float ceilingNits;
    float bendStartNits;
    float maxSourceNits;
};

#define OSD_ROW_COUNT      9
#define OSD_ROW_RAW_LOAD   0
#define OSD_ROW_OUT_LOAD   1
#define OSD_ROW_PANEL_LOAD 2
#define OSD_ROW_FULL       3
#define OSD_ROW_GAIN       4
#define OSD_ROW_CLIPPED    5
#define OSD_ROW_CEILING    6
#define OSD_ROW_KNEE       7
#define OSD_ROW_RAW_NITS   8

#define _ CHAR_SPACE
// Eight letters per row's label.
static const int OSD_ROW_LABELS[OSD_ROW_COUNT * 8] =
{
    CHAR_R, CHAR_A, CHAR_W, _, CHAR_L, CHAR_O, CHAR_A, CHAR_D,
    CHAR_O, CHAR_U, CHAR_T, _, CHAR_L, CHAR_O, CHAR_A, CHAR_D,
    CHAR_P, CHAR_A, CHAR_N, CHAR_E, CHAR_L, _, CHAR_L, CHAR_D,
    CHAR_F, CHAR_U, CHAR_L, CHAR_L, _, _, _, _,
    CHAR_G, CHAR_A, CHAR_I, CHAR_N, _, _, _, _,
    CHAR_C, CHAR_L, CHAR_I, CHAR_P, CHAR_P, CHAR_E, CHAR_D, _,
    CHAR_C, CHAR_E, CHAR_I, CHAR_L, _, _, _, _,
    CHAR_K, CHAR_N, CHAR_E, CHAR_E, _, _, _, _,
    CHAR_R, CHAR_A, CHAR_W, _, CHAR_N, CHAR_I, CHAR_T, CHAR_S
};
#undef _

float DrawRowLabel(float2 texcoord, float2 topLeft, float scale, float stepX, float aspect, int row)
{
    float mask = 0.0;

    [unroll]
    for (int index = 0; index < 8; ++index)
    {
        int letter = OSD_ROW_LABELS[row * 8 + index];
        if (letter >= 0)
            mask += GlyphCell(LetterGlyph(letter), GlyphUV(texcoord, topLeft + float2(stepX * index, 0.0), scale, aspect, true));
    }

    return saturate(mask);
}

bool OSDRowIsPercent(int row)
{
    return row == OSD_ROW_RAW_LOAD || row == OSD_ROW_OUT_LOAD || row == OSD_ROW_PANEL_LOAD || row == OSD_ROW_CLIPPED;
}

float OSDRowValue(int row, OSDStats stats)
{
    if (row == OSD_ROW_RAW_LOAD) return stats.rawLoadPercent;
    if (row == OSD_ROW_OUT_LOAD) return stats.sentLoadPercent;
    if (row == OSD_ROW_PANEL_LOAD) return stats.panelLoadPercent;
    if (row == OSD_ROW_FULL) return stats.fullCompensation;
    if (row == OSD_ROW_GAIN) return stats.gain;
    if (row == OSD_ROW_CLIPPED) return stats.clippedPercent;
    if (row == OSD_ROW_CEILING) return stats.ceilingNits;
    if (row == OSD_ROW_KNEE) return stats.bendStartNits;
    return stats.maxSourceNits;
}

float3 OSDRowColor(int row)
{
    if (row <= OSD_ROW_PANEL_LOAD)
        return float3(0.30, 1.00, 0.30);
    if (row <= OSD_ROW_CLIPPED)
        return float3(1.00, 0.58, 0.25);
    return float3(0.60, 0.85, 1.00);
}

// The stats in the top right corner, over the scene in nits.
float3 DrawStatsOverlay(float2 texcoord, float3 sceneNits, OSDStats stats)
{
    float aspect = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float scale = 0.022;
    float glyphWidth = scale / aspect;
    float stepX = glyphWidth * 1.06;
    float lineSpacing = scale * 1.18;

    float labelScale = scale * 0.92;
    float labelGlyphWidth = labelScale / aspect;
    float labelStepX = labelGlyphWidth * 1.18;
    float labelWidth = labelStepX * 7.0 + labelGlyphWidth;

    float top = 0.034;
    float percentRight = 1.0 - 0.016;
    float valueRight = percentRight - glyphWidth * 1.2;
    float labelLeft = valueRight - stepX * 5.0 - glyphWidth - glyphWidth * 0.82 - labelWidth;
    float bottom = top + lineSpacing * float(OSD_ROW_COUNT - 1) + scale;

    float padX = glyphWidth * 0.48;
    float padY = scale * 0.20;
    if (texcoord.x < labelLeft - padX || texcoord.x > percentRight + padX || texcoord.y < top - padY || texcoord.y > bottom + padY)
        return sceneNits;

    int row = clamp(int(floor((texcoord.y - top + (lineSpacing - scale) * 0.5) / lineSpacing)), 0, OSD_ROW_COUNT - 1);
    float rowTop = top + lineSpacing * float(row);

    float mask = DrawRowLabel(texcoord, float2(labelLeft, rowTop), labelScale, labelStepX, aspect, row);

    float value = OSDRowValue(row, stats);
    if (row >= OSD_ROW_CEILING)
        mask += DrawNumber(texcoord, float2(valueRight, rowTop), scale, stepX, aspect, int(floor(max(value, 0.0) + 0.5)));
    else
        mask += DrawFixed2(texcoord, float2(valueRight, rowTop), scale, stepX, aspect, value);

    if (OSDRowIsPercent(row))
        mask += GetPercentSign((texcoord - float2(percentRight - glyphWidth, rowTop)) * float2(aspect, 1.0) / scale);

    float overlayNits = OVERLAY_PEAK_NITS * OSDBrightness;
    float3 shadedScene = sceneNits * (1.0 - 0.18 * OSDBrightness);
    return lerp(shadedScene, OSDRowColor(row) * overlayNits, saturate(mask));
}

OSDStats ReadOSDStats()
{
    float4 state = tex2Dfetch(SamplerBoostState, int2(0, 0));
    float4 loads = tex2Dfetch(SamplerBoostStats, int2(0, 0));
    float4 curve = tex2Dfetch(SamplerBoostStats, int2(1, 0));

    OSDStats stats;
    stats.rawLoadPercent = loads.x;
    stats.sentLoadPercent = loads.y;
    stats.panelLoadPercent = loads.z;
    stats.fullCompensation = exp2(loads.w);
    stats.gain = exp2(state.w);
    stats.clippedPercent = 100.0 * curve.z;
    stats.ceilingNits = curve.y;
    stats.bendStartNits = curve.x;
    stats.maxSourceNits = asfloat(tex2Dfetch(SamplerGlobalCount, HistGlobalMaxLevelCoord()));
    return stats;
}


#if ENABLE_APL_GRAPH
// ---------------------------------------------------------------------------------------------------------------------
// Debug graph: input nits against output nits under the panel model
// ---------------------------------------------------------------------------------------------------------------------

#define GRAPH_CURVE_SAMPLES 64
#define GRAPH_LINE_COUNT    32

#define GCURVE_SENT      0
#define GCURVE_PREDICTED 1
#define GCURVE_UNBOOSTED 2
#define GCURVE_BT2390    3

static const float2 GRAPH_POSITION_PER_ASPECT = float2(0.055, 0.48);
static const float2 GRAPH_SIZE_PER_ASPECT = float2(0.43, 0.44);

// (filtered panel load %, axis max PQ, raw load %, unused).
texture TexGraphParams { Width = 1; Height = 1; Format = RGBA32F; };
sampler SamplerGraphParams { Texture = TexGraphParams; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

// Per sample: sent nits and predicted shown nits.
texture TexGraphProjection { Width = GRAPH_CURVE_SAMPLES; Height = 1; Format = RGBA32F; };
sampler SamplerGraphProjection { Texture = TexGraphProjection; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

// Screen-space segments of the four curves, one row each.
texture TexGraphCurves { Width = GRAPH_CURVE_SAMPLES; Height = 4; Format = RGBA32F; };
sampler SamplerGraphCurves { Texture = TexGraphCurves; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

// Grid, tick and identity segments.
texture TexGraphLines { Width = GRAPH_LINE_COUNT; Height = 1; Format = RGBA32F; };
sampler SamplerGraphLines { Texture = TexGraphLines; MinFilter = POINT; MagFilter = POINT; MipFilter = POINT; };

static const float PQ_BLACK = 7.309559025783966e-07;

float ClampedGraphAxisMaxNits()
{
    return clamp(GraphAxisMaxNits, 1.0, 10000.0);
}

float GraphAxisMaxPQ()
{
    return GraphUsePQSpace ? max(tex2Dfetch(SamplerGraphParams, int2(0, 0)).y, 1e-6) : 0.0;
}

float2 GraphPosition()
{
    float aspect = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    return GRAPH_POSITION_PER_ASPECT * float2(aspect, 1.0);
}

float2 GraphSize()
{
    float aspect = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    return GRAPH_SIZE_PER_ASPECT * float2(aspect, 1.0);
}

// BT.2390's EETF from sourcePeakNits down to targetPeakNits.
float BT2390OutputNits(float inputNits, float sourcePeakNits, float targetPeakNits)
{
    if (targetPeakNits <= 0.0)
        return 0.0;
    if (targetPeakNits >= sourcePeakNits - 1e-4)
        return inputNits;

    float sourceWhitePQ = max(NitsToPQ(max(sourcePeakNits, 1e-4)), PQ_BLACK + 1e-6);
    float targetWhitePQ = min(NitsToPQ(targetPeakNits), sourceWhitePQ - 1e-6);
    float pqRange = max(sourceWhitePQ - PQ_BLACK, 1e-6);
    float e1 = saturate((NitsToPQ(max(inputNits, 0.0)) - PQ_BLACK) / pqRange);
    float maxLum = saturate((targetWhitePQ - PQ_BLACK) / pqRange);
    float kneeStart = saturate(1.5 * maxLum - 0.5);
    float e2 = e1;

    if (e1 >= kneeStart)
    {
        float shoulderSpan = max(1.0 - kneeStart, 1e-6);
        float compressionSpan = max(maxLum - kneeStart, 1e-6);
        float u = saturate((e1 - kneeStart) / shoulderSpan);
        e2 = kneeStart + compressionSpan * (1.0 - pow(1.0 - u, max(shoulderSpan / compressionSpan, 1.0)));
    }

    return PQToNits(saturate(e2 * pqRange + PQ_BLACK));
}

float GraphLimitedInputNits(float inputNits)
{
    float nits = max(inputNits, 0.0);
    return (GraphInputSignalLimitNits > 0.0) ? min(nits, GraphInputSignalLimitNits) : nits;
}

float GraphAxisCoordinate(float nits, float axisMaxNits, float axisMaxPQ)
{
    return GraphUsePQSpace ? NitsToPQ(max(nits, 0.0)) / max(axisMaxPQ, 1e-6) : max(nits, 0.0) / axisMaxNits;
}

float GraphNitsAtFraction(float fraction, float axisMaxNits, float axisMaxPQ)
{
    return GraphUsePQSpace ? PQToNits(axisMaxPQ * saturate(fraction)) : axisMaxNits * saturate(fraction);
}

float2 GraphPoint(float axisMaxNits, float axisMaxPQ, float xNits, float yNits)
{
    float x = saturate(GraphAxisCoordinate(xNits, axisMaxNits, axisMaxPQ));
    float y = GraphAxisCoordinate(yNits, axisMaxNits, axisMaxPQ);
    return GraphPosition() + float2(x * GraphSize().x, (1.0 - y) * GraphSize().y);
}

float DistanceToSegment(float2 p, float2 a, float2 b, out float along)
{
    float2 pa = p - a;
    float2 ba = b - a;
    along = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return length(pa - ba * along);
}

float DrawSegment(float2 p, float4 segment, float thickness, float dashCount)
{
    float2 boxMin = min(segment.xy, segment.zw) - thickness * 2.2;
    float2 boxMax = max(segment.xy, segment.zw) + thickness * 2.2;
    if (any(p < boxMin) || any(p > boxMax))
        return 0.0;

    float along;
    float line = 1.0 - smoothstep(thickness, thickness * 1.8, DistanceToSegment(p, segment.xy, segment.zw, along));
    return (dashCount > 0.0) ? line * step(frac(along * dashCount), 0.55) : line;
}

float DrawFrame(float2 p, float2 minP, float2 maxP, float thickness)
{
    float inside = step(minP.x, p.x) * step(minP.y, p.y) * step(p.x, maxP.x) * step(p.y, maxP.y);
    float4 edges = abs(float4(p.x - minP.x, p.x - maxP.x, p.y - minP.y, p.y - maxP.y));
    float4 lines = 1.0 - smoothstep(thickness, thickness * 1.8, edges);
    return inside * saturate(lines.x + lines.y + lines.z + lines.w);
}

float4 GraphLineSegment(int index)
{
    return tex2Dfetch(SamplerGraphLines, int2(index, 0));
}

float4 GraphCurveSegment(int sampleIndex, int row)
{
    return tex2Dfetch(SamplerGraphCurves, int2(sampleIndex, row));
}

float3 DrawGraphOverlay(float2 texcoord, float3 sceneNits)
{
    float aspect = ReShade::ScreenSize.x / ReShade::ScreenSize.y;
    float2 p = texcoord * float2(aspect, 1.0);
    float2 graphMin = GraphPosition();
    float2 graphMax = graphMin + GraphSize();

    float thickness = 0.00105;
    float labelScale = 0.014;
    float margin = thickness * 5.0;
    float axisMaxNits = ClampedGraphAxisMaxNits();
    float axisMaxPQ = GraphAxisMaxPQ();
    float labelStep = labelScale * 0.82 / aspect;

    float2 labelMin = graphMin - float2(labelScale * 6.0, labelScale);
    float2 labelMax = graphMax + float2(labelScale * 2.0, 0.010 + labelScale * 1.25);
    if (any(p < labelMin) || any(p > labelMax))
        return sceneNits;

    bool inGraph = all(p >= graphMin - margin) && all(p <= graphMax + margin);
    float inside = all(p >= graphMin) && all(p <= graphMax) ? 1.0 : 0.0;

    float gridMask = 0.0, tickMask = 0.0, frameMask = 0.0, identityMask = 0.0, labelMask = 0.0;
    float sentMask = 0.0, predictedMask = 0.0, unboostedMask = 0.0, referenceMask = 0.0;

    if (inGraph)
    {
        frameMask = DrawFrame(p, graphMin, graphMax, thickness);

        [loop]
        for (int line = 0; line < 9; ++line)
        {
            gridMask += 0.32 * DrawSegment(p, GraphLineSegment(line), 0.0005, 0.0);
            gridMask += 0.32 * DrawSegment(p, GraphLineSegment(line + 9), 0.0005, 0.0);
        }

        [loop]
        for (int tick = 0; tick < 6; ++tick)
        {
            tickMask += DrawSegment(p, GraphLineSegment(tick + 18), 0.00075, 0.0);
            tickMask += DrawSegment(p, GraphLineSegment(tick + 24), 0.00075, 0.0);
        }

        identityMask = DrawSegment(p, GraphLineSegment(30), thickness * 0.9, 22.0);

        int center = clamp(int(floor(saturate((p.x - graphMin.x) / GraphSize().x) * (GRAPH_CURVE_SAMPLES - 1))), 0, GRAPH_CURVE_SAMPLES - 2);

        [unroll]
        for (int neighbor = -2; neighbor <= 2; ++neighbor)
        {
            int s = clamp(center + neighbor, 0, GRAPH_CURVE_SAMPLES - 2);
            sentMask = max(sentMask, DrawSegment(p, GraphCurveSegment(s, GCURVE_SENT), thickness * 0.9, 0.0));
            predictedMask = max(predictedMask, DrawSegment(p, GraphCurveSegment(s, GCURVE_PREDICTED), thickness, 0.0));
            unboostedMask = max(unboostedMask, DrawSegment(p, GraphCurveSegment(s, GCURVE_UNBOOSTED), thickness, 0.0));
            if (GraphShowBT2390Reference)
                referenceMask = max(referenceMask, DrawSegment(p, GraphCurveSegment(s, GCURVE_BT2390), thickness * 0.85, 18.0));
        }
    }

    [loop]
    for (int label = 0; label < 6; ++label)
    {
        int labelNits = int(round(GraphNitsAtFraction(float(label) / 5.0, axisMaxNits, axisMaxPQ)));
        float2 xTick = GraphLineSegment(label + 18).zw;
        float2 yTick = GraphLineSegment(label + 24).xy;
        int digits = CountDigits(labelNits);
        float2 xLabelRight = float2(xTick.x / aspect + 0.5 * labelStep * (digits - 1), graphMax.y + 0.010);
        float2 yLabelRight = float2((graphMin.x - GraphSize().x * 0.035) / aspect, yTick.y - labelScale * 0.52);
        labelMask += DrawNumber(texcoord, xLabelRight, labelScale, labelStep, aspect, labelNits);
        labelMask += DrawNumber(texcoord, yLabelRight, labelScale, labelStep, aspect, labelNits);
    }

    float level = OVERLAY_PEAK_NITS * OSDBrightness;
    float3 nits = lerp(sceneNits, 0.0, inside * 0.12 * GraphOpacity);
    nits = lerp(nits, 0.32 * level, saturate(gridMask) * GraphOpacity);
    nits = lerp(nits, 0.55 * level, saturate(tickMask) * GraphOpacity);
    nits = lerp(nits, 0.70 * level, saturate(frameMask) * GraphOpacity);
    nits = lerp(nits, 0.65 * level, saturate(labelMask) * saturate(GraphOpacity + 0.05));
    nits = lerp(nits, float3(0.40, 0.65, 1.00) * 0.8 * level, saturate(identityMask) * GraphOpacity);
    nits = lerp(nits, float3(1.00, 0.35, 0.92) * 0.8 * level, saturate(referenceMask) * GraphOpacity);
    nits = lerp(nits, float3(0.62, 0.82, 1.00) * 0.8 * level, saturate(unboostedMask) * GraphOpacity);
    nits = lerp(nits, float3(0.30, 0.88, 0.42) * 0.7 * level, saturate(sentMask) * saturate(GraphOpacity + 0.06));
    nits = lerp(nits, float3(0.62, 0.62, 0.62) * 0.8 * level, saturate(predictedMask) * saturate(GraphOpacity + 0.20));
    return nits;
}

// Brightest channel the panel shows for a sent level at a filtered panel load.
float PredictedShownNits(float sentNits, float loadPercent)
{
    return min(sentNits, PANEL_PEAK_NITS) / EvaluatePanelCompensation(loadPercent);
}

float4 PS_GraphParams(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float4 loads = tex2Dfetch(SamplerBoostStats, int2(0, 0));
    float axisMaxPQ = max(NitsToPQ(ClampedGraphAxisMaxNits()), 1e-6);
    return float4(loads.z, axisMaxPQ, loads.x, 0.0);
}

float4 PS_GraphProjection(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float t = float(int(vpos.x)) / float(GRAPH_CURVE_SAMPLES - 1);
    float inputNits = GraphLimitedInputNits(GraphNitsAtFraction(t, ClampedGraphAxisMaxNits(), GraphAxisMaxPQ()));
    float sentNits = inputNits;

    if (NeedsBoost())
    {
        float gain = exp2(tex2Dfetch(SamplerBoostState, int2(0, 0)).w);
        sentNits = gain * ShownLevelNits(inputNits, tex2Dfetch(SamplerToneShape, int2(0, 0)));
    }

    float panelLoad = tex2Dfetch(SamplerGraphParams, int2(0, 0)).x;
    return float4(sentNits, PredictedShownNits(sentNits, panelLoad), 0.0, 1.0);
}

float4 PS_GraphLines(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    int index = int(vpos.x);
    float axisMaxNits = ClampedGraphAxisMaxNits();
    float axisMaxPQ = GraphAxisMaxPQ();
    float tickLength = GraphSize().y * 0.018;

    if (index < 9)
    {
        float tickNits = GraphNitsAtFraction(float(index + 1) / 10.0, axisMaxNits, axisMaxPQ);
        return float4(GraphPoint(axisMaxNits, axisMaxPQ, tickNits, 0.0), GraphPoint(axisMaxNits, axisMaxPQ, tickNits, axisMaxNits));
    }
    if (index < 18)
    {
        float tickNits = GraphNitsAtFraction(float(index - 8) / 10.0, axisMaxNits, axisMaxPQ);
        return float4(GraphPoint(axisMaxNits, axisMaxPQ, 0.0, tickNits), GraphPoint(axisMaxNits, axisMaxPQ, axisMaxNits, tickNits));
    }
    if (index < 24)
    {
        float2 tick = GraphPoint(axisMaxNits, axisMaxPQ, GraphNitsAtFraction(float(index - 18) / 5.0, axisMaxNits, axisMaxPQ), 0.0);
        return float4(tick - float2(0.0, tickLength), tick);
    }
    if (index < 30)
    {
        float2 tick = GraphPoint(axisMaxNits, axisMaxPQ, 0.0, GraphNitsAtFraction(float(index - 24) / 5.0, axisMaxNits, axisMaxPQ));
        return float4(tick, tick + float2(tickLength, 0.0));
    }
    if (index == 30)
        return float4(GraphPoint(axisMaxNits, axisMaxPQ, 0.0, 0.0), GraphPoint(axisMaxNits, axisMaxPQ, axisMaxNits, axisMaxNits));

    return -1.0;
}

float GraphCurveNits(int row, int sampleIndex, float xNits)
{
    float4 projection = tex2Dfetch(SamplerGraphProjection, int2(sampleIndex, 0));
    float4 params = tex2Dfetch(SamplerGraphParams, int2(0, 0));

    if (row == GCURVE_SENT)
        return projection.x;
    if (row == GCURVE_PREDICTED)
        return projection.y;
    if (row == GCURVE_UNBOOSTED)
        return PredictedShownNits(GraphLimitedInputNits(xNits), params.z);

    float ceilingNits = PANEL_SIGNAL_PEAK_NITS / exp2(tex2Dfetch(SamplerBoostState, int2(0, 0)).w);
    return BT2390OutputNits(GraphLimitedInputNits(xNits), ClampedGraphAxisMaxNits(), ceilingNits);
}

float4 PS_GraphCurves(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    int s = int(vpos.x);
    int row = int(vpos.y);
    if (s >= GRAPH_CURVE_SAMPLES - 1 || (row == GCURVE_BT2390 && !GraphShowBT2390Reference))
        return -1.0;

    float axisMaxNits = ClampedGraphAxisMaxNits();
    float axisMaxPQ = GraphAxisMaxPQ();
    float x0 = GraphNitsAtFraction(float(s) / float(GRAPH_CURVE_SAMPLES - 1), axisMaxNits, axisMaxPQ);
    float x1 = GraphNitsAtFraction(float(s + 1) / float(GRAPH_CURVE_SAMPLES - 1), axisMaxNits, axisMaxPQ);
    float2 a = GraphPoint(axisMaxNits, axisMaxPQ, x0, GraphCurveNits(row, s, x0));
    float2 b = GraphPoint(axisMaxNits, axisMaxPQ, x1, GraphCurveNits(row, s + 1, x1));
    return float4(a, b);
}
#endif


// ---------------------------------------------------------------------------------------------------------------------
// Pass 5: boost, calibration LUT, dither and overlays
// ---------------------------------------------------------------------------------------------------------------------

float3 ApplyBoost(float3 color)
{
    float3 colorNits = DecodeBufferToRec2020Nits(color);
    float levelNits = Max3(max(colorNits, 0.0));
    if (levelNits <= 1e-6)
        return color;

    float gain = exp2(tex2Dfetch(SamplerBoostState, int2(0, 0)).w);
    float shownLevelNits = ShownLevelNits(levelNits, tex2Dfetch(SamplerToneShape, int2(0, 0)));
    if (gain == 1.0 && shownLevelNits == levelNits)
        return color;

    return EncodeRec2020NitsToBuffer(BoostRec2020Nits(colorNits, levelNits, shownLevelNits, gain));
}

// Maps a seed to [0, 1) with a 32-bit integer hash (Wellons' lowbias32).
float HashToUnit(uint seed)
{
    seed ^= seed >> 16;
    seed *= 0x7FEB352Du;
    seed ^= seed >> 15;
    seed *= 0x846CA68Bu;
    seed ^= seed >> 16;
    return float(seed >> 8) / 16777216.0;
}

// Triangular noise of one 10-bit code, the same on all channels so it adds no color noise, and the brightest code
// stays the signal peak. Within half a code of the peak the clamp would cut off the noise that rounds up, so there it
// is rectangular over half a code each way, which the clamp only cuts where it rounds to the peak anyway.
float3 DitherHDR10(float3 pq, float2 vpos)
{
    uint seed = uint(vpos.x) * 1973u + uint(vpos.y) * 9277u + uint(FrameCount) * 26699u;
    float peakPQ = NitsToPQ(PANEL_SIGNAL_PEAK_NITS);
    float rectangular = HashToUnit(seed) - 0.5;
    float triangular = HashToUnit(seed) + HashToUnit(seed ^ 0x9E3779B9u) - 1.0;
    float noise = (Max3(pq) > peakPQ - 0.5 / 1023.0) ? rectangular : triangular;
    return clamp(pq + noise / 1023.0, 0.0, peakPQ);
}

bool ShowsOverlay()
{
#if ENABLE_APL_GRAPH
    return ShowOSD || ShowAPLGraph;
#else
    return ShowOSD;
#endif
}

float3 DrawOverlays(float2 texcoord, float3 color)
{
    float3 nits = DecodeBufferToRec2020Nits(color);
    float3 drawn = nits;

    if (NeedsBoost() && ShowOSD)
        drawn = DrawStatsOverlay(texcoord, drawn, ReadOSDStats());

#if ENABLE_APL_GRAPH
    if (ShowAPLGraph)
        drawn = DrawGraphOverlay(texcoord, drawn);
#endif

    return all(drawn == nits) ? color : EncodeRec2020NitsToBuffer(min(drawn, PANEL_SIGNAL_PEAK_NITS));
}

float4 PS_Main(float4 vpos : SV_Position, float2 texcoord : TexCoord) : SV_Target
{
    float3 sourceColor = tex2Dfetch(ReShade::BackBuffer, int2(vpos.xy)).rgb;
    float3 color = sourceColor;

    if (NeedsBoost())
        color = ApplyBoost(color);

#if PQHDRLUT_ENABLE
    if (EnablePQHDRLUT)
        color = ApplyPQHDRLUT(color);
#endif

    // Only a pixel the boost or the LUT moved sits between codes, the rest is already exact.
#if BOOST_COLOR_SPACE != 2
    if (NeedsBoost() && any(color != sourceColor))
        color = DitherHDR10(color, vpos.xy);
#endif

    if (ShowsOverlay())
        color = DrawOverlays(texcoord, color);

    return float4(color, 1.0);
}


technique EOTF_Boost_3_1_27M2N6500
{
    pass Setup
    {
        ComputeShader = CS_Setup<HIST_BINS, 1, 1>;
        DispatchSizeX = 1;
        DispatchSizeY = 1;
    }

    pass RowHistogram
    {
        ComputeShader = CS_BuildRowHistogram<HIST_THREADS_X, HIST_THREADS_Y, 1>;
        DispatchSizeX = HIST_TILE_COUNT_X;
        DispatchSizeY = HIST_TILE_COUNT_Y;
    }

    pass GlobalHistogram
    {
        ComputeShader = CS_ReduceHistogram<HIST_REDUCE_THREADS, 1, 1>;
        DispatchSizeX = HIST_BLOCK_W;
        DispatchSizeY = HIST_BLOCK_H;
    }

    pass Solve
    {
        ComputeShader = CS_Solve<HIST_BINS, 1, 1>;
        DispatchSizeX = 1;
        DispatchSizeY = 1;
    }

#if ENABLE_APL_GRAPH
    pass GraphParams
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_GraphParams;
        RenderTarget = TexGraphParams;
    }

    pass GraphProjection
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_GraphProjection;
        RenderTarget = TexGraphProjection;
    }

    pass GraphLines
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_GraphLines;
        RenderTarget = TexGraphLines;
    }

    pass GraphCurves
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_GraphCurves;
        RenderTarget = TexGraphCurves;
    }
#endif

    pass Boost
    {
        VertexShader = PostProcessVS;
        PixelShader = PS_Main;
    }
}
