// Runs the DWM hook's boost pipeline on a saved HDR frame, as if the frame stayed on screen until the gain settles,
// and writes the boosted frame. Input and output are 16-bit PQ BT.2020 PNGs like ReShade's HDR screenshots.
//
//   RenderFrame <source.png> <boosted.png>

#include "pipeline.h"

#include <d3d11.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <DirectXPackedVector.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <string>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "windowscodecs.lib")

using Microsoft::WRL::ComPtr;
using DirectX::PackedVector::HALF;
using DirectX::PackedVector::XMConvertFloatToHalf;
using DirectX::PackedVector::XMConvertHalfToFloat;

namespace {

const double SCRGB_NITS = 80.0;
const int FRAMES = 200;
const int WOBBLE_FRAMES = 20;
const int TIMED_FRAMES = 100;
const int TIMED_BATCHES = 8;

// The peak boost.hlsl tonemaps into.
const double PANEL_PEAK_NITS = 1060.0;

const double PQ_M1 = 0.1593017578125, PQ_M2 = 78.84375;
const double PQ_C1 = 0.8359375, PQ_C2 = 18.8515625, PQ_C3 = 18.6875;

double PQToNits(double v)
{
    double vp = std::pow(std::clamp(v, 0.0, 1.0), 1.0 / PQ_M2);
    return std::pow(std::max(vp - PQ_C1, 0.0) / (PQ_C2 - PQ_C3 * vp), 1.0 / PQ_M1) * 10000.0;
}

double NitsToPQ(double nits)
{
    double lm1 = std::pow(std::clamp(nits / 10000.0, 0.0, 1.0), PQ_M1);
    return std::pow((PQ_C1 + PQ_C2 * lm1) / (1.0 + PQ_C3 * lm1), PQ_M2);
}

// The shaders' matrices, an exact inverse pair.
const double REC2020_TO_709[3][3] = {
    { 1.660490296, -0.587639106, -0.072851598 },
    { -0.124549970, 1.132899922, -0.008347964 },
    { -0.018151119, -0.100578724, 1.118729878 } };
const double REC709_TO_2020[3][3] = {
    { 0.6274040, 0.3292820, 0.0433136 },
    { 0.0690970, 0.9195400, 0.0113612 },
    { 0.0163916, 0.0880132, 0.8955950 } };

void Transform(const double m[3][3], const double in[3], double out[3])
{
    for (int r = 0; r < 3; ++r)
        out[r] = m[r][0] * in[0] + m[r][1] * in[1] + m[r][2] * in[2];
}

// 16-bit PQ BT.2020 RGB, three values per pixel.
struct Image
{
    UINT width = 0, height = 0;
    std::vector<uint16_t> rgb;
};

bool LoadPng(IWICImagingFactory* wic, const wchar_t* path, Image& img)
{
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(wic->CreateDecoderFromFilename(path, nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder)))
        return false;
    if (FAILED(decoder->GetFrame(0, &frame)))
        return false;

    WICPixelFormatGUID format;
    frame->GetPixelFormat(&format);
    if (format != GUID_WICPixelFormat48bppRGB)
    {
        fwprintf(stderr, L"%s is not a 16-bit RGB PNG\n", path);
        return false;
    }

    frame->GetSize(&img.width, &img.height);
    img.rgb.resize(size_t(img.width) * img.height * 3);
    return SUCCEEDED(frame->CopyPixels(nullptr, img.width * 6, UINT(img.rgb.size() * 2), (BYTE*)img.rgb.data()));
}

bool SavePng(IWICImagingFactory* wic, const wchar_t* path, const Image& img)
{
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapEncoder> encoder;
    ComPtr<IWICBitmapFrameEncode> frame;
    if (FAILED(wic->CreateStream(&stream)) || FAILED(stream->InitializeFromFilename(path, GENERIC_WRITE)))
        return false;
    if (FAILED(wic->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) || FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)))
        return false;
    if (FAILED(encoder->CreateNewFrame(&frame, nullptr)) || FAILED(frame->Initialize(nullptr)))
        return false;

    WICPixelFormatGUID format = GUID_WICPixelFormat48bppRGB;
    frame->SetSize(img.width, img.height);
    if (FAILED(frame->SetPixelFormat(&format)) || format != GUID_WICPixelFormat48bppRGB)
        return false;
    if (FAILED(frame->WritePixels(img.height, img.width * 6, UINT(img.rgb.size() * 2), (BYTE*)img.rgb.data())))
        return false;
    return SUCCEEDED(frame->Commit()) && SUCCEEDED(encoder->Commit());
}

