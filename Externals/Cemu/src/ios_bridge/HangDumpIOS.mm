// Iridia Wii U app: hang watchdog. If the game shows no frame within a while after launch, log every thread's
// call stack (frame-pointer walk) with image offsets, so a hang on the phone can be located with atos on the Mac.
// Raw addresses are collected while each thread is briefly suspended (no allocation then); names come after.
#include <mach/mach.h>
#include <pthread.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <thread>
#include <chrono>
#include <string>
#include "Cafe/HW/Latte/Core/IridiaPerf.h"
#include "Cemu/Logging/CemuLogging.h"

static void hangDumpThreads(const char* why)
{
	constexpr int kMaxThreads = 128, kMaxFrames = 48;
	static uint64_t frames[kMaxThreads][kMaxFrames];
	static int counts[kMaxThreads];
	static char names[kMaxThreads][64];
	thread_act_array_t threads;
	mach_msg_type_number_t n = 0;
	if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS)
		return;
	const thread_t self = mach_thread_self();
	int used = 0;
	for (mach_msg_type_number_t i = 0; i < n && used < kMaxThreads; i++)
	{
		if (threads[i] == self)
			continue;
		names[used][0] = 0;
		if (pthread_t pt = pthread_from_mach_thread_np(threads[i]))
			pthread_getname_np(pt, names[used], sizeof(names[used]));
		int c = 0;
		if (thread_suspend(threads[i]) == KERN_SUCCESS)
		{
			arm_thread_state64_t st;
			mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
			if (thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) == KERN_SUCCESS)
			{
				frames[used][c++] = arm_thread_state64_get_pc(st);
				frames[used][c++] = arm_thread_state64_get_lr(st);
				uint64_t fp = arm_thread_state64_get_fp(st);
				while (fp && c < kMaxFrames)
				{
					uint64_t pair[2];
					vm_size_t got = 0;
					if (vm_read_overwrite(mach_task_self(), fp, sizeof(pair), (vm_address_t)pair, &got) != KERN_SUCCESS || got != sizeof(pair))
						break;
					if (!pair[1])
						break;
					frames[used][c++] = pair[1] & 0x0000000FFFFFFFFFull; // strip pointer auth bits
					if (pair[0] <= fp)
						break;
					fp = pair[0];
				}
			}
			thread_resume(threads[i]);
		}
		counts[used++] = c;
	}
	for (mach_msg_type_number_t i = 0; i < n; i++)
		mach_port_deallocate(mach_task_self(), threads[i]);
	vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof(thread_t));
	mach_port_deallocate(mach_task_self(), self);

	const uint64_t slide = (uint64_t)_dyld_get_image_vmaddr_slide(0);
	cemuLog_log(LogType::Force, "IRIDIA_HANG {}: {} threads, main image slide 0x{:x}", why, used, slide);
	fprintf(stderr, "IRIDIA_HANG %s: %d threads, main image slide 0x%llx\n", why, used, slide);
	for (int t = 0; t < used; t++)
	{
		std::string line = std::string("IRIDIA_HANG thread '") + names[t] + "':";
		for (int f = 0; f < counts[t]; f++)
		{
			Dl_info info{};
			char buf[256];
			if (dladdr((void*)frames[t][f], &info) && info.dli_fname)
			{
				const char* img = strrchr(info.dli_fname, '/');
				snprintf(buf, sizeof(buf), " %s+0x%llx(%s)", img ? img + 1 : info.dli_fname,
						 (unsigned long long)(frames[t][f] - (uint64_t)info.dli_fbase), info.dli_sname ? info.dli_sname : "?");
			}
			else
				snprintf(buf, sizeof(buf), " 0x%llx", (unsigned long long)frames[t][f]);
			line += buf;
		}
		cemuLog_log(LogType::Force, "{}", line);
		fprintf(stderr, "%s\n", line.c_str());
	}
}

void IridiaStartHangWatchdog()
{
	std::thread([] {
		auto start = std::chrono::steady_clock::now();
		for (int s : {25, 60, 120})
		{
			std::this_thread::sleep_until(start + std::chrono::seconds(s));
			if (g_iridiaPerf.flips.load() != 0)
				return;
			char why[48];
			snprintf(why, sizeof(why), "no frame after %d s", s);
			hangDumpThreads(why);
		}
	}).detach();
}
