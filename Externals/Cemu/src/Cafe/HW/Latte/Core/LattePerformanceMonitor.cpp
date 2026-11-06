#if defined(__APPLE__)
#include <sys/resource.h>
#include <unistd.h>
extern "C" int proc_pid_rusage(int pid, int flavor, rusage_info_t* buffer);
#endif
#include <mach/mach_time.h>
#include <pthread.h>
#include <thread>
#include <string>
#include <map>
#include <mutex>
#include "Cafe/HW/Latte/Core/IridiaPerf.h"
IridiaPerfSnapshot g_iridiaPerf;
std::atomic<uint64_t> g_iridiaGpuBusyNs{0};
std::atomic<uint64_t> g_iridiaGpuUnionNs{0};
std::atomic<bool> g_iridiaTimelineOn{false};
namespace
{
	struct IridiaTLRec { uint64_t ns; uint16_t ev; uint16_t core; uint32_t arg; };
	constexpr size_t kTLCap = 1 << 21;
	IridiaTLRec* s_tl = nullptr;
	std::atomic<size_t> s_tlCount{0};
	std::mutex s_tlNameMutex;
	std::map<uint32_t, std::string> s_tlNames;
}
void IridiaTimelineRecordAt(uint64_t ns, uint16_t ev, uint16_t core, uint32_t arg)
{
	const size_t i = s_tlCount.fetch_add(1, std::memory_order_relaxed);
	if (s_tl && i < kTLCap)
		s_tl[i] = { ns, ev, core, arg };
}
void IridiaTimelineThreadName(uint32_t thread, const char* name)
{
	std::lock_guard<std::mutex> l(s_tlNameMutex);
	if (s_tlNames.find(thread) == s_tlNames.end())
		s_tlNames[thread] = name ? name : "";
}
void IridiaTLHostCpu(uint16_t core)
{
	if (!g_iridiaTimelineOn.load(std::memory_order_relaxed))
		return;
	size_t cpu = 0xffff;
	pthread_cpu_number_np(&cpu); // reads the CPU number register, no system call
	IridiaTL(TL_HOSTCPU, core, (uint32_t)cpu);
}
void IridiaWaitTimerBegin(int k) { IridiaTLHostCpu(7); IridiaTL(TL_LWAIT_B, 0, (uint32_t)k); }
void IridiaWaitTimerEnd(int k) { IridiaTL(TL_LWAIT_E, 0, (uint32_t)k); IridiaTLHostCpu(7); }
void IridiaTimelineTick(int gameplaySecond)
{
	static const int start = iridia_getenv("IRIDIA_TIMELINE") ? atoi(iridia_getenv("IRIDIA_TIMELINE")) : -1;
	// IRIDIA_TIMELINE_EVERY=<s> (> 2): a 2 s window again every <s> seconds; window n > 0 goes to <file>.<n>
	static const int every = iridia_getenv("IRIDIA_TIMELINE_EVERY") ? atoi(iridia_getenv("IRIDIA_TIMELINE_EVERY")) : 0;
	static int window = 0, windowStart = -1;
	if (start < 0)
		return;
	const bool atStart = every > 2 ? (gameplaySecond >= start && (gameplaySecond - start) % every == 0 && gameplaySecond != windowStart)
	                               : (gameplaySecond == start && !s_tl);
	if (atStart && !g_iridiaTimelineOn)
	{
		if (!s_tl)
			s_tl = new IridiaTLRec[kTLCap];
		s_tlCount = 0;
		windowStart = gameplaySecond;
		// clock calibration: Metal GPU times are in host time (mach_absolute_time), events in steady_clock
		mach_timebase_info_data_t tb; mach_timebase_info(&tb);
		IridiaTimelineRecordAt(IridiaTimelineNow(), TL_CAL_STEADY, 0, 0);
		IridiaTimelineRecordAt(mach_absolute_time() * tb.numer / tb.denom, TL_CAL_HOST, 0, 0);
		g_iridiaTimelineOn = true;
	}
	else if (gameplaySecond == windowStart + 2 && g_iridiaTimelineOn)
	{
		g_iridiaTimelineOn = false;
		std::this_thread::sleep_for(std::chrono::milliseconds(50));
		const size_t n = std::min(s_tlCount.load(), kTLCap);
		const char* basePath = iridia_getenv("IRIDIA_TIMELINE_FILE");
		const std::string windowPath = basePath ? (window == 0 ? std::string(basePath) : std::string(basePath) + "." + std::to_string(window)) : std::string();
		const char* path = basePath ? windowPath.c_str() : nullptr;
		window++;
		if (FILE* f = path ? fopen(path, "wb") : nullptr)
		{
			fwrite(s_tl, sizeof(IridiaTLRec), n, f);
			fclose(f);
		}
		std::string names = path ? std::string(path) + ".names" : std::string();
		if (FILE* f = path ? fopen(names.c_str(), "w") : nullptr)
		{
			std::lock_guard<std::mutex> l(s_tlNameMutex);
			for (auto& it : s_tlNames)
				fprintf(f, "%08x %s\n", it.first, it.second.c_str());
			fclose(f);
		}
		std::string hle = path ? std::string(path) + ".hle" : std::string();
		if (FILE* f = path ? fopen(hle.c_str(), "w") : nullptr)
		{
			for (uint32_t id = 0; id < 0x4000; id++)
				if (const char* nm = IridiaHleName(id); nm && nm[0])
					fprintf(f, "%u %s\n", id, nm);
			fclose(f);
		}
		fprintf(stderr, "IRIDIA_TIMELINE wrote %zu events (window %d at gameplay second %d)\n", n, window - 1, windowStart);
	}
}
std::atomic<uint32_t> g_iridiaGpuCmdBufs{0};
std::atomic<uint32_t> g_iridiaCpuHist[3][16];
std::atomic<uint64_t> g_iridiaLatteWaitUs[8];
std::atomic<uint32_t> g_iridiaPasses[4];
#include "Cafe/HW/Latte/Core/LattePerformanceMonitor.h"
#include "Cafe/HW/Latte/Core/LatteOverlay.h"
#include "Cafe/HW/Latte/Core/Latte.h"
#include "WindowSystem.h"
#include "Cafe/HW/MMU/MMU.h"
#include <cmath>
#include <vector>

