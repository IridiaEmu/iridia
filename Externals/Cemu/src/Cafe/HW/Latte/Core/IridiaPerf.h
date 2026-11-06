#pragma once
#include <atomic>
#include <cstdint>

// Iridia Wii U app: the last second's numbers from the IRIDIA_PERF line, for the in-app recorder.
struct IridiaPerfSnapshot
{
	std::atomic<uint32_t> seq{0};        // bumped once per second
	std::atomic<float> fps{0};
	std::atomic<uint32_t> drawsPerFrame{0};
	std::atomic<uint32_t> vsyncs{0};
	std::atomic<uint32_t> flips{0};
	std::atomic<uint32_t> vsyncWaitMs{0};  // ms the game spent in GX2WaitForVsync
	std::atomic<uint32_t> gpuWaitMs{0};    // ms the game spent waiting for the GPU thread (GX2WaitTimeStamp)
	std::atomic<float> vblankLateMs{0};    // average vblank delivery lateness
	std::atomic<uint32_t> gameplaySeconds{0};
};
extern IridiaPerfSnapshot g_iridiaPerf;
// Iridia Wii U app diagnostics (IRIDIA_DIAG line): GPU busy time of finished Metal command buffers, and on which
// host CPU each emulated core's time slices started (pthread_cpu_number_np; tells fast from efficiency cores).
extern std::atomic<uint64_t> g_iridiaGpuBusyNs;
extern std::atomic<uint64_t> g_iridiaGpuUnionNs; // busy, overlapping command buffers counted once
extern std::atomic<uint32_t> g_iridiaGpuCmdBufs; // finished command buffers
extern std::atomic<uint32_t> g_iridiaCpuHist[3][16];
// Iridia diagnostics: microseconds the GPU thread spent waiting, by reason (IRIDIA_DIAG "latte" field):
// 0 no commands from the game, 1 wait-for-memory packet, 2 sync of readbacks/queries, 3 next drawable,
// 4 flush with wait, 5 texture readback force-finish, 6 occlusion query flush
extern std::atomic<uint64_t> g_iridiaLatteWaitUs[8];
#include <chrono>
void IridiaWaitTimerBegin(int k);
void IridiaWaitTimerEnd(int k);
struct IridiaWaitTimer
{
	int k; std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
	explicit IridiaWaitTimer(int kind);
	~IridiaWaitTimer() { IridiaWaitTimerEnd(k); g_iridiaLatteWaitUs[k].fetch_add((uint64_t)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - t0).count(), std::memory_order_relaxed); }
};
// Iridia: the GPU thread sleeps while it has nothing to do until it is woken (new commands from the game, a
// queued async command) or the next emulated vblank is due, instead of waking every 20 us to look.
void IridiaLatteWake();
// Iridia diagnostics: render passes begun, and those that re-begin the same attachments as the previous render pass
// (split by a blit/compute encoder [1], a forced recreate [2] or a commit [3]); each split costs a store + load of all
// attachments on a tile-based GPU. [0] = all passes.
extern std::atomic<uint32_t> g_iridiaPasses[4];
// Iridia diagnostics: IRIDIA_TIMELINE=<gameplay second> records 2 s of timed events (thread time slices per core,
// GPU waits, Metal command buffer commit and GPU start/end, game waits for the GPU and vsync) to
// IRIDIA_TIMELINE_FILE (16-byte records: u64 steady-clock ns, u16 event, u16 core, u32 arg) for a frame timeline.
enum IridiaTLEvent : uint16_t { TL_WAITTS_B = 1, TL_WAITTS_E, TL_VSYNC_B, TL_VSYNC_E, TL_SWAPREQ, TL_LWAIT_B, TL_LWAIT_E, TL_COMMIT, TL_GPU_B, TL_GPU_E, TL_RUN_B, TL_RUN_E, TL_LSWAP_B, TL_LSWAP_E, TL_VBLANK, TL_CAL_STEADY, TL_CAL_HOST, TL_WRM_WANT, TL_WRM_HAVE, TL_VBLANK_VAL,
	TL_HOSTCPU /* host CPU number (arg) of the thread recording it, core = emulated core or 7 = GPU thread */,
	TL_END_HLE /* at TL_RUN_E: OS call (HLE id) that ended the slice, 0xffff = time slice used up */, TL_END_LR /* its guest return address (or the guest IP) */,
	TL_END_R3 /* its first argument */,
	TL_WAKE /* a waiting thread was made ready: arg = that thread, core = the waker's emulated core (7 = not a guest thread) */,
	TL_WAKER /* right after TL_WAKE: arg = the guest thread that woke it (0 = none) */,
	TL_HLE /* OS call entered: arg = HLE id, core = emulated core */, TL_HLE_LR /* after TL_HLE for time reads: arg = guest return address */,
	TL_WAKEPRIO /* after TL_WAKER: arg bits 0-4 woken thread priority, 5-7 its affinity, then 6 bits per core 0..2 = priority of the thread running there (63 = none) */ };
// Iridia diagnostics: the OS call each emulated core is inside, recorded at slice ends while the timeline is on
struct IridiaHleCur { uint32_t id = 0xffff, lr = 0, r3 = 0; };
extern IridiaHleCur g_iridiaHleCur[3];
const char* IridiaHleName(uint32_t id);
extern std::atomic<bool> g_iridiaTimelineOn;
void IridiaTimelineRecordAt(uint64_t ns, uint16_t ev, uint16_t core, uint32_t arg);
void IridiaTimelineThreadName(uint32_t thread, const char* name);
// Iridia diagnostics: every frame's GX2WaitForVsync return -> next swap request time, counted as under 16.7 ms,
// under 33.3 ms and longer (printed once per second as IRIDIA_FRAMES); the start time is set at the vsync return
extern std::atomic<uint64_t> g_iridiaFrameStartNs;
extern std::atomic<uint32_t> g_iridiaFrameHist[3];
extern std::atomic<uint64_t> g_iridiaFrameSumUs; // start->swap total, for the mean
inline uint64_t IridiaTimelineNow() { return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
inline void IridiaTL(uint16_t ev, uint16_t core = 0, uint32_t arg = 0) { if (g_iridiaTimelineOn.load(std::memory_order_relaxed)) IridiaTimelineRecordAt(IridiaTimelineNow(), ev, core, arg); }
void IridiaTimelineTick(int gameplaySecond); // once per second from the performance monitor
void IridiaTLHostCpu(uint16_t core); // records TL_HOSTCPU for the calling thread (timeline on only)
inline IridiaWaitTimer::IridiaWaitTimer(int kind) : k(kind) { IridiaWaitTimerBegin(kind); }
