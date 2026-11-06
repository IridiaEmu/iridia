#include "Cafe/HW/Latte/Core/Latte.h"
#include "Cafe/OS/libs/gx2/GX2_Event.h"
#ifdef ENABLE_VULKAN
#include "Cafe/HW/Latte/Renderer/Vulkan/VsyncDriver.h"
#endif
#include "util/highresolutiontimer/HighResolutionTimer.h"
#include "config/CemuConfig.h"
#include "Cafe/CafeSystem.h"

sint32 s_customVsyncFrequency = -1;
// Iridia study: frame-pacing counters, printed per second on the IRIDIA_PERF line
std::atomic<uint32> g_iridiaPace[12]; // 0 vsyncs, 1 flips executed, 2 GX2WaitForVsync, 3 GX2WaitForFlip, 4 GX2GetSwapStatus, 5 GX2SwapScanBuffers, 6 us waited for vsync, 7 us waited for flip, 8 vblank lateness us (sum), 9 max lateness us, 10 GX2WaitTimeStamp calls (incl. GX2DrawDone), 11 us waited in them

void LatteTiming_NotifyHostVSync();

// Iridia study: variable vblank (IRIDIA_VRR=1|2, off by default). When a guest thread is waiting for a vblank
// (GX2WaitForVsync, or GX2WaitForFlip when this vblank would execute the flip), the GPU thread has already
// presented every frame the guest swapped, and that frame is new since the last early vblank, the next vblank is
// delivered at once instead of at the next 60 Hz tick. Frames are then shown when they are done instead of
// snapping to 30/20/15 fps. At most one vblank ahead of the 60 Hz timeline.
//   1 = keep the 60 Hz grid: the early vblank uses up the next tick, so vblanks per second stay at ~60 (games that
//       count vblanks to measure time keep their speed; the per-frame vblank count alternates).
//   2 = restart the 60 Hz timer from the early vblank (more vblanks per second than 60 when frames are slow).
static int s_vrrMode = 0;
static uint32 s_vrrLastSwaps = 0;
// IRIDIA_VRR_MAXFPS=<n>: an early vblank only when at least 1/n s has passed since the last vblank that released a
// waiting guest (caps the shown rate, so the extra frames don't heat the phone); 0 = no cap
static uint64 s_vrrMinGap = 0;
static uint64 s_vrrLastRelease = 0;
// IRIDIA_FPS_LOCK=<n> (e.g. 25, 20): even pacing at exactly n fps. Like IRIDIA_VRR=1 IRIDIA_VRR_MAXFPS=n, and a regular
// 60 Hz vblank that would release a waiting guest before 1/n s is held back until then (at most one tick late), so
// every frame is shown 1/n s after the previous one. Vblanks per second stay at 60 (the tick is only moved).
static bool s_fpsLock = false;
static uint64 s_lockHoldUntil = 0; // a held-back tick fires at this time (0 = none)
static uint32 s_vsyncIntervalCounter = 0;
std::atomic<uint32> g_iridiaGuestSwaps{0}, g_iridiaHostPresents{0};
std::atomic<int> g_iridiaVsyncWaiters{0}, g_iridiaFlipWaiters{0};
std::atomic<uint32> g_iridiaVrr[2]; // early vblanks, sum of us they came early
bool IridiaVrrEnabled() { return s_vrrMode != 0; }

// calculate time between vsync events in timer units
// standard rate on Wii U is 59.94, however to prevent tearing and microstutter on ~60Hz displays it is better if we slightly overshoot 60 Hz
// can be modified by graphic packs
HRTick LatteTime_CalculateTimeBetweenVSync()
{
	// 59.94 -> 60 * 0.999

	HRTick tick = HighResolutionTimer::getFrequency();
	if (s_customVsyncFrequency > 0)
	{
		tick /= (uint64)s_customVsyncFrequency;
	}
	else
	{
		tick *= 1000ull;
		tick /= 1002ull;
		tick /= 60ull;
	}
	return tick;
}

void LatteTiming_setCustomVsyncFrequency(sint32 frequency)
{
	s_customVsyncFrequency = frequency;
}

void LatteTiming_disableCustomVsyncFrequency()
{
	s_customVsyncFrequency = -1;
}

bool LatteTiming_getCustomVsyncFrequency(sint32& customFrequency)
{
	sint32 t = s_customVsyncFrequency;
	if (t <= 0)
		return false;
	customFrequency = t;
	return true;
}

bool s_usingHostDrivenVSync = false;

void LatteTiming_EnableHostDrivenVSync()
{
	if (s_usingHostDrivenVSync)
		return;
	#ifdef ENABLE_VULKAN
	VsyncDriver_startThread(LatteTiming_NotifyHostVSync);
	s_usingHostDrivenVSync = true;
	#endif
}

bool LatteTiming_IsUsingHostDrivenVSync()
{
	return s_usingHostDrivenVSync;
}

