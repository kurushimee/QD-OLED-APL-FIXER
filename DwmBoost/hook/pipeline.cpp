#include "pipeline.h"
#include "boost_bytecode.h"

#include <cstdint>
#include <cstring>

namespace {

bool CreateTex(ID3D11Device* dev, UINT w, UINT h, DXGI_FORMAT fmt, bool wantSRV, bool wantUAV, Tex& out)
{
    D3D11_TEXTURE2D_DESC d = {};
    d.Width = w; d.Height = h; d.MipLevels = 1; d.ArraySize = 1;
    d.Format = fmt; d.SampleDesc.Count = 1; d.Usage = D3D11_USAGE_DEFAULT;
    d.BindFlags = (wantSRV ? D3D11_BIND_SHADER_RESOURCE : 0) | (wantUAV ? D3D11_BIND_UNORDERED_ACCESS : 0);
    if (FAILED(dev->CreateTexture2D(&d, nullptr, &out.t))) return false;
    if (wantSRV && FAILED(dev->CreateShaderResourceView(out.t, nullptr, &out.srv))) return false;
    if (wantUAV && FAILED(dev->CreateUnorderedAccessView(out.t, nullptr, &out.uav))) return false;
    return true;
}

void ClearCS(ID3D11DeviceContext* c)
{
    ID3D11ShaderResourceView* nSrv[8] = {};
    ID3D11UnorderedAccessView* nUav[8] = {};
    c->CSSetShaderResources(0, 8, nSrv);
    c->CSSetUnorderedAccessViews(0, 8, nUav, nullptr);
}

} // namespace

void Tex::Release()
{
    if (uav) { uav->Release(); uav = nullptr; }
    if (srv) { srv->Release(); srv = nullptr; }
    if (t) { t->Release(); t = nullptr; }
}

bool BoostPipeline::Create(ID3D11Device* dev, UINT w, UINT h)
{
    Release();
    width = w; height = h;

    const UINT tileCountY = TileCount(h);
    const UINT rowTexH = tileCountY * BLOCK_H;

    // The count textures carry an aux column for the brightest level.
    bool ok = true;
    ok &= CreateTex(dev, w, h, DXGI_FORMAT_R16G16B16A16_FLOAT, true, false, clean);
    ok &= CreateTex(dev, BLOCK_W + 1, rowTexH, DXGI_FORMAT_R32_SINT, true, true, rowCount);
    ok &= CreateTex(dev, BLOCK_W, rowTexH, DXGI_FORMAT_R32_SINT, true, true, rowOffset);
    ok &= CreateTex(dev, BLOCK_W + 1, BLOCK_H, DXGI_FORMAT_R32_SINT, true, true, globalCount);
    ok &= CreateTex(dev, BLOCK_W, BLOCK_H, DXGI_FORMAT_R32_FLOAT, true, true, globalOffset);
    ok &= CreateTex(dev, 2, 1, DXGI_FORMAT_R32G32B32A32_FLOAT, true, true, aplState);
    ok &= CreateTex(dev, 2, 1, DXGI_FORMAT_R32G32B32A32_FLOAT, true, true, aplPrev);
    ok &= CreateTex(dev, 1, 1, DXGI_FORMAT_R32G32B32A32_FLOAT, true, true, toneShape);
    ok &= CreateTex(dev, TONE_CURVE_LUT_SIZE, 1, DXGI_FORMAT_R32_FLOAT, true, true, toneLUT);

    ok &= SUCCEEDED(dev->CreateComputeShader(g_CS_Setup, sizeof(g_CS_Setup), nullptr, &csSetup));
    ok &= SUCCEEDED(dev->CreateComputeShader(g_CS_Build, sizeof(g_CS_Build), nullptr, &csBuild));
    ok &= SUCCEEDED(dev->CreateComputeShader(g_CS_Reduce, sizeof(g_CS_Reduce), nullptr, &csReduce));
    ok &= SUCCEEDED(dev->CreateComputeShader(g_CS_Solve, sizeof(g_CS_Solve), nullptr, &csSolve));
    ok &= SUCCEEDED(dev->CreateVertexShader(g_VS_Boost, sizeof(g_VS_Boost), nullptr, &vsBoost));
    ok &= SUCCEEDED(dev->CreatePixelShader(g_PS_Boost, sizeof(g_PS_Boost), nullptr, &psBoost));

    D3D11_BUFFER_DESC cbd = {};
    cbd.ByteWidth = 32; cbd.Usage = D3D11_USAGE_DYNAMIC;
    cbd.BindFlags = D3D11_BIND_CONSTANT_BUFFER; cbd.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    ok &= SUCCEEDED(dev->CreateBuffer(&cbd, nullptr, &cb));

    if (!ok) Release();
    return ok;
}

