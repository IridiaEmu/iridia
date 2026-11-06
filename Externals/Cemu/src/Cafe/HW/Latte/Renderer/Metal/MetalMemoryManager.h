#pragma once

#include "Cafe/HW/Latte/Renderer/Metal/MetalBufferAllocator.h"

#include "GameProfile/GameProfile.h"

class MetalMemoryManager
{
public:
    MetalMemoryManager(class MetalRenderer* metalRenderer) : m_mtlr{metalRenderer}, m_stagingAllocator(m_mtlr, m_mtlr->GetOptimalBufferStorageMode(), 32u * 1024 * 1024), m_indexAllocator(m_mtlr, m_mtlr->GetOptimalBufferStorageMode(), 4u * 1024 * 1024) {}
    ~MetalMemoryManager();

    MetalSynchronizedRingAllocator& GetStagingAllocator()
    {
        return m_stagingAllocator;
    }

    MetalSynchronizedHeapAllocator& GetIndexAllocator()
    {
        return m_indexAllocator;
    }

    MTL::Buffer* GetBufferCache()
    {
        return m_bufferCache;
    }

    void CleanupBuffers(MTL::CommandBuffer* latestFinishedCommandBuffer)
    {
        m_stagingAllocator.CleanupBuffer(latestFinishedCommandBuffer);
        m_indexAllocator.CleanupBuffer(latestFinishedCommandBuffer);
    }

    // Texture upload buffer
    void* AcquireTextureUploadBuffer(size_t size);
    void ReleaseTextureUploadBuffer(uint8* mem);

    // Buffer cache
    void InitBufferCache(size_t size);
    void UploadToBufferCache(const void* data, size_t offset, size_t size);
    void CopyBufferCache(size_t srcOffset, size_t dstOffset, size_t size);

    // Iridia: shared (CPU-visible) buffer cache with GPU-use tracking. Each 64 KB page remembers the newest command
    // buffer that reads or writes it; a CPU write to a page that unfinished GPU work still uses goes through an
    // ordered GPU copy instead (so in-flight draws keep seeing the old data), every other upload is a plain memcpy.
    bool TracksBufferCacheUse() const { return !m_pageUse.empty(); }
    void MarkBufferCacheUse(size_t offset, size_t size, uint64 serial)
    {
        if (m_pageUse.empty() || size == 0) return;
        size_t last = std::min((offset + size - 1) >> kPageShift, m_pageUse.size() - 1);
        for (size_t p = offset >> kPageShift; p <= last; p++)
            m_pageUse[p] = serial;
    }
    uint64 BufferCacheLastUse(size_t offset, size_t size) const
    {
        uint64 m = 0;
        if (m_pageUse.empty() || size == 0) return 0;
        size_t last = std::min((offset + size - 1) >> kPageShift, m_pageUse.size() - 1);
        for (size_t p = offset >> kPageShift; p <= last; p++)
            m = std::max(m, m_pageUse[p]);
        return m;
    }
    uint64 m_iridiaCpuUploads = 0, m_iridiaGpuUploads = 0, m_iridiaBusyCurrent = 0, m_iridiaBusyExecuting = 0;
    // Iridia: newest command buffer that WRITES each page on the GPU (GPU-path uploads, cache-to-cache and streamout
    // copies, redirect flushes). While such a write is unfinished, the CPU-side contents are not what the GPU will see.
    void MarkBufferCacheWrite(size_t offset, size_t size, uint64 serial)
    {
        if (m_pageWrite.empty() || size == 0) return;
        size_t last = std::min((offset + size - 1) >> kPageShift, m_pageWrite.size() - 1);
        for (size_t p = offset >> kPageShift; p <= last; p++)
            m_pageWrite[p] = serial;
    }
    // IRIDIA_SKIP_SAME_UPLOAD=1 counters (uploads seen / skipped as byte-identical, and their bytes)
    uint64 m_iridiaUploads = 0, m_iridiaUploadBytes = 0, m_iridiaSkips = 0, m_iridiaSkipBytes = 0, m_iridiaSkipPending = 0;

    // Getters
    bool UseHostMemoryForCache() const
    {
        return (m_metalBufferCacheMode == MetalBufferCacheMode::Host);
    }

    bool NeedsReducedLatency() const
    {
        return (m_metalBufferCacheMode == MetalBufferCacheMode::DeviceShared || m_metalBufferCacheMode == MetalBufferCacheMode::Host);
    }

    MPTR GetImportedMemBaseAddress() const
    {
        return m_importedMemBaseAddress;
    }

    size_t GetHostAllocationSize() const
    {
        return m_hostAllocationSize;
    }

private:
    class MetalRenderer* m_mtlr;

    std::vector<uint8> m_textureUploadBuffer;

    MetalSynchronizedRingAllocator m_stagingAllocator;
    MetalSynchronizedHeapAllocator m_indexAllocator;

    MTL::Buffer* m_bufferCache = nullptr;
    MetalBufferCacheMode m_metalBufferCacheMode;
    MPTR m_importedMemBaseAddress;
    size_t m_hostAllocationSize = 0;

    static constexpr uint32 kPageShift = 8;
    std::vector<uint64> m_pageUse;
    std::vector<uint64> m_pageWrite;
    bool IsBufferCacheRangeBusy(size_t offset, size_t size);
};
