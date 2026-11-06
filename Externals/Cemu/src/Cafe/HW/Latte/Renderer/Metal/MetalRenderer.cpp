#include <map>
#include <mach/mach_time.h>
#include <dlfcn.h>
#include <TargetConditionals.h>
#include "Cafe/HW/Latte/Renderer/Metal/MetalRenderer.h"
#include "Cafe/HW/Latte/Core/IridiaPerf.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalMemoryManager.h"
#include "Cafe/HW/Latte/Renderer/Metal/LatteTextureMtl.h"
#include "Cafe/HW/Latte/Core/IridiaAstc.h"
#include "Cafe/HW/Latte/Renderer/Metal/LatteTextureViewMtl.h"
#include "Cafe/HW/Latte/Renderer/Metal/RendererShaderMtl.h"
#include "Cafe/HW/Latte/Renderer/Metal/CachedFBOMtl.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalOutputShaderCache.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalPipelineCache.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalDepthStencilCache.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalSamplerCache.h"
#include "Cafe/HW/Latte/Renderer/Metal/LatteTextureReadbackMtl.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalVoidVertexPipeline.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalQuery.h"
#include "Cafe/HW/Latte/Renderer/Metal/LatteToMtl.h"
#include "Cafe/HW/Latte/Renderer/Metal/UtilityShaderSource.h"

#include "Cafe/HW/Latte/Core/LatteShader.h"
#include "Cafe/HW/Latte/Core/LatteIndices.h"
#include "Cafe/HW/Latte/Core/LatteBufferCache.h"
#include "CafeSystem.h"
#include "Cemu/Logging/CemuLogging.h"
#include "Cafe/HW/Latte/Core/FetchShader.h"
#include "Cafe/HW/Latte/Core/LatteConst.h"
#include "config/CemuConfig.h"

#define IMGUI_IMPL_METAL_CPP
#include "imgui/imgui_extension.h"
#include "imgui/imgui_impl_metal.h"

extern std::atomic<int> g_iridiaGameplaySeconds;
// Iridia diagnostics: IRIDIA_GPU_PASSES=1 times every render/blit/compute pass on the GPU (counter samples at stage
// boundaries) and prints, every 5 s, GPU ms per frame by pass kind (attachments): IRIDIA_GPUPASS lines.
namespace
{
    struct IridiaPassAcc { double vMs = 0, fMs = 0, spanMs = 0; uint32 n = 0; uint64 draws = 0; };
    struct IridiaPassProf
    {
        bool on = false, checked = false;
        MTL::CounterSampleBuffer* buf = nullptr;
        static constexpr uint32 kSamples = 32768 / 8; // 4 per pass (max buffer size 32 KB)
        uint32 next = 0;
        std::unordered_map<MTL::CommandBuffer*, std::vector<std::pair<uint32, uint32>>> pending; // sample index, key id
        std::vector<std::string> keys;
        std::unordered_map<std::string, uint32> keyIds;
        std::unordered_map<uint32, IridiaPassAcc> acc;
        double tickToMs = 0;
        MTL::Timestamp cal0c = 0, cal0g = 0;
        std::chrono::steady_clock::time_point last = std::chrono::steady_clock::now();
        uint32 frames = 0;
        uint32 allocs = 0;
    } s_pp;

    bool IridiaPassProfOn(MTL::Device* dev)
    {
        if (s_pp.checked)
            return s_pp.on;
        s_pp.checked = true;
        if (!getenv("IRIDIA_GPU_PASSES"))
            return false;
        if (!dev->supportsCounterSampling(MTL::CounterSamplingPointAtStageBoundary))
        {
            fprintf(stderr, "IRIDIA_GPUPASS stage boundary sampling not supported\n");
            return false;
        }
        MTL::CounterSet* ts = nullptr;
        auto sets = dev->counterSets();
        for (NS::UInteger i = 0; i < sets->count(); i++)
        {
            auto cs = (MTL::CounterSet*)sets->object(i);
            if (strcmp(cs->name()->utf8String(), "timestamp") == 0) ts = cs;
        }
        if (!ts) { fprintf(stderr, "IRIDIA_GPUPASS no timestamp counter set\n"); return false; }
        auto d = MTL::CounterSampleBufferDescriptor::alloc()->init();
        d->setCounterSet(ts);
        d->setStorageMode(MTL::StorageModeShared);
        d->setSampleCount(IridiaPassProf::kSamples);
        NS::Error* err = nullptr;
        s_pp.buf = dev->newCounterSampleBuffer(d, &err);
        d->release();
        if (!s_pp.buf) { fprintf(stderr, "IRIDIA_GPUPASS sample buffer failed: %s\n", err ? err->localizedDescription()->utf8String() : "?"); return false; }
        dev->sampleTimestamps(&s_pp.cal0c, &s_pp.cal0g);
        s_pp.on = true;
        return true;
    }

    uint32 IridiaPassKey(const std::string& k)
    {
        auto it = s_pp.keyIds.find(k);
        if (it != s_pp.keyIds.end()) return it->second;
        uint32 id = (uint32)s_pp.keys.size();
        s_pp.keys.push_back(k); s_pp.keyIds[k] = id;
        return id;
    }

    // returns the first of 4 sample indices, or ~0 if the ring is full
    uint32 IridiaPassAlloc(MTL::CommandBuffer* cb, uint32 key)
    {
        s_pp.allocs++;
        uint32 idx = s_pp.next;
        s_pp.next = (s_pp.next + 4) % IridiaPassProf::kSamples;
        s_pp.pending[cb].emplace_back(idx, key);
        return idx;
    }

    std::string IridiaRenderPassKey(MTL::RenderPassDescriptor* rp)
    {
        std::string k;
        for (int i = 0; i < 8; i++)
        {
            auto t = rp->colorAttachments()->object(i)->texture();
            if (!t) continue;
            k += fmt::format("c{}:{}x{}f{}{} ", i, t->width(), t->height(), (int)t->pixelFormat(), rp->colorAttachments()->object(i)->loadAction() == MTL::LoadActionLoad ? "L" : "");
        }
        if (auto t = rp->depthAttachment()->texture())
            k += fmt::format("d:{}x{}f{}{}", t->width(), t->height(), (int)t->pixelFormat(), rp->depthAttachment()->loadAction() == MTL::LoadActionLoad ? "L" : "");
        return k;
    }
    // base texture ids + slice/mip of each attachment (pass sequence log only)
    std::string IridiaRpIds(MTL::RenderPassDescriptor* rp)
    {
        std::string k = " [";
        auto one = [&](MTL::RenderPassAttachmentDescriptor* a, const char* n) {
            auto t = a->texture(); if (!t) return;
            auto base = t->parentTexture() ? t->parentTexture() : t;
            k += fmt::format("{}={:x}/{}/{} ", n, ((uintptr_t)base >> 4) & 0xfffff, a->slice() + (t->parentTexture() ? t->parentRelativeSlice() : 0), a->level() + (t->parentTexture() ? t->parentRelativeLevel() : 0));
        };
        for (int i = 0; i < 8; i++) one(rp->colorAttachments()->object(i), fmt::format("c{}", i).c_str());
        one(rp->depthAttachment(), "d");
        return k + "]";
    }

    void IridiaPassResolve(MTL::Device* dev, MTL::CommandBuffer* cb)
    {
        auto it = s_pp.pending.find(cb);
        if (it == s_pp.pending.end()) return;
        for (auto& [idx, key] : it->second)
        {
            const bool render = s_pp.keys[key] != "blit" && s_pp.keys[key] != "compute";
            NS::Data* data = s_pp.buf->resolveCounterRange(NS::Range(idx, render ? 4 : 2));
            if (!data) continue;
            const uint64* v = (const uint64*)data->mutableBytes();
            auto ok = [](uint64 x) { return x != 0 && x != 0xFFFFFFFFFFFFFFFFull; };
            auto& a = s_pp.acc[key];
            if (ok(v[0]) && ok(v[1]) && v[1] >= v[0]) a.vMs += (double)(v[1] - v[0]);
            if (render && ok(v[2]) && ok(v[3]) && v[3] >= v[2]) a.fMs += (double)(v[3] - v[2]);
            a.n++;
        }
        s_pp.pending.erase(it);
    }

    // study switches read once per call site (getenv scans the whole environment; these sit on per-encoder paths)
#define IridiaEnvOn(name) ([] { static const bool v = getenv(name) != nullptr; return v; }())

    // IRIDIA_PASS_SEQ=<frame number>: logs the encoder sequence of that frame (render pass attachments, draws)
    struct { int target = -2; int frame = 0; std::vector<std::string> seq; uint32 draws = 0; } s_seq;
    bool IridiaSeqOn()
    {
        if (s_seq.target == -2) s_seq.target = getenv("IRIDIA_PASS_SEQ") ? atoi(getenv("IRIDIA_PASS_SEQ")) : -1;
        if (s_seq.target >= 0 && s_seq.frame == 0 && g_iridiaGameplaySeconds.load() >= s_seq.target) s_seq.frame = 1; // armed: record the next whole frame
        return s_seq.frame == 2;
    }
    void IridiaSeq(const std::string& what)
    {
        if (!IridiaSeqOn()) return;
        if (!s_seq.seq.empty()) s_seq.seq.back() += fmt::format(" draws={}", s_seq.draws);
        s_seq.draws = 0;
        s_seq.seq.push_back(what);
    }
    void IridiaSeqFrame()
    {
        if (IridiaSeqOn())
        {
            if (!s_seq.seq.empty()) s_seq.seq.back() += fmt::format(" draws={}", s_seq.draws);
            for (auto& l : s_seq.seq) fprintf(stderr, "IRIDIA_SEQ %s\n", l.c_str());
            s_seq.seq.clear();
        }
        if (s_seq.frame == 1 || s_seq.frame == 2) s_seq.frame++;
    }

    void IridiaPassPrint(MTL::Device* dev)
    {
        s_pp.frames++;
        if (std::chrono::steady_clock::now() - s_pp.last < std::chrono::seconds(5)) return;
        s_pp.last = std::chrono::steady_clock::now();
        // GPU timestamp ticks -> ms, from CPU/GPU timestamp pairs
        MTL::Timestamp c, g; dev->sampleTimestamps(&c, &g);
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        const double m = (double)(c - s_pp.cal0c) * tb.numer / tb.denom / (double)(g - s_pp.cal0g) / 1e6;
        std::vector<std::pair<double, uint32>> order;
        double totV = 0, totF = 0, n = 0;
        for (auto& [k, a] : s_pp.acc) { order.emplace_back(a.vMs + a.fMs, k); totV += a.vMs; totF += a.fMs; n += a.n; }
        std::sort(order.rbegin(), order.rend());
        const double f = s_pp.frames;
        fprintf(stderr, "IRIDIA_GPUPASS frames=%u tick=%.3fns per frame: vertex/encoder %.2f ms, fragment %.2f ms, passes %.1f (allocated %.1f)\n", s_pp.frames, m * 1e6, totV * m / f, totF * m / f, n / f, s_pp.allocs / f);
        s_pp.allocs = 0;
        int shown = 0;
        for (auto& [t, k] : order)
        {
            auto& a = s_pp.acc[k];
            fprintf(stderr, "IRIDIA_GPUPASS  %6.2f ms (v %.2f f %.2f) n %.1f  %s\n", t * m / f, a.vMs * m / f, a.fMs * m / f, a.n / f, s_pp.keys[k].c_str());
            if (++shown == 30) break;
        }
        s_pp.acc.clear(); s_pp.frames = 0;
    }
}


#define EVENT_VALUE_WRAP 4096

extern bool hasValidFramebufferAttached;

float supportBufferData[512 * 4];
std::atomic<uint32> g_iridiaClears[3]; // Iridia: color / depth-stencil clear passes (printed once per second)
std::atomic<uint32> g_iridiaUniformReuse[2]; // Iridia: uniform blocks bound again / uploaded (printed once per second)

// Defined in the Common renderer
void LatteDraw_handleSpecialState8_clearAsDepth();

std::vector<MetalRenderer::DeviceInfo> MetalRenderer::GetDevices()
{
    NS_STACK_SCOPED auto devices = MTL::CopyAllDevices();
    std::vector<MetalRenderer::DeviceInfo> result;
    result.reserve(devices->count());
    for (uint32 i = 0; i < devices->count(); i++)
    {
        MTL::Device* device = static_cast<MTL::Device*>(devices->object(i));
        result.push_back({std::string(device->name()->utf8String()), device->registryID()});
    }

    return result;
}

MetalRenderer::MetalRenderer() : Renderer(RendererAPI::Metal)
{
    // Options

    // Position invariance
    switch (g_current_game_profile->GetPositionInvariance())
    {
    case PositionInvariance::Auto:
        switch (CafeSystem::GetForegroundTitleId())
        {
        // Bayonetta
        case 0x0005000010157F00: // EUR
        case 0x0005000010157E00: // USA
        case 0x000500001014DB00: // JPN
        // Bayonetta 2
        case 0x0005000010172700: // EUR
        case 0x0005000010172600: // USA
        // Disney Planes
        case 0x0005000010136900: // EUR
        case 0x0005000010136A00: // EUR (TODO: check)
        case 0x0005000010136B00: // EUR (TODO: check)
        case 0x000500001011C500: // USA (TODO: check)
        // LEGO STAR WARS: The Force Awakens
        case 0x00050000101DAA00: // EUR
        case 0x00050000101DAB00: // USA
        // Mario Kart 8
        case 0x000500001010ED00: // EUR
        case 0x000500001010EC00: // USA
        case 0x000500001010EB00: // JPN
        case 0x0005000010183A00: // JPN (TODO: check)
        // Minecraft: Story Mode
        case 0x000500001020A300: // EUR
        case 0x00050000101E0100: // USA
        //case 0x000500001020a200: // USA
        // Ninja Gaiden 3: Razor's Edge
        case 0x0005000010110B00: // EUR
        case 0x0005000010139B00: // EUR (TODO: check)
        case 0x0005000010110A00: // USA
        case 0x0005000010110900: // JPN
        // Resident Evil: Revelations
        case 0x000500001012B400: // EUR
        case 0x000500001012CF00: // USA
        // Star Fox Zero
        case 0x00050000101B0500: // EUR
        case 0x0005000010201C00: // EUR (TODO: check)
        case 0x00050000101B0400: // USA
        case 0x0005000010201B00: // USA (TODO: check)
        // The Legend of Zelda: Breath of the Wild
        case 0x00050000101C9500: // EUR
        case 0x00050000101C9400: // USA
        case 0x00050000101C9300: // JPN
        // Wonderful 101
        case 0x0005000010135300: // EUR
        case 0x000500001012DC00: // USA
        case 0x0005000010116300: // JPN
        case 0x0005000010185600: // JPN (TODO: check)
            m_positionInvariance = true;
            break;
        default:
            m_positionInvariance = false;
            break;
        }
        break;
    case PositionInvariance::False:
        m_positionInvariance = false;
        break;
    case PositionInvariance::True:
        m_positionInvariance = true;
        break;
    }

    // Pick a device
    auto& config = GetConfig();
    const bool hasDeviceSet = config.mtl_graphic_device_uuid != 0;

    // If a device is set, try to find it
    if (hasDeviceSet)
    {
        NS_STACK_SCOPED auto devices = MTL::CopyAllDevices();
        for (uint32 i = 0; i < devices->count(); i++)
        {
            MTL::Device* device = static_cast<MTL::Device*>(devices->object(i));
            if (device->registryID() == config.mtl_graphic_device_uuid)
            {
                m_device = device;
                break;
            }
        }
    }

    if (!m_device)
    {
        if (hasDeviceSet)
        {
            cemuLog_log(LogType::Force, "The selected GPU ({}) could not be found. Using the system default device.", config.mtl_graphic_device_uuid);
            config.mtl_graphic_device_uuid = 0;
        }
        // Use the system default device
        m_device = MTL::CreateSystemDefaultDevice();
    }

    // Vendor
    const char* deviceName = m_device->name()->utf8String();
    if (memcmp(deviceName, "Apple", 5) == 0)
        m_vendor = GfxVendor::Apple;
    else if (memcmp(deviceName, "AMD", 3) == 0)
        m_vendor = GfxVendor::AMD;
    else if (memcmp(deviceName, "Intel", 5) == 0)
        m_vendor = GfxVendor::Intel;
    else if (memcmp(deviceName, "NVIDIA", 6) == 0)
        m_vendor = GfxVendor::Nvidia;
    else
        m_vendor = GfxVendor::Generic;

    m_selectedDeviceName = deviceName;

    // Feature support
    m_isAppleGPU = m_device->supportsFamily(MTL::GPUFamilyApple1);
    m_supportsFramebufferFetch = GetConfig().framebuffer_fetch.GetValue() ? m_device->supportsFamily(MTL::GPUFamilyApple2) : false;
    m_hasUnifiedMemory = m_device->hasUnifiedMemory();
#if TARGET_OS_IPHONE
    m_hasUnifiedMemory = true; // Iridia Wii U app: iOS has no managed storage (the Simulator reports otherwise)
#endif
    m_supportsMetal3 = m_device->supportsFamily(MTL::GPUFamilyMetal3);
    m_supportsMeshShaders = (m_supportsMetal3 && (m_vendor != GfxVendor::Intel || GetConfig().force_mesh_shaders.GetValue())); // Intel GPUs have issues with mesh shaders
    m_recommendedMaxVRAMUsage = m_device->recommendedMaxWorkingSetSize();
    m_pixelFormatSupport = MetalPixelFormatSupport(m_device);

    CheckForPixelFormatSupport(m_pixelFormatSupport);

    // Command queue
    m_commandQueue = m_device->newCommandQueue();

    // Synchronization resources
    m_event = m_device->newEvent();

    // Resources
    NS_STACK_SCOPED MTL::SamplerDescriptor* samplerDescriptor = MTL::SamplerDescriptor::alloc()->init();
#ifdef CEMU_DEBUG_ASSERT
    samplerDescriptor->setLabel(GetLabel("Nearest sampler state", samplerDescriptor));
#endif
    m_nearestSampler = m_device->newSamplerState(samplerDescriptor);

    samplerDescriptor->setMinFilter(MTL::SamplerMinMagFilterLinear);
    samplerDescriptor->setMagFilter(MTL::SamplerMinMagFilterLinear);
#ifdef CEMU_DEBUG_ASSERT
    samplerDescriptor->setLabel(GetLabel("Linear sampler state", samplerDescriptor));
#endif
    m_linearSampler = m_device->newSamplerState(samplerDescriptor);

    // Null resources
    NS_STACK_SCOPED MTL::TextureDescriptor* textureDescriptor = MTL::TextureDescriptor::alloc()->init();
    textureDescriptor->setTextureType(MTL::TextureType1D);
    textureDescriptor->setWidth(1);
    textureDescriptor->setUsage(MTL::TextureUsageShaderRead);
    m_nullTexture1D = m_device->newTexture(textureDescriptor);
#ifdef CEMU_DEBUG_ASSERT
    m_nullTexture1D->setLabel(GetLabel("Null texture 1D", m_nullTexture1D));
#endif

    textureDescriptor->setTextureType(MTL::TextureType2D);
    textureDescriptor->setHeight(1);
    textureDescriptor->setUsage(MTL::TextureUsageShaderRead | MTL::TextureUsageRenderTarget);
    m_nullTexture2D = m_device->newTexture(textureDescriptor);
#ifdef CEMU_DEBUG_ASSERT
    m_nullTexture2D->setLabel(GetLabel("Null texture 2D", m_nullTexture2D));
#endif

    m_memoryManager = new MetalMemoryManager(this);
    m_outputShaderCache = new MetalOutputShaderCache(this);
    m_pipelineCache = new MetalPipelineCache(this);
    m_depthStencilCache = new MetalDepthStencilCache(this);
    m_samplerCache = new MetalSamplerCache(this);

    // Lower the commit treshold when buffer cache needs reduced latency
    if (m_memoryManager->NeedsReducedLatency())
        m_defaultCommitTreshlod = 64;
    else
        m_defaultCommitTreshlod = 196;
    // Iridia: on the Mac, commit every 24 draw sequences (sooner commits let the GPU start while the CPU is still
    // encoding the frame). Mac sweep 4..64: 24 best (38.7 fps vs 37.7 at 32, 32.7 at upstream 196). On the iPhone it
    // was slower over 20-min runs (14.7 vs 15.9 fps, heat-bound), so iOS keeps upstream's value.
    // IRIDIA_COMMIT_DRAWS=<n> overrides it (196 = upstream).
#if !TARGET_OS_IPHONE
    m_defaultCommitTreshlod = 24;
#endif
    if (const char* v = getenv("IRIDIA_COMMIT_DRAWS"); v && atoi(v) > 0)
        m_defaultCommitTreshlod = atoi(v);

    // Occlusion queries
    m_occlusionQuery.m_resultBuffer = m_device->newBuffer(OCCLUSION_QUERY_POOL_SIZE * sizeof(uint64), MTL::ResourceStorageModeShared);
#ifdef CEMU_DEBUG_ASSERT
    m_occlusionQuery.m_resultBuffer->setLabel(GetLabel("Occlusion query result buffer", m_occlusionQuery.m_resultBuffer));
#endif
    m_occlusionQuery.m_resultsPtr = (uint64*)m_occlusionQuery.m_resultBuffer->contents();

    // Reset vertex and uniform buffers
   	for (uint32 i = 0; i < MAX_MTL_VERTEX_BUFFERS; i++)
        m_state.m_vertexBufferOffsets[i] = INVALID_OFFSET;

   	for (uint32 i = 0; i < METAL_SHADER_TYPE_TOTAL; i++)
    {
        for (uint32 j = 0; j < MAX_MTL_BUFFERS; j++)
            m_state.m_uniformBufferOffsets[i][j] = INVALID_OFFSET;
    }

    // Utility shader library

    // Create the library
    NS::Error* error = nullptr;
	NS_STACK_SCOPED MTL::Library* utilityLibrary = m_device->newLibrary(ToNSString(utilityShaderSource), nullptr, &error);
	if (error)
    {
        cemuLog_log(LogType::Force, "failed to create utility library (error: {})", error->localizedDescription()->utf8String());
    }

    // Pipelines
    NS_STACK_SCOPED MTL::Function* vertexFullscreenFunction = utilityLibrary->newFunction(ToNSString("vertexFullscreen"));
    NS_STACK_SCOPED MTL::Function* fragmentCopyDepthToColorFunction = utilityLibrary->newFunction(ToNSString("fragmentCopyDepthToColor"));

    m_copyDepthToColorDesc = MTL::RenderPipelineDescriptor::alloc()->init();
    m_copyDepthToColorDesc->setVertexFunction(vertexFullscreenFunction);
    m_copyDepthToColorDesc->setFragmentFunction(fragmentCopyDepthToColorFunction);

    // Void vertex pipelines
    if (m_isAppleGPU)
        m_copyBufferToBufferPipeline = new MetalVoidVertexPipeline(this, utilityLibrary, "vertexCopyBufferToBuffer");

    // HACK: for some reason, this variable ends up being initialized to some garbage data, even though its declared as bool m_captureFrame = false;
    m_occlusionQuery.m_lastCommandBuffer = nullptr;
    m_captureFrame = false;

    // Iridia study only: IRIDIA_GPU_WARM=<iterations> keeps one small compute job always queued on its own queue, so
    // the GPU never looks idle to the OS clock heuristics (measures how much GPU clock speed limits the frame)
    if (const char* v = getenv("IRIDIA_GPU_WARM"); v && atoi(v) > 0)
    {
        const uint32 iterations = (uint32)atoi(v);
        const uint32 sleepUs = getenv("IRIDIA_GPU_WARM_SLEEP_US") ? (uint32)atoi(getenv("IRIDIA_GPU_WARM_SLEEP_US")) : 0; // pause between jobs
        m_iridiaWarmRun = true;
        // IRIDIA_GPU_WARM_GATE=1: only spin while game GPU work is in flight (committed, not completed)
        m_iridiaWarmGate = getenv("IRIDIA_GPU_WARM_GATE") != nullptr;
        m_iridiaWarmThread = std::thread([this, iterations, sleepUs]() {
            NS::Error* err = nullptr;
            auto lib = m_device->newLibrary(ToNSString("kernel void iridiaSpin(device uint* out [[buffer(0)]], constant uint& n [[buffer(1)]], uint tid [[thread_position_in_grid]]) {"
                " uint x = tid; for (uint i = 0; i < n; i++) x = x * 1664525u + 1013904223u; if (x == 7u) out[0] = x; }"), nullptr, &err);
            if (!lib) { fprintf(stderr, "IRIDIA_GPU_WARM: compile failed\n"); return; }
            auto fn = lib->newFunction(ToNSString("iridiaSpin"));
            auto pso = m_device->newComputePipelineState(fn, &err);
            auto queue = m_device->newCommandQueue();
            auto out = m_device->newBuffer(16, MTL::ResourceStorageModePrivate);
            fprintf(stderr, "IRIDIA_GPU_WARM on, %u iterations per job, %u us pause\n", iterations, sleepUs);
            uint64 jobs = 0, jobNs = 0; auto lastPrint = std::chrono::steady_clock::now();
            // IRIDIA_GPU_WARM_MAXTHERMAL (default 1 = fair): no warm-up while the device is hotter than this
            // (0 nominal, 1 fair, 2 serious, 3 critical); the extra GPU clock must not make a hot phone throttle
            const int maxThermal = getenv("IRIDIA_GPU_WARM_MAXTHERMAL") ? atoi(getenv("IRIDIA_GPU_WARM_MAXTHERMAL")) : 1;
            auto lastThermalCheck = std::chrono::steady_clock::now() - std::chrono::seconds(10);
            bool tooHot = false;
            while (m_iridiaWarmRun.load())
            {
                if (std::chrono::steady_clock::now() - lastThermalCheck > std::chrono::seconds(1))
                {
                    lastThermalCheck = std::chrono::steady_clock::now();
                    const bool hot = (int)NS::ProcessInfo::processInfo()->thermalState() > maxThermal;
                    if (hot != tooHot)
                        fprintf(stderr, "IRIDIA_GPU_WARM %s (thermal state %d)\n", hot ? "paused" : "resumed", (int)NS::ProcessInfo::processInfo()->thermalState());
                    tooHot = hot;
                }
                if (tooHot)
                {
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
                    continue;
                }
                if (m_iridiaWarmGate)
                {
                    // IRIDIA_GPU_WARM_HOLD_US: keep spinning this long after the game's GPU work drained
                    static const auto s_hold = std::chrono::microseconds(getenv("IRIDIA_GPU_WARM_HOLD_US") ? atoi(getenv("IRIDIA_GPU_WARM_HOLD_US")) : 0);
                    static auto s_lastBusy = std::chrono::steady_clock::now();
                    const auto now = std::chrono::steady_clock::now();
                    if (m_iridiaInFlight.load(std::memory_order_relaxed) > 0)
                        s_lastBusy = now;
                    else if (now - s_lastBusy >= s_hold)
                    {
                        m_iridiaInFlight.wait(0, std::memory_order_relaxed); // sleep until the game commits GPU work
                        continue;
                    }
                }
                auto pool = NS::AutoreleasePool::alloc()->init();
                auto cb = queue->commandBuffer();
                auto enc = cb->computeCommandEncoder();
                enc->setComputePipelineState(pso);
                enc->setBuffer(out, 0, 0);
                enc->setBytes(&iterations, sizeof(iterations), 1);
                enc->dispatchThreadgroups(MTL::Size(1, 1, 1), MTL::Size(32, 1, 1));
                enc->endEncoding();
                cb->commit();
                cb->waitUntilCompleted();
                jobs++; jobNs += (uint64)((cb->GPUEndTime() - cb->GPUStartTime()) * 1e9);
                pool->release();
                if (std::chrono::steady_clock::now() - lastPrint > std::chrono::seconds(5))
                {
                    fprintf(stderr, "IRIDIA_GPU_WARM jobs/s %.0f, GPU us per job %.0f\n", jobs / 5.0, jobs ? jobNs / 1000.0 / jobs : 0.0);
                    jobs = jobNs = 0; lastPrint = std::chrono::steady_clock::now();
                }
                if (sleepUs)
                    std::this_thread::sleep_for(std::chrono::microseconds(sleepUs));
            }
            out->release(); queue->release(); pso->release(); fn->release(); lib->release();
        });
    }
}