void LatteTiming_Init()
{
	// Iridia study: IRIDIA_VSYNC_HZ=<n> runs the emulated vblank at n Hz. With a fast vblank the game's
	// swap interval no longer rounds frame times up to 33/50/67 ms, so fps shows the real frame capacity
	// (the game also runs faster than normal; measurement only).
	if (const char* hz = getenv("IRIDIA_VSYNC_HZ"))
		s_customVsyncFrequency = atoi(hz);
	if (const char* v = getenv("IRIDIA_VRR"))
		s_vrrMode = atoi(v);
	if (const char* v = getenv("IRIDIA_VRR_MAXFPS"); v && atoi(v) > 0)
		s_vrrMinGap = HighResolutionTimer::getFrequency() / (uint64)atoi(v);
	if (const char* v = getenv("IRIDIA_FPS_LOCK"); v && atoi(v) > 0)
	{
		s_fpsLock = true;
		s_vrrMode = 1;
		s_vrrMinGap = HighResolutionTimer::getFrequency() / (uint64)atoi(v);
		fprintf(stderr, "IRIDIA_FPS_LOCK %d fps\n", atoi(v));
	}
	if (s_vrrMode)
		fprintf(stderr, "IRIDIA_VRR max %s fps, mode %d (%s)\n", getenv("IRIDIA_VRR_MAXFPS") ? getenv("IRIDIA_VRR_MAXFPS") : "-", s_vrrMode, s_vrrMode == 1 ? "early vblank uses up the next 60 Hz tick" : "60 Hz timer restarts at the early vblank");
	LatteGPUState.timer_frequency = HighResolutionTimer::getFrequency();
	LatteGPUState.timer_bootUp = HighResolutionTimer::now().getTick();
	LatteGPUState.timer_nextVSync = LatteGPUState.timer_bootUp + LatteTime_CalculateTimeBetweenVSync();
}

void LatteTiming_signalVsync()
{
	if (!LatteGPUState.gx2InitCalled)
		return;
	g_iridiaPace[0]++;
	s_vsyncIntervalCounter++;
	uint32 swapInterval = 1;
	if (LatteGPUState.sharedArea)
		swapInterval = LatteGPUState.sharedArea->swapInterval;

	// flip
	if (s_vsyncIntervalCounter >= swapInterval)
	{
		if (LatteGPUState.sharedArea)
		{
			// hack/workaround - only execute flip if GX2SwapScanBuffers() isn't lagging behind
			uint64 currentTitleId = CafeSystem::GetForegroundTitleId();
			if (currentTitleId == 0x00050000101c9500 || currentTitleId == 0x00050000101c9400 || currentTitleId == 0x0005000e101c9300)
			{
				uint32 currentFlipRequestCount = _swapEndianU32(LatteGPUState.sharedArea->flipRequestCountBE);
				uint32 currentFlipExecuteCount = _swapEndianU32(LatteGPUState.sharedArea->flipExecuteCountBE);

				if ((currentFlipRequestCount >= currentFlipExecuteCount) || (currentFlipExecuteCount - currentFlipRequestCount < 4))
				{
					LatteGPUState.sharedArea->flipExecuteCountBE = _swapEndianU32(_swapEndianU32(LatteGPUState.sharedArea->flipExecuteCountBE) + 1);
				}

				LatteGPUState.flipCounter++;

			}
			else
			{
				// old code for all other games
				if (LatteGPUState.flipRequestCount > 0)
				{
					LatteGPUState.flipRequestCount.fetch_sub(1);
					LatteGPUState.sharedArea->flipExecuteCountBE = _swapEndianU32(_swapEndianU32(LatteGPUState.sharedArea->flipExecuteCountBE) + 1);
				}

			}
		}
		GX2::__GX2NotifyEvent(GX2::GX2CallbackEventType::FLIP);
		g_iridiaPace[1]++;
		s_vsyncIntervalCounter = 0;
	}
	// vsync
	GX2::__GX2NotifyEvent(GX2::GX2CallbackEventType::VSYNC);
}

HRTick s_lastHostVsync = 0;

// notify when host vsync event is triggered (on renderer canvas)
void LatteTiming_NotifyHostVSync()
{
	if (!LatteTiming_IsUsingHostDrivenVSync())
		return;
	auto nowTimePoint = HighResolutionTimer::now().getTick();
	auto dif = nowTimePoint - s_lastHostVsync;
	auto vsyncPeriod = LatteTime_CalculateTimeBetweenVSync();


	if (dif < vsyncPeriod)
	{
		// skip
		return;
	}
	uint64 elapsedPeriods = dif / vsyncPeriod;
	if (elapsedPeriods >= 10)
	{
		s_lastHostVsync = nowTimePoint;
	}
	else
		s_lastHostVsync += vsyncPeriod;

	LatteTiming_signalVsync();
}