void BoostPipeline::Run(ID3D11DeviceContext* c, ID3D11RenderTargetView* rtv, bool reset, float litFraction, float frameMs)
{
    D3D11_MAPPED_SUBRESOURCE map;
    if (SUCCEEDED(c->Map(cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &map)))
    {
        struct CB { uint32_t reset; uint32_t width, height; float litFraction; float frameMs; float pad[3]; } data = {};
        data.reset = reset ? 1u : 0u;
        data.width = width; data.height = height;
        data.litFraction = litFraction;
        data.frameMs = frameMs;
        memcpy(map.pData, &data, sizeof(data));
        c->Unmap(cb, 0);
    }

    // Pass 1: last run's state copy and row clear.
    ClearCS(c);
    c->CSSetConstantBuffers(0, 1, &cb);
    {
        ID3D11ShaderResourceView* srv[1] = { aplState.srv };
        ID3D11UnorderedAccessView* uav[3] = { rowCount.uav, rowOffset.uav, aplPrev.uav };
        c->CSSetShaderResources(0, 1, srv);
        c->CSSetUnorderedAccessViews(0, 3, uav, nullptr);
        c->CSSetShader(csSetup, nullptr, 0);
        c->Dispatch(1, 1, 1);
    }

    // Pass 2: row histogram build from the clean copy.
    ClearCS(c);
    {
        ID3D11ShaderResourceView* srv[1] = { clean.srv };
        ID3D11UnorderedAccessView* uav[2] = { rowCount.uav, rowOffset.uav };
        c->CSSetShaderResources(0, 1, srv);
        c->CSSetUnorderedAccessViews(0, 2, uav, nullptr);
        c->CSSetShader(csBuild, nullptr, 0);
        c->Dispatch(TileCount(width), TileCount(height), 1);
    }

    // Pass 3: reduce to the global histogram.
    ClearCS(c);
    {
        ID3D11ShaderResourceView* srv[2] = { rowCount.srv, rowOffset.srv };
        ID3D11UnorderedAccessView* uav[2] = { globalCount.uav, globalOffset.uav };
        c->CSSetShaderResources(0, 2, srv);
        c->CSSetUnorderedAccessViews(0, 2, uav, nullptr);
        c->CSSetShader(csReduce, nullptr, 0);
        c->Dispatch(BLOCK_W, BLOCK_H, 1);
    }

    Solve(c);

    // Pass 5: fullscreen boost, clean copy -> render target.
    c->OMSetRenderTargets(1, &rtv, nullptr);
    D3D11_VIEWPORT vp = { 0.0f, 0.0f, (float)width, (float)height, 0.0f, 1.0f };
    c->RSSetViewports(1, &vp);
    c->IASetInputLayout(nullptr);
    c->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    c->VSSetShader(vsBoost, nullptr, 0);
    c->GSSetShader(nullptr, nullptr, 0);
    c->PSSetShader(psBoost, nullptr, 0);

    // Default states: no scissor, no blend, no depth, so the whole frame is replaced whatever DWM left bound.
    c->RSSetState(nullptr);
    c->OMSetBlendState(nullptr, nullptr, 0xFFFFFFFF);
    c->OMSetDepthStencilState(nullptr, 0);
    {
        ID3D11ShaderResourceView* srv[4] = { clean.srv, aplState.srv, toneShape.srv, toneLUT.srv };
        c->PSSetShaderResources(0, 4, srv);
    }
    c->Draw(3, 0);
}

void BoostPipeline::Solve(ID3D11DeviceContext* c)
{
    ClearCS(c);
    {
        ID3D11ShaderResourceView* srv[3] = { globalCount.srv, globalOffset.srv, aplPrev.srv };
        ID3D11UnorderedAccessView* uav[3] = { aplState.uav, toneShape.uav, toneLUT.uav };
        c->CSSetShaderResources(0, 3, srv);
        c->CSSetUnorderedAccessViews(0, 3, uav, nullptr);
        c->CSSetShader(csSolve, nullptr, 0);
        c->Dispatch(1, 1, 1);
    }
    ClearCS(c);
}

void BoostPipeline::Release()
{
    clean.Release();
    rowCount.Release(); rowOffset.Release();
    globalCount.Release(); globalOffset.Release();
    aplState.Release(); aplPrev.Release();
    toneShape.Release(); toneLUT.Release();
    if (csSetup) { csSetup->Release(); csSetup = nullptr; }
    if (csBuild) { csBuild->Release(); csBuild = nullptr; }
    if (csReduce) { csReduce->Release(); csReduce = nullptr; }
    if (csSolve) { csSolve->Release(); csSolve = nullptr; }
    if (vsBoost) { vsBoost->Release(); vsBoost = nullptr; }
    if (psBoost) { psBoost->Release(); psBoost = nullptr; }
    if (cb) { cb->Release(); cb = nullptr; }
    width = height = 0;
}