std::atomic<int> g_iridiaGameplaySeconds{0}; // Iridia study
namespace snd_core { uint32 getNumProcessedFrames(); } // ax_out.cpp: audio frames made (333/s = real time)
std::atomic<uint32> g_iridiaPresentHist[9]; // Iridia study: present-to-present times (LatteRenderTarget.cpp)
std::atomic<uint64> g_iridiaPresentSumUs{0}, g_iridiaPresentSqUs{0};

// Iridia study (game speed): IRIDIA_RAMDUMP=<s,s,...> writes guest MEM2 to IRIDIA_RAMDUMP_DIR/mem2-<s>.bin at those
// gameplay seconds (to find a game's clock offline), IRIDIA_WATCH=<hex addr>[,...] prints those big-endian words
// (as u32 and float) every second with the host time, IRIDIA_GAMECLOCK line. Measurement only.
static void IridiaGameSpeedProbe(int gameplaySecond)
{
	static std::vector<int> s_dumpAt;
	static std::vector<uint32> s_watch;
	static bool s_init = false;
	if (!s_init)
	{
		s_init = true;
		if (const char* v = iridia_getenv("IRIDIA_RAMDUMP"))
			for (const char* q = v; *q; ) { s_dumpAt.push_back(atoi(q)); while (*q && *q != ',') q++; if (*q) q++; }
		if (const char* v = iridia_getenv("IRIDIA_WATCH"))
			for (const char* q = v; *q; ) { s_watch.push_back((uint32)strtoul(q, nullptr, 16)); while (*q && *q != ',') q++; if (*q) q++; }
	}
	for (int t : s_dumpAt)
	{
		if (t != gameplaySecond || !mmuRange_MEM2.isMapped())
			continue;
		const char* dir = iridia_getenv("IRIDIA_RAMDUMP_DIR") ? iridia_getenv("IRIDIA_RAMDUMP_DIR") : ".";
		char path[1024];
		snprintf(path, sizeof(path), "%s/mem2-%d.bin", dir, t);
		if (FILE* f = fopen(path, "wb"))
		{
			fwrite(memory_getPointerFromVirtualOffset(mmuRange_MEM2.getBase()), 1, mmuRange_MEM2.getSize(), f);
			fclose(f);
			fprintf(stderr, "IRIDIA_RAMDUMP second %d host_ms %llu -> %s\n", t, (unsigned long long)(IridiaTimelineNow() / 1000000), path);
		}
		// the game's code too (text area), for offline disassembly of what writes a found value
		snprintf(path, sizeof(path), "%s/text-%d.bin", dir, t);
		if (mmuRange_TEXT_AREA.isMapped())
			if (FILE* f = fopen(path, "wb"))
			{
				fwrite(memory_getPointerFromVirtualOffset(mmuRange_TEXT_AREA.getBase()), 1, mmuRange_TEXT_AREA.getSize(), f);
				fclose(f);
				fprintf(stderr, "IRIDIA_RAMDUMP text base %08x size %08x -> %s\n", mmuRange_TEXT_AREA.getBase(), mmuRange_TEXT_AREA.getSize(), path);
			}
	}
	if (!s_watch.empty())
	{
		std::string line = "IRIDIA_GAMECLOCK host_ms=" + std::to_string(IridiaTimelineNow() / 1000000) + " s=" + std::to_string(gameplaySecond);
		for (uint32 a : s_watch)
		{
			if (!memory_isAddressRangeAccessible(a, 4))
				continue;
			const uint32 u = memory_readU32(a);
			float f;
			memcpy(&f, &u, 4);
			char buf[96];
			snprintf(buf, sizeof(buf), " %08x=%u/%.5f", a, u, f);
			line += buf;
		}
		fprintf(stderr, "%s\n", line.c_str());
	}
}
std::atomic<uint64_t> g_iridiaFrameStartNs{0};
std::atomic<uint32_t> g_iridiaFrameHist[3];
std::atomic<uint64_t> g_iridiaFrameSumUs{0};

