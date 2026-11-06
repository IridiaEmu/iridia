#include "Cafe/HW/Latte/Renderer/Metal/LatteTextureMtl.h"
#include "Cafe/HW/Latte/Renderer/Metal/LatteTextureViewMtl.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalRenderer.h"
#include "Cafe/HW/Latte/Renderer/Metal/LatteToMtl.h"
#include "Cafe/HW/Latte/Renderer/Metal/CachedFBOMtl.h"

LatteTextureMtl::LatteTextureMtl(class MetalRenderer* mtlRenderer, Latte::E_DIM dim, MPTR physAddress, MPTR physMipAddress, Latte::E_GX2SURFFMT format, uint32 width, uint32 height, uint32 depth, uint32 pitch, uint32 mipLevels, uint32 swizzle,
	Latte::E_HWTILEMODE tileMode, bool isDepth)
	: LatteTexture(dim, physAddress, physMipAddress, format, width, height, depth, pitch, mipLevels, swizzle, tileMode, isDepth), m_mtlr(mtlRenderer)
{
    NS_STACK_SCOPED MTL::TextureDescriptor* desc = MTL::TextureDescriptor::alloc()->init();
    desc->setStorageMode(MTL::StorageModePrivate);
    //desc->setCpuCacheMode(MTL::CPUCacheModeWriteCombined);

	sint32 effectiveBaseWidth = width;
	sint32 effectiveBaseHeight = height;
	sint32 effectiveBaseDepth = depth;
	if (overwriteInfo.hasResolutionOverwrite)
	{
		effectiveBaseWidth = overwriteInfo.width;
		effectiveBaseHeight = overwriteInfo.height;
		effectiveBaseDepth = overwriteInfo.depth;
	}
	effectiveBaseWidth = std::max(1, effectiveBaseWidth);
	effectiveBaseHeight = std::max(1, effectiveBaseHeight);
	effectiveBaseDepth = std::max(1, effectiveBaseDepth);

	MTL::TextureType textureType;
	switch (dim)
    {
    case Latte::E_DIM::DIM_1D:
        textureType = MTL::TextureType1D;
        effectiveBaseHeight = 1;
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
        cemu_assert_debug(effectiveBaseDepth % 6 == 0 && "cubemaps must have an array length multiple of 6");

        textureType = MTL::TextureTypeCubeArray;
        break;
    default:
        cemu_assert_unimplemented();
        textureType = MTL::TextureType2D;
        break;
    }
    desc->setTextureType(textureType);

    // Clamp mip levels
    mipLevels = std::min(mipLevels, (uint32)maxPossibleMipLevels);
    mipLevels = std::max(mipLevels, (uint32)1);

	desc->setWidth(effectiveBaseWidth);
	desc->setHeight(effectiveBaseHeight);
	desc->setMipmapLevelCount(mipLevels);

	if (textureType == MTL::TextureType3D)
	{
		desc->setDepth(effectiveBaseDepth);
	}
	else if (textureType == MTL::TextureTypeCubeArray)
	{
		desc->setArrayLength(effectiveBaseDepth / 6);
	}
	else if (textureType == MTL::TextureType2DArray)
	{
		desc->setArrayLength(effectiveBaseDepth);
	}

	auto pixelFormat = GetMtlPixelFormat(format, isDepth);
	m_isAlternateFormat = GetMtlPixelFormatInfo(format, isDepth).isAlternateFormat;
	desc->setPixelFormat(pixelFormat);

	// Iridia: leave out the pixel format view usage (it can turn off lossless compression; phone -1.2 ms per frame).
	// A view that needs it recreates the texture with it (IridiaEnsurePfv).
	// Off by default: no clear gain on the Mac (-1.1%) or the phone (+0.2%). IRIDIA_NO_PFV=1 turns it on.
	static const bool s_noPfv = getenv("IRIDIA_NO_PFV") && atoi(getenv("IRIDIA_NO_PFV")) == 1;
	MTL::TextureUsage usage = MTL::TextureUsageShaderRead | (s_noPfv ? 0 : MTL::TextureUsagePixelFormatView);
	if (FormatIsRenderable(format))
		usage |= MTL::TextureUsageRenderTarget;
	desc->setUsage(usage);

	m_texture = mtlRenderer->GetDevice()->newTexture(desc);
	g_iridiaTexCount[Latte::IsCompressedFormat(format) ? 0 : 1]++;
	IridiaCountBytes();
}

std::atomic<sint64> g_iridiaTexBytes[2], g_iridiaTexCount[2];

