#include "Cafe/HW/Latte/Renderer/Metal/MetalBufferAllocator.h"
#include "Cafe/HW/Latte/Renderer/Metal/MetalCommon.h"
#include <chrono>

MetalBufferChunkedHeap::~MetalBufferChunkedHeap()
{
	for (auto& chunk : m_chunkBuffers)
		chunk->release();
}

uint32 MetalBufferChunkedHeap::allocateNewChunk(uint32 chunkIndex, uint32 minimumAllocationSize)
{
	size_t allocationSize = std::max<size_t>(m_minimumBufferAllocationSize, minimumAllocationSize);
	MTL::Buffer* buffer = m_mtlr->GetDevice()->newBuffer(allocationSize, m_options);
	cemu_assert_debug(buffer);
	cemu_assert_debug(m_chunkBuffers.size() == chunkIndex);
	m_chunkBuffers.emplace_back(buffer);

	return allocationSize;
}

void MetalSynchronizedRingAllocator::addUploadBufferSyncPoint(AllocatorBuffer_t& buffer, uint32 offset)
{
	auto commandBuffer = m_mtlr->GetCurrentCommandBuffer();
	if (commandBuffer == buffer.lastSyncpointCommandBuffer)
		return;
	buffer.lastSyncpointCommandBuffer = commandBuffer;
	buffer.queue_syncPoints.emplace(commandBuffer, offset);
}

void MetalSynchronizedRingAllocator::allocateAdditionalUploadBuffer(uint32 sizeRequiredForAlloc)
{
	// calculate buffer size, should be a multiple of bufferAllocSize that is at least as large as sizeRequiredForAlloc
	uint32 bufferAllocSize = m_minimumBufferAllocSize;
	while (bufferAllocSize < sizeRequiredForAlloc)
		bufferAllocSize += m_minimumBufferAllocSize;

	AllocatorBuffer_t newBuffer{};
	newBuffer.writeIndex = 0;
	newBuffer.basePtr = nullptr;
	newBuffer.mtlBuffer = m_mtlr->GetDevice()->newBuffer(bufferAllocSize, m_options);
	newBuffer.basePtr = (uint8*)newBuffer.mtlBuffer->contents();
	newBuffer.size = bufferAllocSize;
	newBuffer.index = (uint32)m_buffers.size();
	m_buffers.push_back(newBuffer);
}

MetalSynchronizedRingAllocator::AllocatorReservation_t MetalSynchronizedRingAllocator::AllocateBufferMemory(uint32 size, uint32 alignment)
{
	if (alignment < 128)
		alignment = 128;
	size = (size + 127) & ~127;

	for (auto& itr : m_buffers)
	{
		// align pointer
		uint32 alignmentPadding = (alignment - (itr.writeIndex % alignment)) % alignment;
		uint32 distanceToSyncPoint;
		if (!itr.queue_syncPoints.empty())
		{
			if (itr.queue_syncPoints.front().offset < itr.writeIndex)
				distanceToSyncPoint = 0xFFFFFFFF;
			else
				distanceToSyncPoint = itr.queue_syncPoints.front().offset - itr.writeIndex;
		}
		else
			distanceToSyncPoint = 0xFFFFFFFF;
		uint32 spaceNeeded = alignmentPadding + size;
		if (spaceNeeded > distanceToSyncPoint)
			continue; // not enough space in current buffer
		if ((itr.writeIndex + spaceNeeded) > itr.size)
		{
			// wrap-around
			spaceNeeded = size;
			alignmentPadding = 0;
			// check if there is enough space in current buffer after wrap-around
			if (!itr.queue_syncPoints.empty())
			{
				distanceToSyncPoint = itr.queue_syncPoints.front().offset - 0;
				if (spaceNeeded > distanceToSyncPoint)
					continue;
			}
			else if (spaceNeeded > itr.size)
				continue;
			itr.writeIndex = 0;
		}
		addUploadBufferSyncPoint(itr, itr.writeIndex);
		itr.writeIndex += alignmentPadding;
		uint32 offset = itr.writeIndex;
		itr.writeIndex += size;
		itr.cleanupCounter = 0;
		MetalSynchronizedRingAllocator::AllocatorReservation_t res;
		res.mtlBuffer = itr.mtlBuffer;
		res.memPtr = itr.basePtr + offset;
		res.bufferOffset = offset;
		res.size = size;
		res.bufferIndex = itr.index;

		return res;
	}

	// allocate new buffer
	allocateAdditionalUploadBuffer(size);

	return AllocateBufferMemory(size, alignment);
}

