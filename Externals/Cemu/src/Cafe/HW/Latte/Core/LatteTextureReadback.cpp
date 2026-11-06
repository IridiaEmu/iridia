#include <chrono>
#include "Cafe/HW/Latte/Core/Latte.h"
#include "Cafe/HW/Latte/Core/LattePerformanceMonitor.h"
#include "Cafe/HW/Latte/Renderer/Renderer.h"
#include "Cafe/HW/Latte/Core/LatteTexture.h"

#define LOG_READBACK_TIME

#include "Cafe/HW/Latte/Core/IridiaSyncDiag.h"
static bool s_iridiaWriteForced = false; // Iridia diagnostics: the result being written was finished by a sync

struct LatteTextureReadbackQueueEntry
{
	HRTick initiateTime;
	uint32 lastUpdateDrawcallIndex;
	LatteTextureView* textureView;
};

std::vector<LatteTextureReadbackQueueEntry> sTextureScheduledReadbacks; // readbacks that have been queued but the actual transfer has not yet been started
std::queue<LatteTextureReadbackInfo*> sTextureActiveReadbackQueue; // readbacks in flight

void LatteTextureReadback_StartTransfer(LatteTextureView* textureView)
{
	cemuLog_log(LogType::TextureReadback, "[TextureReadback-Start] PhysAddr {:08x} Res {}x{} Fmt {} Slice {} Mip {}", textureView->baseTexture->physAddress, textureView->baseTexture->width, textureView->baseTexture->height, textureView->baseTexture->format, textureView->firstSlice, textureView->firstMip);
	HRTick currentTick = HighResolutionTimer().now().getTick();
	// create info entry and store in ordered linked list
	LatteTextureReadbackInfo* readbackInfo = g_renderer->texture_createReadback(textureView);
	if (!readbackInfo)
		return;
	sTextureActiveReadbackQueue.push(readbackInfo);
	readbackInfo->StartTransfer();
	readbackInfo->transferStartTime = currentTick;
}

/*
 * Checks for queued transfers and starts them if at least five drawcalls have passed since the last write
 * Called after a draw sequence is completed
 * Returns true if at least one transfer was started
 */
bool LatteTextureReadback_Update(bool forceStart)
{
	bool hasStartedTransfer = false;
	for (size_t i = 0; i < sTextureScheduledReadbacks.size(); i++)
	{
		LatteTextureReadbackQueueEntry& entry = sTextureScheduledReadbacks[i];
		uint32 numElapsedDrawcalls = LatteGPUState.drawCallCounter - entry.lastUpdateDrawcallIndex;
		// Iridia: start a readback after 1 draw that did not write the texture (as soon as the game draws to something
		// else, i.e. at the end of its render pass; upstream waits 5). IRIDIA_RB_START_DRAWS=<n> overrides it.
		static const uint32 s_startDraws = iridia_getenv("IRIDIA_RB_START_DRAWS") ? std::max(1, atoi(iridia_getenv("IRIDIA_RB_START_DRAWS"))) : 1;
		if (forceStart || numElapsedDrawcalls >= s_startDraws)
		{
			static const bool s_rbLog = iridia_getenv("IRIDIA_RB_LOG") != nullptr;
			if (s_rbLog)
				fprintf(stderr, "IRIDIA_RB start %08x %ux%u after %u draws%s\n", entry.textureView->baseTexture->physAddress, entry.textureView->baseTexture->width, entry.textureView->baseTexture->height, numElapsedDrawcalls, forceStart ? " (forced)" : "");
#ifdef LOG_READBACK_TIME
			double elapsedSecondsSinceInitiate = HighResolutionTimer::getTimeDiff(entry.initiateTime, HighResolutionTimer().now().getTick());
			cemuLog_log(LogType::TextureReadback, "[TextureReadback-Update] Starting transfer for {:08x} after {} elapsed drawcalls. Time since initiate: {:.4} Force-start: {}", entry.textureView->baseTexture->physAddress, numElapsedDrawcalls, elapsedSecondsSinceInitiate, forceStart?"yes":"no");
#endif
			LatteTextureReadback_StartTransfer(entry.textureView);
			// remove element
			vectorRemoveByIndex(sTextureScheduledReadbacks, i);
			i--;
			hasStartedTransfer = true;
		}
	}
	return hasStartedTransfer;
}

/*
 * Called when a texture is deleted
 */
