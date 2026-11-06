// Iridia Wii U app: once every 2 s, an IRIDIA_DIAG line on stderr explaining where the time goes on the phone:
// CPU use of every busy thread (by name), GPU busy time, which host CPUs each emulated core's time slices started
// on (fast vs efficiency cores), thermal state, Low Power Mode and battery (level, charging). Read with the console
// attached.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <atomic>
#include <mach/mach.h>
#include <pthread.h>
#include <sys/sysctl.h>
#include <thread>
#include <chrono>
#include <map>
#include <string>
#include "Cafe/HW/Latte/Core/IridiaPerf.h"

static void diagLoop()
{
	int perf0 = 0, perf1 = 0;
	size_t len = sizeof(int);
	sysctlbyname("hw.perflevel0.logicalcpu", &perf0, &len, nullptr, 0);
	len = sizeof(int);
	sysctlbyname("hw.perflevel1.logicalcpu", &perf1, &len, nullptr, 0);
	fprintf(stderr, "IRIDIA_DIAG cpus: %d fast (perflevel0), %d efficiency (perflevel1)\n", perf0, perf1);

	std::map<uint64_t, uint64_t> lastCpuUs; // thread id -> user+system time
	uint64_t lastGpuNs = 0;
	uint32_t lastHist[3][16] = {};
	uint64_t lastWait[8] = {};
	auto last = std::chrono::steady_clock::now();
	while (true)
	{
		std::this_thread::sleep_for(std::chrono::seconds(2));
		const auto now = std::chrono::steady_clock::now();
		const double wallUs = (double)std::chrono::duration_cast<std::chrono::microseconds>(now - last).count();
		last = now;
		std::string line = "IRIDIA_DIAG";

		// threads using at least 5% of a core
		thread_act_array_t threads;
		mach_msg_type_number_t n = 0;
		if (task_threads(mach_task_self(), &threads, &n) == KERN_SUCCESS)
		{
			std::map<uint64_t, uint64_t> cur;
			for (mach_msg_type_number_t i = 0; i < n; i++)
			{
				thread_basic_info_data_t bi;
				mach_msg_type_number_t cnt = THREAD_BASIC_INFO_COUNT;
				thread_identifier_info_data_t ii;
				mach_msg_type_number_t icnt = THREAD_IDENTIFIER_INFO_COUNT;
				if (thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&bi, &cnt) == KERN_SUCCESS &&
					thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &icnt) == KERN_SUCCESS)
				{
					const uint64_t us = (uint64_t)bi.user_time.seconds * 1000000 + bi.user_time.microseconds +
						(uint64_t)bi.system_time.seconds * 1000000 + bi.system_time.microseconds;
					cur[ii.thread_id] = us;
					auto it = lastCpuUs.find(ii.thread_id);
					const double pct = it != lastCpuUs.end() ? 100.0 * (double)(us - it->second) / wallUs : 0.0;
					if (pct >= 5.0)
					{
						char name[64] = {};
						if (pthread_t pt = pthread_from_mach_thread_np(threads[i]))
							pthread_getname_np(pt, name, sizeof(name));
						char buf[96];
						snprintf(buf, sizeof(buf), " %s=%.0f%%", name[0] ? name : "?", pct);
						line += buf;
					}
				}
				mach_port_deallocate(mach_task_self(), threads[i]);
			}
			vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof(thread_act_t));
			lastCpuUs.swap(cur);
		}

		// GPU busy (finished Metal command buffers)
		const uint64_t gpuNs = g_iridiaGpuBusyNs.load(std::memory_order_relaxed);
		char buf[160];
		snprintf(buf, sizeof(buf), " | gpu=%.0f%%", 100.0 * (double)(gpuNs - lastGpuNs) / (wallUs * 1000.0));
		line += buf;
		lastGpuNs = gpuNs;

		// GPU thread waits, ms per second: idle (no commands), wait-mem, sync, drawable, flush-wait, readback, query
		line += " | latte";
		const char* waitNames[] = {"idle", "wrm", "sync", "drw", "flw", "rb", "oq", "x"};
		for (int k = 0; k < 7; k++)
		{
			const uint64_t v = g_iridiaLatteWaitUs[k].load(std::memory_order_relaxed);
			snprintf(buf, sizeof(buf), " %s=%.0f", waitNames[k], (double)(v - lastWait[k]) / wallUs * 1000.0);
			line += buf;
			lastWait[k] = v;
		}

		// host CPU of each emulated core's time slices: cpu:count
		for (int c = 0; c < 3; c++)
		{
			snprintf(buf, sizeof(buf), " | core%d", c);
			line += buf;
			for (int k = 0; k < 16; k++)
			{
				const uint32_t v = g_iridiaCpuHist[c][k].load(std::memory_order_relaxed);
				if (v != lastHist[c][k])
				{
					snprintf(buf, sizeof(buf), " %d:%u", k, v - lastHist[c][k]);
					line += buf;
					lastHist[c][k] = v;
				}
			}
		}

		// audio gaps: output callbacks with too little sound queued, of all callbacks
		{
			extern std::atomic<uint32_t> g_iridiaAudioUnderruns, g_iridiaAudioCallbacks;
			static uint32_t lastU = 0, lastC = 0;
			const uint32_t u = g_iridiaAudioUnderruns.load(), c = g_iridiaAudioCallbacks.load();
			snprintf(buf, sizeof(buf), " | audio gaps=%u/%u", u - lastU, c - lastC);
			line += buf;
			lastU = u; lastC = c;
		}
		NSProcessInfo* pi = [NSProcessInfo processInfo];
		const char* thermal[] = {"nominal", "fair", "serious", "critical"};
		const long ts = (long)pi.thermalState;
		snprintf(buf, sizeof(buf), " | thermal=%s lowpower=%d", ts >= 0 && ts < 4 ? thermal[ts] : "?", pi.lowPowerModeEnabled ? 1 : 0);
		line += buf;
		// battery: UIDevice is read on the main thread; this line shows the value from the previous 2 s tick
		static std::atomic<int> s_battPct{-1}, s_battState{0};
		dispatch_async(dispatch_get_main_queue(), ^{
			UIDevice* d = [UIDevice currentDevice];
			d.batteryMonitoringEnabled = YES;
			s_battPct = d.batteryLevel < 0 ? -1 : (int)lroundf(d.batteryLevel * 100.0f);
			s_battState = (int)d.batteryState;
		});
		const char* bstate[] = {"unknown", "unplugged", "charging", "full"};
		const int bs = s_battState.load();
		snprintf(buf, sizeof(buf), " battery=%d%% %s", s_battPct.load(), bs >= 0 && bs < 4 ? bstate[bs] : "?");
		line += buf;
		fprintf(stderr, "%s\n", line.c_str());
	}
}

void IridiaStartDiag()
{
	static bool started = false;
	if (started)
		return;
	started = true;
	std::thread([] {
		pthread_setname_np("IridiaDiag");
		diagLoop();
	}).detach();
}