void MetalSynchronizedRingAllocator::FlushReservation(AllocatorReservation_t& uploadReservation)
{
    if (RequiresFlush())
    {
        uploadReservation.mtlBuffer->didModifyRange(NS::Range(uploadReservation.bufferOffset, uploadReservation.size));
    }
}

void MetalSynchronizedRingAllocator::CleanupBuffer(MTL::CommandBuffer* latestFinishedCommandBuffer)
{
	for (auto& itr : m_buffers)
	{
		while (!itr.queue_syncPoints.empty() && latestFinishedCommandBuffer == itr.queue_syncPoints.front().commandBuffer)
		{
			itr.queue_syncPoints.pop();
		}
		// the command buffer gets released after this and its address can be reused by the next one
		if (itr.lastSyncpointCommandBuffer == latestFinishedCommandBuffer)
			itr.lastSyncpointCommandBuffer = nullptr;
		if (itr.queue_syncPoints.empty())
			itr.cleanupCounter++;
	}

	// check if last buffer is available for deletion
	if (m_buffers.size() >= 2)
	{
		auto& lastBuffer = m_buffers.back();
		if (lastBuffer.cleanupCounter >= 1000)
		{
			// release buffer
			lastBuffer.mtlBuffer->release();
			m_buffers.pop_back();
		}
	}
}

MTL::Buffer* MetalSynchronizedRingAllocator::GetBufferByIndex(uint32 index) const
{
	return m_buffers[index].mtlBuffer;
}

void MetalSynchronizedRingAllocator::GetStats(uint32& numBuffers, size_t& totalBufferSize, size_t& freeBufferSize) const
{
	numBuffers = (uint32)m_buffers.size();
	totalBufferSize = 0;
	freeBufferSize = 0;
	for (auto& itr : m_buffers)
	{
		totalBufferSize += itr.size;
		// calculate free space in buffer
		uint32 distanceToSyncPoint;
		if (!itr.queue_syncPoints.empty())
		{
			if (itr.queue_syncPoints.front().offset < itr.writeIndex)
				distanceToSyncPoint = (itr.size - itr.writeIndex) + itr.queue_syncPoints.front().offset; // size with wrap-around
			else
				distanceToSyncPoint = itr.queue_syncPoints.front().offset - itr.writeIndex;
		}
		else
			distanceToSyncPoint = itr.size;
		freeBufferSize += distanceToSyncPoint;
	}
}

/* MetalSynchronizedHeapAllocator */

bool MetalSynchronizedHeapAllocator::BumpOn()
{
	// on by default (Oct 23: -10% command-thread time per draw); IRIDIA_INDEX_BUMP=0 uses the heap allocator
	static const bool v = !(getenv("IRIDIA_INDEX_BUMP") && getenv("IRIDIA_INDEX_BUMP")[0] == '0');
	return v;
}

MetalSynchronizedHeapAllocator::~MetalSynchronizedHeapAllocator()
{
	for (auto& c : m_bumpChunks)
		c.buffer->release();
}

