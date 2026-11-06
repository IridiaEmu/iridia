#pragma once

#include <Metal/Metal.hpp>

#include "HW/Latte/ISA/LatteReg.h"
#include "util/containers/flat_hash_map.hpp"

class MetalDepthStencilCache
{
public:
    MetalDepthStencilCache(class MetalRenderer* metalRenderer) : m_mtlr{metalRenderer} {}
    ~MetalDepthStencilCache();

    // noDepthWrite: the active framebuffer has no depth attachment (depth writes off without touching DB_DEPTH_CONTROL)
    MTL::DepthStencilState* GetDepthStencilState(const LatteContextRegister& lcr, bool noDepthWrite);

private:
    class MetalRenderer* m_mtlr;

    ska::flat_hash_map<uint64, MTL::DepthStencilState*> m_depthStencilCache;
    // Iridia (MORNING9 item 4): the last lookup, checked before the map
    uint64 m_lastHash = 0;
    MTL::DepthStencilState* m_lastState = nullptr;

    uint64 CalculateDepthStencilHash(const LatteContextRegister& lcr, bool noDepthWrite);
};