MetalRenderer::~MetalRenderer()
{
    m_iridiaWarmRun = false;
    m_iridiaInFlight.fetch_add(1); // wake the warm-up thread if it sleeps
    m_iridiaInFlight.notify_all();
    if (m_iridiaWarmThread.joinable())
        m_iridiaWarmThread.join();
    if (m_isAppleGPU)
        delete m_copyBufferToBufferPipeline;
    //delete m_copyTextureToTexturePipeline;
    //delete m_restrideBufferPipeline;

    m_copyDepthToColorDesc->release();
    for (const auto [pixelFormat, pipeline] : m_copyDepthToColorPipelines)
        pipeline->release();

    delete m_outputShaderCache;
    delete m_pipelineCache;
    delete m_depthStencilCache;
    delete m_samplerCache;
    delete m_memoryManager;

    m_nullTexture1D->release();
    m_nullTexture2D->release();

    m_nearestSampler->release();
    m_linearSampler->release();

    if (m_readbackBuffer)
        m_readbackBuffer->release();

    if (m_xfbRingBuffer)
        m_xfbRingBuffer->release();

    m_occlusionQuery.m_resultBuffer->release();

    m_event->release();

    m_commandQueue->release();
    m_device->release();
}

void MetalRenderer::InitializeLayer(const Vector2i& size, bool mainWindow)
{
    auto& layer = GetLayer(mainWindow);
    layer = MetalLayerHandle(m_device, size, mainWindow);
    layer.GetLayer()->setPixelFormat(MTL::PixelFormatBGRA8Unorm);
}

void MetalRenderer::ShutdownLayer(bool mainWindow)
{
    GetLayer(mainWindow) = MetalLayerHandle();
}

void MetalRenderer::ResizeLayer(const Vector2i& size, bool mainWindow)
{
    GetLayer(mainWindow).Resize(size);
}

void MetalRenderer::Initialize()
{
    Renderer::Initialize();
    RendererShaderMtl::Initialize();
}

void MetalRenderer::Shutdown()
{
    // TODO: should shutdown both layers
    ImGui_ImplMetal_Shutdown();
    CommitCommandBuffer();
    Renderer::Shutdown();
    RendererShaderMtl::Shutdown();
}

bool MetalRenderer::IsPadWindowActive()
{
    return (GetLayer(false).GetLayer() != nullptr);
}

bool MetalRenderer::GetVRAMInfo(int& usageInMB, int& totalInMB) const
{
    // Subtract host memory from total VRAM, since it's shared with the CPU
    usageInMB = (m_device->currentAllocatedSize() - m_memoryManager->GetHostAllocationSize()) / 1024 / 1024;
    totalInMB = m_recommendedMaxVRAMUsage / 1024 / 1024;

    return true;
}

void MetalRenderer::ClearColorbuffer(bool padView)
{
    if (!AcquireDrawable(!padView))
        return;

    ClearColorTextureInternal(GetLayer(!padView).GetDrawable()->texture(), 0, 0, 0.0f, 0.0f, 0.0f, 0.0f);
}

void MetalRenderer::DrawEmptyFrame(bool mainWindow)
{
    if (!BeginFrame(mainWindow))
		return;
	SwapBuffers(mainWindow, !mainWindow);
}

void MetalRenderer::SwapBuffers(bool swapTV, bool swapDRC)
{
    IridiaTL(TL_LSWAP_B);
    if (swapTV)
        SwapBuffer(true);
    if (swapDRC)
        SwapBuffer(false);

    // Reset the command buffers (they are released by TemporaryBufferAllocator)
    CommitCommandBuffer();
    IridiaTL(TL_LSWAP_E);
    if (s_pp.on)
        IridiaPassPrint(m_device);
    IridiaSeqFrame();

    // Debug
    {
        // Iridia diagnostics: IRIDIA_DRAWSTATS=1, per-frame draw kinds every 5 s
        static const bool on = getenv("IRIDIA_DRAWSTATS") != nullptr;
        static uint64 manual = 0, mesh = 0, fans = 0, passes = 0, cbs = 0, frames = 0;
        static auto last = std::chrono::steady_clock::now();
        if (on)
        {
            manual += m_performanceMonitor.m_manualVertexFetchDraws; mesh += m_performanceMonitor.m_meshDraws; fans += m_performanceMonitor.m_triangleFans;
            passes += m_performanceMonitor.m_renderPasses; cbs += m_performanceMonitor.m_commandBuffers; frames++;
            if (std::chrono::steady_clock::now() - last > std::chrono::seconds(5))
            {
                fprintf(stderr, "IRIDIA_DRAWSTATS per frame: manual-fetch draws %.1f, mesh (GS) draws %.1f, triangle fans %.1f, render passes %.1f, command buffers %.1f, buffer uploads cpu %.1f gpu %.1f (busy in recording cb %.1f, in executing cb %.1f), streamout copies in pass %.1f blit %.1f\n",
                    (double)manual / frames, (double)mesh / frames, (double)fans / frames, (double)passes / frames, (double)cbs / frames,
                    (double)m_memoryManager->m_iridiaCpuUploads / frames, (double)m_memoryManager->m_iridiaGpuUploads / frames,
                    (double)m_memoryManager->m_iridiaBusyCurrent / frames, (double)m_memoryManager->m_iridiaBusyExecuting / frames,
                    (double)m_iridiaXfbInPass / frames, (double)m_iridiaXfbBlit / frames);
                m_iridiaXfbInPass = m_iridiaXfbBlit = 0;
                m_memoryManager->m_iridiaCpuUploads = m_memoryManager->m_iridiaGpuUploads = m_memoryManager->m_iridiaBusyCurrent = m_memoryManager->m_iridiaBusyExecuting = 0;
                manual = mesh = fans = passes = cbs = frames = 0; last = std::chrono::steady_clock::now();
            }
        }
    }
    {
        // Iridia diagnostics: IRIDIA_BUFSTATS=1, once a second: buffer cache uploads per frame (and how many
        // IRIDIA_SKIP_SAME_UPLOAD skipped), and the CPU time of this thread (the GPU command thread)
        static const bool on = getenv("IRIDIA_BUFSTATS") != nullptr;
        static uint64 frames = 0, lastCpuNs = 0;
        static auto last = std::chrono::steady_clock::now();
        if (on)
        {
            frames++;
            auto now = std::chrono::steady_clock::now();
            if (now - last >= std::chrono::seconds(1))
            {
                const uint64 cpuNs = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
                const double wallMs = std::chrono::duration<double, std::milli>(now - last).count();
                auto* mm = m_memoryManager;
                fprintf(stderr, "IRIDIA_TEXMEM BC-format textures %lld (%.1f MB), other %lld (%.1f MB), device allocated %.1f MB, BC supported %d\n",
                    (long long)g_iridiaTexCount[0].load(), g_iridiaTexBytes[0].load() / 1048576.0, (long long)g_iridiaTexCount[1].load(),
                    g_iridiaTexBytes[1].load() / 1048576.0, m_device->currentAllocatedSize() / 1048576.0, (int)m_pixelFormatSupport.m_supportsBC);
                {
                    static const char* names[5] = {"BC1", "BC2", "BC3", "BC4", "BC5"};
                    std::string line = "IRIDIA_ASTC transcoded (since start):";
                    for (int i = 0; i < 5; i++)
                    {
                        auto& st = IridiaAstc::g_stats[i];
                        const uint64 b = st.blocks.load();
                        if (!b) continue;
                        const double mse = (double)st.se.load() / (b * 64.0);
                        line += fmt::format(" {} {} blocks PSNR {:.1f} dB {:.0f} ms ({:.0f} ns/block);", names[i], b, mse > 0 ? 10 * std::log10(255.0 * 255.0 / mse) : 99.0, st.ns.load() / 1e6, (double)st.ns.load() / b);
                    }
                    fprintf(stderr, "%s\n", line.c_str());
                }
                fprintf(stderr, "IRIDIA_BUF per frame: uploads %.1f (%.1f KB), skipped same %.1f (%.1f KB), not compared (GPU write pending) %.1f; GPU command thread cpu %.0f ms/s\n",
                    (double)mm->m_iridiaUploads / frames, mm->m_iridiaUploadBytes / 1024.0 / frames, (double)mm->m_iridiaSkips / frames,
                    mm->m_iridiaSkipBytes / 1024.0 / frames, (double)mm->m_iridiaSkipPending / frames,
                    lastCpuNs ? (cpuNs - lastCpuNs) / 1e6 * (1000.0 / wallMs) : 0.0);
                mm->m_iridiaUploads = mm->m_iridiaUploadBytes = mm->m_iridiaSkips = mm->m_iridiaSkipBytes = mm->m_iridiaSkipPending = 0;
                frames = 0; lastCpuNs = cpuNs; last = now;
            }
        }
    }
    m_performanceMonitor.ResetPerFrameData();

    // GPU capture
    if (m_capturing)
    {
        EndCapture();
    }
    else if (m_captureFrame)
    {
        StartCapture();
        m_captureFrame = false;
    }
}

// Iridia study: screenshots are read back without interrupting rendering. The frame is blitted into a
// dedicated shared buffer inside the normal command buffer; the pixels are read on a later frame once that
// command buffer has completed. (Upstream read the staging buffer before the blit ran, and only handled
// RGBA8 formats; forcing a flush mid-frame instead broke rendering.)
static struct
{
	MTL::Buffer* buffer = nullptr;
	MTL::CommandBuffer* commandBuffer = nullptr;
	MTL::PixelFormat format;
	int width = 0, height = 0;
	uint32 bytesPerRow = 0;
	bool padView = false;
} s_pendingShot;

void MetalRenderer::HandleScreenshotRequest(LatteTextureView* texView, bool padView) {
	// finish a pending readback once its command buffer is done
	if (s_pendingShot.commandBuffer && s_pendingShot.commandBuffer->status() >= MTL::CommandBufferStatusCompleted)
	{
		const uint8* mem = (const uint8*)s_pendingShot.buffer->contents();
		std::vector<uint8> rgb_data;
		rgb_data.reserve(3 * s_pendingShot.width * s_pendingShot.height);
		bool formatValid = true;
		for (int y = 0; y < s_pendingShot.height && formatValid; y++)
		{
			const uint8* row = mem + (size_t)y * s_pendingShot.bytesPerRow;
			for (int x = 0; x < s_pendingShot.width; x++)
			{
				const uint8* px = row + x * 4;
				switch (s_pendingShot.format)
				{
				case MTL::PixelFormatRGBA8Unorm:
					rgb_data.insert(rgb_data.end(), { px[0], px[1], px[2] });
					break;
				case MTL::PixelFormatRGBA8Unorm_sRGB:
					rgb_data.insert(rgb_data.end(), { SRGBComponentToRGB(px[0]), SRGBComponentToRGB(px[1]), SRGBComponentToRGB(px[2]) });
					break;
				case MTL::PixelFormatRGB10A2Unorm:
				{
					uint32 v = *(const uint32*)px;
					rgb_data.insert(rgb_data.end(), { (uint8)(((v >> 0) & 0x3FF) >> 2), (uint8)(((v >> 10) & 0x3FF) >> 2), (uint8)(((v >> 20) & 0x3FF) >> 2) });
					break;
				}
				default:
					formatValid = false;
					break;
				}
				if (!formatValid) break;
			}
		}
		if (formatValid)
			SaveScreenshot(rgb_data, s_pendingShot.width, s_pendingShot.height, !s_pendingShot.padView);
		else
			cemuLog_log(LogType::Force, "Unsupported screenshot texture pixel format {}", s_pendingShot.format);
		s_pendingShot.commandBuffer->release();
		s_pendingShot.buffer->release();
		s_pendingShot.commandBuffer = nullptr;
		s_pendingShot.buffer = nullptr;
	}

	if (!m_screenshot_requested || s_pendingShot.commandBuffer || padView)
		return;

	auto texMtl = static_cast<LatteTextureMtl*>(texView->baseTexture);
	int width, height;
	texMtl->GetEffectiveSize(width, height, 0);
	uint32 bytesPerRow = GetMtlTextureBytesPerRow(texMtl->format, texMtl->isDepth, width);
	uint32 size = GetMtlTextureBytesPerImage(texMtl->format, texMtl->isDepth, height, bytesPerRow);

	MTL::Buffer* buffer = m_device->newBuffer(size, MTL::ResourceStorageModeShared);
	auto blitCommandEncoder = GetBlitCommandEncoder();
	blitCommandEncoder->copyFromTexture(texMtl->GetTexture(), 0, 0, MTL::Origin(0, 0, 0), MTL::Size(width, height, 1), buffer, 0, bytesPerRow, 0);

	s_pendingShot.buffer = buffer;
	s_pendingShot.commandBuffer = m_currentCommandBuffer.m_commandBuffer->retain();
	s_pendingShot.format = texMtl->GetTexture()->pixelFormat();
	s_pendingShot.width = width;
	s_pendingShot.height = height;
	s_pendingShot.bytesPerRow = bytesPerRow;
	s_pendingShot.padView = padView;
}

