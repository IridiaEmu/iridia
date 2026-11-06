#pragma once

#include "Cafe/HW/Latte/Renderer/Metal/MetalRenderer.h"
#include "Metal/MTLResource.hpp"
#include "util/ChunkedHeap/ChunkedHeap.h"
#include "util/helpers/MemoryPool.h"

#include <utility>

inline MTL::ResourceOptions GetResourceOptions(MTL::ResourceOptions options)
{
    if (options & MTL::ResourceStorageModeShared || options & MTL::ResourceStorageModeManaged)
        options |= MTL::ResourceCPUCacheModeWriteCombined;

    return options;
}

class MetalBufferChunkedHeap : private ChunkedHeap<>
{
  public:
	MetalBufferChunkedHeap(const class MetalRenderer* mtlRenderer, MTL::ResourceOptions options, size_t minimumBufferAllocationSize) : m_mtlr(mtlRenderer), m_options(GetResourceOptions(options)), m_minimumBufferAllocationSize(minimumBufferAllocationSize) { };
	~MetalBufferChunkedHeap();

	using ChunkedHeap::alloc;
	using ChunkedHeap::free;

	uint8* GetChunkPtr(uint32 index) const
	{
		if (index >= m_chunkBuffers.size())
			return nullptr;

		return (uint8*)m_chunkBuffers[index]->contents();
	}

	MTL::Buffer* GetBufferByIndex(uint32 index) const
    {
        cemu_assert_debug(index < m_chunkBuffers.size());

        return m_chunkBuffers[index];
    }

    bool RequiresFlush() const
    {
        return m_options & MTL::ResourceStorageModeManaged;
    }

	void GetStats(uint32& numBuffers, size_t& totalBufferSize, size_t& freeBufferSize) const
	{
		numBuffers = m_chunkBuffers.size();
		totalBufferSize = m_numHeapBytes;
		freeBufferSize = m_numHeapBytes - m_numAllocatedBytes;
	}

  private:
	uint32 allocateNewChunk(uint32 chunkIndex, uint32 minimumAllocationSize) override;

	const class MetalRenderer* m_mtlr;

	MTL::ResourceOptions m_options;
	size_t m_minimumBufferAllocationSize;

	std::vector<MTL::Buffer*> m_chunkBuffers;
};

// a circular ring-buffer which tracks and releases memory per command-buffer
class MetalSynchronizedRingAllocator
{
public:
	MetalSynchronizedRingAllocator(class MetalRenderer* mtlRenderer, MTL::ResourceOptions options, uint32 minimumBufferAllocSize) : m_mtlr(mtlRenderer), m_options(GetResourceOptions(options)), m_minimumBufferAllocSize(minimumBufferAllocSize) {};
	MetalSynchronizedRingAllocator(const MetalSynchronizedRingAllocator&) = delete; // disallow copy

	struct BufferSyncPoint_t
	{
		// todo - modularize sync point
		MTL::CommandBuffer* commandBuffer;
		uint32 offset;

		BufferSyncPoint_t(MTL::CommandBuffer* _commandBuffer, uint32 _offset) : commandBuffer(_commandBuffer), offset(_offset) {};
	};

	struct AllocatorBuffer_t
	{
		MTL::Buffer* mtlBuffer;
		uint8* basePtr;
		uint32 size;
		uint32 writeIndex;
		std::queue<BufferSyncPoint_t> queue_syncPoints;
		MTL::CommandBuffer* lastSyncpointCommandBuffer{ nullptr };
		uint32 index;
		uint32 cleanupCounter{ 0 }; // increased by one every time CleanupBuffer() is called if there is no sync point. If it reaches 300 then the buffer is released
	};

	struct AllocatorReservation_t
	{
		MTL::Buffer* mtlBuffer;
		uint8* memPtr;
		uint32 bufferOffset;
		uint32 size;
		uint32 bufferIndex;
	};

	AllocatorReservation_t AllocateBufferMemory(uint32 size, uint32 alignment);
	void FlushReservation(AllocatorReservation_t& uploadReservation);
	void CleanupBuffer(MTL::CommandBuffer* latestFinishedCommandBuffer);
	MTL::Buffer* GetBufferByIndex(uint32 index) const;

    bool RequiresFlush() const
    {
        return m_options & MTL::ResourceStorageModeManaged;
    }

	void GetStats(uint32& numBuffers, size_t& totalBufferSize, size_t& freeBufferSize) const;

private:
	void allocateAdditionalUploadBuffer(uint32 sizeRequiredForAlloc);
	void addUploadBufferSyncPoint(AllocatorBuffer_t& buffer, uint32 offset);

	const class MetalRenderer* m_mtlr;

