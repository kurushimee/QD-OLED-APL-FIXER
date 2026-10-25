// Runs a ReShade effect on a saved HDR frame the way ReShade 6.8 runs it in a D3D11 game in performance mode, as if the
// frame stayed on screen until the effect's output stops changing, and writes that output. Input and output are 16-bit
// PQ BT.2020 PNGs like ReShade's HDR screenshots.
//
//   RenderEffect <effect.fx> <scrgb|hdr10> <source.png> <output.png> [-D NAME=VALUE ...] [name=value ...]
//
// scrgb runs the effect on an FP16 scRGB back buffer (BUFFER_COLOR_SPACE 2), hdr10 on a 10-bit PQ one (3). -D adds a
// preprocessor definition and name=value sets a uniform like a preset line, with vector components comma separated.

#include "effect_codegen.hpp"
#include "effect_parser.hpp"
#include "effect_preprocessor.hpp"

#include <d3d11.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <DirectXPackedVector.h>

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

using Microsoft::WRL::ComPtr;
using DirectX::PackedVector::HALF;
using DirectX::PackedVector::XMConvertFloatToHalf;
using DirectX::PackedVector::XMConvertHalfToFloat;

namespace {

const char* const RESHADE_VERSION = "60800";
const float FRAME_MS = 1000.0f / 60.0f;

// The output counts as settled once it holds still this long, and the run gives up after a minute.
const int HOLD_FRAMES = 60;
const int MAX_FRAMES = 3600;

const double SCRGB_NITS = 80.0;

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

enum class ColorSpace { ScRGB = 2, HDR10 = 3 };

struct Args
{
    std::filesystem::path effect, source, output;
    ColorSpace colorSpace = ColorSpace::HDR10;
    std::vector<std::pair<std::string, std::string>> definitions;
    std::vector<std::pair<std::string, std::string>> settings;
};

bool SplitAssignment(const std::string& text, std::pair<std::string, std::string>& assignment)
{
    size_t equals = text.find('=');
    if (equals == std::string::npos || equals == 0)
        return false;

    assignment = { text.substr(0, equals), text.substr(equals + 1) };
    return true;
}

std::string Narrow(const wchar_t* text)
{
    return std::filesystem::path(text).u8string();
}

bool ParseArgs(int argc, wchar_t** argv, Args& args)
{
    if (argc < 5)
        return false;

    args.effect = argv[1];
    args.source = argv[3];
    args.output = argv[4];

    std::wstring colorSpace = argv[2];
    if (colorSpace == L"scrgb")
        args.colorSpace = ColorSpace::ScRGB;
    else if (colorSpace != L"hdr10")
        return false;

    for (int i = 5; i < argc; ++i)
    {
        bool isDefinition = std::wcscmp(argv[i], L"-D") == 0;
        if (isDefinition && ++i == argc)
            return false;

        std::pair<std::string, std::string> assignment;
        if (!SplitAssignment(Narrow(argv[i]), assignment))
            return false;

        (isDefinition ? args.definitions : args.settings).push_back(assignment);
    }
    return true;
}

// 16-bit PQ BT.2020 RGB, three values per pixel.
struct Image
{
    UINT width = 0, height = 0;
    std::vector<uint16_t> rgb;
};

bool LoadPng(IWICImagingFactory* wic, const std::filesystem::path& path, Image& img)
{
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(wic->CreateDecoderFromFilename(path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand, &decoder)))
        return false;
    if (FAILED(decoder->GetFrame(0, &frame)))
        return false;

    WICPixelFormatGUID format;
    frame->GetPixelFormat(&format);
    if (format != GUID_WICPixelFormat48bppRGB)
    {
        fwprintf(stderr, L"%s is not a 16-bit RGB PNG\n", path.c_str());
        return false;
    }

    frame->GetSize(&img.width, &img.height);
    img.rgb.resize(size_t(img.width) * img.height * 3);
    return SUCCEEDED(frame->CopyPixels(nullptr, img.width * 6, UINT(img.rgb.size() * 2), (BYTE*)img.rgb.data()));
}