void MetalRenderer::DrawBackbufferQuad(LatteTextureView* texView, RendererOutputShader* shader, bool useLinearTexFilter,
								sint32 imageX, sint32 imageY, sint32 imageWidth, sint32 imageHeight,
								bool padView, bool clearBackground)
{
    if (!AcquireDrawable(!padView))
        return;

    MTL::Texture* presentTexture = static_cast<LatteTextureViewMtl*>(texView)->GetRGBAView();

    // Create render pass
    auto& layer = GetLayer(!padView);

    NS_STACK_SCOPED MTL::RenderPassDescriptor* renderPassDescriptor = MTL::RenderPassDescriptor::alloc()->init();
    auto colorAttachment = renderPassDescriptor->colorAttachments()->object(0);
    colorAttachment->setTexture(layer.GetDrawable()->texture());
    colorAttachment->setLoadAction(clearBackground ? MTL::LoadActionClear : MTL::LoadActionLoad);
    colorAttachment->setStoreAction(MTL::StoreActionStore);

    auto renderCommandEncoder = GetTemporaryRenderCommandEncoder(renderPassDescriptor);

    // Get a render pipeline

    // Find out which shader we are using
    uint8 shaderIndex = 255;
    if (shader == RendererOutputShader::s_copy_shader) shaderIndex = 0;
    else if (shader == RendererOutputShader::s_bicubic_shader) shaderIndex = 1;
    else if (shader == RendererOutputShader::s_hermit_shader) shaderIndex = 2;
    else if (shader == RendererOutputShader::s_copy_shader_ud) shaderIndex = 3;
    else if (shader == RendererOutputShader::s_bicubic_shader_ud) shaderIndex = 4;
    else if (shader == RendererOutputShader::s_hermit_shader_ud) shaderIndex = 5;

    uint8 shaderType = shaderIndex % 3;

    // Get the render pipeline state
    auto renderPipelineState = m_outputShaderCache->GetPipeline(shader, shaderIndex, m_state.m_usesSRGB);

    // Draw to Metal layer
    renderCommandEncoder->setRenderPipelineState(renderPipelineState);
    renderCommandEncoder->setFragmentTexture(presentTexture, 0);
    renderCommandEncoder->setFragmentSamplerState((useLinearTexFilter ? m_linearSampler : m_nearestSampler), 0);

    // Set uniforms
    float outputSize[2] = {(float)imageWidth, (float)imageHeight};
    switch (shaderType)
    {
    case 2:
        renderCommandEncoder->setFragmentBytes(outputSize, sizeof(outputSize), 0);
        break;
    default:
        break;
    }

    renderCommandEncoder->setViewport(MTL::Viewport{(double)imageX, (double)imageY, (double)imageWidth, (double)imageHeight, 0.0, 1.0});
    renderCommandEncoder->setScissorRect(MTL::ScissorRect{(uint32)imageX, (uint32)imageY, (uint32)imageWidth, (uint32)imageHeight});

    renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle, NS::UInteger(0), NS::UInteger(3));

    EndEncoding();
}

bool MetalRenderer::BeginFrame(bool mainWindow)
{
    return AcquireDrawable(mainWindow);
}

void MetalRenderer::Flush(bool waitIdle)
{
    if (m_recordedDrawcalls > 0 || waitIdle)
        CommitCommandBuffer();

    if (waitIdle && m_executingCommandBuffers.size() != 0)
    {
        IridiaWaitTimer iridiaWait(4);
        m_executingCommandBuffers.back()->waitUntilCompleted();
    }
}

void MetalRenderer::NotifyLatteCommandProcessorIdle()
{
    //if (m_commitOnIdle)
    //    CommitCommandBuffer();
}

bool MetalRenderer::ImguiBegin(bool mainWindow)
{
    if (!Renderer::ImguiBegin(mainWindow))
		return false;

	if (!AcquireDrawable(mainWindow))
		return false;

	EnsureImGuiBackend();

	// Check if the font texture needs to be built
	ImGuiIO& io = ImGui::GetIO();
    if (!io.Fonts->IsBuilt())
        ImGui_ImplMetal_CreateFontsTexture(m_device);

	auto& layer = GetLayer(mainWindow);

	// Render pass descriptor
	NS_STACK_SCOPED MTL::RenderPassDescriptor* renderPassDescriptor = MTL::RenderPassDescriptor::alloc()->init();
    auto colorAttachment = renderPassDescriptor->colorAttachments()->object(0);
    colorAttachment->setTexture(layer.GetDrawable()->texture());
    colorAttachment->setLoadAction(MTL::LoadActionLoad);
    colorAttachment->setStoreAction(MTL::StoreActionStore);

    // New frame
	ImGui_ImplMetal_NewFrame(renderPassDescriptor);
	ImGui_UpdateWindowInformation(mainWindow);
	ImGui::NewFrame();

	if (m_encoderType != MetalEncoderType::Render)
	    GetTemporaryRenderCommandEncoder(renderPassDescriptor);

	return true;
}

void MetalRenderer::ImguiEnd()
{
    EnsureImGuiBackend();

    if (m_encoderType != MetalEncoderType::Render)
    {
        cemuLog_logOnce(LogType::Force, "no render command encoder, cannot draw ImGui");
        return;
    }

    ImGui::Render();
	ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), GetCurrentCommandBuffer(), (MTL::RenderCommandEncoder*)m_commandEncoder);
	//ImGui::EndFrame();

	EndEncoding();
}

ImTextureID MetalRenderer::GenerateTexture(const std::vector<uint8>& data, const Vector2i& size)
{
    try
	{
		std::vector <uint8> tmp(size.x * size.y * 4);
		for (size_t i = 0; i < data.size() / 3; ++i)
		{
			tmp[(i * 4) + 0] = data[(i * 3) + 0];
			tmp[(i * 4) + 1] = data[(i * 3) + 1];
			tmp[(i * 4) + 2] = data[(i * 3) + 2];
			tmp[(i * 4) + 3] = 0xFF;
		}

		NS_STACK_SCOPED MTL::TextureDescriptor* desc = MTL::TextureDescriptor::alloc()->init();
		desc->setTextureType(MTL::TextureType2D);
		desc->setPixelFormat(MTL::PixelFormatRGBA8Unorm);
		desc->setWidth(size.x);
		desc->setHeight(size.y);
		desc->setStorageMode((m_isAppleGPU || TARGET_OS_IPHONE) ? MTL::StorageModeShared : MTL::StorageModeManaged);
		desc->setUsage(MTL::TextureUsageShaderRead);

		MTL::Texture* texture = m_device->newTexture(desc);

		// TODO: do a GPU copy?
		texture->replaceRegion(MTL::Region(0, 0, size.x, size.y), 0, 0, tmp.data(), size.x * 4, 0);

		return (ImTextureID)texture;
	}
	catch (const std::exception& ex)
	{
		cemuLog_log(LogType::Force, "can't generate imgui texture: {}", ex.what());
		return nullptr;
	}
}

void MetalRenderer::DeleteTexture(ImTextureID id)
{
    EnsureImGuiBackend();

    ((MTL::Texture*)id)->release();
}

void MetalRenderer::DeleteFontTextures()
{
    EnsureImGuiBackend();

    ImGui_ImplMetal_DestroyFontsTexture();
}

void MetalRenderer::AppendOverlayDebugInfo()
{
    ImGui::Text("--- GPU info ---");
    ImGui::Text("GPU                        %s", m_device->name()->utf8String());
    ImGui::Text("Is Apple GPU               %s", (m_isAppleGPU ? "yes" : "no"));
    ImGui::Text("Supports framebuffer fetch %s", (m_supportsFramebufferFetch ? "yes" : "no"));
    ImGui::Text("Has unified memory         %s", (m_hasUnifiedMemory ? "yes" : "no"));
    ImGui::Text("Supports Metal3            %s", (m_supportsMetal3 ? "yes" : "no"));

    ImGui::Text("--- Metal info ---");
    ImGui::Text("Render pipeline states     %zu", m_pipelineCache->GetPipelineCacheSize());

    ImGui::Text("--- Metal info (per frame) ---");
    ImGui::Text("Command buffers            %u", m_performanceMonitor.m_commandBuffers);
    ImGui::Text("Render passes              %u", m_performanceMonitor.m_renderPasses);
    ImGui::Text("Clears                     %u", m_performanceMonitor.m_clears);
    ImGui::Text("Manual vertex fetch draws  %u (mesh draws: %u)", m_performanceMonitor.m_manualVertexFetchDraws, m_performanceMonitor.m_meshDraws);
    ImGui::Text("Triangle fans              %u", m_performanceMonitor.m_triangleFans);

    ImGui::Text("--- Cache debug info ---");

	uint32 bufferCacheHeapSize = 0;
	uint32 bufferCacheAllocationSize = 0;
	uint32 bufferCacheNumAllocations = 0;

	LatteBufferCache_getStats(bufferCacheHeapSize, bufferCacheAllocationSize, bufferCacheNumAllocations);

	ImGui::Text("Buffer");
	ImGui::SameLine(60.0f);
	ImGui::Text("%06uKB / %06uKB Allocs: %u", (uint32)(bufferCacheAllocationSize + 1023) / 1024, ((uint32)bufferCacheHeapSize + 1023) / 1024, (uint32)bufferCacheNumAllocations);

	uint32 numBuffers;
	size_t totalSize, freeSize;

	m_memoryManager->GetStagingAllocator().GetStats(numBuffers, totalSize, freeSize);
	ImGui::Text("Staging");
	ImGui::SameLine(60.0f);
	ImGui::Text("%06uKB / %06uKB Buffers: %u", ((uint32)(totalSize - freeSize) + 1023) / 1024, ((uint32)totalSize + 1023) / 1024, (uint32)numBuffers);

	m_memoryManager->GetIndexAllocator().GetStats(numBuffers, totalSize, freeSize);
	ImGui::Text("Index");
	ImGui::SameLine(60.0f);
	ImGui::Text("%06uKB / %06uKB Buffers: %u", ((uint32)(totalSize - freeSize) + 1023) / 1024, ((uint32)totalSize + 1023) / 1024, (uint32)numBuffers);
}

void MetalRenderer::renderTarget_setViewport(float x, float y, float width, float height, float nearZ, float farZ, bool halfZ)
{
    // halfZ is handled in the shader

    m_state.m_viewport = MTL::Viewport{x, y, width, height, nearZ, farZ};
}

void MetalRenderer::renderTarget_setScissor(sint32 scissorX, sint32 scissorY, sint32 scissorWidth, sint32 scissorHeight)
{
    m_state.m_scissor = MTL::ScissorRect{(uint32)scissorX, (uint32)scissorY, (uint32)scissorWidth, (uint32)scissorHeight};
}

LatteCachedFBO* MetalRenderer::rendertarget_createCachedFBO(uint64 key)
{
	return new CachedFBOMtl(this, key);
}

void MetalRenderer::rendertarget_deleteCachedFBO(LatteCachedFBO* cfbo)
{
	if (cfbo == (LatteCachedFBO*)m_state.m_activeFBO.m_fbo)
	    m_state.m_activeFBO = {nullptr};
	if (cfbo == (LatteCachedFBO*)m_iridiaResumeFBO.m_fbo)
	    m_iridiaResumeFBO = {nullptr};
}

void MetalRenderer::rendertarget_bindFramebufferObject(LatteCachedFBO* cfbo)
{
	m_state.m_activeFBO = {(CachedFBOMtl*)cfbo, MetalAttachmentsInfo((CachedFBOMtl*)cfbo)};
	m_state.m_fboChanged = true;
}

void* MetalRenderer::texture_acquireTextureUploadBuffer(uint32 size)
{
    return m_memoryManager->AcquireTextureUploadBuffer(size);
}

void MetalRenderer::texture_releaseTextureUploadBuffer(uint8* mem)
{
    m_memoryManager->ReleaseTextureUploadBuffer(mem);
}

TextureDecoder* MetalRenderer::texture_chooseDecodedFormat(Latte::E_GX2SURFFMT format, bool isDepth, Latte::E_DIM dim, uint32 width, uint32 height)
{
    return GetMtlPixelFormatInfo(format, isDepth).textureDecoder;
}

void MetalRenderer::texture_clearSlice(LatteTexture* hostTexture, sint32 sliceIndex, sint32 mipIndex)
{
    if (hostTexture->isDepth)
    {
        texture_clearDepthSlice(hostTexture, sliceIndex, mipIndex, true, hostTexture->hasStencil, 0.0f, 0);
    }
    else
    {
        texture_clearColorSlice(hostTexture, sliceIndex, mipIndex, 0.0f, 0.0f, 0.0f, 0.0f);
    }
}

MTL::BlitOption GetBlitOptionForTexture(const LatteTextureMtl* texture) {
    switch (texture->GetTexture()->pixelFormat()) {
        case MTL::PixelFormatDepth16Unorm:
        case MTL::PixelFormatDepth32Float:
            return MTL::BlitOptionDepthFromDepthStencil;

        case MTL::PixelFormatStencil8:
            return MTL::BlitOptionStencilFromDepthStencil;

        case MTL::PixelFormatDepth24Unorm_Stencil8:
        case MTL::PixelFormatDepth32Float_Stencil8:
            // Can't copy both in one call — caller must specify.
            // Default to depth
            return MTL::BlitOptionDepthFromDepthStencil;

        default:
            return MTL::BlitOptionNone;
    }
}

bool IsDepthStencilFormat(MTL::PixelFormat format) {
    return format == MTL::PixelFormatDepth24Unorm_Stencil8 ||
           format == MTL::PixelFormatDepth32Float_Stencil8;
}

// TODO: do a cpu copy on Apple Silicon?
void MetalRenderer::texture_loadSlice(LatteTexture* hostTexture, sint32 width, sint32 height, sint32 depth, void* pixelData, sint32 sliceIndex, sint32 mipIndex, uint32 compressedImageSize)
{
    auto textureMtl = (LatteTextureMtl*)hostTexture;

    uint32 offsetZ = 0;
    if (textureMtl->Is3DTexture())
    {
        offsetZ = sliceIndex;
        sliceIndex = 0;
    }

    size_t bytesPerRow = GetMtlTextureBytesPerRow(textureMtl->format, textureMtl->isDepth, width);
    // No need to set bytesPerImage for 3D textures, since we always load just one slice
    //size_t bytesPerImage = GetMtlTextureBytesPerImage(textureMtl->GetFormat(), textureMtl->isDepth, height, bytesPerRow);
    //if (m_isAppleGPU)
    //{
    //    textureMtl->GetTexture()->replaceRegion(MTL::Region(0, 0, offsetZ, width, height, 1), mipIndex, sliceIndex, pixelData, bytesPerRow, 0);
    //}
    //else
    //{
    auto blitCommandEncoder = GetBlitCommandEncoder();

    // Allocate a temporary buffer
    auto& bufferAllocator = m_memoryManager->GetStagingAllocator();
    auto allocation = bufferAllocator.AllocateBufferMemory(compressedImageSize, 1);
    memcpy(allocation.memPtr, pixelData, compressedImageSize);
    bufferAllocator.FlushReservation(allocation);

    // Copy the data from the temporary buffer to the texture
	if (IsDepthStencilFormat(textureMtl->GetTexture()->pixelFormat())) {
        // Metal doesn't allow copying depth and stencil data at the same time, so we need to do two copies for combined depth/stencil formats
        blitCommandEncoder->copyFromBuffer(allocation.mtlBuffer, allocation.bufferOffset, bytesPerRow, 0, MTL::Size(width, height, 1), textureMtl->GetTexture(), sliceIndex, mipIndex, MTL::Origin(0, 0, offsetZ), MTL::BlitOptionDepthFromDepthStencil);
        blitCommandEncoder->copyFromBuffer(allocation.mtlBuffer, allocation.bufferOffset, bytesPerRow, 0, MTL::Size(width, height, 1), textureMtl->GetTexture(), sliceIndex, mipIndex, MTL::Origin(0, 0, offsetZ), MTL::BlitOptionStencilFromDepthStencil);
    } else {
        blitCommandEncoder->copyFromBuffer(allocation.mtlBuffer, allocation.bufferOffset, bytesPerRow, 0, MTL::Size(width, height, 1), textureMtl->GetTexture(), sliceIndex, mipIndex, MTL::Origin(0, 0, offsetZ), GetBlitOptionForTexture(textureMtl));
    }
    //}
}

void MetalRenderer::texture_clearColorSlice(LatteTexture* hostTexture, sint32 sliceIndex, sint32 mipIndex, float r, float g, float b, float a)
{
    if (!FormatIsRenderable(hostTexture->format))
    {
        cemuLog_logOnce(LogType::Force, "cannot clear color texture with format {}, because it's not renderable", hostTexture->format);
        return;
    }

    auto mtlTexture = static_cast<LatteTextureMtl*>(hostTexture)->GetTexture();

    if (IridiaFoldClearsOn())
    {
        IridiaDeferClear(mtlTexture, sliceIndex, mipIndex, r, g, b, a);
        return;
    }
    ClearColorTextureInternal(mtlTexture, sliceIndex, mipIndex, r, g, b, a);
}

// Iridia: a game's color clear is kept pending instead of running as its own render pass. If the next render pass
// renders to that texture (same slice, level and pixel format), the pass starts with a clear load action instead:
// on a tile-based GPU that saves writing the cleared texture out and reading it back in. Before anything else can
// touch a texture (another render pass, a temporary pass, blit or compute work, a commit) the pending clears run as
// before. The open encoder is ended at the clear, like the clear pass did. Off by default: IRIDIA_FOLD_CLEARS=1 turns it on
// (neutral on the Mac; the saving is memory traffic, to be measured on the phone).
bool MetalRenderer::IridiaFoldClearsOn()
{
    static const bool v = getenv("IRIDIA_FOLD_CLEARS") && atoi(getenv("IRIDIA_FOLD_CLEARS")) != 0; // off by default (phone test pending)
    return v;
}

void MetalRenderer::IridiaDeferClear(MTL::Texture* texture, sint32 slice, sint32 mip, float r, float g, float b, float a)
{
    EndEncoding();
    for (auto& c : m_iridiaPendingClears)
        if (c.texture == texture && c.slice == slice && c.mip == mip)
        {
            c.color = MTL::ClearColor(r, g, b, a); // cleared again before any use: the last color wins
            return;
        }
    texture->retain();
    m_iridiaPendingClears.push_back({texture, slice, mip, MTL::ClearColor(r, g, b, a)});
}

void MetalRenderer::IridiaFlushClears()
{
    if (m_iridiaPendingClears.empty())
        return;
    auto pending = std::move(m_iridiaPendingClears);
    m_iridiaPendingClears.clear();
    for (auto& c : pending)
    {
        ClearColorTextureInternal(c.texture, c.slice, c.mip, c.color.red, c.color.green, c.color.blue, c.color.alpha);
        c.texture->release();
    }
}

void MetalRenderer::texture_clearDepthSlice(LatteTexture* hostTexture, uint32 sliceIndex, sint32 mipIndex, bool clearDepth, bool clearStencil, float depthValue, uint32 stencilValue)
{
    clearStencil = (clearStencil && GetMtlPixelFormatInfo(hostTexture->format, true).hasStencil);
    if (!clearDepth && !clearStencil)
    {
        cemuLog_logOnce(LogType::Force, "skipping depth/stencil clear");
        return;
    }

    auto mtlTexture = static_cast<LatteTextureMtl*>(hostTexture)->GetTexture();

    NS_STACK_SCOPED MTL::RenderPassDescriptor* renderPassDescriptor = MTL::RenderPassDescriptor::alloc()->init();
    if (clearDepth)
    {
        auto depthAttachment = renderPassDescriptor->depthAttachment();
        depthAttachment->setTexture(mtlTexture);
        depthAttachment->setClearDepth(depthValue);
        depthAttachment->setLoadAction(MTL::LoadActionClear);
        depthAttachment->setStoreAction(MTL::StoreActionStore);
        depthAttachment->setSlice(sliceIndex);
        depthAttachment->setLevel(mipIndex);
    }
    if (clearStencil)
    {
        auto stencilAttachment = renderPassDescriptor->stencilAttachment();
        stencilAttachment->setTexture(mtlTexture);
        stencilAttachment->setClearStencil(stencilValue);
        stencilAttachment->setLoadAction(MTL::LoadActionClear);
        stencilAttachment->setStoreAction(MTL::StoreActionStore);
        stencilAttachment->setSlice(sliceIndex);
        stencilAttachment->setLevel(mipIndex);
    }

    GetTemporaryRenderCommandEncoder(renderPassDescriptor);
    EndEncoding();

    // Debug
    m_performanceMonitor.m_clears++;
    g_iridiaClears[1].fetch_add(1, std::memory_order_relaxed); // Iridia: depth/stencil clears
}

LatteTexture* MetalRenderer::texture_createTextureEx(Latte::E_DIM dim, MPTR physAddress, MPTR physMipAddress, Latte::E_GX2SURFFMT format, uint32 width, uint32 height, uint32 depth, uint32 pitch, uint32 mipLevels, uint32 swizzle, Latte::E_HWTILEMODE tileMode, bool isDepth)
{
    return new LatteTextureMtl(this, dim, physAddress, physMipAddress, format, width, height, depth, pitch, mipLevels, swizzle, tileMode, isDepth);
}

void MetalRenderer::texture_setLatteTexture(LatteTextureView* textureView, uint32 textureUnit)
{
    m_state.m_textures[textureUnit] = static_cast<LatteTextureViewMtl*>(textureView);
}