std::vector<uint8_t> ReadFileBytes(const wchar_t* path)
{
    std::ifstream file(path, std::ios::binary);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>());
}

// A whole PNG chunk: length, type, data and CRC.
struct Chunk
{
    std::string type;
    std::vector<uint8_t> bytes;
};

std::vector<Chunk> SplitChunks(const std::vector<uint8_t>& png)
{
    std::vector<Chunk> chunks;
    for (size_t at = 8; at + 12 <= png.size();)
    {
        size_t length = (size_t(png[at]) << 24) | (size_t(png[at + 1]) << 16) | (size_t(png[at + 2]) << 8) | png[at + 3];
        size_t end = at + 12 + length;
        if (end > png.size())
            break;
        chunks.push_back({ std::string((const char*)&png[at + 4], 4), std::vector<uint8_t>(png.begin() + at, png.begin() + end) });
        at = end;
    }
    return chunks;
}

bool IsColorChunk(const std::string& type)
{
    return type == "iCCP" || type == "cICP" || type == "cHRM" || type == "sRGB" || type == "gAMA";
}

// Puts the source's color chunks in place of the encoder's, so viewers read the output as PQ BT.2020.
bool CopyColorChunks(const wchar_t* source, const wchar_t* target)
{
    std::vector<uint8_t> sourceBytes = ReadFileBytes(source);
    std::vector<uint8_t> targetBytes = ReadFileBytes(target);
    if (sourceBytes.size() < 8 || targetBytes.size() < 8)
        return false;

    std::vector<Chunk> targetChunks = SplitChunks(targetBytes);
    std::vector<uint8_t> out(targetBytes.begin(), targetBytes.begin() + 8);
    for (const Chunk& chunk : targetChunks)
    {
        if (IsColorChunk(chunk.type))
            continue;

        out.insert(out.end(), chunk.bytes.begin(), chunk.bytes.end());
        if (chunk.type != "IHDR")
            continue;

        for (const Chunk& color : SplitChunks(sourceBytes))
            if (IsColorChunk(color.type))
                out.insert(out.end(), color.bytes.begin(), color.bytes.end());
    }

    std::ofstream file(target, std::ios::binary | std::ios::trunc);
    file.write((const char*)out.data(), out.size());
    return bool(file);
}

// The scRGB the hook reads from DWM's back buffer, 1.0 at 80 nits in Rec.709 primaries.
std::vector<HALF> ToScRGB(const Image& img)
{
    std::vector<HALF> px(size_t(img.width) * img.height * 4);
    for (size_t i = 0; i < size_t(img.width) * img.height; ++i)
    {
        double rec2020[3], rec709[3];
        for (int c = 0; c < 3; ++c)
            rec2020[c] = PQToNits(img.rgb[i * 3 + c] / 65535.0);
        Transform(REC2020_TO_709, rec2020, rec709);

        for (int c = 0; c < 3; ++c)
            px[i * 4 + c] = XMConvertFloatToHalf(float(rec709[c] / SCRGB_NITS));
        px[i * 4 + 3] = XMConvertFloatToHalf(1.0f);
    }
    return px;
}

Image FromScRGB(const std::vector<HALF>& px, UINT width, UINT height)
{
    Image img;
    img.width = width; img.height = height;
    img.rgb.resize(size_t(width) * height * 3);
    for (size_t i = 0; i < size_t(width) * height; ++i)
    {
        double rec709[3], rec2020[3];
        for (int c = 0; c < 3; ++c)
            rec709[c] = XMConvertHalfToFloat(px[i * 4 + c]) * SCRGB_NITS;
        Transform(REC709_TO_2020, rec709, rec2020);

        for (int c = 0; c < 3; ++c)
            img.rgb[i * 3 + c] = uint16_t(std::lround(NitsToPQ(rec2020[c]) * 65535.0));
    }
    return img;
}