performanceMonitor_t performanceMonitor{};

void LattePerformanceMonitor_frameEnd()
{
	// per-frame stats
	performanceMonitor.gpuTime_shaderCreate.frameFinished();
	performanceMonitor.gpuTime_frameTime.frameFinished();
	performanceMonitor.gpuTime_idleTime.frameFinished();
	performanceMonitor.gpuTime_fenceTime.frameFinished();

	performanceMonitor.gpuTime_dcStageTextures.frameFinished();
	performanceMonitor.gpuTime_dcStageVertexMgr.frameFinished();
	performanceMonitor.gpuTime_dcStageShaderAndUniformMgr.frameFinished();
	performanceMonitor.gpuTime_dcStageIndexMgr.frameFinished();
	performanceMonitor.gpuTime_dcStageMRT.frameFinished();
	performanceMonitor.gpuTime_dcStageDrawcallAPI.frameFinished();
	performanceMonitor.gpuTime_waitForAsync.frameFinished();

	uint32 elapsedTime = GetTickCount() - performanceMonitor.cycle[performanceMonitor.cycleIndex].lastUpdate;
	if (elapsedTime >= 1000)
	{
		bool isFirstUpdate = performanceMonitor.cycle[performanceMonitor.cycleIndex].lastUpdate == 0;
		// sum up raw stats
		uint32 totalElapsedTime = GetTickCount() - performanceMonitor.cycle[(performanceMonitor.cycleIndex + 1) % PERFORMANCE_MONITOR_TRACK_CYCLES].lastUpdate;
		uint32 totalElapsedTimeFPS = GetTickCount() - performanceMonitor.cycle[(performanceMonitor.cycleIndex + PERFORMANCE_MONITOR_TRACK_CYCLES - 1) % PERFORMANCE_MONITOR_TRACK_CYCLES].lastUpdate;
		uint32 elapsedFrames = 0;
		uint32 elapsedFrames2S = 0; // elapsed frames for last two entries (seconds)
		uint64 skippedCycles = 0;
		uint64 vertexDataUploaded = 0;
		uint64 vertexDataCached = 0;
		uint64 uniformBankUploadedData = 0;
		uint64 uniformBankUploadedCount = 0;
		uint64 indexDataUploaded = 0;
		uint64 indexDataCached = 0;
		uint32 frameCounter = 0;
		uint32 drawCallCounter = 0;
		uint32 fastDrawCallCounter = 0;
		uint32 shaderBindCounter = 0;
		uint32 recompilerLeaveCount = 0;
		uint32 threadLeaveCount = 0;
		for (sint32 i = 0; i < PERFORMANCE_MONITOR_TRACK_CYCLES; i++)
		{
			elapsedFrames += performanceMonitor.cycle[i].frameCounter;
			skippedCycles += performanceMonitor.cycle[i].skippedCycles;
			vertexDataUploaded += performanceMonitor.cycle[i].vertexDataUploaded;
			vertexDataCached += performanceMonitor.cycle[i].vertexDataCached;
			uniformBankUploadedData += performanceMonitor.cycle[i].uniformBankUploadedData;
			uniformBankUploadedCount += performanceMonitor.cycle[i].uniformBankUploadedCount;
			indexDataUploaded += performanceMonitor.cycle[i].indexDataUploaded;
			indexDataCached += performanceMonitor.cycle[i].indexDataCached;
			frameCounter += performanceMonitor.cycle[i].frameCounter;
			drawCallCounter += performanceMonitor.cycle[i].drawCallCounter;
			fastDrawCallCounter += performanceMonitor.cycle[i].fastDrawCallCounter;
			shaderBindCounter += performanceMonitor.cycle[i].shaderBindCount;
			recompilerLeaveCount += performanceMonitor.cycle[i].recompilerLeaveCount;
			threadLeaveCount += performanceMonitor.cycle[i].threadLeaveCount;
		}
		elapsedFrames = std::max<uint32>(elapsedFrames, 1);
		elapsedFrames2S = performanceMonitor.cycle[(performanceMonitor.cycleIndex + PERFORMANCE_MONITOR_TRACK_CYCLES - 0) % PERFORMANCE_MONITOR_TRACK_CYCLES].frameCounter;
		elapsedFrames2S += performanceMonitor.cycle[(performanceMonitor.cycleIndex + PERFORMANCE_MONITOR_TRACK_CYCLES - 1) % PERFORMANCE_MONITOR_TRACK_CYCLES].frameCounter;
		elapsedFrames2S = std::max<uint32>(elapsedFrames2S, 1);
		// calculate stats
		uint64 passedCycles = PPCInterpreter_getMainCoreCycleCounter() - performanceMonitor.cycle[(performanceMonitor.cycleIndex + 1) % PERFORMANCE_MONITOR_TRACK_CYCLES].lastCycleCount;
		passedCycles -= skippedCycles;
		uint64 vertexDataUploadPerFrame = (vertexDataUploaded / (uint64)elapsedFrames);
		vertexDataUploadPerFrame /= 1024ULL;
		uint64 vertexDataCachedPerFrame = (vertexDataCached / (uint64)elapsedFrames);
		vertexDataCachedPerFrame /= 1024ULL;
		uint64 uniformBankDataUploadedPerFrame = (uniformBankUploadedData / (uint64)elapsedFrames);
		uniformBankDataUploadedPerFrame /= 1024ULL;
		uint32 uniformBankCountUploadedPerFrame = (uint32)(uniformBankUploadedCount / (uint64)elapsedFrames);
		uint64 indexDataUploadPerFrame = (indexDataUploaded / (uint64)elapsedFrames);

		double fps = (double)elapsedFrames2S * 1000.0 / (double)totalElapsedTimeFPS;
		uint32 shaderBindsPerFrame = shaderBindCounter / elapsedFrames;
		passedCycles = passedCycles * 1000ULL / totalElapsedTime;
		uint32 rlps = (uint32)((uint64)recompilerLeaveCount * 1000ULL / (uint64)totalElapsedTime);
		uint32 tlps = (uint32)((uint64)threadLeaveCount * 1000ULL / (uint64)totalElapsedTime);
		// set stats
		performanceMonitor.stats.indexDataUploadPerFrame = indexDataUploadPerFrame;
		// next counter cycle
		sint32 nextCycleIndex = (performanceMonitor.cycleIndex + 1) % PERFORMANCE_MONITOR_TRACK_CYCLES;
		performanceMonitor.cycle[nextCycleIndex].drawCallCounter = 0;
		performanceMonitor.cycle[nextCycleIndex].fastDrawCallCounter = 0;
		performanceMonitor.cycle[nextCycleIndex].frameCounter = 0;
		performanceMonitor.cycle[nextCycleIndex].shaderBindCount = 0;
		performanceMonitor.cycle[nextCycleIndex].lastCycleCount = PPCInterpreter_getMainCoreCycleCounter();
		performanceMonitor.cycle[nextCycleIndex].skippedCycles = 0;
		performanceMonitor.cycle[nextCycleIndex].vertexDataUploaded = 0;
		performanceMonitor.cycle[nextCycleIndex].vertexDataCached = 0;
		performanceMonitor.cycle[nextCycleIndex].uniformBankUploadedData = 0;
		performanceMonitor.cycle[nextCycleIndex].uniformBankUploadedCount = 0;
		performanceMonitor.cycle[nextCycleIndex].indexDataUploaded = 0;
		performanceMonitor.cycle[nextCycleIndex].indexDataCached = 0;
		performanceMonitor.cycle[nextCycleIndex].recompilerLeaveCount = 0;
		performanceMonitor.cycle[nextCycleIndex].threadLeaveCount = 0;
		performanceMonitor.cycleIndex = nextCycleIndex;

		// next update in 1 second
		performanceMonitor.cycle[performanceMonitor.cycleIndex].lastUpdate = GetTickCount();

		if (isFirstUpdate)
		{
			LatteOverlay_updateStats(0.0, 0, 0);
			WindowSystem::UpdateWindowTitles(false, false, 0.0);
		}
		else
		{
			LatteOverlay_updateStats(fps, drawCallCounter / elapsedFrames, fastDrawCallCounter / elapsedFrames);
			WindowSystem::UpdateWindowTitles(false, false, fps);
			// Iridia study: seconds of gameplay seen so far (a full scene: >1000 draws per frame), read by the autopilot.
			// IRIDIA_GAMEPLAY_DRAWS=<n> changes the threshold (test spots with smaller scenes)
			static const uint32 s_gameplayDraws = iridia_getenv("IRIDIA_GAMEPLAY_DRAWS") ? (uint32)atoi(iridia_getenv("IRIDIA_GAMEPLAY_DRAWS")) : 1000;
			if (drawCallCounter / elapsedFrames > s_gameplayDraws)
			{
				const int gs = g_iridiaGameplaySeconds.fetch_add(1) + 1;
				IridiaTimelineTick(gs);
				IridiaGameSpeedProbe(gs);
			}
			{
				// Iridia study: displayed frame times (present to present), early vblanks (IRIDIA_VRR), audio queue
				uint32 h[9]; uint32 n = 0;
				for (int k = 0; k < 9; k++) { h[k] = g_iridiaPresentHist[k].exchange(0); n += h[k]; }
				const uint64 sum = g_iridiaPresentSumUs.exchange(0), sq = g_iridiaPresentSqUs.exchange(0);
				const double mean = n ? sum / 1000.0 / n : 0.0;
				const double var = n ? (double)sq / n / 1000.0 - mean * mean : 0.0;
				fprintf(stderr, "IRIDIA_PRESENT n=%u mean=%.2f sd=%.2f ms <17.5:%u <25:%u <34.2:%u <41:%u <51:%u <60:%u <68:%u <100:%u more:%u\n",
					n, mean, var > 0 ? sqrt(var) : 0.0, h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]);
				extern std::atomic<uint32> g_iridiaVrr[2];
				const uint32 early = g_iridiaVrr[0].exchange(0), earlyUs = g_iridiaVrr[1].exchange(0);
				if (early)
					fprintf(stderr, "IRIDIA_VRR early vblanks=%u mean %.2f ms early\n", early, earlyUs / 1000.0 / early);
				extern std::atomic<uint32_t> g_iridiaAudioUnderruns, g_iridiaAudioCallbacks, g_iridiaAudioDropped, g_iridiaAudioStretched;
				static uint32 s_au = 0, s_ac = 0, s_ad = 0, s_as = 0;
				const uint32 as = g_iridiaAudioStretched.load();
				const uint32 au = g_iridiaAudioUnderruns.load(), ac = g_iridiaAudioCallbacks.load(), ad = g_iridiaAudioDropped.load();
				static uint32 s_axf = 0;
				const uint32 axf = snd_core::getNumProcessedFrames();
				fprintf(stderr, "IRIDIA_AUDIO gaps=%u callbacks=%u dropped=%u axframes=%u stretched=%u\n", au - s_au, ac - s_ac, ad - s_ad, axf - s_axf, as - s_as);
				s_axf = axf;
				s_as = as;
				s_au = au; s_ac = ac; s_ad = ad;
			}
			// Iridia study: one machine-readable line per second (fps, emulated main-core cycles/s, draws/frame)
			uint32 pace[12];
			for (int i = 0; i < 12; i++) pace[i] = g_iridiaPace[i].exchange(0);
			g_iridiaPerf.fps = (float)fps;
			g_iridiaPerf.drawsPerFrame = (uint32)(drawCallCounter / elapsedFrames);
			g_iridiaPerf.vsyncs = pace[0];
			g_iridiaPerf.flips = pace[1];
			g_iridiaPerf.vsyncWaitMs = pace[6] / 1000;
			g_iridiaPerf.gpuWaitMs = pace[11] / 1000;
			g_iridiaPerf.vblankLateMs = pace[0] ? (float)(pace[8] / 1000.0 / pace[0]) : 0.0f;
			g_iridiaPerf.gameplaySeconds = (uint32)g_iridiaGameplaySeconds.load();
			g_iridiaPerf.seq.fetch_add(1);
			// GPU busy ms since the last line (Metal command buffer GPU start-end times, Metal renderer only)
			static uint64 s_lastGpuNs = 0;
			const uint64 gpuNs = g_iridiaGpuBusyNs.load(std::memory_order_relaxed);
			const uint32 gpuMs = (uint32)((gpuNs - s_lastGpuNs) / 1000000);
			s_lastGpuNs = gpuNs;
			{
				// GPU thread waits, ms in the last second: no commands / wait-for-memory / readback+query sync / drawable
				static uint64 s_lastWait[8] = {};
				uint64 w[8];
				for (int k = 0; k < 8; k++) { const uint64 v = g_iridiaLatteWaitUs[k].load(std::memory_order_relaxed); w[k] = (v - s_lastWait[k]) / 1000; s_lastWait[k] = v; }
				static uint64 s_lastUnionNs = 0;
				const uint64 unionNs = g_iridiaGpuUnionNs.load(std::memory_order_relaxed);
				fprintf(stderr, "IRIDIA_GPU busy=%llu ms cmdbufs/frame=%.1f\n", (unsigned long long)((unionNs - s_lastUnionNs) / 1000000), (double)g_iridiaGpuCmdBufs.exchange(0) / elapsedFrames);
				s_lastUnionNs = unionNs;
				fprintf(stderr, "IRIDIA_LATTE idle=%llu wrm=%llu sync=%llu drw=%llu rb=%llu\n", (unsigned long long)w[0], (unsigned long long)w[1], (unsigned long long)w[2], (unsigned long long)w[3], (unsigned long long)w[5]);
				void IridiaPrintWrmStats();
				IridiaPrintWrmStats();
			}
			{
				const uint32 h0 = g_iridiaFrameHist[0].exchange(0), h1 = g_iridiaFrameHist[1].exchange(0), h2 = g_iridiaFrameHist[2].exchange(0);
				const uint64 sumUs = g_iridiaFrameSumUs.exchange(0);
				fprintf(stderr, "IRIDIA_FRAMES start->swap under16.7=%u under33.3=%u longer=%u mean=%.2f\n", h0, h1, h2, (h0 + h1 + h2) ? sumUs / 1000.0 / (h0 + h1 + h2) : 0.0);
			}
			{
				extern std::atomic<uint64> g_iridiaDrawNs[3]; // MetalRenderer.cpp (IRIDIA_DRAW_TIMES=1)
				const uint64 all = g_iridiaDrawNs[0].exchange(0), bind = g_iridiaDrawNs[1].exchange(0), n = g_iridiaDrawNs[2].exchange(0);
				if (n)
				{
					fprintf(stderr, "IRIDIA_DRAWTIME draws=%llu draw_execute=%.1f ms bind=%.1f ms (per second)\n", (unsigned long long)n, all / 1e6, bind / 1e6);
					extern std::atomic<uint64> g_iridiaIndexStats[3]; // LatteIndices.cpp
					const uint64 ih = g_iridiaIndexStats[0].exchange(0), id = g_iridiaIndexStats[1].exchange(0), in = g_iridiaIndexStats[2].exchange(0);
					fprintf(stderr, "IRIDIA_INDICES cache hits %llu, decoded + allocated %llu, no index buffer %llu (per second)\n", (unsigned long long)ih, (unsigned long long)id, (unsigned long long)in);
				}
				extern std::atomic<uint64> g_iridiaPso[4], g_iridiaLib[2]; // Metal: pipeline and library creation
				const uint64 ps = g_iridiaPso[0].exchange(0), psn = g_iridiaPso[1].exchange(0), pa = g_iridiaPso[2].exchange(0), pan = g_iridiaPso[3].exchange(0);
				const uint64 lb = g_iridiaLib[0].exchange(0), lbn = g_iridiaLib[1].exchange(0);
				if (ps + pa + lb)
					fprintf(stderr, "IRIDIA_PSO on GPU thread %llu (%.1f ms), on compile threads %llu (%.1f ms), shader libraries %llu (%.1f ms) (per second)\n",
						(unsigned long long)ps, psn / 1e6, (unsigned long long)pa, pan / 1e6, (unsigned long long)lb, lbn / 1e6);
				extern std::atomic<uint32> g_iridiaClears[3];
				const uint32 cc = g_iridiaClears[0].exchange(0), dc = g_iridiaClears[1].exchange(0), fc = g_iridiaClears[2].exchange(0);
				if (cc + dc + fc)
					fprintf(stderr, "IRIDIA_CLEARS color passes=%u depth=%u folded into the next pass=%u (per second)\n", cc, dc, fc);
			}
			{
				extern std::atomic<uint32> g_iridiaUniformReuse[2]; // MetalRenderer.cpp
				const uint32 reused = g_iridiaUniformReuse[0].exchange(0), uploaded = g_iridiaUniformReuse[1].exchange(0);
				if (reused + uploaded)
					fprintf(stderr, "IRIDIA_UNIFORMS reused=%u uploaded=%u\n", reused, uploaded);
			}
			extern std::atomic<uint32> g_iridiaRedirectStats[2]; // MetalRenderer.cpp: redirected uploads, flushes
			fprintf(stderr, "IRIDIA_PASSES per frame: %.0f, same attachments again after blit/compute %.0f, forced %.0f, other %.0f, redirected uploads %.1f, flushes %.1f\n",
				(double)g_iridiaPasses[0].exchange(0) / elapsedFrames, (double)g_iridiaPasses[1].exchange(0) / elapsedFrames,
				(double)g_iridiaPasses[2].exchange(0) / elapsedFrames, (double)g_iridiaPasses[3].exchange(0) / elapsedFrames,
				(double)g_iridiaRedirectStats[0].exchange(0) / elapsedFrames, (double)g_iridiaRedirectStats[1].exchange(0) / elapsedFrames);
#if defined(__APPLE__)
			{
				// process CPU counters, cumulative (per frame = difference over a window / frames): CPU time on all cores
				// and on P cores (rusage, mach time units), retired instructions and cycles (all, P cores); getrusage us
				// as a unit check
				struct rusage_info_v6 ri;
				struct rusage ru;
				if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t*)&ri) == 0 && getrusage(RUSAGE_SELF, &ru) == 0)
					fprintf(stderr, "IRIDIA_PCORE time=%llu ptime=%llu instr=%llu pinstr=%llu cyc=%llu pcyc=%llu ru_us=%llu\n",
						(unsigned long long)(ri.ri_user_time + ri.ri_system_time), (unsigned long long)(ri.ri_user_ptime + ri.ri_system_ptime),
						(unsigned long long)ri.ri_instructions, (unsigned long long)ri.ri_pinstructions, (unsigned long long)ri.ri_cycles, (unsigned long long)ri.ri_pcycles,
						(unsigned long long)(ru.ru_utime.tv_sec * 1000000ull + ru.ru_utime.tv_usec + ru.ru_stime.tv_sec * 1000000ull + ru.ru_stime.tv_usec));
			}