MetalSynchronizedHeapAllocator::AllocatorReservation* MetalSynchronizedHeapAllocator::BumpAllocate(uint32 size, uint32 alignment)
{
	auto fits = [&](const BumpChunk& c) { return ((c.used + alignment - 1) & ~(alignment - 1)) + size <= c.size; };
	bool chunkReused = false;
	if (m_bumpCurrent == 0xFFFFFFFF || !fits(m_bumpChunks[m_bumpCurrent]))
	{
		// retire the chunk being filled; it is released once its last allocation is
		if (m_bumpCurrent != 0xFFFFFFFF)
		{
			const uint32 old = m_bumpCurrent;
			m_bumpCurrent = 0xFFFFFFFF;
			if (m_bumpChunks[old].live == 0)
				BumpRelease(old);
		}
		for (size_t i = 0; i < m_bumpFree.size(); i++)
		{
			if (m_bumpChunks[m_bumpFree[i]].size >= size)
			{
				m_bumpCurrent = m_bumpFree[i];
				m_bumpFree.erase(m_bumpFree.begin() + i);
				chunkReused = true;
				break;
			}
		}
		if (m_bumpCurrent == 0xFFFFFFFF)
		{
			// IRIDIA_INDEX_BUMP_CHUNK=<bytes>: smaller chunks (debug: makes chunks wrap and get reused every frame)
			static const uint32 s_chunkMin = getenv("IRIDIA_INDEX_BUMP_CHUNK") ? std::max(4096, atoi(getenv("IRIDIA_INDEX_BUMP_CHUNK"))) : 4u * 1024 * 1024;
			const uint32 chunkSize = std::max<uint32>(s_chunkMin, (size + 0xFFFF) & ~0xFFFFu);
			MTL::Buffer* buffer = m_mtlr->GetDevice()->newBuffer(chunkSize, m_bumpOptions);
			cemu_assert_debug(buffer);
			m_bumpChunks.push_back({ buffer, (uint8*)buffer->contents(), chunkSize, 0, 0 });
			m_bumpCurrent = (uint32)m_bumpChunks.size() - 1;
			if (m_bumpChunks.size() % 8 == 0)
				fprintf(stderr, "IRIDIA_INDEX_BUMP %zu chunks\n", m_bumpChunks.size());
		}
		m_bumpChunks[m_bumpCurrent].used = 0;
	}
	BumpChunk& c = m_bumpChunks[m_bumpCurrent];
	const uint32 offset = (c.used + alignment - 1) & ~(alignment - 1);
	c.used = offset + size;
	c.live++;
	AllocatorReservation* res = m_poolAllocatorReservation.allocObj();
	res->bufferIndex = m_bumpCurrent;
	res->bufferOffset = offset;
	res->size = size;
	res->mtlBuffer = c.buffer;
	res->memPtr = c.ptr + offset;
	res->dbgId = 0;
	if (DbgOn()) [[unlikely]]
		DbgAlloc(res, alignment, chunkReused);
	return res;
}

/* Iridia debug tracker (IRIDIA_INDEX_BUMP_DEBUG=1) */

bool MetalSynchronizedHeapAllocator::DbgOn()
{
	static const bool v = BumpOn() && getenv("IRIDIA_INDEX_BUMP_DEBUG") && getenv("IRIDIA_INDEX_BUMP_DEBUG")[0] == '1';
	return v;
}

static uint32 IridiaDbgChecksum(const uint8* p, uint32 size)
{
	uint64 h = 0xcbf29ce484222325ull ^ size;
	uint32 i = 0;
	for (; i + 8 <= size; i += 8)
	{
		uint64 w;
		memcpy(&w, p + i, 8);
		h = (h ^ w) * 0x100000001b3ull;
		h ^= h >> 29;
	}
	for (; i < size; i++)
		h = (h ^ p[i]) * 0x100000001b3ull;
	return (uint32)(h ^ (h >> 32));
}

static const char* const s_iridiaDbgNames[9] = { "allocs", "uses", "misaligned", "overlap", "reuse_in_flight", "use_after_release", "use_before_fill", "changed_before_encode", "changed_before_gpu_done" };

void MetalSynchronizedHeapAllocator::DbgLog(int kind, const DbgRegion& r, const char* what)
{
	m_dbgStats[kind]++;
	if (m_dbgStats[kind] <= 20)
		fprintf(stderr, "IRIDIA_IDXDBG %s chunk=%u off=%u size=%u filled=%d released=%d orphan=%d users=%zu %s\n", s_iridiaDbgNames[kind], r.chunk, r.offset, r.size, r.filled, r.released, r.orphan, r.users.size(), what);
}

