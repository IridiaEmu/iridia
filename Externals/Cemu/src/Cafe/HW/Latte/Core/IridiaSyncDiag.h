#pragma once
#include <atomic>
#include <cstdint>

// Iridia diagnostics for the GX2DrawDone full sync (IT_HLE_SYNC_ASYNC_OPERATIONS).
// IRIDIA_SYNC_LOG=1: one IRIDIA_SYNC line per sync with the texture readbacks and occlusion queries it waited on and
// for how long, and IRIDIA_QRY lines when the game first gets an occlusion query result.
// Builds with IRIDIA_READ_WATCH (CMake option, off) also watch the guest memory each readback result is written to and
// print one IRIDIA_RBW line per result: when the emulated CPU first read it, or that it was overwritten unread.
bool IridiaSyncLogOn();
uint64_t IridiaNowNs();

struct IridiaSyncStats // GPU thread only
{
	uint32_t rbScheduled = 0;  // queued readbacks whose copy the sync had to start
	uint32_t rbInFlight = 0;   // readbacks in flight when the sync began (after starting the scheduled ones)
	uint32_t rbWaited = 0;     // of those, not finished yet: the sync waited for them
	double rbWaitMs = 0, rbMaxWaitMs = 0;
	uint32_t qInFlight = 0;    // host occlusion queries in flight
	uint32_t qGx2Active = 0;   // game (GX2) queries not finished yet
	bool qWaited = false;      // the query command buffer was not complete yet
	double qWaitMs = 0;
	bool inSync = false;
};
extern IridiaSyncStats g_iridiaSync;
void IridiaSyncBegin();
void IridiaSyncEnd();
// a readback result was written to guest memory (forced = finished by the sync)
void IridiaReadbackWritten(uint32_t addr, uint32_t size, uint32_t w, uint32_t h, uint32_t fmt, bool forced);
// a GX2 occlusion query result was written to guest memory / the game got it
void IridiaQueryFinished(uint32_t queryAddr);
void IridiaQueryRead(uint32_t queryAddr);

#ifdef IRIDIA_READ_WATCH_BUILD
extern std::atomic<uint32_t> g_iridiaWatchLo, g_iridiaWatchHi;
void IridiaReadWatchHit(uint32_t addr, uint32_t size, uint32_t pc);
#define IRIDIA_WATCH_LOAD(a, n, pc) do { const uint32_t _wa = (a); if (_wa < g_iridiaWatchHi.load(std::memory_order_relaxed) && _wa + (n) > g_iridiaWatchLo.load(std::memory_order_relaxed)) IridiaReadWatchHit(_wa, (n), (pc)); } while (0)
#else
#define IRIDIA_WATCH_LOAD(a, n, pc)
#endif