// Copies a texture to the CPU, rows packed.
template <class T>
std::vector<T> ReadBack(ID3D11Device* dev, ID3D11DeviceContext* ctx, ID3D11Texture2D* tex, UINT valuesPerTexel)
{
    D3D11_TEXTURE2D_DESC desc;
    tex->GetDesc(&desc);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

    ComPtr<ID3D11Texture2D> staging;
    std::vector<T> values(size_t(desc.Width) * desc.Height * valuesPerTexel);
    D3D11_MAPPED_SUBRESOURCE map;
    if (FAILED(dev->CreateTexture2D(&desc, nullptr, &staging)))
        return values;

    ctx->CopyResource(staging.Get(), tex);
    if (FAILED(ctx->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &map)))
        return values;

    const size_t rowValues = size_t(desc.Width) * valuesPerTexel;
    for (UINT y = 0; y < desc.Height; ++y)
        memcpy(&values[y * rowValues], (const uint8_t*)map.pData + size_t(y) * map.RowPitch, rowValues * sizeof(T));
    ctx->Unmap(staging.Get(), 0);
    return values;
}

// Half the smallest relative step between 10-bit PQ codes up to the panel peak, the most a gain may still move once
// it has settled.
double HalfCodeRatio()
{
    double smallest = 1.0;
    for (int code = 1; code < int(NitsToPQ(PANEL_PEAK_NITS) * 1023.0); ++code)
        smallest = std::min(smallest, PQToNits((code + 1) / 1023.0) / PQToNits(code / 1023.0) - 1.0);
    return 0.5 * smallest;
}

double RelativeGap(float gain, float reference)
{
    return std::fabs(double(gain) / reference - 1.0);
}

// Frames until the gain stays within half a 10-bit code of where it ends up.
int SettleFrames(const std::vector<float>& gains)
{
    const double tolerance = HalfCodeRatio();
    int frames = 1;
    for (size_t i = 0; i < gains.size(); ++i)
        if (RelativeGap(gains[i], gains.back()) > tolerance)
            frames = int(i) + 2;
    return frames;
}

// How far the gain still moves over the last frames, from float rounding in the loop.
double Wobble(const std::vector<float>& gains)
{
    double wobble = 0.0;
    for (size_t i = gains.size() - WOBBLE_FRAMES; i < gains.size(); ++i)
        wobble = std::max(wobble, RelativeGap(gains[i], gains.back()));
    return wobble;
}

// GPU milliseconds of one run of work, over a batch of runs that repeat the settled frame.
template <typename Work>
double TimeBatch(ID3D11Device* dev, ID3D11DeviceContext* ctx, Work work)
{
    ComPtr<ID3D11Query> disjoint, start, end;
    D3D11_QUERY_DESC desc = { D3D11_QUERY_TIMESTAMP_DISJOINT, 0 };
    dev->CreateQuery(&desc, &disjoint);
    desc.Query = D3D11_QUERY_TIMESTAMP;
    dev->CreateQuery(&desc, &start);
    dev->CreateQuery(&desc, &end);

    ctx->Begin(disjoint.Get());
    ctx->End(start.Get());
    for (int i = 0; i < TIMED_FRAMES; ++i)
        work();
    ctx->End(end.Get());
    ctx->End(disjoint.Get());

    D3D11_QUERY_DATA_TIMESTAMP_DISJOINT clock = {};
    UINT64 t0 = 0, t1 = 0;
    while (ctx->GetData(disjoint.Get(), &clock, sizeof(clock), 0) == S_FALSE) {}
    while (ctx->GetData(start.Get(), &t0, sizeof(t0), 0) == S_FALSE) {}
    while (ctx->GetData(end.Get(), &t1, sizeof(t1), 0) == S_FALSE) {}

    if (clock.Disjoint || clock.Frequency == 0)
        return -1.0;
    return double(t1 - t0) / double(clock.Frequency) * 1000.0 / TIMED_FRAMES;
}