void MetalRenderer::texture_copyImageSubData(LatteTexture* src, sint32 srcMip, sint32 effectiveSrcX, sint32 effectiveSrcY, sint32 srcSlice, LatteTexture* dst, sint32 dstMip, sint32 effectiveDstX, sint32 effectiveDstY, sint32 dstSlice, sint32 effectiveCopyWidth, sint32 effectiveCopyHeight, sint32 srcDepth_)
{
    // Source size seems to apply to the destination texture as well, therefore we need to adjust it when block size doesn't match
    Uvec2 srcBlockTexelSize = GetMtlPixelFormatInfo(src->format, src->isDepth).blockTexelSize;
    Uvec2 dstBlockTexelSize = GetMtlPixelFormatInfo(dst->format, dst->isDepth).blockTexelSize;
    if (srcBlockTexelSize.x != dstBlockTexelSize.x || srcBlockTexelSize.y != dstBlockTexelSize.y)
    {
        uint32 multX = (srcBlockTexelSize.x > dstBlockTexelSize.x ? srcBlockTexelSize.x / dstBlockTexelSize.x : dstBlockTexelSize.x / srcBlockTexelSize.x);
        effectiveCopyWidth *= multX;

        uint32 multY = (srcBlockTexelSize.y > dstBlockTexelSize.y ? srcBlockTexelSize.y / dstBlockTexelSize.y : dstBlockTexelSize.y / srcBlockTexelSize.y);
        effectiveCopyHeight *= multY;
    }

    if (IridiaSeqOn())
    {
        // is either texture an attachment of the open render pass?
        auto att = [&](LatteTexture* t) {
            if (m_encoderType != MetalEncoderType::Render || !m_state.m_lastUsedFBO.m_fbo) return 0;
            auto rp = m_state.m_lastUsedFBO.m_fbo->GetRenderPassDescriptor();
            auto mt = static_cast<LatteTextureMtl*>(t)->GetTexture();
            for (int i = 0; i < 8; i++) if (rp->colorAttachments()->object(i)->texture() == mt) return 1;
            return rp->depthAttachment()->texture() == mt ? 2 : 0; };
        IridiaSeq(fmt::format("copy {}x{} f{} mip{} sl{} -> {}x{} f{} mip{} sl{} size {}x{}x{} at {},{} -> {},{} src {:x} dst {:x} att {}{}{}", src->width, src->height, (int)src->format, srcMip, srcSlice, dst->width, dst->height, (int)dst->format, dstMip, dstSlice, effectiveCopyWidth, effectiveCopyHeight, srcDepth_, effectiveSrcX, effectiveSrcY, effectiveDstX, effectiveDstY, (uintptr_t)src & 0xffffff, (uintptr_t)dst & 0xffffff, att(src), att(dst), m_encoderType == MetalEncoderType::Render ? " inpass" : ""));
    }
    auto blitCommandEncoder = GetBlitCommandEncoder();

    auto mtlSrc = static_cast<LatteTextureMtl*>(src)->GetTexture();
    auto mtlDst = static_cast<LatteTextureMtl*>(dst)->GetTexture();

    uint32 srcBaseLayer = 0;
    uint32 dstBaseLayer = 0;
    uint32 srcOffsetZ = 0;
    uint32 dstOffsetZ = 0;
    uint32 srcLayerCount = 1;
    uint32 dstLayerCount = 1;
    uint32 srcDepth = 1;
    uint32 dstDepth = 1;

	if (src->Is3DTexture())
	{
		srcOffsetZ = srcSlice;
		srcDepth = srcDepth_;
	}
	else
	{
		srcBaseLayer = srcSlice;
		srcLayerCount = srcDepth_;
	}

	if (dst->Is3DTexture())
	{
		dstOffsetZ = dstSlice;
		dstDepth = srcDepth_;
	}
	else
	{
		dstBaseLayer = dstSlice;
		dstLayerCount = srcDepth_;
	}

	// If copying whole textures, we can do a more efficient copy
    if (effectiveSrcX == 0 && effectiveSrcY == 0 && effectiveDstX == 0 && effectiveDstY == 0 &&
        srcOffsetZ == 0 && dstOffsetZ == 0 &&
        effectiveCopyWidth == src->GetMipWidth(srcMip) && effectiveCopyHeight == src->GetMipHeight(srcMip) && srcDepth == src->GetMipDepth(srcMip) &&
        effectiveCopyWidth == dst->GetMipWidth(dstMip) && effectiveCopyHeight == dst->GetMipHeight(dstMip) && dstDepth == dst->GetMipDepth(dstMip) &&
        srcLayerCount == dstLayerCount)
    {
        blitCommandEncoder->copyFromTexture(mtlSrc, srcBaseLayer, srcMip, mtlDst, dstBaseLayer, dstMip, srcLayerCount, 1);
    }
    else
    {
        if (srcLayerCount == dstLayerCount)
        {
            for (uint32 i = 0; i < srcLayerCount; i++)
            {
                blitCommandEncoder->copyFromTexture(mtlSrc, srcBaseLayer + i, srcMip, MTL::Origin(effectiveSrcX, effectiveSrcY, srcOffsetZ), MTL::Size(effectiveCopyWidth, effectiveCopyHeight, srcDepth), mtlDst, dstBaseLayer + i, dstMip, MTL::Origin(effectiveDstX, effectiveDstY, dstOffsetZ));
            }
        }
        else
        {
            for (uint32 i = 0; i < std::max(srcLayerCount, dstLayerCount); i++)
            {
                if (srcLayerCount == 1)
                    srcOffsetZ++;
                else
                    srcSlice++;

                if (dstLayerCount == 1)
                    dstOffsetZ++;
                else
                    dstSlice++;

                blitCommandEncoder->copyFromTexture(mtlSrc, srcBaseLayer, srcMip, MTL::Origin(effectiveSrcX, effectiveSrcY, srcOffsetZ), MTL::Size(effectiveCopyWidth, effectiveCopyHeight, 1), mtlDst, dstBaseLayer, dstMip, MTL::Origin(effectiveDstX, effectiveDstY, dstOffsetZ));
            }
        }
    }
}

LatteTextureReadbackInfo* MetalRenderer::texture_createReadback(LatteTextureView* textureView)
{
    auto* baseTexture = static_cast<LatteTextureMtl*>(textureView->baseTexture);
    if (baseTexture->m_isAlternateFormat)
    {
        cemuLog_logDebug(LogType::Force, "Metal does not support readback of texture format 0x{:x}", (uint32)baseTexture->format);
        return nullptr;
    }
    size_t uploadSize = baseTexture->GetTexture()->allocatedSize();

    if ((m_readbackBufferWriteOffset + uploadSize) > TEXTURE_READBACK_SIZE)
	{
		m_readbackBufferWriteOffset = 0;
	}

    // Iridia: the ring must never wrap over a readback whose data has not been written to guest memory yet
    for (const auto& live : m_iridiaReadbackLive)
    {
        if (m_readbackBufferWriteOffset < live.first + live.second && live.first < m_readbackBufferWriteOffset + uploadSize)
        {
            static uint32 s_overlaps = 0;
            if (s_overlaps++ < 20)
                fprintf(stderr, "IRIDIA_RB_RING_OVERLAP new %u+%zu over unconsumed %u+%u\n", m_readbackBufferWriteOffset, uploadSize, live.first, live.second);
            cemu_assert_debug(false);
        }
    }
    m_iridiaReadbackLive.emplace_back(m_readbackBufferWriteOffset, (uint32)uploadSize);

    auto* result = new LatteTextureReadbackInfoMtl(this, textureView, m_readbackBufferWriteOffset);
    m_readbackBufferWriteOffset += uploadSize;

	return result;
}

void MetalRenderer::surfaceCopy_copySurfaceWithFormatConversion(LatteTexture* sourceTexture, sint32 srcMip, sint32 srcSlice, LatteTexture* destinationTexture, sint32 dstMip, sint32 dstSlice, sint32 width, sint32 height)
{
    // scale copy size to effective size
	sint32 effectiveCopyWidth = width;
	sint32 effectiveCopyHeight = height;
	LatteTexture_scaleToEffectiveSize(sourceTexture, &effectiveCopyWidth, &effectiveCopyHeight, 0);
	//sint32 sourceEffectiveWidth, sourceEffectiveHeight;
	//sourceTexture->GetEffectiveSize(sourceEffectiveWidth, sourceEffectiveHeight, srcMip);

    texture_copyImageSubData(sourceTexture, srcMip, 0, 0, srcSlice, destinationTexture, dstMip, 0, 0, dstSlice, effectiveCopyWidth, effectiveCopyHeight, 1);
}

void MetalRenderer::bufferCache_init(const sint32 bufferSize)
{
    m_memoryManager->InitBufferCache(bufferSize);
}

void MetalRenderer::bufferCache_upload(uint8* buffer, sint32 size, uint32 bufferOffset)
{
    m_memoryManager->UploadToBufferCache(buffer, bufferOffset, size);
}

void MetalRenderer::bufferCache_copy(uint32 srcOffset, uint32 dstOffset, uint32 size)
{
    m_memoryManager->CopyBufferCache(srcOffset, dstOffset, size);
}

// Iridia: copy into the buffer cache inside the open render pass with a vertex shader (one word per vertex) instead
// of a blit, which ended the pass and made the GPU store and reload every attachment (IRIDIA_XFB_BLIT=1 = always blit).
// Earlier draws of this pass may still read the destination (on tile GPUs their fragment work runs after all vertex
// work of the pass), so a destination they use takes the blit. srcAfter: stages that wrote src in this pass (0 = none).
bool MetalRenderer::IridiaCopyInPass(MTL::Buffer* src, size_t srcOffset, size_t dstOffset, size_t size, MTL::RenderStages srcAfter)
{
    static const bool s_blit = getenv("IRIDIA_XFB_BLIT") != nullptr;
    bool inPass = !s_blit && m_isAppleGPU && m_encoderType == MetalEncoderType::Render && ((srcOffset | dstOffset | size) & 3) == 0 && size > 0;
    for (size_t i = 0; inPass && i < m_iridiaPassReads.size(); i++)
    {
        const auto [o, n] = m_iridiaPassReads[i];
        if (n == 0 || (o < dstOffset + size && dstOffset < o + n))
            inPass = false;
    }
    (inPass ? m_iridiaXfbInPass : m_iridiaXfbBlit)++;
    if (!inPass)
        return false;
    auto renderCommandEncoder = static_cast<MTL::RenderCommandEncoder*>(m_commandEncoder);
    MTL::Buffer* dst = m_memoryManager->GetBufferCache();

    MTL::Resource* barrierBuffers[] = {src};
    if (srcAfter)
        renderCommandEncoder->memoryBarrier(barrierBuffers, 1, srcAfter, MTL::RenderStageVertex);

    renderCommandEncoder->setRenderPipelineState(m_copyBufferToBufferPipeline->GetRenderPipelineState());
    m_state.m_encoderState.m_renderPipelineState = m_copyBufferToBufferPipeline->GetRenderPipelineState();

    SetBuffer(renderCommandEncoder, METAL_SHADER_TYPE_VERTEX, src, srcOffset, GET_HELPER_BUFFER_BINDING(0));
    SetBuffer(renderCommandEncoder, METAL_SHADER_TYPE_VERTEX, dst, dstOffset, GET_HELPER_BUFFER_BINDING(1));

    renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypePoint, NS::UInteger(0), NS::UInteger(size / 4));

    barrierBuffers[0] = dst;
    renderCommandEncoder->memoryBarrier(barrierBuffers, 1, MTL::RenderStageVertex, ALL_MTL_RENDER_STAGES);
    if (src == dst)
        m_iridiaPassReads.emplace_back(srcOffset, size);
    return true;
}

// Iridia: a buffer cache upload to a range that draws of the open render pass already read can't be done in place
// (on tile GPUs their fragment work runs after all vertex work of the pass) and used to end the pass for a blit,
// storing and reloading every attachment (the G-buffer pass was split ~14 times per frame in BotW). Instead the new
// data stays in its staging allocation: draws later in this pass bind the staging copy for that range (renaming),
// and the copy into the buffer cache runs right after the pass ends. Ranges that a draw would only partly read from
// a redirect, and other writes to those cache bytes, end the pass first (IridiaFlushRedirects).
// IRIDIA_NO_REDIRECT=1: the old blit.
std::atomic<uint32> g_iridiaRedirectStats[2];
bool MetalRenderer::IridiaRedirectUpload(MTL::Buffer* src, size_t srcOffset, size_t dstOffset, size_t size)
{
    static const bool s_off = getenv("IRIDIA_NO_REDIRECT") != nullptr;
    if (s_off || m_encoderType != MetalEncoderType::Render || size == 0)
        return false;
    m_iridiaRedirects.push_back({ dstOffset, size, src, srcOffset });
    g_iridiaRedirectStats[0]++;
    return true;
}

bool MetalRenderer::IridiaRedirectOverlaps(size_t offset, size_t size) const
{
    for (const auto& r : m_iridiaRedirects)
        if (r.offset < offset + size && offset < r.offset + r.size)
            return true;
    return false;
}

void MetalRenderer::IridiaApplyRedirects(MTL::BlitCommandEncoder* blit)
{
    for (const auto& r : m_iridiaRedirects) // oldest first: the newest data ends up in the cache
    {
        blit->copyFromBuffer(r.buffer, r.bufferOffset, m_memoryManager->GetBufferCache(), r.offset, r.size);
        m_memoryManager->MarkBufferCacheWrite(r.offset, r.size, m_iridiaSerial);
    }
    m_iridiaRedirects.clear();
}

void MetalRenderer::IridiaFlushRedirects()
{
    if (m_iridiaRedirects.empty())
        return;
    g_iridiaRedirectStats[1]++;
    EndEncoding(); // applies the pending copies after the pass
}

// binds a buffer cache range, from the newest redirect that holds all of it if there is one
void MetalRenderer::IridiaBindCacheBuffer(MTL::RenderCommandEncoder* encoder, MetalShaderType shaderType, size_t offset, size_t size, uint32 index)
{
    for (size_t i = m_iridiaRedirects.size(); i-- > 0;)
    {
        const auto& r = m_iridiaRedirects[i];
        if (r.offset < offset + std::max<size_t>(size, 1) && offset < r.offset + r.size)
        {
            if (offset >= r.offset && offset + size <= r.offset + r.size) // checked before the draw: no partial overlaps here
            {
                SetBuffer(encoder, shaderType, r.buffer, r.bufferOffset + (offset - r.offset), index);
                return;
            }
            break;
        }
    }
    SetBuffer(encoder, shaderType, m_memoryManager->GetBufferCache(), offset, index);
}

void MetalRenderer::bufferCache_copyStreamoutToMainBuffer(uint32 srcOffset, uint32 dstOffset, uint32 size)
{
    if (m_memoryManager->UseHostMemoryForCache())
        dstOffset -= m_memoryManager->GetImportedMemBaseAddress();

    if (IridiaRedirectOverlaps(dstOffset, size))
        IridiaFlushRedirects();
    if (!IridiaCopyInPass(GetXfbRingBuffer(), srcOffset, dstOffset, size, MTL::RenderStageVertex | MTL::RenderStageMesh))
        CopyBufferToBuffer(GetXfbRingBuffer(), srcOffset, m_memoryManager->GetBufferCache(), dstOffset, size, MTL::RenderStageVertex | MTL::RenderStageMesh, ALL_MTL_RENDER_STAGES);
    m_memoryManager->MarkBufferCacheUse(dstOffset, size, m_iridiaSerial);
    m_memoryManager->MarkBufferCacheWrite(dstOffset, size, m_iridiaSerial);
}

void MetalRenderer::buffer_bindVertexBuffers(std::span<BindBufferParam> bindings)
{
    cemu_assert_debug(!m_memoryManager->UseHostMemoryForCache());
    for (const auto& binding : bindings)
    {
        cemu_assert_debug(binding.index < LATTE_MAX_VERTEX_BUFFERS);
        m_state.m_vertexBufferOffsets[binding.index] = binding.bindOffset;
        m_iridiaVbSize[binding.index] = binding.bindSize;
    }
}

void MetalRenderer::buffer_bindUniformBuffer(LatteConst::ShaderType shaderType, uint32 bufferIndex, uint32 offset, uint32 size)
{
    cemu_assert_debug(!m_memoryManager->UseHostMemoryForCache());

    m_state.m_uniformBufferOffsets[GetMtlGeneralShaderType(shaderType)][bufferIndex] = offset;
    m_iridiaUbSize[GetMtlGeneralShaderType(shaderType)][bufferIndex] = size;
}

RendererShader* MetalRenderer::shader_create(RendererShader::ShaderType type, uint64 baseHash, uint64 auxHash, const std::string& source, bool isGameShader, bool isGfxPackShader)
{
    return new RendererShaderMtl(this, type, baseHash, auxHash, isGameShader, isGfxPackShader, source);
}

void MetalRenderer::streamout_setupXfbBuffer(uint32 bufferIndex, sint32 ringBufferOffset, uint32 rangeAddr, uint32 rangeSize)
{
    m_state.m_streamoutState.buffers[bufferIndex].enabled = true;
	m_state.m_streamoutState.buffers[bufferIndex].ringBufferOffset = ringBufferOffset;
}

void MetalRenderer::streamout_begin()
{
    // Do nothing
}

void MetalRenderer::streamout_rendererFinishDrawcall()
{
    // Do nothing
}

void MetalRenderer::draw_beginSequence()
{
    m_state.m_skipDrawSequence = false;
    m_iridiaFast.valid = false;

    bool streamoutEnable = LatteGPUState.contextRegister[mmVGT_STRMOUT_EN] != 0;

    // update shader state
	LatteSHRC_UpdateActiveShaders();
	if (LatteGPUState.activeShaderHasError)
	{
		cemuLog_logOnce(LogType::Force, "Skipping drawcalls due to shader error\n");
		m_state.m_skipDrawSequence = true;
		cemu_assert_debug(false);
		return;
	}

	// update render target and texture state
	LatteGPUState.requiresTextureBarrier = false;
	while (true)
	{
		LatteGPUState.repeatTextureInitialization = false;
		if (!LatteMRT::UpdateCurrentFBO())
		{
			cemuLog_logOnce(LogType::Force, "Rendertarget invalid\n");
			m_state.m_skipDrawSequence = true;
			return; // no render target
		}

		if (!hasValidFramebufferAttached && !streamoutEnable)
		{
			cemuLog_logOnce(LogType::Force, "Drawcall with no color buffer or depth buffer attached\n");
			m_state.m_skipDrawSequence = true;
			return; // no render target
		}
		LatteTexture_updateTextures();
		if (!LatteGPUState.repeatTextureInitialization)
			break;
	}

	// apply render target
	LatteMRT::ApplyCurrentState();

	// viewport and scissor box
	LatteRenderTarget_updateViewport();
	LatteRenderTarget_updateScissorBox();

	if (!LatteGPUState.contextNew.IsRasterizationEnabled() && !streamoutEnable)
		m_state.m_skipDrawSequence = true;
}

// Iridia study: IRIDIA_DRAW_TIMES=1 times draw_execute on the GPU command thread: [0] whole call, [1] resource
// binding (BindStageResources for all stages), [2] draws timed; printed once per second (LattePerformanceMonitor)
std::atomic<uint64> g_iridiaDrawNs[3];
static bool IridiaDrawTimesOn() { static const bool v = getenv("IRIDIA_DRAW_TIMES") != nullptr; return v; }
struct IridiaDrawTimer
{
    uint64 t0 = IridiaDrawTimesOn() ? IridiaTimelineNow() : 0;
    ~IridiaDrawTimer() { if (t0) { g_iridiaDrawNs[0].fetch_add(IridiaTimelineNow() - t0, std::memory_order_relaxed); g_iridiaDrawNs[2].fetch_add(1, std::memory_order_relaxed); } }
};

std::atomic<uint64> g_iridiaFastDrawStats[4]; // fast continued draws, pipeline re-looked-up, check mismatches, full draws
std::atomic<uint64> g_iridiaFastDrawMis[4]; // check mismatches by kind: pipeline, depth-stencil, textures, support buffer
// on by default since Oct 30 (Mac +3.7% uncapped, 4/4 rounds); IRIDIA_FASTDRAW=0 turns it off, =2 is the check mode
static int IridiaFastDrawMode() { static const int v = getenv("IRIDIA_FASTDRAW") ? atoi(getenv("IRIDIA_FASTDRAW")) : 1; return v; }