void MetalSynchronizedHeapAllocator::DbgAlloc(AllocatorReservation* res, uint32 alignment, bool chunkReused)
{
	const uint32 chunk = res->bufferIndex;
	if (m_dbgChunkRegions.size() <= chunk)
		m_dbgChunkRegions.resize(chunk + 1);
	auto& list = m_dbgChunkRegions[chunk];
	if (chunkReused)
	{
		// the chunk starts over: regions nobody still reads are dropped, the rest stay as orphans until their readers finish
		m_dbgChunkReuses++;
		std::vector<uint64> keep;
		for (uint64 id : list)
		{
			DbgRegion& r = m_dbgRegions[id];
			if (r.users.empty())
			{
				m_dbgRegions.erase(id);
				continue;
			}
			bool inFlight = false;
			for (auto* cb : r.users)
				inFlight |= !CommandBufferCompleted(cb);
			if (inFlight)
				DbgLog(4, r, "chunk reused while a command buffer reading it is still running");
			r.orphan = true;
			keep.push_back(id);
		}
		list.swap(keep);
	}
	DbgRegion nr{ chunk, res->bufferOffset, res->size, 0, false, false, false, {} };
	if ((res->bufferOffset % alignment) != 0 || (res->bufferOffset % 4) != 0)
		DbgLog(2, nr, "allocation offset misaligned");
	const uint32 end = res->bufferOffset + res->size;
	for (auto it = list.rbegin(); it != list.rend(); ++it)
	{
		const DbgRegion& r = m_dbgRegions[*it];
		const bool overlaps = res->bufferOffset < r.offset + r.size && r.offset < end;
		if (overlaps)
			DbgLog(3, r, r.orphan ? "new allocation overlaps a region still in flight" : "new allocation overlaps a region of the same fill");
		if (!r.orphan)
			break; // the current fill is in increasing order: only its last region can overlap
	}
	m_dbgStats[0]++;
	res->dbgId = m_dbgNextId++;
	m_dbgRegions.emplace(res->dbgId, std::move(nr));
	list.push_back(res->dbgId);
}

void MetalSynchronizedHeapAllocator::DbgUse(AllocatorReservation* res, MTL::CommandBuffer* cb, uint32 indexSize)
{
	if (!res || !res->dbgId)
		return;
	auto it = m_dbgRegions.find(res->dbgId);
	if (it == m_dbgRegions.end())
		return;
	DbgRegion& r = it->second;
	m_dbgStats[1]++;
	if (indexSize && (res->bufferOffset % indexSize) != 0)
		DbgLog(2, r, "draw offset not a multiple of the index size");
	if (r.released)
		DbgLog(5, r, "draw from a released region");
	if (!r.filled)
		DbgLog(6, r, "draw from a region that was never filled");
	else if (IridiaDbgChecksum(res->memPtr, r.size) != r.checksum)
		DbgLog(7, r, "contents changed between fill and draw");
	if (r.users.empty() || r.users.back() != cb)
	{
		r.users.push_back(cb);
		m_dbgCbUses[cb].push_back(res->dbgId);
	}
}

void MetalSynchronizedHeapAllocator::DbgCompleted(MTL::CommandBuffer* cb)
{
	auto it = m_dbgCbUses.find(cb);
	if (it == m_dbgCbUses.end())
		return;
	for (uint64 id : it->second)
	{
		auto rit = m_dbgRegions.find(id);
		if (rit == m_dbgRegions.end())
			continue;
		DbgRegion& r = rit->second;
		if (IridiaDbgChecksum(m_bumpChunks[r.chunk].ptr + r.offset, r.size) != r.checksum)
			DbgLog(8, r, "contents changed before the command buffer reading them finished");
		r.users.erase(std::remove(r.users.begin(), r.users.end(), cb), r.users.end());
		if (r.orphan && r.users.empty())
		{
			auto& list = m_dbgChunkRegions[r.chunk];
			list.erase(std::remove(list.begin(), list.end(), id), list.end());
			m_dbgRegions.erase(rit);
		}
	}
	m_dbgCbUses.erase(it);
	DbgReport();
}

void MetalSynchronizedHeapAllocator::DbgReport()
{
	static auto s_last = std::chrono::steady_clock::now();
	const auto now = std::chrono::steady_clock::now();
	if (now - s_last < std::chrono::seconds(10))
		return;
	s_last = now;
	fprintf(stderr, "IRIDIA_IDXDBG_STATS chunks=%zu free=%zu chunk_reuses=%llu regions=%zu", m_bumpChunks.size(), m_bumpFree.size(), (unsigned long long)m_dbgChunkReuses, m_dbgRegions.size());
	for (int i = 0; i < 9; i++)
		fprintf(stderr, " %s=%llu", s_iridiaDbgNames[i], (unsigned long long)m_dbgStats[i]);
	fprintf(stderr, "\n");
}

void MetalSynchronizedHeapAllocator::BumpRelease(uint32 chunkIndex)
{
	// GPU work recorded so far may still read the chunk: reuse it after the current command buffer finishes
	m_bumpReleaseQueue[m_mtlr->GetCurrentCommandBuffer()].push_back(chunkIndex);
}