void LatteTextureReadback_NotifyTextureDeletion(LatteTexture* texture)
{
	// delete from queue
	for (size_t i = 0; i < sTextureScheduledReadbacks.size(); i++)
	{
		LatteTextureReadbackQueueEntry& entry = sTextureScheduledReadbacks[i];
		if (entry.textureView->baseTexture == texture)
		{
			vectorRemoveByIndex(sTextureScheduledReadbacks, i);
			break;
		}
	}
}

void LatteTextureReadback_Initate(LatteTextureView* textureView)
{
	// currently we don't support readback for resized textures
	if (textureView->baseTexture->overwriteInfo.hasResolutionOverwrite)
	{
		cemuLog_log(LogType::Force, "Texture readback is not supported for textures with modified resolution. Texture: {:08x} {}x{}", textureView->baseTexture->physAddress, textureView->baseTexture->width, textureView->baseTexture->height);
		return;
	}
	// check if texture isn't already queued for transfer
	for (size_t i = 0; i < sTextureScheduledReadbacks.size(); i++)
	{
		LatteTextureReadbackQueueEntry& entry = sTextureScheduledReadbacks[i];
		if (entry.textureView == textureView)
		{
			entry.lastUpdateDrawcallIndex = LatteGPUState.drawCallCounter;
			return;
		}
	}
	// queue
	LatteTextureReadbackQueueEntry queueEntry;
	queueEntry.initiateTime = HighResolutionTimer().now().getTick();
	queueEntry.textureView = textureView;
	queueEntry.lastUpdateDrawcallIndex = LatteGPUState.drawCallCounter;
	sTextureScheduledReadbacks.emplace_back(queueEntry);
}

