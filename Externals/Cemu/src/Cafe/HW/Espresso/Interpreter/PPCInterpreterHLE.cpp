#include "Cafe/HW/Latte/Core/IridiaPerf.h"
#include "../PPCState.h"
#include "PPCInterpreterInternal.h"
#include "PPCInterpreterHelper.h"
#include "Cafe/HW/Espresso/IridiaCounters.h"

static bool s_hleTrace() { static const bool v = getenv("IRIDIA_HLETRACE") != nullptr; return v; } // read on first use: the app sets study switches after load
static void HLETrace_dump(const char* why);

std::unordered_set<std::string> s_unsupportedHLECalls;

void PPCInterpreter_handleUnsupportedHLECall(PPCInterpreter_t* hCPU)
{
	const char* libFuncName = (char*)memory_getPointerFromVirtualOffset(hCPU->instructionPointer + 8);
	std::string tempString = fmt::format("Unsupported lib call: {}", libFuncName);
	if (s_unsupportedHLECalls.find(tempString) == s_unsupportedHLECalls.end())
	{
		cemuLog_log(LogType::UnsupportedAPI, "{}", tempString);
		if (s_hleTrace() && strstr(libFuncName, "SYSLaunchMenu"))
			HLETrace_dump(libFuncName);
		s_unsupportedHLECalls.emplace(tempString);
	}
	hCPU->gpr[3] = 0;
	PPCInterpreter_nextInstruction(hCPU);
}

static constexpr size_t HLE_TABLE_CAPACITY = 0x4000;
HLECALL s_ppcHleTable[HLE_TABLE_CAPACITY]{};
// Iridia study: optional trace of OS calls (IRIDIA_HLETRACE=1), dumped when the game asks for the system menu
std::string s_ppcHleNames[HLE_TABLE_CAPACITY];
static constexpr size_t HLE_TRACE_LEN = 4000;
static struct { uint32 idx; uint32 lr; uint32 r3; uint32 core; } s_hleTraceBuf[HLE_TRACE_LEN];
static size_t s_hleTracePos = 0;
static std::mutex s_hleTraceMutex;
static void HLETrace_dump(const char* why)
{
	std::unique_lock _l(s_hleTraceMutex);
	fprintf(stderr, "IRIDIA_HLETRACE dump (%s), last %zu calls:\n", why, std::min(s_hleTracePos, HLE_TRACE_LEN));
	size_t start = s_hleTracePos > HLE_TRACE_LEN ? s_hleTracePos - HLE_TRACE_LEN : 0;
	for (size_t i = start; i < s_hleTracePos; i++)
	{
		auto& e = s_hleTraceBuf[i % HLE_TRACE_LEN];
		fprintf(stderr, "IRIDIA_HLE c%u %s lr=%08x r3=%08x\n", e.core, s_ppcHleNames[e.idx].c_str(), e.lr, e.r3);
	}
}
sint32 s_ppcHleTableWriteIndex = 0;
std::mutex s_ppcHleTableMutex;

#ifdef IRIDIA_COUNTERS
// Iridia study counters: OS calls per function and emulated core; time reads also per call site (LR)
static std::atomic<uint64> s_hleCnt[3][HLE_TABLE_CAPACITY];
static std::mutex s_hleCntSiteMutex;
static std::unordered_map<uint64, uint64> s_hleCntSites; // (function index << 32 | LR) -> calls
static void IridiaCountHLE(PPCInterpreter_t* hCPU, uint32 idx)
{
	if (!g_iridiaCntOn.load(std::memory_order_relaxed))
		return;
	const uint32 core = std::min<uint32>(PPCInterpreter_getCoreIndex(hCPU), 2);
	s_hleCnt[core][idx].fetch_add(1, std::memory_order_relaxed);
	static std::atomic<uint8> s_isTime[HLE_TABLE_CAPACITY]; // 0 unknown, 1 no, 2 yes
	uint8 k = s_isTime[idx].load(std::memory_order_relaxed);
	if (k == 0)
	{
		const std::string& n = s_ppcHleNames[idx];
		k = (n.find("Time") != std::string::npos || n.find("Tick") != std::string::npos) ? 2 : 1;
		s_isTime[idx].store(k, std::memory_order_relaxed);
	}
	if (k == 2)
	{
		std::unique_lock _l(s_hleCntSiteMutex);
		s_hleCntSites[((uint64)idx << 32) | hCPU->spr.LR]++;
	}
}