void MetalRenderer::draw_execute(uint32 baseVertex, uint32 baseInstance, uint32 instanceCount, uint32 count, MPTR indexDataMPTR, Latte::LATTE_VGT_DMA_INDEX_TYPE::E_INDEX_TYPE indexType, const LatteDrawcallContext& drawcallContext)
{
    IridiaDrawTimer iridiaDrawTimer;
    m_iridiaCmdDraws++;
    const int fastMode = IridiaFastDrawMode();
    const bool fast = fastMode && !drawcallContext.isFirst && m_iridiaFast.valid;
    if (fastMode)
        g_iridiaFastDrawStats[fast ? 0 : 3].fetch_add(1, std::memory_order_relaxed);
    if (!fast)
        m_iridiaFast.valid = false; // this draw takes the full path and records the state again
    if (m_state.m_skipDrawSequence)
	{
	    LatteGPUState.drawCallCounter++;
		return;
	}

	// fast clear color as depth
	if (LatteGPUState.contextNew.GetSpecialStateValues()[8] != 0)
	{
		m_iridiaFast.valid = false;
		LatteDraw_handleSpecialState8_clearAsDepth();
		LatteGPUState.drawCallCounter++;
		return;
	}
	else if (LatteGPUState.contextNew.GetSpecialStateValues()[5] != 0)
	{
		m_iridiaFast.valid = false;
		draw_handleSpecialState5();
		LatteGPUState.drawCallCounter++;
		return;
	}

	auto& encoderState = m_state.m_encoderState;

    // Shaders
    LatteDecompilerShader* vertexShader = LatteSHRC_GetActiveVertexShader();
    LatteDecompilerShader* geometryShader = LatteSHRC_GetActiveGeometryShader();
    LatteDecompilerShader* pixelShader = LatteSHRC_GetActivePixelShader();
    const auto fetchShader = LatteSHRC_GetActiveFetchShader();

    /*
    bool neverSkipAccurateBarrier = false;

    // "Accurate barriers" is usually enabled globally but since the CPU cost is substantial we allow users to disable it (debug -> 'Accurate barriers' option)
	// We always force accurate barriers for known problematic shaders
	if (pixelShader)
	{
		if (pixelShader->baseHash == 0x6f6f6e7b9aae57af && pixelShader->auxHash == 0x00078787f9249249) // BotW lava
			neverSkipAccurateBarrier = true;
		if (pixelShader->baseHash == 0x4c0bd596e3aef4a6 && pixelShader->auxHash == 0x003c3c3fc9269249) // BotW foam layer for water on the bottom of waterfalls
			neverSkipAccurateBarrier = true;
	}

	// Check if we need to end the render pass
	if (!m_state.m_isFirstDrawInRenderPass && (GetConfig().vk_accurate_barriers || neverSkipAccurateBarrier))
	{
    	// Fragment shader is most likely to require a render pass flush, so check for it first
    	bool endRenderPass = CheckIfRenderPassNeedsFlush(pixelShader);
    	if (!endRenderPass)
    	    endRenderPass = CheckIfRenderPassNeedsFlush(vertexShader);
    	if (!endRenderPass && geometryShader)
    	    endRenderPass = CheckIfRenderPassNeedsFlush(geometryShader);

    	if (endRenderPass)
        {
    	    EndEncoding();
            // TODO: only log in debug?
            cemuLog_logOnce(LogType::Force, "Ending render pass due to render target self-dependency\n");
        }
	}
	*/

    // Primitive type
    const LattePrimitiveMode primitiveMode = LatteGPUState.contextNew.VGT_PRIMITIVE_TYPE.get_PRIMITIVE_MODE();
    auto mtlPrimitiveType = GetMtlPrimitiveType(primitiveMode);

    bool usesGeometryShader = UseGeometryShader(LatteGPUState.contextNew, geometryShader != nullptr);
    if (usesGeometryShader && !m_supportsMeshShaders)
        return;

    bool fetchVertexManually = (usesGeometryShader || fetchShader->mtlFetchVertexManually);

	// Index buffer
	Renderer::INDEX_TYPE hostIndexType;
	uint32 hostIndexCount;
	uint32 indexMax = 0;
	Renderer::IndexAllocation indexAllocation;
	LatteIndices_decode(memory_getPointerFromVirtualOffset(indexDataMPTR), indexType, count, primitiveMode, indexMax, hostIndexType, hostIndexCount, indexAllocation);
	auto indexAllocationMtl = static_cast<MetalSynchronizedHeapAllocator::AllocatorReservation*>(indexAllocation.rendererInternal);

	// Buffer cache
	if (m_memoryManager->UseHostMemoryForCache())
	{
		// direct memory access (Wii U memory space imported as a buffer), update buffer bindings
		draw_updateVertexBuffersDirectAccess();
		if (vertexShader)
			draw_updateUniformBuffersDirectAccess(vertexShader, mmSQ_VTX_UNIFORM_BLOCK_START);
		if (geometryShader)
			draw_updateUniformBuffersDirectAccess(geometryShader, mmSQ_GS_UNIFORM_BLOCK_START);
		if (pixelShader)
			draw_updateUniformBuffersDirectAccess(pixelShader, mmSQ_PS_UNIFORM_BLOCK_START);
	}
	else
	{
    	// synchronize vertex and uniform cache and update buffer bindings
    	// We need to call this before getting the render command encoder, since it can cause buffer copies
		uint8 stageUniformModifiedMask = 0;
		if (fast) // Iridia: only the buffers the command processor marked dirty in this sequence (Vulkan's incremental sync)
			LatteBufferCache_Sync(indexMax + baseVertex, baseInstance, instanceCount, drawcallContext.vertexBufferDirtyMask, drawcallContext.vsUniformBufferDirtyMask, drawcallContext.psUniformBufferDirtyMask, drawcallContext.gsUniformBufferDirtyMask, stageUniformModifiedMask, true);
		else
    		LatteBufferCache_Sync(indexMax + baseVertex, baseInstance, instanceCount, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, stageUniformModifiedMask);
	}

	// Render pass
	// Iridia: a bound range that a redirect covers only partly can't be served from one buffer: end the pass first
	if (!m_iridiaRedirects.empty())
	{
		bool partial = false;
		auto check = [&](size_t o, size_t n) {
			if (o == INVALID_OFFSET) return;
			for (const auto& r : m_iridiaRedirects)
				if (r.offset < o + std::max<size_t>(n, 1) && o < r.offset + r.size && !(o >= r.offset && o + n <= r.offset + r.size))
					partial = true;
		};
		for (uint8 i = 0; i < MAX_MTL_VERTEX_BUFFERS; i++)
			check(m_state.m_vertexBufferOffsets[i], m_iridiaVbSize[i]);
		for (uint32 t = 0; t < METAL_GENERAL_SHADER_TYPE_TOTAL; t++)
			for (sint32 i = 0; i < LATTE_NUM_MAX_UNIFORM_BUFFERS; i++)
				check(m_state.m_uniformBufferOffsets[t][i], m_iridiaUbSize[t][i]);
		if (partial)
			IridiaFlushRedirects();
	}
	auto renderCommandEncoder = GetRenderCommandEncoder();

    // Render pipeline state
    // Iridia (item 5): in a continued draw only the vertex strides and the primitive type can change the pipeline
    const uint32 primRaw = LatteGPUState.contextRegister[mmVGT_PRIMITIVE_TYPE];
    bool pipelineLookup = !fast;
    if (fast && m_iridiaEncoderGen != m_iridiaFast.encoderGen)
    {
        pipelineLookup = true;
        g_iridiaFastDrawStats[1].fetch_add(1, std::memory_order_relaxed);
    }
    else if (fast && (drawcallContext.vertexBufferDirtyMask || primRaw != m_iridiaFast.primType))
    {
        uint32 k = 0;
        for (auto& group : fetchShader->bufferGroups)
            if (k >= m_iridiaFast.nStrides || group.getCurrentBufferStride(LatteGPUState.contextRegister) != m_iridiaFast.strides[k++])
                pipelineLookup = true;
        if (primRaw != m_iridiaFast.primType)
            pipelineLookup = true;
        if (pipelineLookup)
            g_iridiaFastDrawStats[1].fetch_add(1, std::memory_order_relaxed);
    }
    PipelineObject* pipelineObj;
    if (pipelineLookup || fastMode == 2)
    {
        pipelineObj = m_pipelineCache->GetRenderPipelineState(fetchShader, vertexShader, geometryShader, pixelShader, m_state.m_lastUsedFBO.m_attachmentsInfo, m_state.m_activeFBO.m_attachmentsInfo, m_state.m_activeFBO.m_fbo->m_size, count, LatteGPUState.contextNew);
        if (!pipelineLookup && pipelineObj != m_iridiaFast.pipelineObj)
            g_iridiaFastDrawStats[2].fetch_add(1, std::memory_order_relaxed), g_iridiaFastDrawMis[0].fetch_add(1, std::memory_order_relaxed);
        if (fastMode)
        {
            m_iridiaFast.pipelineObj = pipelineObj;
            m_iridiaFast.primType = primRaw;
            m_iridiaFast.encoderGen = m_iridiaEncoderGen;
            m_iridiaFast.nStrides = 0;
            for (auto& group : fetchShader->bufferGroups)
                if (m_iridiaFast.nStrides < Latte::GPU_LIMITS::NUM_VERTEX_BUFFERS)
                    m_iridiaFast.strides[m_iridiaFast.nStrides++] = group.getCurrentBufferStride(LatteGPUState.contextRegister);
        }
    }
    else
        pipelineObj = m_iridiaFast.pipelineObj;
    if (!pipelineObj->m_pipeline)
        return;

    if (pipelineObj->m_pipeline != encoderState.m_renderPipelineState)
   	{
        renderCommandEncoder->setRenderPipelineState(pipelineObj->m_pipeline);
  		encoderState.m_renderPipelineState = pipelineObj->m_pipeline;
   	}

	// Depth stencil state

	// Disable depth write when there is no depth attachment (Iridia: passed to the cache instead of rewriting
	// DB_DEPTH_CONTROL around the lookup on every draw)
	MTL::DepthStencilState* depthStencilState;
	if (fast && fastMode != 2)
	    depthStencilState = m_iridiaFast.depthStencil; // context registers and the framebuffer are fixed in a sequence
	else
	{
	    depthStencilState = m_depthStencilCache->GetDepthStencilState(LatteGPUState.contextNew, !m_state.m_activeFBO.m_fbo->depthBuffer.texture);
	    if (fast && depthStencilState != m_iridiaFast.depthStencil)
	        g_iridiaFastDrawStats[2].fetch_add(1, std::memory_order_relaxed), g_iridiaFastDrawMis[1].fetch_add(1, std::memory_order_relaxed);
	    m_iridiaFast.depthStencil = depthStencilState;
	}
	if (depthStencilState != encoderState.m_depthStencilState)
	{
	    renderCommandEncoder->setDepthStencilState(depthStencilState);
		encoderState.m_depthStencilState = depthStencilState;
	}

	// Stencil reference
	bool stencilEnable = LatteGPUState.contextNew.DB_DEPTH_CONTROL.get_STENCIL_ENABLE();
	if (stencilEnable)
	{
	    bool backStencilEnable = LatteGPUState.contextNew.DB_DEPTH_CONTROL.get_BACK_STENCIL_ENABLE();
		uint32 stencilRefFront = LatteGPUState.contextNew.DB_STENCILREFMASK.get_STENCILREF_F();
    	uint32 stencilRefBack;
        if (backStencilEnable)
            stencilRefBack = LatteGPUState.contextNew.DB_STENCILREFMASK_BF.get_STENCILREF_B();
        else
            stencilRefBack = stencilRefFront;

	    if (stencilRefFront != encoderState.m_stencilRefFront || stencilRefBack != encoderState.m_stencilRefBack)
		{
		    renderCommandEncoder->setStencilReferenceValues(stencilRefFront, stencilRefBack);

			encoderState.m_stencilRefFront = stencilRefFront;
			encoderState.m_stencilRefBack = stencilRefBack;
		}
	}

	// Blend color
	uint32* blendColorConstantU32 = LatteGPUState.contextRegister + Latte::REGADDR::CB_BLEND_RED;

	if (blendColorConstantU32[0] != encoderState.m_blendColor[0] || blendColorConstantU32[1] != encoderState.m_blendColor[1] || blendColorConstantU32[2] != encoderState.m_blendColor[2] || blendColorConstantU32[3] != encoderState.m_blendColor[3])
	{
    	float* blendColorConstant = (float*)LatteGPUState.contextRegister + Latte::REGADDR::CB_BLEND_RED;
    	renderCommandEncoder->setBlendColor(blendColorConstant[0], blendColorConstant[1], blendColorConstant[2], blendColorConstant[3]);

        encoderState.m_blendColor[0] = blendColorConstantU32[0];
        encoderState.m_blendColor[1] = blendColorConstantU32[1];
        encoderState.m_blendColor[2] = blendColorConstantU32[2];
        encoderState.m_blendColor[3] = blendColorConstantU32[3];
	}

	// polygon control
	const auto& polygonControlReg = LatteGPUState.contextNew.PA_SU_SC_MODE_CNTL;
	const auto frontFace = polygonControlReg.get_FRONT_FACE();
	uint32 cullFront = polygonControlReg.get_CULL_FRONT();
	uint32 cullBack = polygonControlReg.get_CULL_BACK();
	uint32 polyOffsetFrontEnable = polygonControlReg.get_OFFSET_FRONT_ENABLED();

	if (polyOffsetFrontEnable)
	{
    	uint32 frontScaleU32 = LatteGPUState.contextNew.PA_SU_POLY_OFFSET_FRONT_SCALE.getRawValue();
    	uint32 frontOffsetU32 = LatteGPUState.contextNew.PA_SU_POLY_OFFSET_FRONT_OFFSET.getRawValue();
    	uint32 offsetClampU32 = LatteGPUState.contextNew.PA_SU_POLY_OFFSET_CLAMP.getRawValue();

        if (frontOffsetU32 != encoderState.m_depthBias || frontScaleU32 != encoderState.m_depthSlope || offsetClampU32 != encoderState.m_depthClamp)
        {
           	float frontScale = LatteGPUState.contextNew.PA_SU_POLY_OFFSET_FRONT_SCALE.get_SCALE();
           	float frontOffset = LatteGPUState.contextNew.PA_SU_POLY_OFFSET_FRONT_OFFSET.get_OFFSET();
           	float offsetClamp = LatteGPUState.contextNew.PA_SU_POLY_OFFSET_CLAMP.get_CLAMP();

           	frontScale /= 16.0f;

            renderCommandEncoder->setDepthBias(frontOffset, frontScale, offsetClamp);

            encoderState.m_depthBias = frontOffsetU32;
            encoderState.m_depthSlope = frontScaleU32;
            encoderState.m_depthClamp = offsetClampU32;
        }
	}
	else
	{
	    if (0 != encoderState.m_depthBias || 0 != encoderState.m_depthSlope || 0 != encoderState.m_depthClamp)
		{
	        renderCommandEncoder->setDepthBias(0.0f, 0.0f, 0.0f);

			encoderState.m_depthBias = 0;
			encoderState.m_depthSlope = 0;
			encoderState.m_depthClamp = 0;
		}
	}

	// Depth clip mode
	cemu_assert_debug(LatteGPUState.contextNew.PA_CL_CLIP_CNTL.get_ZCLIP_NEAR_DISABLE() == LatteGPUState.contextNew.PA_CL_CLIP_CNTL.get_ZCLIP_FAR_DISABLE()); // near or far clipping can be disabled individually
	bool zClipEnable = LatteGPUState.contextNew.PA_CL_CLIP_CNTL.get_ZCLIP_FAR_DISABLE() == false;

	if (zClipEnable != encoderState.m_depthClipEnable)
	{
	    renderCommandEncoder->setDepthClipMode(zClipEnable ? MTL::DepthClipModeClip : MTL::DepthClipModeClamp);
        encoderState.m_depthClipEnable = zClipEnable;
	}

	// Visibility result mode
	if (m_occlusionQuery.m_active)
	{
	    auto mode = (m_occlusionQuery.m_currentIndex == INVALID_UINT32 ? MTL::VisibilityResultModeDisabled : MTL::VisibilityResultModeCounting);
	    renderCommandEncoder->setVisibilityResultMode(mode, m_occlusionQuery.m_currentIndex * sizeof(uint64));
	}

	// todo - how does culling behave with rects?
	// right now we just assume that their winding is always CW
	if (primitiveMode == Latte::LATTE_VGT_PRIMITIVE_TYPE::E_PRIMITIVE_TYPE::RECTS)
	{
		if (frontFace == Latte::LATTE_PA_SU_SC_MODE_CNTL::E_FRONTFACE::CW)
			cullFront = cullBack;
		else
			cullBack = cullFront;
	}

	// Cull mode

	// Cull front and back is handled by disabling rasterization
	if (!(cullFront && cullBack))
	{
        MTL::CullMode cullMode;
       	if (cullFront)
      		cullMode = MTL::CullModeFront;
       	else if (cullBack)
      		cullMode = MTL::CullModeBack;
       	else
      		cullMode = MTL::CullModeNone;

        if (cullMode != encoderState.m_cullMode)
       	{
       	    renderCommandEncoder->setCullMode(cullMode);
      		encoderState.m_cullMode = cullMode;
       	}
	}

	// Front face
	MTL::Winding frontFaceWinding;
	if (frontFace == Latte::LATTE_PA_SU_SC_MODE_CNTL::E_FRONTFACE::CCW)
		frontFaceWinding = MTL::WindingCounterClockwise;
	else
		frontFaceWinding = MTL::WindingClockwise;

    if (frontFaceWinding != encoderState.m_frontFaceWinding)
   	{
   	    renderCommandEncoder->setFrontFacingWinding(frontFaceWinding);
  		encoderState.m_frontFaceWinding = frontFaceWinding;
   	}

    // Viewport
    if (m_state.m_viewport.originX != encoderState.m_viewport.originX ||
        m_state.m_viewport.originY != encoderState.m_viewport.originY ||
        m_state.m_viewport.width != encoderState.m_viewport.width ||
        m_state.m_viewport.height != encoderState.m_viewport.height ||
        m_state.m_viewport.znear != encoderState.m_viewport.znear ||
        m_state.m_viewport.zfar != encoderState.m_viewport.zfar)
    {
        renderCommandEncoder->setViewport(m_state.m_viewport);

        encoderState.m_viewport = m_state.m_viewport;
    }

    // Scissor
    if (m_state.m_scissor.x != encoderState.m_scissor.x ||
        m_state.m_scissor.y != encoderState.m_scissor.y ||
        m_state.m_scissor.width != encoderState.m_scissor.width ||
        m_state.m_scissor.height != encoderState.m_scissor.height)
    {
        encoderState.m_scissor = m_state.m_scissor;

        // TODO: clamp scissor to render target dimensions?
        //scissor.width = ;
        //scissor.height = ;
        renderCommandEncoder->setScissorRect(encoderState.m_scissor);
    }

	// Resources

	// Vertex buffers
    for (uint8 i = 0; i < MAX_MTL_VERTEX_BUFFERS; i++)
    {
        size_t offset = m_state.m_vertexBufferOffsets[i];
        if (offset != INVALID_OFFSET)
        {
            // Bind
            IridiaBindCacheBuffer(renderCommandEncoder, GetMtlShaderType(vertexShader->shaderType, usesGeometryShader), offset, m_iridiaVbSize[i], GET_MTL_VERTEX_BUFFER_INDEX(i));
            m_memoryManager->MarkBufferCacheUse(offset, m_iridiaVbSize[i], m_iridiaSerial);
            m_iridiaPassReads.emplace_back(offset, m_iridiaVbSize[i]);
        }
    }

	// Prepare streamout
	m_state.m_streamoutState.verticesPerInstance = count;
	LatteStreamout_PrepareDrawcall(count, instanceCount);

	// Uniform buffers, textures and samplers
	const uint64 iridiaBind0 = iridiaDrawTimer.t0 ? IridiaTimelineNow() : 0;
	// Iridia (item 5): a stage's support buffer is unchanged in a continued draw when its ALU constants and uniform
	// buffer bindings are not dirty (the rest of it comes from context registers, textures and the viewport, which a
	// sequence keeps)
	BindStageResources(renderCommandEncoder, vertexShader, usesGeometryShader, fast, !drawcallContext.aluConstVSDirty && drawcallContext.vsUniformBufferDirtyMask == 0);
	if (usesGeometryShader && geometryShader)
	    BindStageResources(renderCommandEncoder, geometryShader, usesGeometryShader, fast, drawcallContext.gsUniformBufferDirtyMask == 0);
	BindStageResources(renderCommandEncoder, pixelShader, usesGeometryShader, fast, !drawcallContext.aluConstPSDirty && drawcallContext.psUniformBufferDirtyMask == 0);
	if (fastMode)
	    m_iridiaFast.valid = true;
	if (iridiaBind0)
	    g_iridiaDrawNs[1].fetch_add(IridiaTimelineNow() - iridiaBind0, std::memory_order_relaxed);

	// Draw
	if (usesGeometryShader)
	{
	    if (hostIndexType != INDEX_TYPE::NONE)
		    SetBuffer(renderCommandEncoder, METAL_SHADER_TYPE_OBJECT, indexAllocationMtl->mtlBuffer, indexAllocationMtl->bufferOffset, vertexShader->resourceMapping.indexBufferBinding);
	    if (hostIndexType != INDEX_TYPE::NONE && MetalSynchronizedHeapAllocator::DbgOn()) [[unlikely]]
		    m_memoryManager->GetIndexAllocator().DbgUse(indexAllocationMtl, GetCurrentCommandBuffer(), hostIndexType == INDEX_TYPE::U16 ? 2 : 4);

		uint8 hostIndexTypeU8 = (uint8)hostIndexType;
		renderCommandEncoder->setObjectBytes(&hostIndexTypeU8, sizeof(hostIndexTypeU8), vertexShader->resourceMapping.indexTypeBinding);
        encoderState.m_buffers[METAL_SHADER_TYPE_OBJECT][vertexShader->resourceMapping.indexTypeBinding] = {nullptr};

		uint32 verticesPerPrimitive = GetVerticesPerPrimitive(primitiveMode);
		uint32 threadgroupCount = count * instanceCount;
		if (PrimitiveRequiresConnection(primitiveMode))
		    threadgroupCount -= verticesPerPrimitive - 1;
		else
		    threadgroupCount /= verticesPerPrimitive;

		renderCommandEncoder->drawMeshThreadgroups(MTL::Size(threadgroupCount, 1, 1), MTL::Size(verticesPerPrimitive, 1, 1), MTL::Size(1, 1, 1));
	}
	else
	{
        if (hostIndexType != INDEX_TYPE::NONE)
       	{
       	    auto mtlIndexType = GetMtlIndexType(hostIndexType);
      		renderCommandEncoder->drawIndexedPrimitives(mtlPrimitiveType, hostIndexCount, mtlIndexType, indexAllocationMtl->mtlBuffer, indexAllocationMtl->bufferOffset, instanceCount, baseVertex, baseInstance);
      		if (MetalSynchronizedHeapAllocator::DbgOn()) [[unlikely]]
      		    m_memoryManager->GetIndexAllocator().DbgUse(indexAllocationMtl, GetCurrentCommandBuffer(), hostIndexType == INDEX_TYPE::U16 ? 2 : 4);
       	}
       	else
       	{
      		renderCommandEncoder->drawPrimitives(mtlPrimitiveType, baseVertex, count, instanceCount, baseInstance);
       	}
	}

	m_state.m_isFirstDrawInRenderPass = false;
	s_seq.draws++;

	// Occlusion queries
	if (m_occlusionQuery.m_active)
	    m_occlusionQuery.m_currentIndex = (m_occlusionQuery.m_currentIndex + 1) % OCCLUSION_QUERY_POOL_SIZE;

	// Streamout
	LatteStreamout_FinishDrawcall(m_memoryManager->UseHostMemoryForCache());

	// Debug
	if (fetchVertexManually)
	    m_performanceMonitor.m_manualVertexFetchDraws++;
	if (usesGeometryShader)
	    m_performanceMonitor.m_meshDraws++;
	if (primitiveMode == LattePrimitiveMode::TRIANGLE_FAN)
	    m_performanceMonitor.m_triangleFans++;

	LatteGPUState.drawCallCounter++;
}