bool SavePng(IWICImagingFactory* wic, const std::filesystem::path& path, const Image& img)
{
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapEncoder> encoder;
    ComPtr<IWICBitmapFrameEncode> frame;
    if (FAILED(wic->CreateStream(&stream)) || FAILED(stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE)))
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

std::vector<uint8_t> ReadFileBytes(const std::filesystem::path& path)
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
bool CopyColorChunks(const std::filesystem::path& source, const std::filesystem::path& target)
{
    std::vector<uint8_t> sourceBytes = ReadFileBytes(source);
    std::vector<uint8_t> targetBytes = ReadFileBytes(target);
    if (sourceBytes.size() < 8 || targetBytes.size() < 8)
        return false;

    std::vector<uint8_t> out(targetBytes.begin(), targetBytes.begin() + 8);
    for (const Chunk& chunk : SplitChunks(targetBytes))
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

DXGI_FORMAT BackBufferFormat(ColorSpace colorSpace)
{
    return colorSpace == ColorSpace::ScRGB ? DXGI_FORMAT_R16G16B16A16_FLOAT : DXGI_FORMAT_R10G10B10A2_UNORM;
}

UINT BackBufferTexelSize(ColorSpace colorSpace)
{
    return colorSpace == ColorSpace::ScRGB ? 8 : 4;
}

// The frame as the game hands it to ReShade: 10-bit PQ for HDR10, Rec.709 at 1.0 = 80 nits in FP16 for scRGB.
std::vector<uint8_t> ToBackBuffer(const Image& img, ColorSpace colorSpace)
{
    const size_t pixels = size_t(img.width) * img.height;
    std::vector<uint8_t> texels(pixels * BackBufferTexelSize(colorSpace));

    for (size_t i = 0; i < pixels; ++i)
    {
        const uint16_t* pq = &img.rgb[i * 3];

        if (colorSpace == ColorSpace::HDR10)
        {
            uint32_t packed = 3u << 30;
            for (int c = 0; c < 3; ++c)
                packed |= ((uint32_t(pq[c]) * 1023 + 32767) / 65535) << (10 * c);
            memcpy(&texels[i * 4], &packed, 4);
            continue;
        }

        double rec2020[3], rec709[3];
        for (int c = 0; c < 3; ++c)
            rec2020[c] = PQToNits(pq[c] / 65535.0);
        Transform(REC2020_TO_709, rec2020, rec709);

        HALF half[4] = { 0, 0, 0, XMConvertFloatToHalf(1.0f) };
        for (int c = 0; c < 3; ++c)
            half[c] = XMConvertFloatToHalf(float(rec709[c] / SCRGB_NITS));
        memcpy(&texels[i * 8], half, 8);
    }
    return texels;
}

Image FromBackBuffer(const std::vector<uint8_t>& texels, UINT width, UINT height, ColorSpace colorSpace)
{
    Image img;
    img.width = width;
    img.height = height;
    img.rgb.resize(size_t(width) * height * 3);

    for (size_t i = 0; i < size_t(width) * height; ++i)
    {
        uint16_t* pq = &img.rgb[i * 3];

        if (colorSpace == ColorSpace::HDR10)
        {
            uint32_t packed;
            memcpy(&packed, &texels[i * 4], 4);
            for (int c = 0; c < 3; ++c)
                pq[c] = uint16_t((((packed >> (10 * c)) & 1023) * 65535 + 511) / 1023);
            continue;
        }

        HALF half[4];
        memcpy(half, &texels[i * 8], 8);

        double rec709[3], rec2020[3];
        for (int c = 0; c < 3; ++c)
            rec709[c] = XMConvertHalfToFloat(half[c]) * SCRGB_NITS;
        Transform(REC709_TO_2020, rec709, rec2020);

        for (int c = 0; c < 3; ++c)
            pq[c] = uint16_t(std::lround(NitsToPQ(rec2020[c]) * 65535.0));
    }
    return img;
}

// HDR10 holds exactly. FP16 may keep flipping a last bit from float rounding in the effect's state, far below one
// 10-bit PQ step, so one unit of difference still counts as the same signal.
bool SameSignal(const std::vector<uint8_t>& a, const std::vector<uint8_t>& b, ColorSpace colorSpace)
{
    if (a.size() != b.size())
        return false;

    if (colorSpace == ColorSpace::HDR10)
        return a == b;

    const uint16_t* ha = (const uint16_t*)a.data();
    const uint16_t* hb = (const uint16_t*)b.data();
    for (size_t i = 0; i < a.size() / 2; ++i)
        if (std::abs(int(ha[i]) - int(hb[i])) > 1)
            return false;
    return true;
}

bool ParseComponent(const std::string& text, reshadefx::type::datatype base, reshadefx::constant& value, size_t index)
{
    const char* first = text.data();
    const char* last = first + text.size();

    switch (base)
    {
    case reshadefx::type::t_bool:
    case reshadefx::type::t_uint:
        return std::from_chars(first, last, value.as_uint[index]).ec == std::errc();
    case reshadefx::type::t_int:
        return std::from_chars(first, last, value.as_int[index]).ec == std::errc();
    case reshadefx::type::t_float:
        return std::from_chars(first, last, value.as_float[index]).ec == std::errc();
    default:
        return false;
    }
}

// In performance mode a uniform with a default value is a specialization constant, set the way a preset line sets it.
bool ApplySetting(const std::pair<std::string, std::string>& setting, std::vector<reshadefx::uniform>& specConstants)
{
    auto constant = std::find_if(specConstants.begin(), specConstants.end(),
        [&](const reshadefx::uniform& candidate) { return candidate.name == setting.first; });
    if (constant == specConstants.end())
    {
        fprintf(stderr, "no setting named %s\n", setting.first.c_str());
        return false;
    }

    std::vector<std::string> components;
    for (size_t start = 0, end; start <= setting.second.size(); start = end + 1)
    {
        end = std::min(setting.second.find(',', start), setting.second.size());
        components.push_back(setting.second.substr(start, end - start));
    }

    bool parsed = components.size() == constant->type.components();
    for (size_t i = 0; parsed && i < components.size(); ++i)
        parsed = ParseComponent(components[i], constant->type.base, constant->initializer_value, i);

    if (!parsed)
        fprintf(stderr, "%s cannot take %s\n", setting.first.c_str(), setting.second.c_str());
    return parsed;
}

struct CompiledEffect
{
    reshadefx::effect_module module;
    std::map<std::string, std::string> bytecode;
};

bool CompileEffect(const Args& args, UINT width, UINT height, CompiledEffect& compiled)
{
    reshadefx::preprocessor pp;

    // Definitions passed in come first since the first definition of a name wins, as ReShade does with a preset's.
    for (const auto& definition : args.definitions)
        pp.add_macro_definition(definition.first, definition.second);

    pp.add_macro_definition("__RESHADE__", RESHADE_VERSION);
    pp.add_macro_definition("BUFFER_WIDTH", std::to_string(width));
    pp.add_macro_definition("BUFFER_HEIGHT", std::to_string(height));
    pp.add_macro_definition("BUFFER_RCP_WIDTH", "(1.0 / BUFFER_WIDTH)");
    pp.add_macro_definition("BUFFER_RCP_HEIGHT", "(1.0 / BUFFER_HEIGHT)");
    pp.add_macro_definition("BUFFER_COLOR_SPACE", std::to_string(int(args.colorSpace)));
    pp.add_include_path(std::filesystem::absolute(args.effect).parent_path());
    pp.add_include_path(RESHADE_FXH_DIR);

    if (!pp.append_file(args.effect))
    {
        fprintf(stderr, "%s", pp.errors().c_str());
        return false;
    }

    std::unique_ptr<reshadefx::codegen> codegen(reshadefx::create_codegen_dxbc(50, false, true, 3));
    reshadefx::parser parser;
    if (!parser.parse(pp.output(), codegen.get()))
    {
        fprintf(stderr, "%s%s", pp.errors().c_str(), parser.errors().c_str());
        return false;
    }

    for (const auto& setting : args.settings)
        if (!ApplySetting(setting, codegen->module().spec_constants))
            return false;

    for (const auto& entryPoint : codegen->module().entry_points)
    {
        std::string cso, assembly, errors;
        if (!codegen->assemble_code_for_entry_point(entryPoint.first, cso, assembly, errors))
        {
            fprintf(stderr, "%s\n%s", entryPoint.first.c_str(), errors.c_str());
            return false;
        }
        compiled.bytecode[entryPoint.first] = std::move(cso);
    }

    compiled.module = codegen->module();
    return true;
}

std::string AnnotationString(const std::vector<reshadefx::annotation>& annotations, const char* name)
{
    for (const reshadefx::annotation& annotation : annotations)
        if (annotation.name == name)
            return annotation.value.string_data;
    return std::string();
}

struct Texture
{
    UINT width = 0, height = 0;
    ComPtr<ID3D11Texture2D> resource;
    ComPtr<ID3D11ShaderResourceView> srv;
    ComPtr<ID3D11RenderTargetView> rtv;
    ComPtr<ID3D11UnorderedAccessView> uav;
};

bool CreateTexture(ID3D11Device* dev, UINT width, UINT height, DXGI_FORMAT format, UINT bindFlags, Texture& tex)
{
    D3D11_TEXTURE2D_DESC desc = {};
    desc.Width = width;
    desc.Height = height;
    desc.MipLevels = 1;
    desc.ArraySize = 1;
    desc.Format = format;
    desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = bindFlags;

    tex.width = width;
    tex.height = height;
    if (FAILED(dev->CreateTexture2D(&desc, nullptr, &tex.resource)))
        return false;

    bool ok = true;
    if (bindFlags & D3D11_BIND_SHADER_RESOURCE)
        ok = ok && SUCCEEDED(dev->CreateShaderResourceView(tex.resource.Get(), nullptr, &tex.srv));
    if (bindFlags & D3D11_BIND_RENDER_TARGET)
        ok = ok && SUCCEEDED(dev->CreateRenderTargetView(tex.resource.Get(), nullptr, &tex.rtv));
    if (bindFlags & D3D11_BIND_UNORDERED_ACCESS)
        ok = ok && SUCCEEDED(dev->CreateUnorderedAccessView(tex.resource.Get(), nullptr, &tex.uav));
    return ok;
}

class EffectRunner
{
public:
    bool Create(ID3D11Device* dev, ID3D11DeviceContext* ctx, const CompiledEffect& compiled, const Texture& backBuffer)
    {
        _module = compiled.module;
        _backBuffer = &backBuffer;

        if (_module.techniques.size() != 1)
        {
            fprintf(stderr, "the effect has %zu techniques, RenderEffect runs exactly one\n", _module.techniques.size());
            return false;
        }

        return CreateTextures(dev, ctx) && CreateSamplers(dev) && CreateShaders(dev, compiled) && CreatePassStates(dev) &&
               CreateConstants(dev);
    }

    void Render(ID3D11DeviceContext* ctx)
    {
        if (_constants)
            ctx->UpdateSubresource(_constants.Get(), 0, nullptr, _constantData.data(), 0, 0);

        // The back buffer copy is refreshed before the first pass and after every pass that drew to the back buffer.
        bool backBufferChanged = true;
        const std::vector<reshadefx::pass>& passes = _module.techniques[0].passes;
        for (size_t i = 0; i < passes.size(); ++i)
        {
            if (backBufferChanged && _colorTexture)
                ctx->CopyResource(_colorTexture->resource.Get(), _backBuffer->resource.Get());

            if (!passes[i].cs_entry_point.empty())
            {
                RenderCompute(ctx, passes[i]);
                backBufferChanged = false;
            }
            else
            {
                RenderGraphics(ctx, passes[i], _blendStates[i].Get());
                backBufferChanged = passes[i].render_target_names[0].empty();
            }
        }
    }

private:
    reshadefx::effect_module _module;
    const Texture* _backBuffer = nullptr;
    const Texture* _colorTexture = nullptr;
    std::map<std::string, Texture> _textures;
    std::vector<ComPtr<ID3D11SamplerState>> _samplers;
    std::map<std::string, ComPtr<ID3D11ComputeShader>> _computeShaders;
    std::map<std::string, ComPtr<ID3D11VertexShader>> _vertexShaders;
    std::map<std::string, ComPtr<ID3D11PixelShader>> _pixelShaders;
    std::vector<ComPtr<ID3D11BlendState>> _blendStates;
    ComPtr<ID3D11RasterizerState> _rasterizer;
    ComPtr<ID3D11Buffer> _constants;
    std::vector<uint8_t> _constantData;

    bool CreateTextures(ID3D11Device* dev, ID3D11DeviceContext* ctx)
    {
        for (const reshadefx::texture& info : _module.textures)
        {
            if (info.semantic == "DEPTH")
                continue;

            if (info.semantic == "COLOR")
            {
                D3D11_TEXTURE2D_DESC desc;
                _backBuffer->resource->GetDesc(&desc);
                if (!CreateTexture(dev, desc.Width, desc.Height, desc.Format, D3D11_BIND_SHADER_RESOURCE, _textures[info.unique_name]))
                    return false;
                _colorTexture = &_textures[info.unique_name];
                continue;
            }

            if (!info.semantic.empty() || !AnnotationString(info.annotations, "source").empty() ||
                info.type != reshadefx::texture_type::texture_2d || info.levels > 1)
            {
                fprintf(stderr, "%s: RenderEffect supports plain 2D textures without mipmaps only\n", info.unique_name.c_str());
                return false;
            }

            UINT bindFlags = D3D11_BIND_SHADER_RESOURCE;
            if (info.render_target)
                bindFlags |= D3D11_BIND_RENDER_TARGET;
            if (info.storage_access)
                bindFlags |= D3D11_BIND_UNORDERED_ACCESS;

            // ReShade's texture formats carry the DXGI format numbers.
            Texture& tex = _textures[info.unique_name];
            if (!CreateTexture(dev, info.width, info.height, DXGI_FORMAT(info.format), bindFlags, tex))
            {
                fprintf(stderr, "%s: cannot create the texture\n", info.unique_name.c_str());
                return false;
            }

            if (tex.uav)
            {
                const UINT zero[4] = {};
                ctx->ClearUnorderedAccessViewUint(tex.uav.Get(), zero);
            }
            else if (tex.rtv)
            {
                const float zero[4] = {};
                ctx->ClearRenderTargetView(tex.rtv.Get(), zero);
            }
        }
        return true;
    }

    bool CreateSamplers(ID3D11Device* dev)
    {
        for (const reshadefx::pass& pass : _module.techniques[0].passes)
        {
            for (const reshadefx::sampler_binding& binding : pass.sampler_bindings)
            {
                if (binding.entry_point_binding < _samplers.size() && _samplers[binding.entry_point_binding])
                    continue;

                // ReShade's filter and address modes carry the D3D11 numbers.
                const reshadefx::sampler& info = _module.samplers[binding.index];
                D3D11_SAMPLER_DESC desc = {};
                desc.Filter = D3D11_FILTER(info.filter);
                desc.AddressU = D3D11_TEXTURE_ADDRESS_MODE(info.address_u);
                desc.AddressV = D3D11_TEXTURE_ADDRESS_MODE(info.address_v);
                desc.AddressW = D3D11_TEXTURE_ADDRESS_MODE(info.address_w);
                desc.MipLODBias = info.lod_bias;
                desc.MaxAnisotropy = 16;
                desc.ComparisonFunc = D3D11_COMPARISON_NEVER;
                desc.MinLOD = info.min_lod;
                desc.MaxLOD = info.max_lod;

                _samplers.resize(std::max<size_t>(_samplers.size(), binding.entry_point_binding + 1));
                if (FAILED(dev->CreateSamplerState(&desc, &_samplers[binding.entry_point_binding])))
                    return false;
            }
        }
        return true;
    }

    bool CreateShaders(ID3D11Device* dev, const CompiledEffect& compiled)
    {
        for (const auto& entryPoint : _module.entry_points)
        {
            const std::string& code = compiled.bytecode.at(entryPoint.first);
            HRESULT hr = E_FAIL;

            switch (entryPoint.second)
            {
            case reshadefx::shader_type::compute:
                hr = dev->CreateComputeShader(code.data(), code.size(), nullptr, &_computeShaders[entryPoint.first]);
                break;
            case reshadefx::shader_type::vertex:
                hr = dev->CreateVertexShader(code.data(), code.size(), nullptr, &_vertexShaders[entryPoint.first]);
                break;
            case reshadefx::shader_type::pixel:
                hr = dev->CreatePixelShader(code.data(), code.size(), nullptr, &_pixelShaders[entryPoint.first]);
                break;
            default:
                break;
            }

            if (FAILED(hr))
            {
                fprintf(stderr, "%s: cannot create the shader\n", entryPoint.first.c_str());
                return false;
            }
        }
        return true;
    }

    bool CreatePassStates(ID3D11Device* dev)
    {
        for (const reshadefx::pass& pass : _module.techniques[0].passes)
        {
            bool blends = std::find(std::begin(pass.blend_enable), std::end(pass.blend_enable), true) != std::end(pass.blend_enable);
            if (blends || pass.srgb_write_enable || pass.stencil_enable)
            {
                fprintf(stderr, "%s: RenderEffect supports passes without blending, sRGB writes or stencil only\n", pass.name.c_str());
                return false;
            }

            D3D11_BLEND_DESC desc = {};
            desc.IndependentBlendEnable = TRUE;
            for (int i = 0; i < 8; ++i)
                desc.RenderTarget[i].RenderTargetWriteMask = pass.render_target_write_mask[i];

            _blendStates.emplace_back();
            if (FAILED(dev->CreateBlendState(&desc, &_blendStates.back())))
                return false;
        }

        D3D11_RASTERIZER_DESC desc = {};
        desc.FillMode = D3D11_FILL_SOLID;
        desc.CullMode = D3D11_CULL_NONE;
        desc.DepthClipEnable = TRUE;
        return SUCCEEDED(dev->CreateRasterizerState(&desc, &_rasterizer));
    }

    bool CreateConstants(ID3D11Device* dev)
    {
        if (_module.total_uniform_size == 0)
            return true;

        _constantData.assign((_module.total_uniform_size + 15) & ~15u, 0);
        for (const reshadefx::uniform& info : _module.uniforms)
        {
            std::string source = AnnotationString(info.annotations, "source");
            if (source == "frametime")
            {
                memcpy(&_constantData[info.offset], &FRAME_MS, sizeof(FRAME_MS));
            }
            else if (!source.empty())
            {
                fprintf(stderr, "%s: RenderEffect has no uniform source %s\n", info.name.c_str(), source.c_str());
                return false;
            }
        }

        D3D11_BUFFER_DESC desc = {};
        desc.ByteWidth = UINT(_constantData.size());
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        return SUCCEEDED(dev->CreateBuffer(&desc, nullptr, &_constants));
    }

    std::vector<ID3D11ShaderResourceView*> PassResourceViews(const reshadefx::pass& pass) const
    {
        std::vector<ID3D11ShaderResourceView*> views;
        for (const reshadefx::texture_binding& binding : pass.texture_bindings)
        {
            views.resize(std::max<size_t>(views.size(), binding.entry_point_binding + 1), nullptr);

            auto tex = _textures.find(_module.samplers[binding.index].texture_name);
            if (tex != _textures.end())
                views[binding.entry_point_binding] = tex->second.srv.Get();
        }
        return views;
    }

    std::vector<ID3D11UnorderedAccessView*> PassStorageViews(const reshadefx::pass& pass) const
    {
        std::vector<ID3D11UnorderedAccessView*> views;
        for (const reshadefx::storage_binding& binding : pass.storage_bindings)
        {
            views.resize(std::max<size_t>(views.size(), binding.entry_point_binding + 1), nullptr);
            views[binding.entry_point_binding] = _textures.at(_module.storages[binding.index].texture_name).uav.Get();
        }
        return views;
    }

    std::vector<ID3D11SamplerState*> SamplerStates() const
    {
        std::vector<ID3D11SamplerState*> states;
        for (const ComPtr<ID3D11SamplerState>& state : _samplers)
            states.push_back(state.Get());
        return states;
    }

    void RenderCompute(ID3D11DeviceContext* ctx, const reshadefx::pass& pass)
    {
        std::vector<ID3D11ShaderResourceView*> srvs = PassResourceViews(pass);
        std::vector<ID3D11UnorderedAccessView*> uavs = PassStorageViews(pass);
        std::vector<ID3D11SamplerState*> samplers = SamplerStates();

        ctx->CSSetShader(_computeShaders.at(pass.cs_entry_point).Get(), nullptr, 0);
        ctx->CSSetConstantBuffers(0, 1, _constants.GetAddressOf());
        ctx->CSSetSamplers(0, UINT(samplers.size()), samplers.data());
        ctx->CSSetShaderResources(0, UINT(srvs.size()), srvs.data());
        ctx->CSSetUnorderedAccessViews(0, UINT(uavs.size()), uavs.data(), nullptr);

        ctx->Dispatch(pass.viewport_width, pass.viewport_height, pass.viewport_dispatch_z);

        std::fill(srvs.begin(), srvs.end(), nullptr);
        std::fill(uavs.begin(), uavs.end(), nullptr);
        ctx->CSSetShaderResources(0, UINT(srvs.size()), srvs.data());
        ctx->CSSetUnorderedAccessViews(0, UINT(uavs.size()), uavs.data(), nullptr);
    }

    void RenderGraphics(ID3D11DeviceContext* ctx, const reshadefx::pass& pass, ID3D11BlendState* blend)
    {
        std::vector<ID3D11RenderTargetView*> rtvs;
        UINT width = _backBuffer->width, height = _backBuffer->height;
        if (pass.render_target_names[0].empty())
        {
            rtvs.push_back(_backBuffer->rtv.Get());
        }
        else
        {
            for (int i = 0; i < 8 && !pass.render_target_names[i].empty(); ++i)
                rtvs.push_back(_textures.at(pass.render_target_names[i]).rtv.Get());
            width = _textures.at(pass.render_target_names[0]).width;
            height = _textures.at(pass.render_target_names[0]).height;
        }

        if (pass.clear_render_targets)
        {
            const float zero[4] = {};
            for (ID3D11RenderTargetView* rtv : rtvs)
                ctx->ClearRenderTargetView(rtv, zero);
        }

        D3D11_VIEWPORT viewport = {};
        viewport.Width = float(pass.viewport_width != 0 ? pass.viewport_width : width);
        viewport.Height = float(pass.viewport_height != 0 ? pass.viewport_height : height);
        viewport.MaxDepth = 1.0f;

        std::vector<ID3D11ShaderResourceView*> srvs = PassResourceViews(pass);
        std::vector<ID3D11SamplerState*> samplers = SamplerStates();

        ctx->OMSetRenderTargets(UINT(rtvs.size()), rtvs.data(), nullptr);
        ctx->OMSetBlendState(blend, nullptr, 0xFFFFFFFF);
        ctx->RSSetState(_rasterizer.Get());
        ctx->RSSetViewports(1, &viewport);
        ctx->IASetInputLayout(nullptr);
        ctx->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY(pass.topology));
        ctx->VSSetShader(_vertexShaders.at(pass.vs_entry_point).Get(), nullptr, 0);
        ctx->PSSetShader(pass.ps_entry_point.empty() ? nullptr : _pixelShaders.at(pass.ps_entry_point).Get(), nullptr, 0);
        ctx->VSSetConstantBuffers(0, 1, _constants.GetAddressOf());
        ctx->PSSetConstantBuffers(0, 1, _constants.GetAddressOf());
        ctx->VSSetSamplers(0, UINT(samplers.size()), samplers.data());
        ctx->PSSetSamplers(0, UINT(samplers.size()), samplers.data());
        ctx->VSSetShaderResources(0, UINT(srvs.size()), srvs.data());
        ctx->PSSetShaderResources(0, UINT(srvs.size()), srvs.data());

        ctx->Draw(pass.num_vertices, 0);

        std::fill(srvs.begin(), srvs.end(), nullptr);
        ctx->VSSetShaderResources(0, UINT(srvs.size()), srvs.data());
        ctx->PSSetShaderResources(0, UINT(srvs.size()), srvs.data());
        ctx->OMSetRenderTargets(0, nullptr, nullptr);
    }
};

