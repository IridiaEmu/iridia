#include "Cafe/HW/Latte/Renderer/Metal/MetalCommon.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalMemoryManager.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalVoidVertexPipeline.h"

#include "CafeSystem.h"
#include "Cemu/Logging/CemuLogging.h"
#include "Common/precompiled.h"
#include "HW/MMU/MMU.h"
#include "config/CemuConfig.h"

MetalMemoryManager::~MetalMemoryManager()
{
    if (m_bufferCache)
    {
        m_bufferCache->release();
    }
}

void* MetalMemoryManager::AcquireTextureUploadBuffer(size_t size)
{
    if (m_textureUploadBuffer.size() < size)
    {
        m_textureUploadBuffer.resize(size);
    }

    return m_textureUploadBuffer.data();
}

void MetalMemoryManager::ReleaseTextureUploadBuffer(uint8* mem)
{
    cemu_assert_debug(m_textureUploadBuffer.data() == mem);
	m_textureUploadBuffer.clear();
}

void MetalMemoryManager::InitBufferCache(size_t size)
{
    cemu_assert_debug(!m_bufferCache);

    m_metalBufferCacheMode = g_current_game_profile->GetBufferCacheMode();
    // Iridia study: IRIDIA_BUFFER_HOST=1 = on unified memory, let the GPU read guest MEM2 directly (Host mode)
    // instead of a separate buffer cache, for every game (A/B of memory use and upload cost).
    static const bool s_forceHost = getenv("IRIDIA_BUFFER_HOST") != nullptr;
    if (s_forceHost && m_metalBufferCacheMode == MetalBufferCacheMode::Auto && m_mtlr->HasUnifiedMemory())
        m_metalBufferCacheMode = MetalBufferCacheMode::Host;
    // Iridia: on unified memory (default, IRIDIA_BUFFER_PRIVATE=1 = upstream private cache), a shared buffer cache with
    // GPU-use tracking: uploads are a memcpy unless unfinished GPU work still uses those 256-byte pages, instead of
    // staging copies on the GPU that split render passes. BotW, Mac at 60 Hz: 22.9 -> 25.0 fps.
    bool iridiaTracked = false;
    if (!getenv("IRIDIA_BUFFER_PRIVATE") && m_metalBufferCacheMode == MetalBufferCacheMode::Auto && m_mtlr->HasUnifiedMemory())
    {
        m_metalBufferCacheMode = MetalBufferCacheMode::DeviceShared;
        iridiaTracked = true;
    }

    if (m_metalBufferCacheMode == MetalBufferCacheMode::Auto)
    {
        // TODO: do this for all unified memory systems?
        if (m_mtlr->IsAppleGPU())
        {
            switch (CafeSystem::GetForegroundTitleId())
            {
            // The Legend of Zelda: Wind Waker HD
            case 0x0005000010143600: // EUR
            case 0x0005000010143500: // USA
            case 0x0005000010143400: // JPN
                // TODO: use host instead?
                m_metalBufferCacheMode = MetalBufferCacheMode::DeviceShared;
                break;
            default:
                m_metalBufferCacheMode = MetalBufferCacheMode::DevicePrivate;
                break;
            }
        }
        else
        {
            m_metalBufferCacheMode = MetalBufferCacheMode::DevicePrivate;
        }
    }

    // First, try to import the host memory as a buffer
    if (m_metalBufferCacheMode == MetalBufferCacheMode::Host)
    {
        if (m_mtlr->HasUnifiedMemory())
        {
            m_importedMemBaseAddress = mmuRange_MEM2.getBase();
           	m_hostAllocationSize = mmuRange_MEM2.getSize();
            m_bufferCache = m_mtlr->GetDevice()->newBuffer(memory_getPointerFromVirtualOffset(m_importedMemBaseAddress), m_hostAllocationSize, MTL::ResourceStorageModeShared, nullptr);
            if (!m_bufferCache)
            {
                cemuLog_log(LogType::Force, "Failed to import host memory as a buffer, using device shared mode instead");
                m_metalBufferCacheMode = MetalBufferCacheMode::DeviceShared;
            }
        }
        else
        {
            cemuLog_log(LogType::Force, "Host buffer cache mode is only available on unified memory systems, using device shared mode instead");
            m_metalBufferCacheMode = MetalBufferCacheMode::DeviceShared;
        }
    }

    if (!m_bufferCache)
        m_bufferCache = m_mtlr->GetDevice()->newBuffer(size, (m_metalBufferCacheMode == MetalBufferCacheMode::DevicePrivate ? MTL::ResourceStorageModePrivate : MTL::ResourceStorageModeShared));
    if (iridiaTracked && m_metalBufferCacheMode == MetalBufferCacheMode::DeviceShared)
    {
        m_pageUse.assign((m_bufferCache->length() >> kPageShift) + 1, 0);
        m_pageWrite.assign(m_pageUse.size(), 0);
    }

#ifdef CEMU_DEBUG_ASSERT
    m_bufferCache->setLabel(GetLabel("Buffer cache", m_bufferCache));
#endif
}