void MetalRenderer::draw_endSequence()
{
    LatteDecompilerShader* pixelShader = LatteSHRC_GetActivePixelShader();
	// post-drawcall logic
	if (pixelShader)
		LatteRenderTarget_trackUpdates();
	bool hasReadback = LatteTextureReadback_Update();
	m_recordedDrawcalls++;
	// Iridia study: IRIDIA_LATTE_SPIN_NS=<n> busy-waits n ns per draw on this thread (off by default). Sensitivity
	// test for moving encoding off this thread: if added time here does not lower fps, removing it will not raise it.
	static const uint64 s_spinNs = getenv("IRIDIA_LATTE_SPIN_NS") ? strtoull(getenv("IRIDIA_LATTE_SPIN_NS"), nullptr, 10) : 0;
	if (s_spinNs)
	{
		static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
		const uint64 end = mach_absolute_time() + s_spinNs * tb.denom / tb.numer;
		while (mach_absolute_time() < end) {}
	}
	// The number of draw calls needs to twice as big, since we are interrupting the render pass
	// TODO: ucomment?
	// Iridia study: IRIDIA_INPASS_COMMIT=<n> sets the in-pass multiplier (default 2). A commit inside a render pass
	// splits it: the reopened pass reloads its attachments and its vertex stage waits for the first half's fragments.
	static const uint32 s_inPassMult = getenv("IRIDIA_INPASS_COMMIT") ? (uint32)atoi(getenv("IRIDIA_INPASS_COMMIT")) : 2;
	if (m_recordedDrawcalls >= m_commitTreshold * s_inPassMult/* || hasReadback*/)
	{
		static const bool s_noResume = getenv("IRIDIA_NO_RESUME") != nullptr;
		if (!s_noResume && m_commandEncoder && m_encoderType == MetalEncoderType::Render && m_state.m_lastUsedFBO.m_fbo)
			m_iridiaResumeFBO = m_state.m_lastUsedFBO;
		CommitCommandBuffer();

        // TODO: where should this be called?
        LatteTextureReadback_UpdateFinishedTransfers(false);
	}
}

void MetalRenderer::draw_updateVertexBuffersDirectAccess()
{
	LatteFetchShader* parsedFetchShader = LatteSHRC_GetActiveFetchShader();
	if (!parsedFetchShader)
		return;

	for (auto& bufferGroup : parsedFetchShader->bufferGroups)
	{
		uint32 bufferIndex = bufferGroup.attributeBufferIndex;
		uint32 bufferBaseRegisterIndex = mmSQ_VTX_ATTRIBUTE_BLOCK_START + bufferIndex * 7;
		MPTR bufferAddress = LatteGPUState.contextRegister[bufferBaseRegisterIndex + 0];

		if (bufferAddress == MPTR_NULL) [[unlikely]]
			bufferAddress = m_memoryManager->GetImportedMemBaseAddress();

		m_state.m_vertexBufferOffsets[bufferIndex] = bufferAddress - m_memoryManager->GetImportedMemBaseAddress();
	}
}

void MetalRenderer::draw_updateUniformBuffersDirectAccess(LatteDecompilerShader* shader, const uint32 uniformBufferRegOffset)
{
	if (shader->uniformMode == LATTE_DECOMPILER_UNIFORM_MODE_FULL_CBANK)
	{
		for (const auto& buf : shader->list_quickBufferList)
		{
			sint32 i = buf.index;
			MPTR physicalAddr = LatteGPUState.contextRegister[uniformBufferRegOffset + i * 7 + 0];
			uint32 uniformSize = LatteGPUState.contextRegister[uniformBufferRegOffset + i * 7 + 1] + 1;

			if (physicalAddr == MPTR_NULL) [[unlikely]]
			{
				cemu_assert_unimplemented();
				continue;
			}
			uniformSize = std::min<uint32>(uniformSize, buf.size);

			cemu_assert_debug(physicalAddr < 0x50000000);

			uint32 bufferIndex = i;
			cemu_assert_debug(bufferIndex < 16);

			m_state.m_uniformBufferOffsets[GetMtlGeneralShaderType(shader->shaderType)][bufferIndex] = physicalAddr - m_memoryManager->GetImportedMemBaseAddress();
		}
	}
}

void MetalRenderer::draw_handleSpecialState5()
{
    LatteMRT::UpdateCurrentFBO();
	LatteRenderTarget_updateViewport();

	LatteTextureView* colorBuffer = LatteMRT::GetColorAttachment(0);
	LatteTextureView* depthBuffer = LatteMRT::GetDepthAttachment();
	auto colorTextureMtl = static_cast<LatteTextureViewMtl*>(colorBuffer);
	auto depthTextureMtl = static_cast<LatteTextureViewMtl*>(depthBuffer);

	sint32 vpWidth, vpHeight;
	LatteMRT::GetVirtualViewportDimensions(vpWidth, vpHeight);

	// Get the pipeline
	MTL::PixelFormat colorPixelFormat = colorTextureMtl->GetRGBAView()->pixelFormat();
	auto& pipeline = m_copyDepthToColorPipelines[colorPixelFormat];
	if (!pipeline)
	{
	    m_copyDepthToColorDesc->colorAttachments()->object(0)->setPixelFormat(colorPixelFormat);

        NS::Error* error = nullptr;
        pipeline = m_device->newRenderPipelineState(m_copyDepthToColorDesc, &error);
        if (error)
        {
            cemuLog_log(LogType::Force, "failed to create copy depth to color pipeline (error: {})", error->localizedDescription()->utf8String());
        }
	}

	// Sadly, we need to end encoding to ensure that the depth data is up-to-date
	EndEncoding();

	// Copy depth to color
	auto renderCommandEncoder = GetRenderCommandEncoder();

	auto& encoderState = m_state.m_encoderState;

	renderCommandEncoder->setRenderPipelineState(pipeline);
	// TODO: make a helper function for this
	encoderState.m_renderPipelineState = pipeline;
	SetTexture(renderCommandEncoder, METAL_SHADER_TYPE_FRAGMENT, depthTextureMtl->GetRGBAView(), GET_HELPER_TEXTURE_BINDING(0));
	// TODO: make a helper function for this
	renderCommandEncoder->setFragmentBytes(&vpWidth, sizeof(sint32), GET_HELPER_BUFFER_BINDING(0));
	encoderState.m_buffers[METAL_SHADER_TYPE_FRAGMENT][GET_HELPER_BUFFER_BINDING(0)] = {nullptr};

	renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypeTriangle,  NS::UInteger(0),  NS::UInteger(3));
}

Renderer::IndexAllocation MetalRenderer::indexData_reserveIndexMemory(uint32 size)
{
    auto allocation = m_memoryManager->GetIndexAllocator().AllocateBufferMemory(size, 128);

    return {allocation->memPtr, allocation};
}

void MetalRenderer::indexData_releaseIndexMemory(IndexAllocation& allocation)
{
    m_memoryManager->GetIndexAllocator().FreeReservation(static_cast<MetalSynchronizedHeapAllocator::AllocatorReservation*>(allocation.rendererInternal));
}

void MetalRenderer::indexData_uploadIndexMemory(IndexAllocation& allocation)
{
    m_memoryManager->GetIndexAllocator().FlushReservation(static_cast<MetalSynchronizedHeapAllocator::AllocatorReservation*>(allocation.rendererInternal));
}

LatteQueryObject* MetalRenderer::occlusionQuery_create() {
	return new LatteQueryObjectMtl(this);
}

void MetalRenderer::occlusionQuery_destroy(LatteQueryObject* queryObj) {
    auto queryObjMtl = static_cast<LatteQueryObjectMtl*>(queryObj);
    delete queryObjMtl;
}

void MetalRenderer::occlusionQuery_flush() {
    if (m_occlusionQuery.m_lastCommandBuffer)
    {
        IridiaWaitTimer iridiaWait(6);
        m_occlusionQuery.m_lastCommandBuffer->waitUntilCompleted();
    }
}

void MetalRenderer::occlusionQuery_updateState() {
    ProcessFinishedCommandBuffers();
}

void MetalRenderer::SetBuffer(MTL::RenderCommandEncoder* renderCommandEncoder, MetalShaderType shaderType, MTL::Buffer* buffer, size_t offset, uint32 index)
{
    auto& boundBuffer = m_state.m_encoderState.m_buffers[shaderType][index];
    if (buffer == boundBuffer.m_buffer && offset == boundBuffer.m_offset)
        return;

    if (buffer == boundBuffer.m_buffer)
    {
        // Update just the offset
        boundBuffer.m_offset = offset;

        switch (shaderType)
        {
        case METAL_SHADER_TYPE_VERTEX:
            renderCommandEncoder->setVertexBufferOffset(offset, index);
            break;
        case METAL_SHADER_TYPE_OBJECT:
            renderCommandEncoder->setObjectBufferOffset(offset, index);
            break;
        case METAL_SHADER_TYPE_MESH:
            renderCommandEncoder->setMeshBufferOffset(offset, index);
            break;
        case METAL_SHADER_TYPE_FRAGMENT:
            renderCommandEncoder->setFragmentBufferOffset(offset, index);
            break;
        }

        return;
    }

    boundBuffer = {buffer, offset};

    switch (shaderType)
    {
    case METAL_SHADER_TYPE_VERTEX:
        renderCommandEncoder->setVertexBuffer(buffer, offset, index);
        break;
    case METAL_SHADER_TYPE_OBJECT:
        renderCommandEncoder->setObjectBuffer(buffer, offset, index);
        break;
    case METAL_SHADER_TYPE_MESH:
        renderCommandEncoder->setMeshBuffer(buffer, offset, index);
        break;
    case METAL_SHADER_TYPE_FRAGMENT:
        renderCommandEncoder->setFragmentBuffer(buffer, offset, index);
        break;
    }
}

void MetalRenderer::SetTexture(MTL::RenderCommandEncoder* renderCommandEncoder, MetalShaderType shaderType, MTL::Texture* texture, uint32 index)
{
    auto& boundTexture = m_state.m_encoderState.m_textures[shaderType][index];
    if (texture == boundTexture)
        return;

    boundTexture = texture;

    switch (shaderType)
    {
    case METAL_SHADER_TYPE_VERTEX:
        renderCommandEncoder->setVertexTexture(texture, index);
        break;
    case METAL_SHADER_TYPE_OBJECT:
        renderCommandEncoder->setObjectTexture(texture, index);
        break;
    case METAL_SHADER_TYPE_MESH:
        renderCommandEncoder->setMeshTexture(texture, index);
        break;
    case METAL_SHADER_TYPE_FRAGMENT:
        renderCommandEncoder->setFragmentTexture(texture, index);
        break;
    }
}

void MetalRenderer::SetSamplerState(MTL::RenderCommandEncoder* renderCommandEncoder, MetalShaderType shaderType, MTL::SamplerState* samplerState, uint32 index)
{
    auto& boundSamplerState = m_state.m_encoderState.m_samplers[shaderType][index];
    if (samplerState == boundSamplerState)
        return;

    boundSamplerState = samplerState;

    switch (shaderType)
    {
    case METAL_SHADER_TYPE_VERTEX:
        renderCommandEncoder->setVertexSamplerState(samplerState, index);
        break;
    case METAL_SHADER_TYPE_OBJECT:
        renderCommandEncoder->setObjectSamplerState(samplerState, index);
        break;
    case METAL_SHADER_TYPE_MESH:
        renderCommandEncoder->setMeshSamplerState(samplerState, index);
        break;
    case METAL_SHADER_TYPE_FRAGMENT:
        renderCommandEncoder->setFragmentSamplerState(samplerState, index);
        break;
    }
}

MTL::CommandBuffer* MetalRenderer::GetCommandBuffer()
{
    bool needsNewCommandBuffer = (!m_currentCommandBuffer.m_commandBuffer || m_currentCommandBuffer.m_commited);
    if (needsNewCommandBuffer)
	{
        // Debug
        //m_commandQueue->insertDebugCaptureBoundary();

        auto pool = NS::AutoreleasePool::alloc()->init();
	    MTL::CommandBuffer* mtlCommandBuffer = m_commandQueue->commandBuffer()->retain();
		pool->release();
		m_currentCommandBuffer = {mtlCommandBuffer};
		m_iridiaSerial++;

		// Wait for the previous command buffer
		if (m_eventValue != -1)
		    mtlCommandBuffer->encodeWait(m_event, m_eventValue);

		m_recordedDrawcalls = 0;
		m_iridiaCmdDraws = 0;
		m_commitTreshold = m_defaultCommitTreshlod;

        // Debug
        m_performanceMonitor.m_commandBuffers++;

		return mtlCommandBuffer;
	}
	else
	{
	    return m_currentCommandBuffer.m_commandBuffer;
	}
}

MTL::RenderCommandEncoder* MetalRenderer::GetTemporaryRenderCommandEncoder(MTL::RenderPassDescriptor* renderPassDescriptor)
{
    IridiaFlushClears();
    EndEncoding();

    auto commandBuffer = GetCommandBuffer();

    auto pool = NS::AutoreleasePool::alloc()->init();
    auto renderCommandEncoder = commandBuffer->renderCommandEncoder(renderPassDescriptor)->retain();
    pool->release();
    if (IridiaEnvOn("IRIDIA_ENC_LABELS"))
    {
        fprintf(stderr, "IRIDIA_ENC R temp %s\n", IridiaRenderPassKey(renderPassDescriptor).c_str());
        renderCommandEncoder->setLabel(NS::String::string(("temp " + IridiaRenderPassKey(renderPassDescriptor)).c_str(), NS::UTF8StringEncoding));
    }
    if (IridiaSeqOn())
        IridiaSeq(fmt::format("temp {}{}", IridiaRenderPassKey(renderPassDescriptor), IridiaRpIds(renderPassDescriptor)));
#ifdef CEMU_DEBUG_ASSERT
    renderCommandEncoder->setLabel(GetLabel("Temporary render command encoder", renderCommandEncoder));
#endif
    m_commandEncoder = renderCommandEncoder;
    m_encoderType = MetalEncoderType::Render;
    m_iridiaPassReads.clear();

    // Debug
    m_performanceMonitor.m_renderPasses++;

    return renderCommandEncoder;
}


// Some render passes clear the attachments, forceRecreate is supposed to be used in those cases
// Iridia diagnostics: who ends a render pass with a blit/compute encoder (IRIDIA_PASS_SPLITS=1, every 5 s)
static void IridiaCountSplit(void* ra, const std::string& pass)
{
    static std::map<std::pair<uintptr_t, std::string>, uint32> hits;
    static auto last = std::chrono::steady_clock::now();
    Dl_info info{};
    dladdr((void*)&IridiaCountSplit, &info);
    hits[{(uintptr_t)ra - (uintptr_t)info.dli_fbase, pass}]++;
    if (std::chrono::steady_clock::now() - last < std::chrono::seconds(5))
        return;
    last = std::chrono::steady_clock::now();
    for (auto& [k, n] : hits)
        if (n >= 50)
            fprintf(stderr, "IRIDIA_PASS_SPLITS %x %u %s\n", (unsigned)k.first, n, k.second.c_str());
    hits.clear();
}

