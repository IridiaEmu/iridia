#include <set>
#include <mutex>
#include "Cafe/HW/Latte/Renderer/Metal/LatteTextureViewMtl.h"
#include "Cafe/HW/Latte/Renderer/Metal/LatteTextureMtl.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalRenderer.h"
#include "Cafe/HW/Latte/Renderer/Metal/LatteToMtl.h"
#include "Metal/MTLTexture.hpp"

uint32 LatteTextureMtl_AdjustTextureCompSel(Latte::E_GX2SURFFMT format, uint32 compSel)
{
	switch (format)
	{
	case Latte::E_GX2SURFFMT::R8_UNORM: // R8 is replicated on all channels (while OpenGL would return 1.0 for BGA instead)
	case Latte::E_GX2SURFFMT::R8_SNORM: // probably the same as _UNORM, but needs testing
		if (compSel >= 1 && compSel <= 3)
			compSel = 0;
		break;
	case Latte::E_GX2SURFFMT::A1_B5_G5_R5_UNORM: // order of components is reversed (RGBA -> ABGR)
		if (compSel >= 0 && compSel <= 3)
			compSel = 3 - compSel;
		break;
	case Latte::E_GX2SURFFMT::BC4_UNORM:
	case Latte::E_GX2SURFFMT::BC4_SNORM:
		if (compSel >= 1 && compSel <= 3)
			compSel = 0;
		break;
	case Latte::E_GX2SURFFMT::BC5_UNORM:
	case Latte::E_GX2SURFFMT::BC5_SNORM:
		// RG maps to RG
		// B maps to ?
		// A maps to G (guessed)
		if (compSel == 3)
			compSel = 1; // read Alpha as Green
		break;
	case Latte::E_GX2SURFFMT::A2_B10_G10_R10_UNORM:
		// reverse components (Wii U: ABGR, OpenGL: RGBA)
		// used in Resident Evil Revelations
		if (compSel >= 0 && compSel <= 3)
			compSel = 3 - compSel;
		break;
	case Latte::E_GX2SURFFMT::X24_G8_UINT:
		// map everything to alpha?
		if (compSel >= 0 && compSel <= 3)
			compSel = 3;
		break;
	case Latte::E_GX2SURFFMT::R4_G4_UNORM:
		// red and green swapped
		if (compSel == 0)
			compSel = 1;
		else if (compSel == 1)
			compSel = 0;
		break;
	default:
		break;
	}
	return compSel;
}

LatteTextureViewMtl::LatteTextureViewMtl(MetalRenderer* mtlRenderer, LatteTextureMtl* texture, Latte::E_DIM dim, Latte::E_GX2SURFFMT format, sint32 firstMip, sint32 mipCount, sint32 firstSlice, sint32 sliceCount)
	: LatteTextureView(texture, firstMip, mipCount, firstSlice, sliceCount, dim, format), m_mtlr(mtlRenderer), m_baseTexture(texture)
{
    m_rgbaView = CreateSwizzledView(RGBA_SWIZZLE);
}

LatteTextureViewMtl::~LatteTextureViewMtl()
{
    if (m_rgbaView)
        m_rgbaView->release();
	for (sint32 i = 0; i < std::size(m_viewCache); i++)
    {
        if (m_viewCache[i].key != INVALID_SWIZZLE)
            m_viewCache[i].texture->release();
    }

    for (auto& [key, texture] : m_fallbackViewCache)
    {
        texture->release();
    }
}

MTL::Texture* LatteTextureViewMtl::GetSwizzledView(uint32 gpuSamplerSwizzle)
{
    // Mask out
    gpuSamplerSwizzle &= 0x0FFF0000;

    // RGBA swizzle == no swizzle
    if (gpuSamplerSwizzle == RGBA_SWIZZLE)
    {
        return m_rgbaView;
    }

    // First, try to find a view in the cache

    // Fast cache
    sint32 freeIndex = -1;
    for (sint32 i = 0; i < std::size(m_viewCache); i++)
    {
        const auto& entry = m_viewCache[i];
        if (entry.key == gpuSamplerSwizzle)
        {
            return entry.texture;
        }
        else if (entry.key == INVALID_SWIZZLE && freeIndex == -1)
        {
            freeIndex = i;
        }
    }

    // Fallback cache
    auto& fallbackEntry = m_fallbackViewCache[gpuSamplerSwizzle];
    if (fallbackEntry)
    {
        return fallbackEntry;
    }

    MTL::Texture* texture = CreateSwizzledView(gpuSamplerSwizzle);
    if (freeIndex != -1)
        m_viewCache[freeIndex] = {gpuSamplerSwizzle, texture};
    else
        fallbackEntry = texture;

    return texture;
}

