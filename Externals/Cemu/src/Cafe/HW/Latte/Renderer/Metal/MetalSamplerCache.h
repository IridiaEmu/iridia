#pragma once

#include <Metal/Metal.hpp>

#include "HW/Latte/Core/LatteConst.h"
#include "HW/Latte/ISA/LatteReg.h"
#include "util/containers/flat_hash_map.hpp"

class MetalSamplerCache
{
public:
    MetalSamplerCache(class MetalRenderer* metalRenderer) : m_mtlr{metalRenderer} {}
    ~MetalSamplerCache();

    MTL::SamplerState* GetSamplerState(const LatteContextRegister& lcr, LatteConst::ShaderType shaderType, uint32 stageSamplerIndex, const _LatteRegisterSetSampler* samplerWords);

private:
    class MetalRenderer* m_mtlr;

    ska::flat_hash_map<uint64, MTL::SamplerState*> m_samplerCache;
    // Iridia (MORNING9 item 4): last hash and result per stage sampler slot, checked before the map
    struct { uint64 hash; MTL::SamplerState* state; } m_lastPerSlot[3][Latte::GPU_LIMITS::NUM_SAMPLERS_PER_STAGE] = {};

    uint64 CalculateSamplerHash(const LatteContextRegister& lcr, LatteConst::ShaderType shaderType, uint32 stageSamplerIndex, const _LatteRegisterSetSampler* samplerWords);
};