MTL::RenderCommandEncoder* MetalRenderer::GetRenderCommandEncoder(bool forceRecreate)
{
    bool fboChanged = m_state.m_fboChanged;
    m_state.m_fboChanged = false;
    const MetalEncoderType prevType = m_commandEncoder ? m_encoderType : MetalEncoderType::None;

    // Check if we need to begin a new render pass
    if (m_commandEncoder)
    {
        if (!forceRecreate)
        {
            if (m_encoderType == MetalEncoderType::Render)
            {
                bool needsNewRenderPass = false;
                if (fboChanged)
                {
                    needsNewRenderPass = (m_state.m_lastUsedFBO.m_fbo == nullptr);
                    if (!needsNewRenderPass)
                    {
                        for (uint8 i = 0; i < 8; i++)
                        {
                            if (m_state.m_activeFBO.m_fbo->colorBuffer[i].texture && m_state.m_activeFBO.m_fbo->colorBuffer[i].texture != m_state.m_lastUsedFBO.m_fbo->colorBuffer[i].texture)
                            {
                                needsNewRenderPass = true;
                                break;
                            }
                        }
                    }

                    if (!needsNewRenderPass)
                    {
                        if (m_state.m_activeFBO.m_fbo->depthBuffer.texture && (m_state.m_activeFBO.m_fbo->depthBuffer.texture != m_state.m_lastUsedFBO.m_fbo->depthBuffer.texture || ( m_state.m_activeFBO.m_fbo->depthBuffer.hasStencil && !m_state.m_lastUsedFBO.m_fbo->depthBuffer.hasStencil)))
                        {
                            needsNewRenderPass = true;
                        }
                    }
                }

                if (!needsNewRenderPass)
                {
                    return (MTL::RenderCommandEncoder*)m_commandEncoder;
                }
            }
        }

        // Iridia study: IRIDIA_BOUNDARY_COMMIT=<n> commits at a render pass boundary once the command buffer holds n
        // draws (the sequence-count threshold lets ~460 draws pile up). The pass ends here anyway, so no pass is split
        // and the GPU gets the work sooner.
        static const uint32 s_boundaryCommit = getenv("IRIDIA_BOUNDARY_COMMIT") ? (uint32)atoi(getenv("IRIDIA_BOUNDARY_COMMIT")) : 0;
        if (s_boundaryCommit && m_iridiaCmdDraws >= s_boundaryCommit && m_encoderType == MetalEncoderType::Render)
            CommitCommandBuffer();
        else
            EndEncoding();
    }

    // Iridia: a pass cut by a draw-count commit reopens with the same attachments when they cover the active ones
    // (the pipelines mask the ones not bound), so a following draw that binds one of them again keeps the pass
    MetalActiveFBOState passFBO = m_state.m_activeFBO;
    if (CachedFBOMtl* r = m_iridiaResumeFBO.m_fbo; r && r != passFBO.m_fbo)
    {
        CachedFBOMtl* f = passFBO.m_fbo;
        bool covers = true;
        for (uint8 i = 0; i < 8 && covers; i++)
            if (f->colorBuffer[i].texture && f->colorBuffer[i].texture != r->colorBuffer[i].texture)
                covers = false;
        if (covers && f->depthBuffer.texture && (f->depthBuffer.texture != r->depthBuffer.texture || (f->depthBuffer.hasStencil && !r->depthBuffer.hasStencil)))
            covers = false;
        if (covers)
            passFBO = m_iridiaResumeFBO;
    }
    m_iridiaResumeFBO = {nullptr};

    // Iridia: pending clears (IridiaDeferClear) of this pass's color attachments become its load actions; the rest
    // run now, before the command buffer is taken (running them can commit it)
    MTL::RenderPassDescriptor* iridiaRp = passFBO.m_fbo->GetRenderPassDescriptor();
    std::vector<std::pair<IridiaPendingClear, int>> iridiaFolded;
    if (!m_iridiaPendingClears.empty())
    {
        // the pass's area: the smallest attachment (a clear load action only covers that)
        uint32 passW = ~0u, passH = ~0u;
        auto sizeOf = [&](MTL::RenderPassAttachmentDescriptor* at) {
            if (MTL::Texture* t = at->texture())
            {
                passW = std::min<uint32>(passW, std::max<uint32>(1, (uint32)t->width() >> at->level()));
                passH = std::min<uint32>(passH, std::max<uint32>(1, (uint32)t->height() >> at->level()));
            }
        };
        for (int i = 0; i < 8; i++)
            sizeOf(iridiaRp->colorAttachments()->object(i));
        sizeOf(iridiaRp->depthAttachment());
        sizeOf(iridiaRp->stencilAttachment());
        if (iridiaRp->renderTargetWidth()) passW = std::min<uint32>(passW, (uint32)iridiaRp->renderTargetWidth());
        if (iridiaRp->renderTargetHeight()) passH = std::min<uint32>(passH, (uint32)iridiaRp->renderTargetHeight());
        std::vector<IridiaPendingClear> rest;
        for (auto& c : m_iridiaPendingClears)
        {
            const uint32 cw = std::max<uint32>(1, (uint32)c.texture->width() >> c.mip), ch = std::max<uint32>(1, (uint32)c.texture->height() >> c.mip);
            if (cw != passW || ch != passH) { rest.push_back(c); continue; } // the pass would clear only part of it
            int index = -1;
            for (int i = 0; i < 8 && index < 0; i++)
            {
                auto at = iridiaRp->colorAttachments()->object(i);
                MTL::Texture* t = at->texture();
                if (!t) continue;
                MTL::Texture* base = t->parentTexture() ? t->parentTexture() : t;
                const sint32 slice = (sint32)at->slice() + (t->parentTexture() ? (sint32)t->parentRelativeSlice() : 0);
                const sint32 level = (sint32)at->level() + (t->parentTexture() ? (sint32)t->parentRelativeLevel() : 0);
                if (base == c.texture && slice == c.slice && level == c.mip && t->pixelFormat() == c.texture->pixelFormat() &&
                    t->arrayLength() == 1 && t->textureType() != MTL::TextureType3D && at->loadAction() == MTL::LoadActionLoad)
                    index = i;
            }
            if (index >= 0)
                iridiaFolded.emplace_back(c, index);
            else
                rest.push_back(c);
        }
        m_iridiaPendingClears = std::move(rest);
        IridiaFlushClears();
    }
    auto commandBuffer = GetCommandBuffer();

    auto pool = NS::AutoreleasePool::alloc()->init();
    if (IridiaSeqOn())
        IridiaSeq(fmt::format("render {}{}{}", IridiaRenderPassKey(iridiaRp), forceRecreate ? " (forced)" : "", IridiaRpIds(iridiaRp)));
    if (IridiaPassProfOn(m_device))
    {
        auto sa = iridiaRp->sampleBufferAttachments()->object(0);
        const uint32 idx = IridiaPassAlloc(commandBuffer, IridiaPassKey(IridiaRenderPassKey(iridiaRp)));
        sa->setSampleBuffer(s_pp.buf);
        sa->setStartOfVertexSampleIndex(idx); sa->setEndOfVertexSampleIndex(idx + 1);
        sa->setStartOfFragmentSampleIndex(idx + 2); sa->setEndOfFragmentSampleIndex(idx + 3);
    }
    for (auto& [c, i] : iridiaFolded)
    {
        iridiaRp->colorAttachments()->object(i)->setLoadAction(MTL::LoadActionClear);
        iridiaRp->colorAttachments()->object(i)->setClearColor(c.color);
        g_iridiaClears[2].fetch_add(1, std::memory_order_relaxed);
    }
    auto renderCommandEncoder = commandBuffer->renderCommandEncoder(iridiaRp)->retain();
    for (auto& [c, i] : iridiaFolded)
    {
        iridiaRp->colorAttachments()->object(i)->setLoadAction(MTL::LoadActionLoad); // the cached descriptor stays as it was
        c.texture->release();
    }
    static const bool s_iridiaLabels = getenv("IRIDIA_ENC_LABELS") != nullptr; // Iridia: pass names in Metal System Trace
    if (s_iridiaLabels)
    {
        fprintf(stderr, "IRIDIA_ENC R %s\n", IridiaRenderPassKey(iridiaRp).c_str());
        renderCommandEncoder->setLabel(NS::String::string(IridiaRenderPassKey(iridiaRp).c_str(), NS::UTF8StringEncoding));
    }
    if (s_pp.on)
        iridiaRp->sampleBufferAttachments()->object(0)->setSampleBuffer(nullptr);
    pool->release();
#ifdef CEMU_DEBUG_ASSERT
    renderCommandEncoder->setLabel(GetLabel("Render command encoder", renderCommandEncoder));
#endif
    m_commandEncoder = renderCommandEncoder;
    m_encoderType = MetalEncoderType::Render;
    m_iridiaPassReads.clear();

    // Update state
    m_state.m_lastUsedFBO = passFBO;
    m_state.m_isFirstDrawInRenderPass = true;

    ResetEncoderState();

    // Debug
    m_performanceMonitor.m_renderPasses++;
    {
        // Iridia diagnostics (g_iridiaPasses): same attachments as the previous render pass?
        static const void* s_prev[9] = {};
        const void* cur[9] = {};
        if (CachedFBOMtl* f = m_state.m_activeFBO.m_fbo)
        {
            for (uint8 i = 0; i < 8; i++)
                cur[i] = f->colorBuffer[i].texture;
            cur[8] = f->depthBuffer.texture;
        }
        g_iridiaPasses[0].fetch_add(1, std::memory_order_relaxed);
        if (memcmp(cur, s_prev, sizeof(cur)) == 0)
            g_iridiaPasses[prevType == MetalEncoderType::Blit || prevType == MetalEncoderType::Compute ? 1 : prevType == MetalEncoderType::Render ? 2 : 3].fetch_add(1, std::memory_order_relaxed);
        memcpy(s_prev, cur, sizeof(cur));
    }

    return renderCommandEncoder;
}

MTL::ComputeCommandEncoder* MetalRenderer::GetComputeCommandEncoder()
{
    IridiaFlushClears();
    if (m_commandEncoder)
    {
        if (m_encoderType == MetalEncoderType::Compute)
        {
            return (MTL::ComputeCommandEncoder*)m_commandEncoder;
        }

        if (m_encoderType == MetalEncoderType::Render && IridiaEnvOn("IRIDIA_PASS_SPLITS"))
            IridiaCountSplit(__builtin_return_address(0), m_state.m_lastUsedFBO.m_fbo ? IridiaRenderPassKey(m_state.m_lastUsedFBO.m_fbo->GetRenderPassDescriptor()) : std::string("?"));
        EndEncoding();
    }

    auto commandBuffer = GetCommandBuffer();

    auto pool = NS::AutoreleasePool::alloc()->init();
    MTL::ComputeCommandEncoder* computeCommandEncoder;
    if (IridiaSeqOn())
    {
        Dl_info info{}; dladdr((void*)&IridiaSeqOn, &info);
        IridiaSeq(fmt::format("compute from {:x}", (uintptr_t)__builtin_return_address(0) - (uintptr_t)info.dli_fbase));
    }
    if (IridiaPassProfOn(m_device))
    {
        auto pd = MTL::ComputePassDescriptor::alloc()->init();
        const uint32 idx = IridiaPassAlloc(commandBuffer, IridiaPassKey("compute"));
        auto sa = pd->sampleBufferAttachments()->object(0);
        sa->setSampleBuffer(s_pp.buf);
        sa->setStartOfEncoderSampleIndex(idx); sa->setEndOfEncoderSampleIndex(idx + 1);
        computeCommandEncoder = commandBuffer->computeCommandEncoder(pd)->retain();
        pd->release();
    }
    else
        computeCommandEncoder = commandBuffer->computeCommandEncoder()->retain();
    if (IridiaEnvOn("IRIDIA_ENC_LABELS"))
    {
        Dl_info info{}; dladdr((void*)&IridiaSeqOn, &info);
        fprintf(stderr, "IRIDIA_ENC C %x\n", (unsigned)((uintptr_t)__builtin_return_address(0) - (uintptr_t)info.dli_fbase));
        char lb[32]; snprintf(lb, sizeof(lb), "C %x", (unsigned)((uintptr_t)__builtin_return_address(0) - (uintptr_t)info.dli_fbase));
        computeCommandEncoder->setLabel(NS::String::string(lb, NS::UTF8StringEncoding));
    }
    pool->release();
    m_commandEncoder = computeCommandEncoder;
    m_encoderType = MetalEncoderType::Compute;

    ResetEncoderState();

    return computeCommandEncoder;
}

MTL::BlitCommandEncoder* MetalRenderer::GetBlitCommandEncoder()
{
    IridiaFlushClears();
    if (m_commandEncoder)
    {
        if (m_encoderType == MetalEncoderType::Blit)
        {
            return (MTL::BlitCommandEncoder*)m_commandEncoder;
        }

        if (m_encoderType == MetalEncoderType::Render && IridiaEnvOn("IRIDIA_PASS_SPLITS"))
            IridiaCountSplit(__builtin_return_address(0), m_state.m_lastUsedFBO.m_fbo ? IridiaRenderPassKey(m_state.m_lastUsedFBO.m_fbo->GetRenderPassDescriptor()) : std::string("?"));
        EndEncoding();
    }

    auto commandBuffer = GetCommandBuffer();

    auto pool = NS::AutoreleasePool::alloc()->init();
    MTL::BlitCommandEncoder* blitCommandEncoder;
    if (IridiaSeqOn())
    {
        Dl_info info{}; dladdr((void*)&IridiaSeqOn, &info);
        IridiaSeq(fmt::format("blit from {:x}", (uintptr_t)__builtin_return_address(0) - (uintptr_t)info.dli_fbase));
    }
    if (IridiaPassProfOn(m_device))
    {
        auto pd = MTL::BlitPassDescriptor::alloc()->init();
        const uint32 idx = IridiaPassAlloc(commandBuffer, IridiaPassKey("blit"));
        auto sa = pd->sampleBufferAttachments()->object(0);
        sa->setSampleBuffer(s_pp.buf);
        sa->setStartOfEncoderSampleIndex(idx); sa->setEndOfEncoderSampleIndex(idx + 1);
        blitCommandEncoder = commandBuffer->blitCommandEncoder(pd)->retain();
        pd->release();
    }
    else
        blitCommandEncoder = commandBuffer->blitCommandEncoder()->retain();
    if (IridiaEnvOn("IRIDIA_ENC_LABELS"))
    {
        Dl_info info{}; dladdr((void*)&IridiaSeqOn, &info);
        fprintf(stderr, "IRIDIA_ENC B %x\n", (unsigned)((uintptr_t)__builtin_return_address(0) - (uintptr_t)info.dli_fbase));
        char lb[32]; snprintf(lb, sizeof(lb), "B %x", (unsigned)((uintptr_t)__builtin_return_address(0) - (uintptr_t)info.dli_fbase));
        blitCommandEncoder->setLabel(NS::String::string(lb, NS::UTF8StringEncoding));
    }
    pool->release();
    m_commandEncoder = blitCommandEncoder;
    m_encoderType = MetalEncoderType::Blit;

    ResetEncoderState();

    return blitCommandEncoder;
}

void MetalRenderer::EndEncoding()
{
    if (m_commandEncoder)
    {
        if (IridiaSeqOn())
        {
            Dl_info info{}; dladdr((void*)&IridiaSeqOn, &info);
            void* ra = __builtin_return_address(0);
            IridiaSeq(fmt::format("  end from {:x}", (uintptr_t)ra - (uintptr_t)info.dli_fbase));
        }
        const bool wasRender = m_encoderType == MetalEncoderType::Render;
        m_commandEncoder->endEncoding();
        m_commandEncoder->release();
        m_commandEncoder = nullptr;
        m_encoderType = MetalEncoderType::None;
        if (wasRender && !m_iridiaRedirects.empty())
        {
            auto pool = NS::AutoreleasePool::alloc()->init();
            MTL::BlitCommandEncoder* blit = GetCommandBuffer()->blitCommandEncoder();
            IridiaApplyRedirects(blit);
            blit->endEncoding();
            pool->release();
        }

        // Commit the command buffer if enough draw calls have been recorded
        if (m_recordedDrawcalls >= m_commitTreshold)
            CommitCommandBuffer();
    }
}

void MetalRenderer::CommitCommandBuffer()
{
    if (!m_currentCommandBuffer.m_commandBuffer)
        return;

    IridiaFlushClears();
    EndEncoding();

    ProcessFinishedCommandBuffers();

    // Commit the command buffer
    if (!m_currentCommandBuffer.m_commited)
    {
        // Handled differently, since it seems like Metal doesn't always call the completion handler
        //commandBuffer.m_commandBuffer->addCompletedHandler(^(MTL::CommandBuffer*) {
        //    m_memoryManager->GetTemporaryBufferAllocator().CommandBufferFinished(commandBuffer.m_commandBuffer);
        //});

        // Signal event
        m_eventValue = (m_eventValue + 1) % EVENT_VALUE_WRAP;
        auto mtlCommandBuffer = m_currentCommandBuffer.m_commandBuffer;
        mtlCommandBuffer->encodeSignalEvent(m_event, m_eventValue);

        if (m_iridiaWarmGate)
        {
            if (m_iridiaInFlight.fetch_add(1, std::memory_order_relaxed) == 0)
                m_iridiaInFlight.notify_one(); // wakes the warm-up thread
            mtlCommandBuffer->addCompletedHandler([this](MTL::CommandBuffer*) { m_iridiaInFlight.fetch_sub(1, std::memory_order_relaxed); });
        }
        mtlCommandBuffer->commit();
        IridiaTL(TL_COMMIT, 0, (uint32)((uintptr_t)mtlCommandBuffer >> 4));
        m_currentCommandBuffer.m_commited = true;

        m_executingCommandBuffers.push_back(mtlCommandBuffer);
        m_iridiaExecutingSerials.push_back(m_iridiaSerial);

        // Debug
        //m_commandQueue->insertDebugCaptureBoundary();
    }
}

void MetalRenderer::ProcessFinishedCommandBuffers()
{
    // Check for finished command buffers
    for (auto it = m_executingCommandBuffers.begin(); it != m_executingCommandBuffers.end();)
    {
        auto commandBuffer = *it;
        if (CommandBufferCompleted(commandBuffer))
        {
            const double gpuTime = commandBuffer->GPUEndTime() - commandBuffer->GPUStartTime(); // Iridia: IRIDIA_DIAG
            if (gpuTime > 0.0 && gpuTime < 1.0)
            {
                g_iridiaGpuBusyNs.fetch_add((uint64_t)(gpuTime * 1e9), std::memory_order_relaxed);
                // GPU busy without counting overlapping command buffers twice (union of their start-end spans)
                static double s_lastEnd = 0.0;
                const double start = std::max(commandBuffer->GPUStartTime(), s_lastEnd);
                if (commandBuffer->GPUEndTime() > start)
                    g_iridiaGpuUnionNs.fetch_add((uint64_t)((commandBuffer->GPUEndTime() - start) * 1e9), std::memory_order_relaxed);
                s_lastEnd = std::max(s_lastEnd, commandBuffer->GPUEndTime());
                g_iridiaGpuCmdBufs.fetch_add(1, std::memory_order_relaxed);
                if (g_iridiaTimelineOn.load(std::memory_order_relaxed))
                {
                    IridiaTimelineRecordAt((uint64_t)(commandBuffer->GPUStartTime() * 1e9), TL_GPU_B, 0, (uint32)((uintptr_t)commandBuffer >> 4));
                    IridiaTimelineRecordAt((uint64_t)(commandBuffer->GPUEndTime() * 1e9), TL_GPU_E, 0, (uint32)((uintptr_t)commandBuffer >> 4));
                }
            }
            if (s_pp.on)
                IridiaPassResolve(m_device, commandBuffer);
            m_memoryManager->CleanupBuffers(commandBuffer);
            commandBuffer->release();
            m_iridiaExecutingSerials.erase(m_iridiaExecutingSerials.begin() + (it - m_executingCommandBuffers.begin()));
            it = m_executingCommandBuffers.erase(it);
        }
        else
        {
            ++it;
        }
    }
}

bool MetalRenderer::AcquireDrawable(bool mainWindow)
{
    auto& layer = GetLayer(mainWindow);
    if (!layer.GetLayer())
        return false;

    const bool latteBufferUsesSRGB = mainWindow ? LatteGPUState.tvBufferUsesSRGB : LatteGPUState.drcBufferUsesSRGB;
    if (latteBufferUsesSRGB != m_state.m_usesSRGB)
    {
        layer.GetLayer()->setPixelFormat(latteBufferUsesSRGB ? MTL::PixelFormatBGRA8Unorm_sRGB : MTL::PixelFormatBGRA8Unorm);
        m_state.m_usesSRGB = latteBufferUsesSRGB;
    }

    return layer.AcquireDrawable();
}

/*
bool MetalRenderer::CheckIfRenderPassNeedsFlush(LatteDecompilerShader* shader)
{
    sint32 textureCount = shader->resourceMapping.getTextureCount();
	for (int i = 0; i < textureCount; ++i)
	{
		const auto relative_textureUnit = shader->resourceMapping.getTextureUnitFromBindingPoint(i);
		auto hostTextureUnit = relative_textureUnit;
		auto textureDim = shader->textureUnitDim[relative_textureUnit];

		// Texture is accessed as a framebuffer fetch, therefore there is no need to flush it
		if (shader->textureRenderTargetIndex[relative_textureUnit] != 255)
		    continue;

		auto texUnitRegIndex = hostTextureUnit * 7;
		switch (shader->shaderType)
		{
		case LatteConst::ShaderType::Vertex:
			hostTextureUnit += LATTE_CEMU_VS_TEX_UNIT_BASE;
			texUnitRegIndex += Latte::REGADDR::SQ_TEX_RESOURCE_WORD0_N_VS;
			break;
		case LatteConst::ShaderType::Pixel:
			hostTextureUnit += LATTE_CEMU_PS_TEX_UNIT_BASE;
			texUnitRegIndex += Latte::REGADDR::SQ_TEX_RESOURCE_WORD0_N_PS;
			break;
		case LatteConst::ShaderType::Geometry:
			hostTextureUnit += LATTE_CEMU_GS_TEX_UNIT_BASE;
			texUnitRegIndex += Latte::REGADDR::SQ_TEX_RESOURCE_WORD0_N_GS;
			break;
		default:
			UNREACHABLE;
		}

		auto textureView = m_state.m_textures[hostTextureUnit];
		if (!textureView)
            continue;

		LatteTexture* baseTexture = textureView->baseTexture;

	    // If the texture is also used in the current render pass, we need to end the render pass to "flush" the texture
		for (uint8 i = 0; i < LATTE_NUM_COLOR_TARGET; i++)
		{
		    auto colorTarget = m_state.m_activeFBO.m_fbo->colorBuffer[i].texture;
			if (colorTarget && colorTarget->baseTexture == baseTexture)
			    return true;
		}
	}

	return false;
}
*/