	MTL::ResourceOptions m_options;
	const uint32 m_minimumBufferAllocSize;

	std::vector<AllocatorBuffer_t> m_buffers;
};

// heap style allocator with released memory being freed after the current command buffer finishes
class MetalSynchronizedHeapAllocator
{
	struct TrackedAllocation
	{
		TrackedAllocation(CHAddr allocation) : allocation(allocation) {};
		CHAddr allocation;
	};

  public:
	MetalSynchronizedHeapAllocator(class MetalRenderer* mtlRenderer, MTL::ResourceOptions options, size_t minimumBufferAllocSize) : m_mtlr(mtlRenderer), m_chunkedHeap(m_mtlr, options, minimumBufferAllocSize), m_bumpOptions(GetResourceOptions(options)) {}
	~MetalSynchronizedHeapAllocator();
	MetalSynchronizedHeapAllocator(const MetalSynchronizedHeapAllocator&) = delete; // disallow copy

	struct AllocatorReservation
	{
		MTL::Buffer* mtlBuffer;
		uint8* memPtr;
		uint32 bufferOffset;
		uint32 size;
		uint32 bufferIndex;
		uint64 dbgId; // IRIDIA_INDEX_BUMP_DEBUG region id (0: not tracked)
	};

	AllocatorReservation* AllocateBufferMemory(uint32 size, uint32 alignment);
	void FreeReservation(AllocatorReservation* uploadReservation);
	void FlushReservation(AllocatorReservation* uploadReservation);

	void CleanupBuffer(MTL::CommandBuffer* latestFinishedCommandBuffer);

	void GetStats(uint32& numBuffers, size_t& totalBufferSize, size_t& freeBufferSize) const;
  private:
	const class MetalRenderer* m_mtlr;
	MetalBufferChunkedHeap m_chunkedHeap;
	// allocations
	std::vector<TrackedAllocation> m_activeAllocations;
	MemoryPool<AllocatorReservation> m_poolAllocatorReservation{32};
	// release queue
	std::unordered_map<MTL::CommandBuffer*, std::vector<CHAddr>> m_releaseQueue;

	// Iridia study (IRIDIA_INDEX_BUMP=1, off by default): allocations are carved in order from 4 MB chunks. A chunk
	// counts its live allocations; once it is no longer the one being filled and its last allocation is released,
	// it goes on the release queue of the command buffer current at that moment (like the heap's frees) and is
	// reused after that command buffer finishes. bufferIndex = chunk index.
	struct BumpChunk
	{
		MTL::Buffer* buffer;
		uint8* ptr;
		uint32 size;
		uint32 used;
		uint32 live;
	};
	static bool BumpOn();
	AllocatorReservation* BumpAllocate(uint32 size, uint32 alignment);
	void BumpRelease(uint32 chunkIndex);
	MTL::ResourceOptions m_bumpOptions;
	std::vector<BumpChunk> m_bumpChunks;
	std::vector<uint32> m_bumpFree;
	uint32 m_bumpCurrent{0xFFFFFFFF};
	std::unordered_map<MTL::CommandBuffer*, std::vector<uint32>> m_bumpReleaseQueue;

	// Iridia debug (IRIDIA_INDEX_BUMP_DEBUG=1, with the bump allocator): every allocation is a tracked region with a
	// checksum taken when it is filled and the list of command buffers that drew from it. Checks: alignment, overlap
	// with a region still in flight, a chunk reused while a command buffer that read it hasn't finished, a draw from
	// a released or unfilled region, and contents that changed before the last command buffer reading them finished.
  public:
	static bool DbgOn();
	void DbgUse(AllocatorReservation* res, MTL::CommandBuffer* cb, uint32 indexSize);
	void DbgReport();
  private:
	struct DbgRegion
	{
		uint32 chunk, offset, size, checksum;
		bool filled, released, orphan;
		std::vector<MTL::CommandBuffer*> users;
	};
	void DbgAlloc(AllocatorReservation* res, uint32 alignment, bool chunkReused);
	void DbgCompleted(MTL::CommandBuffer* cb);
	void DbgLog(int kind, const DbgRegion& r, const char* what);
	std::unordered_map<uint64, DbgRegion> m_dbgRegions;
	std::vector<std::vector<uint64>> m_dbgChunkRegions; // per chunk: regions of the current fill + orphans
	std::unordered_map<MTL::CommandBuffer*, std::vector<uint64>> m_dbgCbUses;
	uint64 m_dbgNextId{1};
	uint64 m_dbgStats[9]{}; // allocs, uses, misaligned, overlap, reuse in flight, use after release, use before fill, changed before encode, changed before GPU done
	uint64 m_dbgChunkReuses{0};
};