std::vector<uint8_t> ReadBack(ID3D11Device* dev, ID3D11DeviceContext* ctx, ID3D11Texture2D* staging, ID3D11Texture2D* tex, UINT texelSize)
{
    D3D11_TEXTURE2D_DESC desc;
    tex->GetDesc(&desc);
    ctx->CopyResource(staging, tex);

    std::vector<uint8_t> bytes(size_t(desc.Width) * desc.Height * texelSize);
    D3D11_MAPPED_SUBRESOURCE map;
    if (FAILED(ctx->Map(staging, 0, D3D11_MAP_READ, 0, &map)))
        return bytes;

    const size_t rowBytes = size_t(desc.Width) * texelSize;
    for (UINT y = 0; y < desc.Height; ++y)
        memcpy(&bytes[y * rowBytes], (const uint8_t*)map.pData + size_t(y) * map.RowPitch, rowBytes);
    ctx->Unmap(staging, 0);
    return bytes;
}

int Run(const Args& args)
{
    ComPtr<IWICImagingFactory> wic;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic))))
        return 1;

    Image source;
    if (!LoadPng(wic.Get(), args.source, source))
    {
        fwprintf(stderr, L"cannot read %s\n", args.source.c_str());
        return 1;
    }

    CompiledEffect compiled;
    if (!CompileEffect(args, source.width, source.height, compiled))
        return 1;

    ComPtr<ID3D11Device> dev;
    ComPtr<ID3D11DeviceContext> ctx;
    D3D_FEATURE_LEVEL level = D3D_FEATURE_LEVEL_11_0;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, &level, 1, D3D11_SDK_VERSION, &dev, nullptr, &ctx)))
        return 1;

    const DXGI_FORMAT format = BackBufferFormat(args.colorSpace);
    const UINT texelSize = BackBufferTexelSize(args.colorSpace);
    Texture backBuffer;
    if (!CreateTexture(dev.Get(), source.width, source.height, format, D3D11_BIND_RENDER_TARGET, backBuffer))
        return 1;

    D3D11_TEXTURE2D_DESC stagingDesc;
    backBuffer.resource->GetDesc(&stagingDesc);
    stagingDesc.Usage = D3D11_USAGE_STAGING;
    stagingDesc.BindFlags = 0;
    stagingDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;
    if (FAILED(dev->CreateTexture2D(&stagingDesc, nullptr, &staging)))
        return 1;

    EffectRunner effect;
    if (!effect.Create(dev.Get(), ctx.Get(), compiled, backBuffer))
        return 1;

    // The game draws the same frame every time and the effect runs on it until its output holds still.
    const std::vector<uint8_t> frame = ToBackBuffer(source, args.colorSpace);
    std::vector<uint8_t> previous, current;
    int frames = 0, unchanged = 0;
    for (; frames < MAX_FRAMES && unchanged < HOLD_FRAMES; ++frames)
    {
        ctx->UpdateSubresource(backBuffer.resource.Get(), 0, nullptr, frame.data(), source.width * texelSize, 0);
        effect.Render(ctx.Get());

        current = ReadBack(dev.Get(), ctx.Get(), staging.Get(), backBuffer.resource.Get(), texelSize);
        unchanged = SameSignal(previous, current, args.colorSpace) ? unchanged + 1 : 0;
        std::swap(previous, current);
    }

    Image output = FromBackBuffer(previous, source.width, source.height, args.colorSpace);
    if (!SavePng(wic.Get(), args.output, output) || !CopyColorChunks(args.source, args.output))
    {
        fwprintf(stderr, L"cannot write %s\n", args.output.c_str());
        return 1;
    }

    if (unchanged < HOLD_FRAMES)
    {
        fprintf(stderr, "output still changing after %d frames\n", frames);
        return 3;
    }

    const int settled = frames - HOLD_FRAMES;
    printf("settled after %d frames (%.2f s)\n", settled, settled * FRAME_MS / 1000.0f);
    return 0;
}

} // namespace

int wmain(int argc, wchar_t** argv)
{
    Args args;
    if (!ParseArgs(argc, argv, args))
    {
        fwprintf(stderr, L"usage: RenderEffect <effect.fx> <scrgb|hdr10> <source.png> <output.png> [-D NAME=VALUE ...] [name=value ...]\n");
        return 2;
    }

    if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED)))
        return 1;

    int result = Run(args);
    CoUninitialize();
    return result;
}