// The fastest batch, since GPU clocks drift from batch to batch and from run to run.
template <typename Work>
double TimeGpu(ID3D11Device* dev, ID3D11DeviceContext* ctx, Work work)
{
    double best = -1.0;

    for (int batch = 0; batch < TIMED_BATCHES; ++batch)
    {
        double ms = TimeBatch(dev, ctx, work);
        if (ms >= 0.0 && (best < 0.0 || ms < best))
            best = ms;
    }

    return best;
}

int Run(const wchar_t* sourcePath, const wchar_t* outputPath)
{
    ComPtr<IWICImagingFactory> wic;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic))))
        return 1;

    Image source;
    if (!LoadPng(wic.Get(), sourcePath, source))
    {
        fwprintf(stderr, L"cannot read %s\n", sourcePath);
        return 1;
    }

    ComPtr<ID3D11Device> dev;
    ComPtr<ID3D11DeviceContext> ctx;
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &level, 1, D3D11_SDK_VERSION, &dev, nullptr, &ctx)))
        return 1;

    BoostPipeline pipe;
    if (!pipe.Create(dev.Get(), source.width, source.height))
        return 1;

    std::vector<HALF> scRGB = ToScRGB(source);
    ctx->UpdateSubresource(pipe.clean.t, 0, nullptr, scRGB.data(), source.width * 8, 0);

    D3D11_TEXTURE2D_DESC targetDesc = {};
    targetDesc.Width = source.width; targetDesc.Height = source.height; targetDesc.MipLevels = 1; targetDesc.ArraySize = 1;
    targetDesc.Format = DXGI_FORMAT_R16G16B16A16_FLOAT; targetDesc.SampleDesc.Count = 1;
    targetDesc.Usage = D3D11_USAGE_DEFAULT; targetDesc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> target;
    ComPtr<ID3D11RenderTargetView> rtv;
    if (FAILED(dev->CreateTexture2D(&targetDesc, nullptr, &target)) || FAILED(dev->CreateRenderTargetView(target.Get(), nullptr, &rtv)))
        return 1;

    // The first frame has no history, as when the hook starts on fresh content.
    std::vector<float> gains;
    for (int frame = 0; frame < FRAMES; ++frame)
    {
        pipe.Run(ctx.Get(), rtv.Get(), frame == 0, 1.0f);
        gains.push_back(ReadBack<float>(dev.Get(), ctx.Get(), pipe.boostParams.t, 4)[0]);
    }

    std::vector<float> apl = ReadBack<float>(dev.Get(), ctx.Get(), pipe.aplInstant.t, 4);
    std::vector<float> params = ReadBack<float>(dev.Get(), ctx.Get(), pipe.boostParams.t, 4);
    double gpuMs = TimeGpu(dev.Get(), ctx.Get(), [&] { pipe.Run(ctx.Get(), rtv.Get(), false, 1.0f); });
    double solveMs = TimeGpu(dev.Get(), ctx.Get(), [&] { pipe.Solve(ctx.Get()); });

    Image boosted = FromScRGB(ReadBack<HALF>(dev.Get(), ctx.Get(), target.Get(), 4), source.width, source.height);
    if (!SavePng(wic.Get(), outputPath, boosted) || !CopyColorChunks(sourcePath, outputPath))
    {
        fwprintf(stderr, L"cannot write %s\n", outputPath);
        return 1;
    }

    wprintf(L"raw_apl %.6f out_apl %.6f gain %.6f comp %.6f knee_nits %.3f departure_nits %.3f settle_frames %d wobble %.1e gpu_ms %.4f solve_ms %.4f\n",
            apl[0], apl[1], params[0], params[6], params[2], PQToNits(params[5]), SettleFrames(gains), Wobble(gains), gpuMs, solveMs);
    return 0;
}

} // namespace

int wmain(int argc, wchar_t** argv)
{
    if (argc != 3)
    {
        fwprintf(stderr, L"usage: RenderFrame <source.png> <boosted.png>\n");
        return 2;
    }

    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)))
        return 1;

    int result = Run(argv[1], argv[2]);
    CoUninitialize();
    return result;
}