// One file: "S seconds", "C name total core0 core1 core2" for the counters, "X core kind result count" for block
// exits, "H name core0 core1 core2" for OS calls, "T name lr calls" for time-read call sites.
void IridiaCounters_dump(const char* path, double seconds)
{
	FILE* f = fopen(path, "w");
	if (!f) return;
	fprintf(f, "S %.3f\n", seconds);
	static const char* names[CNT_COUNT] = { "thread_switch", "dcflush_notify", "dcflush_pages", "dcrange_lines", "memcpy_bytes",
		"gx2_multi_calls", "gx2_multi_words", "gx2_word_calls", "gx2_array_calls", "gx2_array_words", "loop_probes", "loop_cache_miss", "loop_builds",
		"timer_contended", "dcq_contended", "mftb", "thread_load" };
	for (uint32 i = 0; i < CNT_COUNT; i++)
		fprintf(f, "C %s %llu\n", names[i], (unsigned long long)g_iridiaCnt[i].load());
	fprintf(f, "C timer_reads %llu %llu %llu %llu %llu\n", (unsigned long long)(g_iridiaCntTimer[0] + g_iridiaCntTimer[1] + g_iridiaCntTimer[2] + g_iridiaCntTimer[3]),
		(unsigned long long)g_iridiaCntTimer[0].load(), (unsigned long long)g_iridiaCntTimer[1].load(), (unsigned long long)g_iridiaCntTimer[2].load(), (unsigned long long)g_iridiaCntTimer[3].load());
	for (uint32 c = 0; c < 3; c++)
		for (uint32 k = 0; k < CNT_EXIT_KINDS; k++)
			for (uint32 r = 0; r < CNT_EXIT_RESULTS; r++)
				fprintf(f, "X %u %u %u %llu\n", c, k, r, (unsigned long long)g_iridiaCntExit[c][k][r]);
	for (sint32 i = 0; i < s_ppcHleTableWriteIndex; i++)
	{
		const uint64 a = s_hleCnt[0][i].load(), b = s_hleCnt[1][i].load(), c = s_hleCnt[2][i].load();
		if (a | b | c)
			fprintf(f, "H %s %llu %llu %llu\n", s_ppcHleNames[i].c_str(), (unsigned long long)a, (unsigned long long)b, (unsigned long long)c);
	}
	{
		std::unique_lock _l(s_hleCntSiteMutex);
		for (auto& [key, n] : s_hleCntSites)
			fprintf(f, "T %s %08x %llu\n", s_ppcHleNames[key >> 32].c_str(), (uint32)key, (unsigned long long)n);
	}
	fclose(f);
	fprintf(stderr, "IRIDIA_COUNTERS written to %s\n", path);
}
#endif

HLEIDX PPCInterpreter_registerHLECall(HLECALL hleCall, std::string hleName)
{
	std::unique_lock _l(s_ppcHleTableMutex);
	if (s_ppcHleTableWriteIndex >= HLE_TABLE_CAPACITY)
	{
		cemuLog_log(LogType::Force, "HLE table is full");
		cemu_assert(false);
	}
	for (sint32 i = 0; i < s_ppcHleTableWriteIndex; i++)
	{
		if (s_ppcHleTable[i] == hleCall)
		{
			return i;
		}
	}
	cemu_assert(s_ppcHleTableWriteIndex < HLE_TABLE_CAPACITY);
	s_ppcHleTable[s_ppcHleTableWriteIndex] = hleCall;
	s_ppcHleNames[s_ppcHleTableWriteIndex] = hleName;
	HLEIDX funcIndex = s_ppcHleTableWriteIndex;
	s_ppcHleTableWriteIndex++;
	return funcIndex;
}

HLECALL PPCInterpreter_getHLECall(HLEIDX funcIndex)
{
	if (funcIndex < 0 || funcIndex >= HLE_TABLE_CAPACITY)
		return nullptr;
	return s_ppcHleTable[funcIndex];
}

std::mutex s_hleLogMutex;

#if defined(IRIDIA_HLE_TRIM_BUILD)
// MORNING11 item 3b: study switches folded into one byte, read on first use (the app sets them after load)
static sint8 s_hleStudyFlag = -1;
static bool s_hleStudy() { if (s_hleStudyFlag < 0) [[unlikely]] s_hleStudyFlag = (s_hleTrace() || getenv("IRIDIA_CODEDUMP")) ? 1 : 0; return s_hleStudyFlag != 0; }
#endif