MTL::Texture* LatteTextureViewMtl::CreateSwizzledView(uint32 gpuSamplerSwizzle)
{
    uint32 compSelR = (gpuSamplerSwizzle >> 16) & 0x7;
	uint32 compSelG = (gpuSamplerSwizzle >> 19) & 0x7;
	uint32 compSelB = (gpuSamplerSwizzle >> 22) & 0x7;
	uint32 compSelA = (gpuSamplerSwizzle >> 25) & 0x7;
	compSelR = LatteTextureMtl_AdjustTextureCompSel(format, compSelR);
	compSelG = LatteTextureMtl_AdjustTextureCompSel(format, compSelG);
	compSelB = LatteTextureMtl_AdjustTextureCompSel(format, compSelB);
	compSelA = LatteTextureMtl_AdjustTextureCompSel(format, compSelA);

	MTL::TextureType textureType;
    switch (dim)
    {
    case Latte::E_DIM::DIM_1D:
        textureType = MTL::TextureType1D;
        break;
    case Latte::E_DIM::DIM_2D:
    case Latte::E_DIM::DIM_2D_MSAA:
        textureType = MTL::TextureType2D;
        break;
    case Latte::E_DIM::DIM_2D_ARRAY:
        textureType = MTL::TextureType2DArray;
        break;
    case Latte::E_DIM::DIM_3D:
        textureType = MTL::TextureType3D;
        break;
    case Latte::E_DIM::DIM_CUBEMAP:
        cemu_assert_debug(this->numSlice % 6 == 0 && "cubemaps must have an array length multiple of 6");

        textureType = MTL::TextureTypeCubeArray;
        break;
    default:
        cemu_assert_unimplemented();
        textureType = MTL::TextureType2D;
        break;
    }

    uint32 baseLevel = firstMip;
    uint32 levelCount = this->numMip;
    uint32 baseLayer = 0;
    uint32 layerCount = 1;
    // TODO: check if base texture is 3D texture as well
    if (textureType == MTL::TextureType3D)
    {
        cemu_assert_debug(firstMip == 0);
        cemu_assert_debug(this->numSlice == baseTexture->depth);
    }
    else
    {
        baseLayer = firstSlice;
        if (textureType == MTL::TextureTypeCubeArray || textureType == MTL::TextureType2DArray)
            layerCount = this->numSlice;
    }

    MTL::TextureSwizzleChannels swizzle;
    swizzle.red = GetMtlTextureSwizzle(compSelR);
    swizzle.green = GetMtlTextureSwizzle(compSelG);
    swizzle.blue = GetMtlTextureSwizzle(compSelB);
    swizzle.alpha = GetMtlTextureSwizzle(compSelA);

    // Clamp mip levels
    levelCount = std::min(levelCount, m_baseTexture->maxPossibleMipLevels - baseLevel);
    levelCount = std::max(levelCount, (uint32)1);

    auto pixelFormat = GetMtlPixelFormat(format, m_baseTexture->isDepth);
    if (m_baseTexture->IridiaNeedsPfv(pixelFormat))
        m_baseTexture->IridiaEnsurePfv();
    // Iridia test: IRIDIA_PFV_TEST=<n> also makes a throwaway uint view on the first n renderable 4-byte color
    // textures, which forces the recreate path above (the picture must stay the same)
    static const int s_pfvTest = getenv("IRIDIA_PFV_TEST") ? atoi(getenv("IRIDIA_PFV_TEST")) : 0;
    static int s_pfvTestDone = 0;
    if (s_pfvTestDone < s_pfvTest && (m_baseTexture->GetTexture()->usage() & MTL::TextureUsageRenderTarget) && (pixelFormat == MTL::PixelFormatRGBA8Unorm || pixelFormat == MTL::PixelFormatBGRA8Unorm) && m_baseTexture->GetTexture()->textureType() == MTL::TextureType2D)
    {
        s_pfvTestDone++;
        static const bool s_noFix = getenv("IRIDIA_PFV_TEST_NOFIX") != nullptr; // positive control for the validation layer
        if (!s_noFix && m_baseTexture->IridiaNeedsPfv(MTL::PixelFormatR32Uint))
            m_baseTexture->IridiaEnsurePfv();
        m_baseTexture->GetTexture()->newTextureView(MTL::PixelFormatR32Uint)->release();
    }
    MTL::Texture* texture = m_baseTexture->GetTexture()->newTextureView(pixelFormat, textureType, NS::Range::Make(baseLevel, levelCount), NS::Range::Make(baseLayer, layerCount), swizzle);
    // Iridia diagnostics: IRIDIA_VIEW_FMT=1 logs each (texture format, view format) pair once, for the pixel format view usage study
    static const bool s_viewFmt = getenv("IRIDIA_VIEW_FMT") != nullptr;
    if (s_viewFmt && pixelFormat != m_baseTexture->GetTexture()->pixelFormat())
    {
        static std::mutex s_m; static std::set<std::pair<int, int>> s_seen;
        std::lock_guard l(s_m);
        if (s_seen.emplace((int)m_baseTexture->GetTexture()->pixelFormat(), (int)pixelFormat).second)
            fprintf(stderr, "IRIDIA_VIEW_FMT texture %d view %d (gx2 %x) %ux%u rt %d\n", (int)m_baseTexture->GetTexture()->pixelFormat(), (int)pixelFormat, (uint32)format, m_baseTexture->width, m_baseTexture->height, (int)((m_baseTexture->GetTexture()->usage() & MTL::TextureUsageRenderTarget) != 0));
    }

    return texture;
}

void LatteTextureViewMtl::IridiaRecreateViews()
{
    if (m_rgbaView)
    {
        m_rgbaView->release();
        m_rgbaView = CreateSwizzledView(RGBA_SWIZZLE);
    }
    for (auto& entry : m_viewCache)
    {
        if (entry.key != INVALID_SWIZZLE)
        {
            entry.texture->release();
            entry.texture = CreateSwizzledView(entry.key);
        }
    }
    for (auto& [key, texture] : m_fallbackViewCache)
    {
        if (texture)
        {
            texture->release();
            texture = CreateSwizzledView(key);
        }
    }
}