// Iridia study: deliver the next vblank now (IRIDIA_VRR), see the comment at the top
static bool IridiaVrrEarlyVblank(uint64 currentTimer)
{
	const uint64 period = LatteTime_CalculateTimeBetweenVSync();
	if (currentTimer + period < LatteGPUState.timer_nextVSync)
		return false; // already one tick ahead
	const uint32 swaps = g_iridiaGuestSwaps.load(std::memory_order_acquire);
	if (swaps == s_vrrLastSwaps || (sint32)(g_iridiaHostPresents.load(std::memory_order_acquire) - swaps) < 0)
		return false; // no new frame since the last early vblank, or the GPU thread hasn't presented it yet
	const uint32 swapInterval = LatteGPUState.sharedArea ? (uint32)LatteGPUState.sharedArea->swapInterval : 1;
	const bool waiting = g_iridiaVsyncWaiters.load() > 0 || (g_iridiaFlipWaiters.load() > 0 && s_vsyncIntervalCounter + 1 >= swapInterval);
	if (!waiting)
		return false;
	if (!LatteGPUState.gx2InitCalled)
		return false;
	if (s_vrrMinGap && currentTimer - s_vrrLastRelease < s_vrrMinGap)
		return false;
	s_vrrLastSwaps = swaps;
	s_vrrLastRelease = currentTimer;
	g_iridiaVrr[0]++;
	g_iridiaVrr[1] += (uint32)((LatteGPUState.timer_nextVSync - currentTimer) * 1000000ull / HighResolutionTimer::getFrequency());
	LatteTiming_signalVsync();
	if (s_vrrMode == 1)
		LatteGPUState.timer_nextVSync += period;
	else
		LatteGPUState.timer_nextVSync = currentTimer + period;
	return true;
}

// Iridia study: when the GPU thread should next look at the vblank timer (a held-back tick may be due before the
// next regular one)
uint64 LatteTiming_NextEventTick(uint64 now)
{
	if (s_lockHoldUntil)
		return s_lockHoldUntil;
	uint64 t = LatteGPUState.timer_nextVSync;
	if (s_vrrMode && s_vrrMinGap && (g_iridiaVsyncWaiters.load() > 0 || g_iridiaFlipWaiters.load() > 0))
	{
		const uint64 due = s_vrrLastRelease + s_vrrMinGap; // an early vblank may become allowed then
		if (due > now && due < t)
			t = due;
	}
	return t;
}

// handle timed vsync event
void LatteTiming_HandleTimedVsync()
{
	// simulate VSync
	uint64 currentTimer = HighResolutionTimer::now().getTick();
	if (s_vrrMode && currentTimer < LatteGPUState.timer_nextVSync && !LatteTiming_IsUsingHostDrivenVSync() && IridiaVrrEarlyVblank(currentTimer))
		return;
	if( currentTimer >= LatteGPUState.timer_nextVSync )
	{
		if(!LatteTiming_IsUsingHostDrivenVSync())
		{
			{
				// Iridia study: how late this vblank fires (it is only checked when the GPU thread polls)
				const uint32 lateUs = (uint32)((currentTimer - LatteGPUState.timer_nextVSync) * 1000000ull / HighResolutionTimer::getFrequency());
				g_iridiaPace[8] += lateUs;
				uint32 prev = g_iridiaPace[9].load();
				while (lateUs > prev && !g_iridiaPace[9].compare_exchange_weak(prev, lateUs)) {}
			}
			const bool releases = g_iridiaVsyncWaiters.load() > 0 || g_iridiaFlipWaiters.load() > 0;
			if (s_fpsLock && releases && currentTimer - s_vrrLastRelease < s_vrrMinGap &&
				currentTimer - LatteGPUState.timer_nextVSync < LatteTime_CalculateTimeBetweenVSync())
			{
				// Iridia study (IRIDIA_FPS_LOCK): hold this tick back until the frame is due (at most one tick)
				s_lockHoldUntil = s_vrrLastRelease + s_vrrMinGap;
				return;
			}
			s_lockHoldUntil = 0;
			if (s_vrrMode && releases)
				s_vrrLastRelease = currentTimer;
			LatteTiming_signalVsync();
		}
		// even if vsync is delegated to the host device, we still use this virtual vsync timer to check finished states
		LatteQuery_UpdateFinishedQueries();
		LatteTextureReadback_UpdateFinishedTransfers(false);
		// update vsync timer
		uint64 vsyncTime = LatteTime_CalculateTimeBetweenVSync();
		uint64 missedVsyncCount = (currentTimer - LatteGPUState.timer_nextVSync) / vsyncTime;
		if (missedVsyncCount >= 2)
		{
			LatteGPUState.timer_nextVSync += vsyncTime*(missedVsyncCount+1ULL);
		}
		else	
			LatteGPUState.timer_nextVSync += vsyncTime;
	}
}