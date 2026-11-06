#pragma once
#include <atomic>
#include <cstdint>

// Iridia study: transcode BC1-BC5 (unorm) blocks to ASTC 4x4 at texture upload, for GPUs without BC support.
// Game-agnostic. Fixed single-partition ASTC modes are tried per block and the one with the lowest error vs the
// BC-decoded texels is kept:
//   BC1 opaque          RGB direct, 4 weight levels (matches BC1's 4-colour mode) or 3 levels (3-colour mode)
//   BC1 with alpha      RGBA, alpha in a second weight plane (3 levels each)
//   BC2 / BC3           RGBA, alpha in a second weight plane (4 levels) or 3 levels; or RGB if alpha is all 255
//   BC4                 R only (G = B = 0), 8 weight levels
//   BC5                 R and G in two weight planes (B = 0)
// DecodeBlock is the CPU model of the hardware decoder for the modes above (used to pick modes and for checks).
namespace IridiaAstc
{
	enum class Src { BC1, BC2, BC3, BC4, BC5 };

	// decode one BC block to 16 RGBA8 texels (BC4: R,0,0,255; BC5: R,G,0,255)
	void DecodeBC(Src src, const uint8_t* block, uint8_t rgba[64]);
	// encode 16 RGBA8 texels of a source of type src to one ASTC 4x4 block; returns the summed squared error
	uint64_t EncodeBlock(Src src, const uint8_t rgba[64], uint8_t out[16], bool srgb);
	// BC block -> ASTC block (DecodeBC + EncodeBlock)
	// fast direct mappings for most blocks, the search (EncodeBlock) for the rest; measure = return the error
	uint64_t TranscodeBlock(Src src, const uint8_t* bcBlock, uint8_t out[16], bool srgb, bool measure = true);
	// CPU decode of a block produced by EncodeBlock (returns false for modes this model does not cover)
	bool DecodeBlock(const uint8_t in[16], uint8_t rgba[64], bool srgb);

	// upload statistics per source format (blocks, summed squared error over 4 channels x 16 texels, encode time)
	struct Stats { std::atomic<uint64_t> blocks{0}, se{0}, ns{0}; };
	extern Stats g_stats[5];
}