void PPCInterpreter_virtualHLE(PPCInterpreter_t* hCPU, unsigned int opcode)
{
	uint32 hleFuncId = opcode & 0xFFFF;
	if (hleFuncId == 0xFFD0) [[unlikely]]
	{
#if defined(IRIDIA_HLE_TRIM_BUILD)
		// MORNING11 item 3b: a call site already handled (and logged once) on this host thread skips the string
		// formatting, the mutex and the set search; same result (r3 = 0, next instruction)
		static thread_local std::unordered_set<uint32> t_unsupportedSeen;
		if (t_unsupportedSeen.count(hCPU->instructionPointer))
		{
			hCPU->gpr[3] = 0;
			PPCInterpreter_nextInstruction(hCPU);
			return;
		}
		t_unsupportedSeen.insert(hCPU->instructionPointer);
#endif
		s_hleLogMutex.lock();
		PPCInterpreter_handleUnsupportedHLECall(hCPU);
		s_hleLogMutex.unlock();
	}
	else
	{
		// os lib function
		auto hleCall = PPCInterpreter_getHLECall(hleFuncId);
		cemu_assert(hleCall);
#ifdef IRIDIA_COUNTERS
		IridiaCountHLE(hCPU, hleFuncId);
#endif
#if defined(IRIDIA_HLE_TRIM_BUILD)
		if (s_hleStudy()) [[unlikely]]
#endif
		{
		if (s_hleTrace()) [[unlikely]]
		{
			std::unique_lock _l(s_hleTraceMutex);
			s_hleTraceBuf[s_hleTracePos % HLE_TRACE_LEN] = { (uint32)hleFuncId, hCPU->spr.LR, hCPU->gpr[3], (uint32)PPCInterpreter_getCoreIndex(hCPU) };
			s_hleTracePos++;
			static bool seen[HLE_TABLE_CAPACITY];
			if (!seen[hleFuncId])
			{
				seen[hleFuncId] = true;
				fprintf(stderr, "IRIDIA_HLEFIRST t=%u c%u %s lr=%08x r3=%08x r4=%08x\n", (unsigned)GetTickCount(), (uint32)PPCInterpreter_getCoreIndex(hCPU), s_ppcHleNames[hleFuncId].c_str(), hCPU->spr.LR, hCPU->gpr[3], hCPU->gpr[4]);
			}
		}
		// Iridia study: IRIDIA_CODEDUMP=<hex addr>,... prints the guest code words around each address once, in gameplay
		static const char* s_codeDump = getenv("IRIDIA_CODEDUMP");
		if (s_codeDump) [[unlikely]]
		{
			extern std::atomic<int> g_iridiaGameplaySeconds;
			static std::atomic<bool> s_done{false};
			if (g_iridiaGameplaySeconds.load() >= 20 && !s_done.exchange(true))
			{
				for (const char* p = s_codeDump; *p;)
				{
					char* e; const uint32 a = (uint32)strtoul(p, &e, 16) & ~3u;
					for (uint32 x = a - 0x300; x < a + 0x100; x += 4)
						fprintf(stderr, "IRIDIA_CODE %08x %08x\n", x, memory_readU32(x));
					p = *e ? e + 1 : e;
				}
			}
		}
		}
		if (g_iridiaTimelineOn.load(std::memory_order_relaxed)) [[unlikely]]
		{
			// Iridia study: remember which OS call this core is inside, for slice-end attribution in the timeline
			const uint32 core = PPCInterpreter_getCoreIndex(hCPU);
			IridiaTL(TL_HLE, (uint16)core, hleFuncId);
			{
				// time reads also get their call site (time-budgeted loops)
				static std::atomic<uint8> s_isTime[HLE_TABLE_CAPACITY]; // 0 unknown, 1 no, 2 yes
				uint8 k = s_isTime[hleFuncId].load(std::memory_order_relaxed);
				if (k == 0)
				{
					const std::string& n = s_ppcHleNames[hleFuncId];
					k = (n.find("Time") != std::string::npos || n.find("Tick") != std::string::npos) ? 2 : 1;
					s_isTime[hleFuncId].store(k, std::memory_order_relaxed);
				}
				if (k == 2)
					IridiaTL(TL_HLE_LR, (uint16)core, hCPU->spr.LR);
			}
			const IridiaHleCur prev = g_iridiaHleCur[core];
			g_iridiaHleCur[core] = { hleFuncId, hCPU->spr.LR, hCPU->gpr[3] };
			hleCall(hCPU);
			if (PPCInterpreter_t* cur = PPCInterpreter_getCurrentInstance())
				g_iridiaHleCur[PPCInterpreter_getCoreIndex(cur)] = prev;
			return;
		}
		hleCall(hCPU);
	}
}
IridiaHleCur g_iridiaHleCur[3];
const char* IridiaHleName(uint32_t id) { return id < HLE_TABLE_CAPACITY ? s_ppcHleNames[id].c_str() : ""; }