void MetalRenderer::BindStageResources(MTL::RenderCommandEncoder* renderCommandEncoder, LatteDecompilerShader* shader, bool usesGeometryShader, bool fast, bool supportStatic)
{
    auto mtlShaderType = GetMtlShaderType(shader->shaderType, usesGeometryShader);
    const int fastMode = IridiaFastDrawMode();

    // Iridia (item 5): textures and samplers can't change inside a draw sequence (a texture or sampler register
    // write ends it), so a continued draw replays the bindings the sequence's full draw made for this stage. The
    // Set* calls still compare with the encoder state, so a new encoder in the middle of a sequence gets them all.
    const uint32 fastStage = (uint32)GetMtlGeneralShaderType(shader->shaderType);
    auto& fastTex = m_iridiaFast.tex[fastStage];
    uint32& fastTexCount = m_iridiaFast.nTex[fastStage];
    // the binding stage (vertex vs object) also follows the primitive type (rects use the mesh path)
    static MetalShaderType s_fastTexType[3];
    const bool replayTextures = fast && m_iridiaFast.texValid[fastStage] && s_fastTexType[fastStage] == mtlShaderType && fastMode != 2;
    if (replayTextures)
    {
        for (uint32 k = 0; k < fastTexCount; k++)
        {
            if (fastTex[k].sampler)
                SetSamplerState(renderCommandEncoder, mtlShaderType, fastTex[k].sampler, fastTex[k].binding);
            SetTexture(renderCommandEncoder, mtlShaderType, fastTex[k].texture, fastTex[k].binding);
        }
    }
    const bool checkTextures = fast && fastMode == 2 && m_iridiaFast.texValid[fastStage];
    IridiaFastDraw::TexBind checkTex[32];
    uint32 checkCount = 0;
    auto recordTex = [&](uint32 binding, MTL::Texture* texture, MTL::SamplerState* sampler) {
        if (checkTextures) { if (checkCount < 32) checkTex[checkCount++] = {binding, texture, sampler}; return; }
        if (fastTexCount < 32) fastTex[fastTexCount++] = {binding, texture, sampler};
        else m_iridiaFast.texValid[fastStage] = false; // too many to record: this stage takes the full path
    };
    if (!replayTextures && !checkTextures && fastMode)
    {
        fastTexCount = 0;
        m_iridiaFast.texValid[fastStage] = true;
        s_fastTexType[fastStage] = mtlShaderType;
    }

    sint32 textureCount = replayTextures ? 0 : shader->resourceMapping.getTextureCount();
	for (int i = 0; i < textureCount; ++i)
	{
		const auto relative_textureUnit = shader->resourceMapping.getRelativeTextureUnitFromRelativeBindingPoint(i);
		auto hostTextureUnit = relative_textureUnit;

		// Don't bind textures that are accessed with a framebuffer fetch
		if (m_supportsFramebufferFetch && shader->textureRenderTargetIndex[relative_textureUnit] != 255)
            continue;

		auto textureDim = shader->textureUnitDim[relative_textureUnit];
		auto texUnitRegIndex = hostTextureUnit * 7;
		switch (shader->shaderType)
		{
		case LatteConst::ShaderType::Vertex:
			hostTextureUnit += LATTE_CEMU_VS_TEX_UNIT_BASE;
			texUnitRegIndex += Latte::REGADDR::SQ_TEX_RESOURCE_WORD0_N_VS;
			break;
		case LatteConst::ShaderType::Pixel:
			hostTextureUnit += LATTE_CEMU_PS_TEX_UNIT_BASE;
			texUnitRegIndex += Latte::REGADDR::SQ_TEX_RESOURCE_WORD0_N_PS;
			break;
		case LatteConst::ShaderType::Geometry:
			hostTextureUnit += LATTE_CEMU_GS_TEX_UNIT_BASE;
			texUnitRegIndex += Latte::REGADDR::SQ_TEX_RESOURCE_WORD0_N_GS;
			break;
		default:
			UNREACHABLE;
		}

		// TODO: correct?
		uint32 binding = shader->resourceMapping.getTextureBaseBindingPoint() + i;
		if (binding >= MAX_MTL_TEXTURES)
		{
		    cemuLog_logOnce(LogType::Force, "invalid texture binding {}", binding);
            continue;
		}

		auto textureView = m_state.m_textures[hostTextureUnit];
		if (!textureView)
		{
            if (textureDim == Latte::E_DIM::DIM_1D)
                SetTexture(renderCommandEncoder, mtlShaderType, m_nullTexture1D, binding);
           	else
                SetTexture(renderCommandEncoder, mtlShaderType, m_nullTexture2D, binding);
            SetSamplerState(renderCommandEncoder, mtlShaderType, m_nearestSampler, binding);
            recordTex(binding, textureDim == Latte::E_DIM::DIM_1D ? m_nullTexture1D : m_nullTexture2D, m_nearestSampler);
            continue;
		}

		if (textureDim == Latte::E_DIM::DIM_1D && (textureView->dim != Latte::E_DIM::DIM_1D))
		{
		    SetTexture(renderCommandEncoder, mtlShaderType, m_nullTexture1D, binding);
		    recordTex(binding, m_nullTexture1D, nullptr);
			continue;
		}
		else if (textureDim == Latte::E_DIM::DIM_2D && (textureView->dim != Latte::E_DIM::DIM_2D && textureView->dim != Latte::E_DIM::DIM_2D_MSAA))
		{
		    SetTexture(renderCommandEncoder, mtlShaderType, m_nullTexture2D, binding);
		    recordTex(binding, m_nullTexture2D, nullptr);
			continue;
		}

		LatteTexture* baseTexture = textureView->baseTexture;

		uint32 stageSamplerIndex = shader->textureUnitSamplerAssignment[relative_textureUnit];
		MTL::SamplerState* sampler;
		if (stageSamplerIndex != LATTE_DECOMPILER_SAMPLER_NONE)
		{
		    uint32 samplerIndex = stageSamplerIndex + LatteDecompiler_getTextureSamplerBaseIndex(shader->shaderType);
			_LatteRegisterSetSampler* samplerWords = LatteGPUState.contextNew.SQ_TEX_SAMPLER + samplerIndex;

			// Overwriting

            // Lod bias
            //if (baseTexture->overwriteInfo.hasLodBias)
            //    samplerWords->WORD1.set_LOD_BIAS(baseTexture->overwriteInfo.lodBias);
            //else if (baseTexture->overwriteInfo.hasRelativeLodBias)
            //    samplerWords->WORD1.set_LOD_BIAS(samplerWords->WORD1.get_LOD_BIAS() + baseTexture->overwriteInfo.relativeLodBias);

            // Max anisotropy
            if (baseTexture->overwriteInfo.anisotropicLevel >= 0)
                samplerWords->WORD0.set_MAX_ANISO_RATIO(baseTexture->overwriteInfo.anisotropicLevel);

    		sampler = m_samplerCache->GetSamplerState(LatteGPUState.contextNew, shader->shaderType, stageSamplerIndex, samplerWords);
		}
		else
		{
		    sampler = m_nearestSampler;
		}
        SetSamplerState(renderCommandEncoder, mtlShaderType, sampler, binding);

		// get texture register word 0
		uint32 word4 = LatteGPUState.contextRegister[texUnitRegIndex + 4];
		auto& boundTexture = m_state.m_encoderState.m_textures[mtlShaderType][binding];
		MTL::Texture* mtlTexture = textureView->GetSwizzledView(word4);
		SetTexture(renderCommandEncoder, mtlShaderType, mtlTexture, binding);
		recordTex(binding, mtlTexture, sampler);
	}
	if (checkTextures)
	{
	    bool same = checkCount == fastTexCount;
	    for (uint32 k = 0; same && k < checkCount; k++)
	        same = checkTex[k].binding == fastTex[k].binding && checkTex[k].texture == fastTex[k].texture && checkTex[k].sampler == fastTex[k].sampler;
	    if (!same)
	        g_iridiaFastDrawStats[2].fetch_add(1, std::memory_order_relaxed), g_iridiaFastDrawMis[2].fetch_add(1, std::memory_order_relaxed);
	}

	// Support buffer
	auto GET_UNIFORM_DATA_PTR = [&](size_t index) { return supportBufferData + (index / 4); };

	sint32 shaderAluConst;
	sint32 shaderUniformRegisterOffset;

	switch (shader->shaderType)
	{
	case LatteConst::ShaderType::Vertex:
		shaderAluConst = 0x400;
		shaderUniformRegisterOffset = mmSQ_VTX_UNIFORM_BLOCK_START;
		break;
	case LatteConst::ShaderType::Pixel:
		shaderAluConst = 0;
		shaderUniformRegisterOffset = mmSQ_PS_UNIFORM_BLOCK_START;
		break;
	case LatteConst::ShaderType::Geometry:
		shaderAluConst = 0; // geometry shader has no ALU const
		shaderUniformRegisterOffset = mmSQ_GS_UNIFORM_BLOCK_START;
		break;
	default:
		UNREACHABLE;
	}

	// Iridia (item 5): the last upload of this stage, kept for the identical-uniform skip and the continued draws
	struct LastUpload { uint64 serial = ~0ull; size_t size = 0; MTL::Buffer* buffer = nullptr; size_t offset = 0; const uint8* data = nullptr; const LatteDecompilerShader* shader = nullptr; };
	static LastUpload s_last[3];
	LastUpload& last = s_last[GetMtlGeneralShaderType(shader->shaderType)];
	const bool reuseSupport = fast && supportStatic && shader->uniform.loc_verticesPerInstance < 0 && last.buffer && last.shader == shader &&
		last.serial == m_iridiaSerial && last.size == shader->uniform.uniformRangeSize && fastMode != 2;
	if (shader->resourceMapping.uniformVarsBufferBindingPoint >= 0 && reuseSupport)
	{
		g_iridiaUniformReuse[0].fetch_add(1, std::memory_order_relaxed);
		SetBuffer(renderCommandEncoder, mtlShaderType, last.buffer, last.offset, shader->resourceMapping.uniformVarsBufferBindingPoint);
	}
	else if (shader->resourceMapping.uniformVarsBufferBindingPoint >= 0)
	{
		if (shader->uniform.list_ufTexRescale.empty() == false)
		{
			for (auto& entry : shader->uniform.list_ufTexRescale)
			{
				float* xyScale = LatteTexture_getEffectiveTextureScale(shader->shaderType, entry.texUnit);
				memcpy(entry.currentValue, xyScale, sizeof(float) * 2);
				memcpy(GET_UNIFORM_DATA_PTR(entry.uniformLocation), xyScale, sizeof(float) * 2);
			}
		}
		if (shader->uniform.loc_alphaTestRef >= 0)
		{
			*GET_UNIFORM_DATA_PTR(shader->uniform.loc_alphaTestRef) = LatteGPUState.contextNew.SX_ALPHA_REF.get_ALPHA_TEST_REF();
		}
		if (shader->uniform.loc_pointSize >= 0)
		{
			const auto& pointSizeReg = LatteGPUState.contextNew.PA_SU_POINT_SIZE;
			float pointWidth = (float)pointSizeReg.get_WIDTH() / 8.0f;
			if (pointWidth == 0.0f)
				pointWidth = 1.0f / 8.0f; // minimum size
			*GET_UNIFORM_DATA_PTR(shader->uniform.loc_pointSize) = pointWidth;
		}
		if (shader->uniform.loc_remapped >= 0)
		{
			LatteBufferCache_LoadRemappedUniforms(shader, GET_UNIFORM_DATA_PTR(shader->uniform.loc_remapped), true, (1<<LATTE_NUM_MAX_UNIFORM_BUFFERS)-1);
		}
		if (shader->uniform.loc_uniformRegister >= 0)
		{
			uint32* uniformRegData = (uint32*)(LatteGPUState.contextRegister + mmSQ_ALU_CONSTANT0_0 + shaderAluConst);
			memcpy(GET_UNIFORM_DATA_PTR(shader->uniform.loc_uniformRegister), uniformRegData, shader->uniform.count_uniformRegister * 16);
		}
		if (shader->uniform.loc_windowSpaceToClipSpaceTransform >= 0)
		{
			sint32 viewportWidth;
			sint32 viewportHeight;
			LatteRenderTarget_GetCurrentVirtualViewportSize(&viewportWidth, &viewportHeight); // always call after _updateViewport()
			float* v = GET_UNIFORM_DATA_PTR(shader->uniform.loc_windowSpaceToClipSpaceTransform);
			v[0] = 2.0f / (float)viewportWidth;
			v[1] = 2.0f / (float)viewportHeight;
		}
		if (shader->uniform.loc_fragCoordScale >= 0)
		{
			LatteMRT::GetCurrentFragCoordScale(GET_UNIFORM_DATA_PTR(shader->uniform.loc_fragCoordScale));
		}
		for (sint32 t = 0; t < LATTE_NUM_MAX_TEX_UNITS; t++)
		{
			if (shader->uniform.loc_framebufferFetchSize[t] < 0)
				continue;
			const auto& texture = LatteGPUState.contextNew.SQ_TEX_START_PS[t];
			sint32* size = reinterpret_cast<sint32*>(GET_UNIFORM_DATA_PTR(shader->uniform.loc_framebufferFetchSize[t]));
			size[0] = texture.word0.get_WIDTH() + 1;
			size[1] = texture.word1.get_HEIGHT() + 1;
		}
		if (shader->uniform.loc_verticesPerInstance >= 0)
		{
			*(int*)(supportBufferData + ((size_t)shader->uniform.loc_verticesPerInstance / 4)) = m_state.m_streamoutState.verticesPerInstance;
			for (sint32 b = 0; b < LATTE_NUM_STREAMOUT_BUFFER; b++)
			{
				if (shader->uniform.loc_streamoutBufferBase[b] >= 0)
				{
					*(uint32*)GET_UNIFORM_DATA_PTR(shader->uniform.loc_streamoutBufferBase[b]) = m_state.m_streamoutState.buffers[b].ringBufferOffset;
				}
			}
		}

		size_t size = shader->uniform.uniformRangeSize;
		// Iridia: a draw whose uniform block for this stage is byte-identical to the previous upload in the same
		// command buffer binds that upload again instead of copying a new one (the ring keeps it until the command
		// buffer completes). IRIDIA_UNIFORM_REUSE=0 turns it off (A/B).
		static const bool s_reuseOn = !getenv("IRIDIA_UNIFORM_REUSE") || atoi(getenv("IRIDIA_UNIFORM_REUSE")) != 0;
		// check mode: a continued draw that would have reused the support buffer must produce the same bytes
		if (fast && fastMode == 2 && supportStatic && shader->uniform.loc_verticesPerInstance < 0 && last.buffer && last.shader == shader &&
			last.serial == m_iridiaSerial && last.size == size && memcmp(last.data, supportBufferData, size) != 0)
			g_iridiaFastDrawStats[2].fetch_add(1, std::memory_order_relaxed), g_iridiaFastDrawMis[3].fetch_add(1, std::memory_order_relaxed);
		if (s_reuseOn && last.serial == m_iridiaSerial && last.size == size && last.buffer && memcmp(last.data, supportBufferData, size) == 0)
		{
			last.shader = shader;
			g_iridiaUniformReuse[0].fetch_add(1, std::memory_order_relaxed);
			SetBuffer(renderCommandEncoder, mtlShaderType, last.buffer, last.offset, shader->resourceMapping.uniformVarsBufferBindingPoint);
		}
		else
		{
			auto& bufferAllocator = m_memoryManager->GetStagingAllocator();
			auto allocation = bufferAllocator.AllocateBufferMemory(size, 1);
			memcpy(allocation.memPtr, supportBufferData, size);
			bufferAllocator.FlushReservation(allocation);
			g_iridiaUniformReuse[1].fetch_add(1, std::memory_order_relaxed);
			last = { m_iridiaSerial, size, allocation.mtlBuffer, allocation.bufferOffset, (const uint8*)allocation.memPtr, shader };

			SetBuffer(renderCommandEncoder, mtlShaderType, allocation.mtlBuffer, allocation.bufferOffset, shader->resourceMapping.uniformVarsBufferBindingPoint);
		}
	}

	// Uniform buffers
	for (sint32 i = 0; i < LATTE_NUM_MAX_UNIFORM_BUFFERS; i++)
	{
		if (shader->resourceMapping.uniformBuffersBindingPoint[i] >= 0)
		{
    		uint32 binding = shader->resourceMapping.uniformBuffersBindingPoint[i];
    		if (binding >= MAX_MTL_BUFFERS)
    		{
    		    cemuLog_logOnce(LogType::Force, "invalid buffer binding {}", binding);
    			continue;
    		}

    		size_t offset = m_state.m_uniformBufferOffsets[GetMtlGeneralShaderType(shader->shaderType)][i];
    		if (offset == INVALID_OFFSET)
                continue;

            IridiaBindCacheBuffer(renderCommandEncoder, mtlShaderType, offset, m_iridiaUbSize[GetMtlGeneralShaderType(shader->shaderType)][i], binding);
            m_memoryManager->MarkBufferCacheUse(offset, m_iridiaUbSize[GetMtlGeneralShaderType(shader->shaderType)][i], m_iridiaSerial);
            m_iridiaPassReads.emplace_back(offset, m_iridiaUbSize[GetMtlGeneralShaderType(shader->shaderType)][i]);
		}
	}

	// Storage buffer
	if (shader->resourceMapping.tfStorageBindingPoint >= 0)
	{
        SetBuffer(renderCommandEncoder, mtlShaderType, m_xfbRingBuffer, 0, shader->resourceMapping.tfStorageBindingPoint);
	}
}

void MetalRenderer::ClearColorTextureInternal(MTL::Texture* mtlTexture, sint32 sliceIndex, sint32 mipIndex, float r, float g, float b, float a)
{
    NS_STACK_SCOPED MTL::RenderPassDescriptor* renderPassDescriptor = MTL::RenderPassDescriptor::alloc()->init();
    auto colorAttachment = renderPassDescriptor->colorAttachments()->object(0);
    colorAttachment->setTexture(mtlTexture);
    colorAttachment->setClearColor(MTL::ClearColor(r, g, b, a));
    colorAttachment->setLoadAction(MTL::LoadActionClear);
    colorAttachment->setStoreAction(MTL::StoreActionStore);
    colorAttachment->setSlice(sliceIndex);
    colorAttachment->setLevel(mipIndex);

    GetTemporaryRenderCommandEncoder(renderPassDescriptor);
    EndEncoding();

    // Debug
    m_performanceMonitor.m_clears++;
    g_iridiaClears[0].fetch_add(1, std::memory_order_relaxed); // Iridia: color clears
}

void MetalRenderer::CopyBufferToBuffer(MTL::Buffer* src, uint32 srcOffset, MTL::Buffer* dst, uint32 dstOffset, uint32 size, MTL::RenderStages after, MTL::RenderStages before)
{
    // TODO: uncomment and fix performance issues
    // Do the copy in a vertex shader on Apple GPUs
    /*
    if (m_isAppleGPU && m_encoderType == MetalEncoderType::Render)
    {
        auto renderCommandEncoder = static_cast<MTL::RenderCommandEncoder*>(m_commandEncoder);

        MTL::Resource* barrierBuffers[] = {src};
        renderCommandEncoder->memoryBarrier(barrierBuffers, 1, after, after | MTL::RenderStageVertex);

		renderCommandEncoder->setRenderPipelineState(m_copyBufferToBufferPipeline->GetRenderPipelineState());
		m_state.m_encoderState.m_renderPipelineState = m_copyBufferToBufferPipeline->GetRenderPipelineState();

		SetBuffer(renderCommandEncoder, METAL_SHADER_TYPE_VERTEX, src, srcOffset, GET_HELPER_BUFFER_BINDING(0));
		SetBuffer(renderCommandEncoder, METAL_SHADER_TYPE_VERTEX, dst, dstOffset, GET_HELPER_BUFFER_BINDING(1));

		renderCommandEncoder->drawPrimitives(MTL::PrimitiveTypePoint, NS::UInteger(0), NS::UInteger(size));

		barrierBuffers[0] = dst;
        renderCommandEncoder->memoryBarrier(barrierBuffers, 1, before | MTL::RenderStageVertex, before);
    }
    else
    {
    */
        auto blitCommandEncoder = GetBlitCommandEncoder();

        blitCommandEncoder->copyFromBuffer(src, srcOffset, dst, dstOffset, size);
    //}
}

void MetalRenderer::SwapBuffer(bool mainWindow)
{
    if (!AcquireDrawable(mainWindow))
        return;

    auto commandBuffer = GetCommandBuffer();
    GetLayer(mainWindow).PresentDrawable(commandBuffer);
}

void MetalRenderer::EnsureImGuiBackend()
{
    if (!ImGui::GetIO().BackendRendererUserData)
    {
        ImGui_ImplMetal_Init(m_device);
        //ImGui_ImplMetal_CreateFontsTexture(m_device);
    }
}

void MetalRenderer::StartCapture()
{
    auto captureManager = MTL::CaptureManager::sharedCaptureManager();
    auto desc = MTL::CaptureDescriptor::alloc()->init();
    desc->setCaptureObject(m_device);

    // Check if a debugger with support for GPU capture is attached
    if (captureManager->supportsDestination(MTL::CaptureDestinationDeveloperTools))
    {
        desc->setDestination(MTL::CaptureDestinationDeveloperTools);
    }
    else
    {
        if (GetConfig().gpu_capture_dir.GetValue().empty())
        {
            cemuLog_log(LogType::Force, "No GPU capture directory specified, cannot do a GPU capture");
            return;
        }

        // Check if the GPU trace document destination is available
        if (!captureManager->supportsDestination(MTL::CaptureDestinationGPUTraceDocument))
        {
            cemuLog_log(LogType::Force, "GPU trace document destination is not available, cannot do a GPU capture");
            return;
        }

        // Get current date and time as a string
        auto now = std::chrono::system_clock::now();
        std::time_t now_time = std::chrono::system_clock::to_time_t(now);
        std::ostringstream oss;
        oss << std::put_time(std::localtime(&now_time), "%Y-%m-%d_%H-%M-%S");
        std::string now_str = oss.str();

        std::string capturePath = fmt::format("{}/cemu_{}.gputrace", GetConfig().gpu_capture_dir.GetValue(), now_str);
        desc->setDestination(MTL::CaptureDestinationGPUTraceDocument);
        desc->setOutputURL(ToNSURL(capturePath));
    }

    NS::Error* error = nullptr;
    captureManager->startCapture(desc, &error);
    if (error)
    {
        cemuLog_log(LogType::Force, "Failed to start GPU capture: {}", error->localizedDescription()->utf8String());
    }

    m_capturing = true;
}

void MetalRenderer::EndCapture()
{
    auto captureManager = MTL::CaptureManager::sharedCaptureManager();
    captureManager->stopCapture();

    m_capturing = false;
}