void MetalMemoryManager::UploadToBufferCache(const void* data, size_t offset, size_t size)
{
    cemu_assert_debug(m_metalBufferCacheMode != MetalBufferCacheMode::Host);
    cemu_assert_debug(m_bufferCache);
    cemu_assert_debug((offset + size) <= m_bufferCache->length());

    // a range with a pending redirect (newer data waiting in staging) must go the same way, or older data would win
    const bool redirected = m_mtlr->IridiaRedirectOverlaps(offset, size);
    // Iridia study: IRIDIA_SKIP_SAME_UPLOAD=1 skips an upload whose bytes already are in the (shared) cache. Only when
    // no GPU write to those pages is unfinished and none is waiting in a redirect: then the CPU-side contents are
    // exactly what the GPU will read, so leaving them alone is the same as writing the same bytes again.
    static const bool s_skipSame = getenv("IRIDIA_SKIP_SAME_UPLOAD") && atoi(getenv("IRIDIA_SKIP_SAME_UPLOAD")) == 1;
    m_iridiaUploads++; m_iridiaUploadBytes += size;
    if (s_skipSame && TracksBufferCacheUse() && !redirected)
    {
        uint64 lastWrite = 0;
        size_t lastPage = std::min((offset + size - 1) >> kPageShift, m_pageWrite.size() - 1);
        for (size_t p = offset >> kPageShift; p <= lastPage; p++)
            lastWrite = std::max(lastWrite, m_pageWrite[p]);
        if (lastWrite > m_mtlr->IridiaCompletedSerial())
            m_mtlr->ProcessFinishedCommandBuffers();
        if (lastWrite > m_mtlr->IridiaCompletedSerial())
            m_iridiaSkipPending++;
        else if (memcmp((const uint8*)m_bufferCache->contents() + offset, data, size) == 0)
        {
            m_iridiaSkips++; m_iridiaSkipBytes += size;
            return;
        }
    }
    const bool gpuCopy = redirected || m_metalBufferCacheMode == MetalBufferCacheMode::DevicePrivate || (TracksBufferCacheUse() && IsBufferCacheRangeBusy(offset, size));
    if (TracksBufferCacheUse())
        (gpuCopy ? m_iridiaGpuUploads : m_iridiaCpuUploads)++;
    if (gpuCopy)
    {
        MarkBufferCacheUse(offset, size, m_mtlr->IridiaCurrentSerial());
        MarkBufferCacheWrite(offset, size, m_mtlr->IridiaCurrentSerial());

        auto allocation = m_stagingAllocator.AllocateBufferMemory(size, 4);
        memcpy(allocation.memPtr, data, size);
        m_stagingAllocator.FlushReservation(allocation);

        if (!(!redirected && m_mtlr->IridiaCopyInPass(allocation.mtlBuffer, allocation.bufferOffset, offset, size, 0)) &&
            !m_mtlr->IridiaRedirectUpload(allocation.mtlBuffer, allocation.bufferOffset, offset, size))
            m_mtlr->GetBlitCommandEncoder()->copyFromBuffer(allocation.mtlBuffer, allocation.bufferOffset, m_bufferCache, offset, size);

        //m_mtlr->CopyBufferToBuffer(allocation.mtlBuffer, allocation.bufferOffset, m_bufferCache, offset, size, ALL_MTL_RENDER_STAGES, ALL_MTL_RENDER_STAGES);
    }
    else
    {
        memcpy((uint8*)m_bufferCache->contents() + offset, data, size);
    }
}

void MetalMemoryManager::CopyBufferCache(size_t srcOffset, size_t dstOffset, size_t size)
{
    cemu_assert_debug(m_metalBufferCacheMode != MetalBufferCacheMode::Host);
    cemu_assert_debug(m_bufferCache);
    if (m_mtlr->IridiaRedirectOverlaps(srcOffset, size) || m_mtlr->IridiaRedirectOverlaps(dstOffset, size))
        m_mtlr->IridiaFlushRedirects(); // the cache must hold the newest data first

    if (m_metalBufferCacheMode == MetalBufferCacheMode::DevicePrivate || (TracksBufferCacheUse() && (IsBufferCacheRangeBusy(srcOffset, size) || IsBufferCacheRangeBusy(dstOffset, size))))
    {
        if (!m_mtlr->IridiaCopyInPass(m_bufferCache, srcOffset, dstOffset, size, 0))
            m_mtlr->CopyBufferToBuffer(m_bufferCache, srcOffset, m_bufferCache, dstOffset, size, ALL_MTL_RENDER_STAGES, ALL_MTL_RENDER_STAGES);
        MarkBufferCacheUse(srcOffset, size, m_mtlr->IridiaCurrentSerial());
        MarkBufferCacheUse(dstOffset, size, m_mtlr->IridiaCurrentSerial());
        MarkBufferCacheWrite(dstOffset, size, m_mtlr->IridiaCurrentSerial());
    }
    else
        memcpy((uint8*)m_bufferCache->contents() + dstOffset, (uint8*)m_bufferCache->contents() + srcOffset, size);
}

// Iridia: does GPU work that is not finished yet (including the command buffer being recorded) use this range?
bool MetalMemoryManager::IsBufferCacheRangeBusy(size_t offset, size_t size)
{
    const uint64 lastUse = BufferCacheLastUse(offset, size);
    if (lastUse <= m_mtlr->IridiaCompletedSerial())
        return false;
    m_mtlr->ProcessFinishedCommandBuffers(); // refresh which command buffers completed
    const bool busy = lastUse > m_mtlr->IridiaCompletedSerial();
    if (busy)
        (lastUse == m_mtlr->IridiaCurrentSerial() ? m_iridiaBusyCurrent : m_iridiaBusyExecuting)++;
    return busy;
}
