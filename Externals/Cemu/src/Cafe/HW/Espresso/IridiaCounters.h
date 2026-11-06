#pragma once
// Iridia study (IRIDIA_COUNTERS builds only; compiled out of every other build): event counts over the
// IRIDIA_GUEST_PROF window, written to <file>.cnt next to the instruction mix (<file>.mix) when the window ends.
#ifdef IRIDIA_COUNTERS
#include <atomic>
#include <unordered_map>

enum IridiaCnt : uint32
{
	CNT_THREAD_SWITCH,     // guest thread switches (fiber switch to another OSThread)
	CNT_DCFLUSH_NOTIFY,    // LatteBufferCache_notifyDCFlush calls (every source: dcbf/dcbst, DCFlushRange, memcpy, ...)
	CNT_DCFLUSH_PAGES,     // 1 KB pages marked by those calls
	CNT_DCRANGE_LINES,     // 32-byte lines covered by DCFlushRange / DCFlushRangeNoSync / DCStoreRangeNoSync
	CNT_MEMCPY_BYTES,      // bytes copied by coreinit memcpy / memmove / OSBlockMove
	CNT_GX2_MULTI_CALLS,   // gx2WriteGather_submit(...) calls: one core lookup for several words
	CNT_GX2_MULTI_WORDS,
	CNT_GX2_WORD_CALLS,    // gx2WriteGather_submitU32AsBE/LE: one core lookup per word
	CNT_GX2_ARRAY_CALLS,   // gx2WriteGather_submitU32AsLEArray
	CNT_GX2_ARRAY_WORDS,
	CNT_LOOP_PROBES,       // run loop: block lookups through the per-core cache
	CNT_LOOP_CACHE_MISS,   //   ... not in the cache: page table
	CNT_LOOP_BUILDS,       //   ... not in the page table either (or stale): block decoded
	CNT_TIMER_CONTENDED,   // guest timer reads that found its spinlock taken
	CNT_DCQ_CONTENDED,     // flush notifications that found the flush-queue spinlock taken
	CNT_MFTB,              // mftb instructions executed (TBL and TBU)
	CNT_THREAD_LOAD,       // __OSLoadThread calls (each reads the guest timer for wakeUpTime)
	CNT_COUNT
};
// block exit kinds seen by tbNextBlock: 0 other (fall-through, fused compare-branch, side exit), 1 blr, 2 bctr, 3 b/bc
// at the block end; results: 0 chained through the cache, 1 cache miss (back to the run loop), 2 time slice over
enum { CNT_EXIT_KINDS = 4, CNT_EXIT_RESULTS = 3 };

inline std::atomic<bool> g_iridiaCntOn{false};
inline std::atomic<uint64> g_iridiaCnt[CNT_COUNT];
inline uint64 g_iridiaCntExit[4][CNT_EXIT_KINDS][CNT_EXIT_RESULTS]; // [emulated core][kind][result], plain: one host thread per core
inline thread_local uint8 t_iridiaExitKind = 0;
inline std::atomic<uint64> g_iridiaCntTimer[4]; // guest timer reads (PPCTimer_getFromRDTSC) by emulated core 0-2, 3 = other host threads

#define IRIDIA_CNT(k, n) do { if (g_iridiaCntOn.load(std::memory_order_relaxed)) g_iridiaCnt[k].fetch_add((n), std::memory_order_relaxed); } while (0)
#define IRIDIA_CNT_EXITKIND(k) (t_iridiaExitKind = (k))
// taken side exits per branch step (one map per emulated core, each touched only by the host thread running that
// core): with the block executions this gives exact per-instruction counts (<file>.mix.side)
inline std::unordered_map<const void*, uint64> g_iridiaSideTaken[3];
#define IRIDIA_CNT_SIDE(hCPU, step) do { if (g_iridiaCntOn.load(std::memory_order_relaxed) && (hCPU)->spr.UPIR < 3) g_iridiaSideTaken[(hCPU)->spr.UPIR][(const void*)(step)]++; } while (0)
void IridiaCounters_dump(const char* path, double seconds);
#else
#define IRIDIA_CNT(k, n) do {} while (0)
#define IRIDIA_CNT_EXITKIND(k) do {} while (0)
#define IRIDIA_CNT_SIDE(hCPU, step) do {} while (0)
#endif