void LatteTextureReadback_UpdateFinishedTransfers(bool forceFinish)
{
	if (forceFinish)
	{
		// start any delayed transfers
		LatteTextureReadback_Update(true);
		if (g_iridiaSync.inSync)
			g_iridiaSync.rbInFlight = (uint32)sTextureActiveReadbackQueue.size();
	}
	performanceMonitor.gpuTime_waitForAsync.beginMeasuring();
	while (!sTextureActiveReadbackQueue.empty())
	{
		LatteTextureReadbackInfo* readbackInfo = sTextureActiveReadbackQueue.front();
		if (forceFinish)
		{
			if (!readbackInfo->IsFinished())
			{
				readbackInfo->waitStartTime = HighResolutionTimer().now().getTick();
#ifdef LOG_READBACK_TIME
				if (cemuLog_isLoggingEnabled(LogType::TextureReadback))
				{
					double elapsedSecondsTransfer = HighResolutionTimer::getTimeDiff(readbackInfo->transferStartTime, HighResolutionTimer().now().getTick());
					cemuLog_log(LogType::TextureReadback, "[Texture-Readback] Force-finish: {:08x} Res {:}/{:} TM {:} FMT {:04x} Transfer time so far: {:.4}ms", readbackInfo->hostTextureCopy.physAddress, readbackInfo->hostTextureCopy.width, readbackInfo->hostTextureCopy.height, readbackInfo->hostTextureCopy.tileMode, (uint32)readbackInfo->hostTextureCopy.format, elapsedSecondsTransfer * 1000.0);
				}
#endif
				readbackInfo->forceFinish = true;
				{
					// Iridia diagnostics: IRIDIA_RB_LOG=1 logs every forced readback wait
					static const bool s_rbLog = iridia_getenv("IRIDIA_RB_LOG") != nullptr;
					const auto t0 = std::chrono::steady_clock::now();
					readbackInfo->ForceFinish();
					if (g_iridiaSync.inSync)
					{
						const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
						g_iridiaSync.rbWaited++;
						g_iridiaSync.rbWaitMs += ms;
						g_iridiaSync.rbMaxWaitMs = std::max(g_iridiaSync.rbMaxWaitMs, ms);
					}
					if (s_rbLog)
						fprintf(stderr, "IRIDIA_RB force-finish %08x %ux%u fmt %04x: started %.2f ms ago, waited %.2f ms\n", readbackInfo->hostTextureCopy.physAddress, readbackInfo->hostTextureCopy.width, readbackInfo->hostTextureCopy.height, (uint32)readbackInfo->hostTextureCopy.format,
							HighResolutionTimer::getTimeDiff(readbackInfo->transferStartTime, HighResolutionTimer().now().getTick()) * 1000.0, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
				}
				// rerun logic since ->ForceFinish() can recurively call this function and thus modify the queue
				continue;
			}
		}
		else
		{
			if (!readbackInfo->IsFinished())
				break;
			readbackInfo->waitStartTime = HighResolutionTimer().now().getTick();
		}
		// performance testing
#ifdef LOG_READBACK_TIME
		if (cemuLog_isLoggingEnabled(LogType::TextureReadback))
		{
			HRTick currentTick = HighResolutionTimer().now().getTick();
			double elapsedSecondsTransfer = HighResolutionTimer::getTimeDiff(readbackInfo->transferStartTime, currentTick);
			double elapsedSecondsWaiting = HighResolutionTimer::getTimeDiff(readbackInfo->waitStartTime, currentTick);
			cemuLog_log(LogType::TextureReadback, "[Texture-Readback] {:08x} Res {}/{} TM {} FMT {:04x} ReadbackLatency: {:6.3}ms WaitTime: {:6.3}ms ForcedWait {}", readbackInfo->hostTextureCopy.physAddress, readbackInfo->hostTextureCopy.width, readbackInfo->hostTextureCopy.height, readbackInfo->hostTextureCopy.tileMode, (uint32)readbackInfo->hostTextureCopy.format, elapsedSecondsTransfer * 1000.0, elapsedSecondsWaiting * 1000.0, readbackInfo->forceFinish ? "yes" : "no");
		}
#endif
		uint8* pixelData = readbackInfo->GetData();
		s_iridiaWriteForced = forceFinish;
		LatteTextureLoader_writeReadbackTextureToMemory(&readbackInfo->hostTextureCopy, readbackInfo->m_firstSlice, readbackInfo->m_firstMip, pixelData, readbackInfo->m_rowPitch);
		s_iridiaWriteForced = false;
		readbackInfo->ReleaseData();
		// get the original texture if it still exists and invalidate the current data hash
		LatteTextureView* origTexView = LatteTextureViewLookupCache::lookupSlice(readbackInfo->hostTextureCopy.physAddress, readbackInfo->hostTextureCopy.width, readbackInfo->hostTextureCopy.height, readbackInfo->hostTextureCopy.pitch, 0, 0, readbackInfo->hostTextureCopy.format);
		if (origTexView)
			LatteTC_ResetTextureChangeTracker(origTexView->baseTexture, true);
		delete readbackInfo;
		// remove from queue
		cemu_assert_debug(!sTextureActiveReadbackQueue.empty());
		cemu_assert_debug(readbackInfo == sTextureActiveReadbackQueue.front());
		sTextureActiveReadbackQueue.pop();
	}
	performanceMonitor.gpuTime_waitForAsync.endMeasuring();
}

bool LatteTextureReadback_ReadbackToLinearBlocking(LatteTextureView* sourceView, uint8* dstPtr, uint32 dstWidth, uint32 dstHeight, uint32 dstPitch)
{
	LatteTextureReadbackInfo* info = g_renderer->texture_createReadback(sourceView);
	if (!info)
		return false;

	info->StartTransfer();
	info->ForceFinish();
	cemu_assert(info->IsFinished());

	uint8* data = info->GetData(); // returned pixel format should match Latte format
	uint32 bpp = Latte::GetFormatBits(sourceView->baseTexture->format) / 8;
	uint32 srcRowBytes = info->m_rowPitch;
	uint32 dstRowBytes = dstWidth * bpp;
	for (uint32 y = 0; y < dstHeight; y++)
		memcpy(dstPtr + y * dstPitch * bpp, data + y * srcRowBytes, dstRowBytes);

	info->ReleaseData();
	delete info;
	return true;
}

uint32 LatteTextureReadbackInfo::GetReadbackRowPitch(LatteTextureView* textureView, uint32 rowAlignment)
{
	uint32 width = textureView->baseTexture->GetMipWidth(textureView->firstMip);
	if (Latte::IsCompressedFormat(textureView->format))
		width = (width + 3) / 4;
	uint32 rowPitch = width * (Latte::GetFormatBits(textureView->format) / 8);
	return (rowPitch + rowAlignment - 1) & ~(rowAlignment - 1);
}

uint32 LatteTextureReadbackInfo::GetReadbackImageSize(LatteTextureView* textureView, uint32 rowPitch)
{
	uint32 height = textureView->baseTexture->GetMipHeight(textureView->firstMip);
	if (Latte::IsCompressedFormat(textureView->format))
		height = (height + 3) / 4;
	return height * rowPitch;
}

// Iridia diagnostics for the GX2DrawDone full sync (see IridiaSyncDiag.h)
#include "Cafe/HW/Latte/Core/IridiaSyncDiag.h"
#include <mutex>
#include <unordered_map>

IridiaSyncStats g_iridiaSync;

bool IridiaSyncLogOn()
{
	static const bool s_on = iridia_getenv("IRIDIA_SYNC_LOG") != nullptr;
	return s_on;
}

uint64_t IridiaNowNs()
{
	return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

static uint64_t s_iridiaSyncStartNs;

void IridiaSyncBegin()
{
	g_iridiaSync = {};
	g_iridiaSync.inSync = true;
	g_iridiaSync.rbScheduled = (uint32_t)sTextureScheduledReadbacks.size();
	s_iridiaSyncStartNs = IridiaNowNs();
}

void IridiaSyncEnd()
{
	IridiaSyncStats& s = g_iridiaSync;
	s.inSync = false;
	fprintf(stderr, "IRIDIA_SYNC f=%u rb sched %u inflight %u waited %u wait %.2f max %.2f | q host %u gx2 %u %s %.2f | total %.2f ms\n", LatteGPUState.frameCounter,
		s.rbScheduled, s.rbInFlight, s.rbWaited, s.rbWaitMs, s.rbMaxWaitMs, s.qInFlight, s.qGx2Active, s.qWaited ? "waited" : "ready", s.qWaitMs, (IridiaNowNs() - s_iridiaSyncStartNs) / 1e6);
}

// Readback results in guest memory, watched until the emulated CPU first reads them (IRIDIA_READ_WATCH builds)
struct IridiaRbWatch { uint32_t addr, size, w, h, fmt, writeFrame; uint64_t writeNs; bool forced, used; };
static std::mutex s_iridiaWatchMutex;
static IridiaRbWatch s_iridiaWatch[16];
std::atomic<uint32_t> g_iridiaWatchLo{0xFFFFFFFF}, g_iridiaWatchHi{0};
static std::atomic<uint32_t> s_iridiaSlotLo[16], s_iridiaSlotHi[16]; // lock-free copy of the watched ranges (empty: lo >= hi)

static void IridiaWatchBoundsLocked()
{
	uint32_t lo = 0xFFFFFFFF, hi = 0;
	for (int i = 0; i < 16; i++)
	{
		auto& e = s_iridiaWatch[i];
		s_iridiaSlotLo[i].store(e.used ? e.addr : 1, std::memory_order_relaxed);
		s_iridiaSlotHi[i].store(e.used ? e.addr + e.size : 0, std::memory_order_relaxed);
		if (e.used) { lo = std::min(lo, e.addr); hi = std::max(hi, e.addr + e.size); }
	}
	g_iridiaWatchLo.store(lo, std::memory_order_relaxed);
	g_iridiaWatchHi.store(hi, std::memory_order_relaxed);
}

static void IridiaWatchReport(const IridiaRbWatch& e, const char* what, uint32_t pc)
{
	const uint64_t now = IridiaNowNs();
	fprintf(stderr, "IRIDIA_RBW %08x %ux%u fmt %04x %s %s +%.2f ms (+%d frames) pc %08x\n", e.addr, e.w, e.h, e.fmt, e.forced ? "sync" : "async", what,
		(now - e.writeNs) / 1e6, (int)(LatteGPUState.frameCounter - e.writeFrame), pc);
}

void IridiaReadbackWritten(uint32_t addr, uint32_t size, uint32_t w, uint32_t h, uint32_t fmt, bool forced)
{
	forced = forced || s_iridiaWriteForced;
	if (IridiaSyncLogOn())
		fprintf(stderr, "IRIDIA_RBWRITE %08x %ux%u fmt %04x %u bytes %s f=%u\n", addr, w, h, fmt, size, forced ? "sync" : "async", LatteGPUState.frameCounter);
}


static std::mutex s_iridiaQueryMutex;
static std::unordered_map<uint32_t, std::pair<uint64_t, uint32_t>> s_iridiaQueryDone; // query -> (finish time, frame)

void IridiaQueryFinished(uint32_t queryAddr)
{
	std::lock_guard l(s_iridiaQueryMutex);
	s_iridiaQueryDone[queryAddr] = { IridiaNowNs(), LatteGPUState.frameCounter };
}

void IridiaQueryRead(uint32_t queryAddr)
{
	std::lock_guard l(s_iridiaQueryMutex);
	auto it = s_iridiaQueryDone.find(queryAddr);
	if (it == s_iridiaQueryDone.end())
		return;
	fprintf(stderr, "IRIDIA_QRY %08x read +%.2f ms (+%d frames) after its result was written\n", queryAddr, (IridiaNowNs() - it->second.first) / 1e6, (int)(LatteGPUState.frameCounter - it->second.second));
	s_iridiaQueryDone.erase(it);
}