#endif
			fprintf(stderr, "IRIDIA_PERF t=%u fps=%.2f cyc=%llu draws=%u si=%u vs=%u fl=%u wv=%u wf=%u gs=%u sw=%u wvms=%u wfms=%u vlate=%.2f/%.2f wts=%u wtsms=%u gpums=%u\n", (unsigned)(GetTickCount() / 1000), fps, (unsigned long long)passedCycles, (unsigned)(drawCallCounter / elapsedFrames),
				LatteGPUState.sharedArea ? (unsigned)LatteGPUState.sharedArea->swapInterval : 0u, pace[0], pace[1], pace[2], pace[3], pace[4], pace[5], pace[6] / 1000, pace[7] / 1000, pace[0] ? pace[8] / 1000.0 / pace[0] : 0.0, pace[9] / 1000.0, pace[10], pace[11] / 1000, gpuMs);
			// draws per frame: all, and "continued" ones (not the first of a draw sequence, Vulkan's draw_execute_continued)
			fprintf(stderr, "IRIDIA_DRAWS total=%.1f continued=%.1f\n", (double)drawCallCounter / elapsedFrames, (double)fastDrawCallCounter / elapsedFrames);
#ifdef ENABLE_METAL
			{
				extern std::atomic<uint64> g_iridiaFastDrawStats[4]; // MetalRenderer.cpp (IRIDIA_FASTDRAW)
				const uint64 f0 = g_iridiaFastDrawStats[0].exchange(0), f1 = g_iridiaFastDrawStats[1].exchange(0), f2 = g_iridiaFastDrawStats[2].exchange(0), f3 = g_iridiaFastDrawStats[3].exchange(0);
				if (f0 + f3)
				{
					extern std::atomic<uint64> g_iridiaFastDrawMis[4];
					const uint64 m0 = g_iridiaFastDrawMis[0].exchange(0), m1 = g_iridiaFastDrawMis[1].exchange(0), m2 = g_iridiaFastDrawMis[2].exchange(0), m3 = g_iridiaFastDrawMis[3].exchange(0);
					fprintf(stderr, "IRIDIA_FASTDRAW fast=%llu full=%llu relookup=%llu mismatch=%llu pipe=%llu ds=%llu tex=%llu sup=%llu\n", (unsigned long long)f0, (unsigned long long)f3, (unsigned long long)f1, (unsigned long long)f2,
						(unsigned long long)m0, (unsigned long long)m1, (unsigned long long)m2, (unsigned long long)m3);
				}
			}
#endif
			extern std::atomic<uint64> g_iridiaAesBytes, g_iridiaAesNs; // aes128.cpp, cumulative
			fprintf(stderr, "IRIDIA_AESSTAT mb=%.1f ms=%.1f\n", g_iridiaAesBytes.load() / 1048576.0, g_iridiaAesNs.load() / 1e6);
		}
	}
}

void LattePerformanceMonitor_frameBegin()
{
	performanceMonitor.vk.numDrawBarriersPerFrame.reset();
	performanceMonitor.vk.numBeginRenderpassPerFrame.reset();
}