void LatteTextureMtl::IridiaCountBytes()
{
	const sint64 now = m_texture ? (sint64)m_texture->allocatedSize() : 0;
	g_iridiaTexBytes[Latte::IsCompressedFormat(format) ? 0 : 1] += now - m_iridiaBytes;
	m_iridiaBytes = now;
}

LatteTextureMtl::~LatteTextureMtl()
{
	g_iridiaTexBytes[Latte::IsCompressedFormat(format) ? 0 : 1] -= m_iridiaBytes;
	g_iridiaTexCount[Latte::IsCompressedFormat(format) ? 0 : 1]--;
	m_texture->release();
}

LatteTextureView* LatteTextureMtl::CreateView(Latte::E_DIM dim, Latte::E_GX2SURFFMT format, sint32 firstMip, sint32 mipCount, sint32 firstSlice, sint32 sliceCount)
{
	cemu_assert_debug(mipCount > 0);
	cemu_assert_debug(sliceCount > 0);
	cemu_assert_debug((firstMip + mipCount) <= this->mipLevels);
	cemu_assert_debug((firstSlice + sliceCount) <= this->depth);

	return new LatteTextureViewMtl(m_mtlr, this, dim, format, firstMip, mipCount, firstSlice, sliceCount);
}

// TODO: lazy allocation?
void LatteTextureMtl::AllocateOnHost()
{
	// The texture is already allocated
}

static MTL::PixelFormat IridiaLinearFormat(MTL::PixelFormat f)
{
	switch (f)
	{
	case MTL::PixelFormatRGBA8Unorm_sRGB: return MTL::PixelFormatRGBA8Unorm;
	case MTL::PixelFormatBGRA8Unorm_sRGB: return MTL::PixelFormatBGRA8Unorm;
	case MTL::PixelFormatBC1_RGBA_sRGB: return MTL::PixelFormatBC1_RGBA;
	case MTL::PixelFormatBC2_RGBA_sRGB: return MTL::PixelFormatBC2_RGBA;
	case MTL::PixelFormatBC3_RGBA_sRGB: return MTL::PixelFormatBC3_RGBA;
	case MTL::PixelFormatBC7_RGBAUnorm_sRGB: return MTL::PixelFormatBC7_RGBAUnorm;
	case MTL::PixelFormatASTC_4x4_sRGB: return MTL::PixelFormatASTC_4x4_LDR;
	default: return f;
	}
}

bool LatteTextureMtl::IridiaNeedsPfv(MTL::PixelFormat viewFormat) const
{
	if (viewFormat == m_texture->pixelFormat() || (m_texture->usage() & MTL::TextureUsagePixelFormatView))
		return false;
	return IridiaLinearFormat(viewFormat) != IridiaLinearFormat(m_texture->pixelFormat());
}

void LatteTextureMtl::IridiaEnsurePfv()
{
	if (m_texture->usage() & MTL::TextureUsagePixelFormatView)
		return;
	static uint32 s_count = 0;
	fprintf(stderr, "IRIDIA_PFV_RECREATE %u: texture format %d %ux%u mips %u views %u\n", ++s_count, (int)m_texture->pixelFormat(), width, height, (uint32)m_texture->mipmapLevelCount(), (uint32)views.size());
	m_mtlr->EndEncoding(); // an open render pass may have this texture attached

	NS_STACK_SCOPED MTL::TextureDescriptor* desc = MTL::TextureDescriptor::alloc()->init();
	desc->setStorageMode(MTL::StorageModePrivate);
	desc->setTextureType(m_texture->textureType());
	desc->setPixelFormat(m_texture->pixelFormat());
	desc->setWidth(m_texture->width());
	desc->setHeight(m_texture->height());
	desc->setDepth(m_texture->depth());
	desc->setArrayLength(m_texture->arrayLength());
	desc->setMipmapLevelCount(m_texture->mipmapLevelCount());
	desc->setSampleCount(m_texture->sampleCount());
	desc->setUsage(m_texture->usage() | MTL::TextureUsagePixelFormatView);
	MTL::Texture* texture = m_mtlr->GetDevice()->newTexture(desc);

	// the command buffer keeps the old texture alive until the copy has run
	m_mtlr->GetBlitCommandEncoder()->copyFromTexture(m_texture, texture);
	m_mtlr->EndEncoding();
	m_texture->release();
	m_texture = texture;
	IridiaCountBytes();

	for (auto view : views)
	{
		auto viewMtl = static_cast<LatteTextureViewMtl*>(view);
		viewMtl->IridiaRecreateViews();
		for (auto fbo : view->list_associatedFbo)
			static_cast<CachedFBOMtl*>(fbo)->IridiaRefreshTextures();
	}
}
