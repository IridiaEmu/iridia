#pragma once
#include <chrono>
#include "Cafe/HW/Latte/Core/LatteTextureLoader.h"
#include "Cafe/HW/Latte/Core/IridiaAstc.h"

// Iridia study (IRIDIA_BC_ASTC=1, only where the GPU has no BC): texture decoders that transcode BC1-BC5 (unorm)
// blocks to ASTC 4x4 blocks at upload, instead of decoding them to 32-bit float texels.
template<IridiaAstc::Src SRC, bool SRGB>
class TextureDecoder_BC_To_ASTC : public TextureDecoder, public SingletonClass<TextureDecoder_BC_To_ASTC<SRC, SRGB>>
{
public:
	sint32 getBytesPerTexel(LatteTextureLoaderCtx* textureLoader) override { return 16; }
	sint32 getTexelCountX(LatteTextureLoaderCtx* textureLoader) override { return (textureLoader->width + 3) / 4; }
	sint32 getTexelCountY(LatteTextureLoaderCtx* textureLoader) override { return (textureLoader->height + 3) / 4; }

	void decode(LatteTextureLoaderCtx* textureLoader, uint8* outputData) override
	{
		// IRIDIA_ASTC_MEASURE=1: also compute the error of every block (slower; for the PSNR in IRIDIA_ASTC lines)
		static const bool s_measure = iridia_getenv("IRIDIA_ASTC_MEASURE") != nullptr;
		const auto t0 = std::chrono::steady_clock::now();
		const sint32 blocksPerRow = (textureLoader->width + 3) / 4;
		uint64 se = 0, n = 0;
		for (sint32 y = 0; y < textureLoader->height; y += textureLoader->stepY)
		{
			for (sint32 x = 0; x < textureLoader->width; x += textureLoader->stepX)
			{
				uint8* blockData = LatteTextureLoader_GetInput(textureLoader, x, y);
				se += IridiaAstc::TranscodeBlock(SRC, blockData, outputData + ((x / 4) + (y / 4) * blocksPerRow) * 16, SRGB, s_measure);
				n++;
			}
		}
		auto& st = IridiaAstc::g_stats[(int)SRC];
		st.blocks += n; st.se += se;
		st.ns += (uint64)std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count();
	}

	void decodePixelToRGBA(uint8* blockData, uint8* outputPixel, uint8 blockOffsetX, uint8 blockOffsetY) override
	{
		uint8_t rgba[64];
		IridiaAstc::DecodeBC(SRC, blockData, rgba);
		const int i = (blockOffsetY * 4 + blockOffsetX) * 4;
		outputPixel[0] = rgba[i]; outputPixel[1] = rgba[i + 1]; outputPixel[2] = rgba[i + 2]; outputPixel[3] = rgba[i + 3];
	}
};