MetalSynchronizedHeapAllocator::AllocatorReservation* MetalSynchronizedHeapAllocator::AllocateBufferMemory(uint32 size, uint32 alignment)
{
	if (BumpOn()) [[unlikely]]
		return BumpAllocate(size, alignment);
	CHAddr addr = m_chunkedHeap.alloc(size, alignment);
	m_activeAllocations.emplace_back(addr);
	AllocatorReservation* res = m_poolAllocatorReservation.allocObj();
	res->bufferIndex = addr.chunkIndex;
	res->bufferOffset = addr.offset;
	res->size = size;
	res->mtlBuffer = m_chunkedHeap.GetBufferByIndex(addr.chunkIndex);
	res->memPtr = m_chunkedHeap.GetChunkPtr(addr.chunkIndex) + addr.offset;
	res->dbgId = 0;

	return res;
}

void MetalSynchronizedHeapAllocator::FreeReservation(AllocatorReservation* uploadReservation)
{
	if (BumpOn()) [[unlikely]]
	{
		const uint32 chunk = uploadReservation->bufferIndex;
		cemu_assert_debug(m_bumpChunks[chunk].live > 0);
		if (uploadReservation->dbgId)
			if (auto it = m_dbgRegions.find(uploadReservation->dbgId); it != m_dbgRegions.end())
				it->second.released = true;
		if (--m_bumpChunks[chunk].live == 0 && chunk != m_bumpCurrent)
			BumpRelease(chunk);
		m_poolAllocatorReservation.freeObj(uploadReservation);
		return;
	}
	// put the allocation on a delayed release queue for the current command buffer
	MTL::CommandBuffer* currentCommandBuffer = m_mtlr->GetCurrentCommandBuffer();
	auto it = std::find_if(m_activeAllocations.begin(), m_activeAllocations.end(), [&uploadReservation](const TrackedAllocation& allocation) { return allocation.allocation.chunkIndex == uploadReservation->bufferIndex && allocation.allocation.offset == uploadReservation->bufferOffset; });
	cemu_assert_debug(it != m_activeAllocations.end());
	m_releaseQueue[currentCommandBuffer].emplace_back(it->allocation);
	m_activeAllocations.erase(it);
	m_poolAllocatorReservation.freeObj(uploadReservation);
}

void MetalSynchronizedHeapAllocator::FlushReservation(AllocatorReservation* uploadReservation)
{
	if (BumpOn()) [[unlikely]]
	{
		if (m_bumpOptions & MTL::ResourceStorageModeManaged)
			uploadReservation->mtlBuffer->didModifyRange(NS::Range(uploadReservation->bufferOffset, uploadReservation->size));
		if (uploadReservation->dbgId)
			if (auto it = m_dbgRegions.find(uploadReservation->dbgId); it != m_dbgRegions.end())
			{
				it->second.checksum = IridiaDbgChecksum(uploadReservation->memPtr, uploadReservation->size);
				it->second.filled = true;
			}
		return;
	}
	if (m_chunkedHeap.RequiresFlush())
	{
	    uploadReservation->mtlBuffer->didModifyRange(NS::Range(uploadReservation->bufferOffset, uploadReservation->size));
	}
}

void MetalSynchronizedHeapAllocator::CleanupBuffer(MTL::CommandBuffer* latestFinishedCommandBuffer)
{
	if (DbgOn()) [[unlikely]]
		DbgCompleted(latestFinishedCommandBuffer);
	if (!m_bumpReleaseQueue.empty())
	{
		if (auto bit = m_bumpReleaseQueue.find(latestFinishedCommandBuffer); bit != m_bumpReleaseQueue.end())
		{
			for (uint32 chunk : bit->second)
				m_bumpFree.push_back(chunk);
			m_bumpReleaseQueue.erase(bit);
		}
	}
    auto it = m_releaseQueue.find(latestFinishedCommandBuffer);
    if (it == m_releaseQueue.end())
        return;

    // release allocations
	for (auto& addr : it->second)
		m_chunkedHeap.free(addr);
	m_releaseQueue.erase(it);
}

void MetalSynchronizedHeapAllocator::GetStats(uint32& numBuffers, size_t& totalBufferSize, size_t& freeBufferSize) const
{
	m_chunkedHeap.GetStats(numBuffers, totalBufferSize, freeBufferSize);
}
