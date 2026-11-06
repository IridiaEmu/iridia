#include <set>
#include <unordered_map>
#include <map>
#include <bit>
#include <chrono>
#include "PPCInterpreterInternal.h"
#include "Cafe/HW/Latte/Core/IridiaPerf.h"
#include "Cafe/HW/Latte/Core/IridiaSyncDiag.h"
#include "PPCInterpreterHelper.h"
#if defined(__aarch64__)
#include <arm_acle.h>
#endif
#if defined(__aarch64__)
#include <arm_neon.h>
#endif
#if defined(__aarch64__)
#define TB_PSQ_WIDE 1
#else
#define TB_PSQ_WIDE 0
#endif
#include "Cafe/HW/Espresso/Debugger/Debugger.h"
#include "Cafe/HW/Espresso/Debugger/GDBStub.h"
#include "Cafe/HW/Espresso/IridiaCounters.h"

// Iridia AOT verify builds (IRIDIA_AOT_VERIFY_BUILD): every guest store of the user-mode interpreter can be logged
// (address and the bytes it overwrote), so a block's stores can be undone and compared with another run.
#define IRIDIA_LOG_STORE(a, n)

// Iridia: guest loads and stores are volatile, so the compiler keeps their order (other cores see them in program
// order); the AOT local-state blocks would otherwise let it reorder them (XenonRecomp does the same).
class PPCItpCafeOSUsermode
{
public:
	static const bool allowSupervisorMode = false;
	static const bool allowDSI = false;

	inline static uint32 memory_readCodeU32(PPCInterpreter_t* hCPU, uint32 address)
	{
		return _swapEndianU32(*(volatile uint32*)(memory_base + address));
	}

	inline static void ppcMem_writeDataDouble(PPCInterpreter_t* hCPU, uint32 address, double vf)
	{
		IRIDIA_LOG_STORE(address, 8);
		uint64 v = *(uint64*)&vf;
		uint32 v1 = v & 0xFFFFFFFF;
		uint32 v2 = v >> 32;
		uint8* ptr = memory_getPointerFromVirtualOffset(address);
		*(volatile uint32*)(ptr + 4) = CPU_swapEndianU32(v1);
		*(volatile uint32*)(ptr + 0) = CPU_swapEndianU32(v2);
	}

	inline static void ppcMem_writeDataU64(PPCInterpreter_t* hCPU, uint32 address, uint64 v)
	{
		IRIDIA_LOG_STORE(address, 8);
		*(volatile uint64*)(memory_getPointerFromVirtualOffset(address)) = CPU_swapEndianU64(v);
	}

	inline static void ppcMem_writeDataU32(PPCInterpreter_t* hCPU, uint32 address, uint32 v)
	{
		IRIDIA_LOG_STORE(address, 4);
		*(volatile uint32*)(memory_getPointerFromVirtualOffset(address)) = CPU_swapEndianU32(v);
	}

	inline static void ppcMem_writeDataU16(PPCInterpreter_t* hCPU, uint32 address, uint16 v)
	{
		IRIDIA_LOG_STORE(address, 2);
		*(volatile uint16*)(memory_getPointerFromVirtualOffset(address)) = CPU_swapEndianU16(v);
	}

	inline static void ppcMem_writeDataU8(PPCInterpreter_t* hCPU, uint32 address, uint8 v)
	{
		IRIDIA_LOG_STORE(address, 1);
		*(volatile uint8*)(memory_getPointerFromVirtualOffset(address)) = v;
	}
	
	inline static double ppcMem_readDataDouble(PPCInterpreter_t* hCPU, uint32 address)
	{
		IRIDIA_WATCH_LOAD(address, 8, hCPU->instructionPointer);
		uint32 v[2];
		v[1] = *(volatile uint32*)(memory_getPointerFromVirtualOffset(address));
		v[0] = *(volatile uint32*)(memory_getPointerFromVirtualOffset(address) + 4);
		v[0] = CPU_swapEndianU32(v[0]);
		v[1] = CPU_swapEndianU32(v[1]);
		return *(double*)v;
	}

	inline static float ppcMem_readDataFloat(PPCInterpreter_t* hCPU, uint32 address)
	{
		IRIDIA_WATCH_LOAD(address, 4, hCPU->instructionPointer);
		uint32 v = *(volatile uint32*)(memory_getPointerFromVirtualOffset(address));
		v = CPU_swapEndianU32(v);
		return *(float*)&v;
	}

	inline static uint64 ppcMem_readDataU64(PPCInterpreter_t* hCPU, uint32 address)
	{
		IRIDIA_WATCH_LOAD(address, 8, hCPU->instructionPointer);
		uint64 v = *(volatile uint64*)(memory_getPointerFromVirtualOffset(address));
		return CPU_swapEndianU64(v);
	}

	inline static uint32 ppcMem_readDataU32(PPCInterpreter_t* hCPU, uint32 address)
	{
		IRIDIA_WATCH_LOAD(address, 4, hCPU->instructionPointer);
		uint32 v = *(volatile uint32*)(memory_getPointerFromVirtualOffset(address));
		return CPU_swapEndianU32(v);
	}

	inline static uint16 ppcMem_readDataU16(PPCInterpreter_t* hCPU, uint32 address)
	{
		IRIDIA_WATCH_LOAD(address, 2, hCPU->instructionPointer);
		uint16 v = *(volatile uint16*)(memory_getPointerFromVirtualOffset(address));
		return CPU_swapEndianU16(v);
	}

	inline static uint8 ppcMem_readDataU8(PPCInterpreter_t* hCPU, uint32 address)
	{
		IRIDIA_WATCH_LOAD(address, 1, hCPU->instructionPointer);
		return *(volatile uint8*)(memory_getPointerFromVirtualOffset(address));
	}

	inline static uint64 ppcMem_readDataFloatEx(PPCInterpreter_t* hCPU, uint32 addr)
	{
		IRIDIA_WATCH_LOAD(addr, 4, hCPU->instructionPointer);
		return ConvertToDoubleNoFTZ(_swapEndianU32(*(volatile uint32*)(memory_base + addr)));
	}

	inline static void ppcMem_writeDataFloatEx(PPCInterpreter_t* hCPU, uint32 addr, uint64 value)
	{
		IRIDIA_LOG_STORE(addr, 4);
		*(volatile uint32*)(memory_base + addr) = _swapEndianU32(ConvertToSingleNoFTZ(value));
	}

	inline static uint64 getTB(PPCInterpreter_t* hCPU)
	{
		return PPCInterpreter_getMainCoreCycleCounter();
	}
};

uint32 debug_lastTranslatedHit;

void generateDSIException(PPCInterpreter_t* hCPU, uint32 dataAddress)
{
	// todo - check if we are already inside an interrupt handler (in which case the DSI exception is queued and not executed immediately?)

	// set flag to cancel current instruction
	hCPU->memoryException = true;

	hCPU->sprExtended.srr0 = hCPU->instructionPointer;
	hCPU->sprExtended.srr1 = hCPU->sprExtended.msr & 0x87C0FFFF;

	hCPU->sprExtended.dar = dataAddress;

	hCPU->sprExtended.msr &= ~0x04EF36;

	hCPU->instructionPointer = 0xFFF00300;


	uint32 dsisr = 0;
	dsisr |= (1<<(31-1)); // set if no TLB/BAT match found

	hCPU->sprExtended.dsisr = dsisr;

}

class PPCItpSupervisorWithMMU
{
public:
	static const bool allowSupervisorMode = true;
	static const bool allowDSI = true;

	inline static uint32 ppcMem_translateVirtualDataToPhysicalAddr(PPCInterpreter_t* hCPU, uint32 vAddr)
	{
		// check if address translation is disabled for data accesses
		if (GET_MSR_BIT(MSR_DR) == 0)
		{
			return vAddr;
		}

#ifdef CEMU_DEBUG_ASSERT
		if (hCPU->memoryException)
			assert_dbg(); // should not be set anymore
#endif

		// how to determine if BAT is valid:
		// BAT_entry_valid = (Vs & ~MSR[PR]) | (Vp & MSR[PR]) (The entry has separate enable flags for usermode and supervisor mode)
		for (sint32 i = 0; i < 8; i++)
		{
			// upper
			uint32 batU = hCPU->sprExtended.dbatU[i];
			uint32 BEPI = ((batU >> 17) & 0x7FFF) << 17;
			uint32 Vp = (batU >> 0) & 1;
			uint32 Vs = (batU >> 1) & 1;
			uint32 BL = (((batU >> 2) & 0x7FF) ^ 0x7FF) << 17;
			BL |= 0xF0000000;
			if (Vs == 0)
				continue; // todo - check if in supervisor/usermode
			// lower
			uint32 batL = hCPU->sprExtended.dbatL[i];
			uint32 PP = (batL >> 0) & 3;
			uint32 WIMG = (batL >> 3) & 0xF;
			uint32 BRPN = ((batL >> 17) & 0x7FFF) << 17;

			// check for match
			if ((vAddr&BL) == BEPI)
			{
				// match
				vAddr = (vAddr&~BL) | (BRPN&BL);
				debug_lastTranslatedHit = vAddr;
				return vAddr;
			}
		}

		// no match
		debug_lastTranslatedHit = 0xFFFFFFFF;

		// find segment
		uint32 segmentIndex = (vAddr>>28);
		//uint32 pageIndex = (vAddr >> 12) & 0xFFFF; // for 4KB pages
		// uint32 byteOffset = vAddr & 0xFFF; // for 4KB pages
		uint32 pageIndex = (vAddr >> 17) & 0x7FF; // for 128KB pages 
		uint32 byteOffset = vAddr & 0x1FFFF;
		uint32 srValue = hCPU->sprExtended.sr[segmentIndex];
		
		uint8 sr_ks = (srValue >> 30) & 1; // supervisor
		uint8 sr_kp = (srValue >> 29) & 1; // user mode
		uint8 sr_n = (srValue >> 28) & 1; // no-execute
		uint32 sr_vsid = (srValue & 0xFFFFFF);
		//uint32 vpn = pageIndex | (sr_vsid << 16); // 40bit virtual page number


		// look up in page table
		//uint32 lookupHash = (sr_vsid ^ pageIndex) & 0x7FFFF; // not correct for 4KB pages? sr_vsid must be shifted?
		//uint32 lookupHash = (sr_vsid ^ pageIndex) & 0x7FFFF;
		//uint32 lookupHash = ((sr_vsid>>8) ^ pageIndex) & 0x7FFFF;
		uint32 lookupHash = ((sr_vsid >> 0) ^ pageIndex) & 0x7FFFF;

		//lookupHash ^= 0x7FFFF;

		uint32 pageTableAddr = hCPU->sprExtended.sdr1&0xFFFF0000;
		uint32 pageTableMask = hCPU->sprExtended.sdr1&0x1FF;

		for (uint32 ch = 0; ch < 2; ch++)
		{
			uint32 ptegSelectLow = (lookupHash & 0x3FF);
			uint32 maskOR = (lookupHash >> 10) & pageTableMask;

			uint32* pteg = (uint32*)(memory_base + (pageTableAddr | (maskOR << 16)) + ptegSelectLow * 64);
			for (sint32 t = 0; t < 8; t++)
			{
				uint32 w0 = _swapEndianU32(pteg[0]);
				uint32 w1 = _swapEndianU32(pteg[1]);
				pteg += 2;
				if ((w0 & 0x80000000) == 0)
					continue; // entry not valid

				uint32 abPageIndex = (w0 >> 0) & 0x3F;
				uint8 h = (w0 >> 6) & 1;
				uint32 ptegVSID = (w0 >> 7) & 0xFFFFFF;

				if (abPageIndex == (pageIndex >> 5) && ptegVSID == sr_vsid && h == ch)
				{
					if (ch == 1)
						assert_dbg();
					// match
					uint32 ptegPhysicalPage = (w1 >> 12) & 0xFFFFF;
					// replace page (128KB)
					vAddr = (vAddr & ~0xFFFE0000) | (ptegPhysicalPage << 12);
					return vAddr;

				}
			}
			// calculate hash 2
			lookupHash = ~lookupHash;
		}

		cemuLog_logDebug(LogType::Force, "DSI exception at 0x{:08x} DataAddress {:08x}", hCPU->instructionPointer, vAddr);

		generateDSIException(hCPU, vAddr);

		// todo: Check hash func 1
		// todo: Check protection bits
		// todo: Check supervisor/usermode bits


		// also use this function in all the mem stuff below

		// note: bat has higher priority than TLB

		// since iterating the bats and page table is too slow, we need to pre-process the data somehow.

		return vAddr;
	}

	inline static uint32 ppcMem_translateVirtualCodeToPhysicalAddr(PPCInterpreter_t* hCPU, uint32 vAddr)
	{
		// check if address translation is disabled for instruction accesses
		if (GET_MSR_BIT(MSR_IR) == 0)
		{
			return vAddr;
		}

		// how to determine if BAT is valid:
		// BAT_entry_valid = (Vs & ~MSR[PR]) | (Vp & MSR[PR]) (The entry has separate enable flags for usermode and supervisor mode)
		for (sint32 i = 0; i < 8; i++)
		{
			// upper
			uint32 batU = hCPU->sprExtended.ibatU[i];
			uint32 BEPI = ((batU >> 17) & 0x7FFF) << 17;
			uint32 Vp = (batU >> 0) & 1;
			uint32 Vs = (batU >> 1) & 1;
			uint32 BL = (((batU >> 2) & 0x7FF) ^ 0x7FF) << 17;
			BL |= 0xF0000000;
			if (Vs == 0)
				continue; // todo - check if in supervisor/usermode
			// lower
			uint32 batL = hCPU->sprExtended.ibatL[i];
			uint32 PP = (batL >> 0) & 3;
			uint32 WIMG = (batL >> 3) & 0xF;
			uint32 BRPN = ((batL >> 17) & 0x7FFF) << 17;

			// check for match
			if ((vAddr&BL) == BEPI)
			{
				// match
				vAddr = (vAddr&~BL) | (BRPN&BL);
				debug_lastTranslatedHit = vAddr;
				return vAddr;
			}
		}
		assert_dbg();

		// no match
		// todo - throw exception if translation is enabled?
		return vAddr;
	}

	static uint32 memory_readCodeU32(PPCInterpreter_t* hCPU, uint32 address)
	{
		return _swapEndianU32(*(uint32*)(memory_base + ppcMem_translateVirtualCodeToPhysicalAddr(hCPU, address)));
	}

	inline static uint8* ppcMem_getDataPtr(PPCInterpreter_t* hCPU, uint32 vAddr)
	{
		return memory_base + ppcMem_translateVirtualDataToPhysicalAddr(hCPU, vAddr);
	}

	inline static void ppcMem_writeDataDouble(PPCInterpreter_t* hCPU, uint32 address, double vf)
	{
		uint64 v = *(uint64*)&vf;
		uint32 v1 = v & 0xFFFFFFFF;
		uint32 v2 = v >> 32;
		uint8* ptr = ppcMem_getDataPtr(hCPU, address);
		*(uint32*)(ptr + 4) = CPU_swapEndianU32(v1);
		*(uint32*)(ptr + 0) = CPU_swapEndianU32(v2);
	}

	inline static void ppcMem_writeDataU64(PPCInterpreter_t* hCPU, uint32 address, uint64 v)
	{
		*(uint64*)(ppcMem_getDataPtr(hCPU, address)) = CPU_swapEndianU64(v);
	}

	inline static void ppcMem_writeDataU32(PPCInterpreter_t* hCPU, uint32 address, uint32 v)
	{
		uint32 pAddr = ppcMem_translateVirtualDataToPhysicalAddr(hCPU, address); 
		if (hCPU->memoryException)
			return;

		if (pAddr >= 0x0c000000 && pAddr < 0x0d100000)
		{
			cemu_assert_unimplemented();
			return;
		}
		*(uint32*)(memory_base + pAddr) = CPU_swapEndianU32(v);
	}

	inline static void ppcMem_writeDataU16(PPCInterpreter_t* hCPU, uint32 address, uint16 v)
	{
		*(uint16*)(ppcMem_getDataPtr(hCPU, address)) = CPU_swapEndianU16(v);
	}

	inline static void ppcMem_writeDataU8(PPCInterpreter_t* hCPU, uint32 address, uint8 v)
	{
		*(uint8*)(ppcMem_getDataPtr(hCPU, address)) = v;
	}

	inline static double ppcMem_readDataDouble(PPCInterpreter_t* hCPU, uint32 address)
	{
		uint32 v[2];
		v[1] = *(uint32*)(ppcMem_getDataPtr(hCPU, address));
		v[0] = *(uint32*)(ppcMem_getDataPtr(hCPU, address) + 4);
		v[0] = CPU_swapEndianU32(v[0]);
		v[1] = CPU_swapEndianU32(v[1]);
		return *(double*)v;
	}

	inline static float ppcMem_readDataFloat(PPCInterpreter_t* hCPU, uint32 address)
	{
		uint32 v = *(uint32*)(ppcMem_getDataPtr(hCPU, address));
		v = CPU_swapEndianU32(v);
		return *(float*)&v;
	}

	inline static uint64 ppcMem_readDataU64(PPCInterpreter_t* hCPU, uint32 address)
	{
		uint64 v = *(uint64*)(ppcMem_getDataPtr(hCPU, address));
		return CPU_swapEndianU64(v);
	}

	inline static uint32 ppcMem_readDataU32(PPCInterpreter_t* hCPU, uint32 address)
	{
		uint32 pAddr = ppcMem_translateVirtualDataToPhysicalAddr(hCPU, address);
		if (hCPU->memoryException)
			return 0;
		if (pAddr >= 0x01FFF000 && pAddr < 0x02000000)
		{
			debug_printf("Access u32 boot param block 0x%08x IP %08x LR %08x\n", pAddr, hCPU->instructionPointer, hCPU->spr.LR);
			cemuLog_logDebug(LogType::Force, "Access u32 boot param block 0x{:08x} (org {:08x}) IP {:08x}", pAddr, address, hCPU->instructionPointer);
		}
		if (pAddr >= 0xFFEB73B0 && pAddr < (0xFFEB73B0+0x40C))
		{
			debug_printf("Access cached u32 boot param block 0x%08x IP %08x LR %08x\n", pAddr, hCPU->instructionPointer, hCPU->spr.LR);
			cemuLog_logDebug(LogType::Force, "Access cached u32 boot param block 0x{:08x} (org {:08x}) IP {:08x}", pAddr, address, hCPU->instructionPointer);
		}

		if (pAddr >= 0x0c000000 && pAddr < 0x0d100000)
		{
			cemu_assert_unimplemented();
			return 0;
		}
		uint32 v = *(uint32*)(memory_base + pAddr);
		return CPU_swapEndianU32(v);
	}

	inline static uint16 ppcMem_readDataU16(PPCInterpreter_t* hCPU, uint32 address)
	{
		uint16 v = *(uint16*)(ppcMem_getDataPtr(hCPU, address));
		return CPU_swapEndianU16(v);
	}

	inline static uint8 ppcMem_readDataU8(PPCInterpreter_t* hCPU, uint32 address)
	{
		uint32 pAddr = ppcMem_translateVirtualDataToPhysicalAddr(hCPU, address);
		if (pAddr >= 0x0c000000 && pAddr < 0x0d100000)
		{
			cemu_assert_unimplemented();
			return 0;
		}
		return *(uint8*)(memory_base + pAddr);
	}

	inline static uint64 ppcMem_readDataFloatEx(PPCInterpreter_t* hCPU, uint32 addr)
	{
		return ConvertToDoubleNoFTZ(_swapEndianU32(*(uint32*)(memory_base + addr)));
	}

	inline static void ppcMem_writeDataFloatEx(PPCInterpreter_t* hCPU, uint32 addr, uint64 value)
	{
		*(uint32*)(memory_base + addr) = _swapEndianU32(ConvertToSingleNoFTZ(value));
	}

	inline static uint64 getTB(PPCInterpreter_t* hCPU)
	{
		return hCPU->global->tb / 20ULL;
	}
};

// Iridia study: threaded block interpreter (no JIT). A block is an array of steps decoded once; each
// step runs one instruction's handler (inlined via the template) and then jumps straight to the next
// step, so every handler has its own dispatch branch. Only functions compiled into the app run.
using PPCInstrFn = void(*)(PPCInterpreter_t* hCPU, uint32 opcode);
struct PPCTBEntry;
// Iridia: steps use clang's preserve_none convention on arm64: no callee-saved registers, so hCPU and the step
// pointer travel in registers that survive the handler's helper calls (no save/restore around every step).
// -DIRIDIA_TB_NO_PRESERVE_NONE builds the old convention (A/B).
#if defined(__clang__) && defined(__aarch64__) && !defined(IRIDIA_TB_NO_PRESERVE_NONE)
#define TB_CC __attribute__((preserve_none))
#else
#define TB_CC
#endif
// Iridia: guest r1 (the stack pointer) also travels with every step in a register (pr1), so stack loads and stores
// skip reading it from the CPU state. Write-through: the CPU state copy is always current, and every step that
// writes r1 updates both, so block exits, OS calls and the stock handlers need nothing extra. Steps that write r1
// without a pinned variant are left to the stock handler, which reloads pr1 afterwards (tbStep).
// -DIRIDIA_TB_NO_PIN builds never pick the pinned variants (A/B).
using PPCTBFn = TB_CC void(*)(PPCInterpreter_t* hCPU, const PPCTBEntry* step, uint32 pr1);
struct PPCTBEntry
{
	PPCTBFn fn;
	uint32 opcode;
	uint32 address;   // this instruction's address (the exit step: the address after the block)
	uint32 imm;       // specialized steps: pre-decoded immediate / mask
	uint8 r0, r1, r2, r3; // specialized steps: pre-decoded register numbers / shift
};

#ifdef CEMU_TBI
// Per-host-thread direct-mapped cache in front of the page table (address -> block steps). Any code
// change bumps s_tbGeneration, which makes every cache entry stale at once.
namespace
{
	constexpr uint32 kTBCacheSize = 4096;
	constexpr bool kTBVictim = false;
	constexpr uint32 kTBCacheAlloc = kTBVictim ? 2 * kTBCacheSize : kTBCacheSize;
	struct TBCacheEntry { uint32 ip; uint32 generation; const PPCTBEntry* steps; }; // 16 bytes
	// A block's instruction count sits just before its steps (PPCTBBlock).
	inline uint32 tbBlockCount(const PPCTBEntry* steps) { return ((const uint32*)steps)[-1]; }
	std::atomic<uint32> s_tbGeneration{1};
	// Iridia study (IRIDIA_TB_STATS=1): how often code is invalidated and blocks are decoded again, and how many
	// of those rebuilds produced the same instructions as the block they replaced. Reported every 10 s.
	std::atomic<uint64> s_tbStatInval{0}, s_tbStatPages{0}, s_tbStatBytes{0}, s_tbStatNew{0}, s_tbStatStale{0}, s_tbStatSame{0}, s_tbStatMiss{0};
	// miss reasons (MORNING11 item 2): slot held this address but the generation moved on (code invalidated) /
	// slot empty / slot held another address (evicted); of the evicted, how many a second way (the last address
	// pushed out of the slot) would have hit, and how many were returns (blr) or bctr
	std::atomic<uint64> s_tbMissGen{0}, s_tbMissEmpty{0}, s_tbMissEvict{0}, s_tbMissVictimHit{0};
	bool tbStatsOn() { static const bool v = iridia_getenv("IRIDIA_TB_STATS") && iridia_getenv("IRIDIA_TB_STATS")[0] == '1'; return v; }
	void tbStatsReport()
	{
		static std::atomic<uint64> s_last{0};
		const uint64 now = (uint64)std::chrono::duration_cast<std::chrono::seconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
		uint64 last = s_last.load(std::memory_order_relaxed);
		if (now < last + 10 || !s_last.compare_exchange_strong(last, now))
			return;
		fprintf(stderr, "IRIDIA_TB_STATS invalidations %llu pages %llu bytes %llu | builds new %llu stale %llu (same code %llu) | cache misses %llu (generation %llu, empty %llu, evicted %llu of which a 2nd way hits %llu)\n",
			(unsigned long long)s_tbStatInval.load(), (unsigned long long)s_tbStatPages.load(), (unsigned long long)s_tbStatBytes.load(),
			(unsigned long long)s_tbStatNew.load(), (unsigned long long)s_tbStatStale.load(), (unsigned long long)s_tbStatSame.load(), (unsigned long long)s_tbStatMiss.load(),
			(unsigned long long)s_tbMissGen.load(), (unsigned long long)s_tbMissEmpty.load(), (unsigned long long)s_tbMissEvict.load(), (unsigned long long)s_tbMissVictimHit.load());
	}
	inline void tbCountExec(PPCInterpreter_t*, const PPCTBEntry*) {}
	// Iridia study: IRIDIA_TBI_VERIFY=1 runs every block a second time on the stock interpreter from the same
	// starting state and reports any difference in registers (use with the single-core interpreter so no other
	// core changes memory in between). Blocks with HLE calls, sc, lwarx/stwcx. or SPR/timebase reads are skipped.
	// Iridia AOT verify builds: compiled blocks are checked against the stock interpreter (AotVerifyBlock) and
	// don't chain, so each one is checked on its own. Set once gameplay starts.
	static constexpr bool s_aotVerifyOn = false;
	// read on first use (the app sets study switches after load); a plain byte, no guard: this is on the hottest path
	static inline sint8 s_tbVerifyFlag = -1;
	__attribute__((always_inline)) inline bool s_tbVerify() { if (s_tbVerifyFlag < 0) [[unlikely]] s_tbVerifyFlag = iridia_getenv("IRIDIA_TBI_VERIFY") != nullptr; return s_tbVerifyFlag != 0; }

	// The next block straight from this thread's cache, or nullptr (time slice used up, or not cached:
	// the run loop takes over). Inlined into each block-ending step, so each has its own jump site.
// Iridia study: IRIDIA_TB_HIST=1 counts guest instructions entered through this loop per block start, split into
// AOT and TB blocks, and prints the top TB blocks every 10 s (AOT blocks that chain directly are not seen here)
static bool s_tbHistOn()
{
	static const bool on = iridia_getenv("IRIDIA_TB_HIST") != nullptr;
	return on;
}
static void TBHistAdd(uint32 ip, bool aot, uint32 n)
{
	static std::mutex mtx;
	static std::unordered_map<uint32, uint64> tb;
	static uint64 aotN = 0, tbN = 0;
	static int reports = 0;
	static auto last = std::chrono::steady_clock::now();
	std::lock_guard lock(mtx);
	if (aot) aotN += n; else { tbN += n; tb[ip] += n; }
	if (std::chrono::steady_clock::now() - last < std::chrono::seconds(10))
		return;
	last = std::chrono::steady_clock::now();
	std::vector<std::pair<uint64, uint32>> v;
	for (auto& [a, c] : tb) v.emplace_back(c, a);
	std::sort(v.rbegin(), v.rend());
	fprintf(stderr, "IRIDIA_TB_HIST report %d entered instructions: aot %llu tb %llu (%zu tb blocks)\n", reports + 1, (unsigned long long)aotN, (unsigned long long)tbN, tb.size());
	for (size_t i = 0; i < v.size() && i < 40; i++)
		fprintf(stderr, "IRIDIA_TB_HIST %08x %llu\n", v[i].second, (unsigned long long)v[i].first);
	++reports;
	if (const char* path = iridia_getenv("IRIDIA_TB_HIST_FILE"); path)
		if (FILE* f = fopen(fmt::format("{}.{}", path, reports).c_str(), "w"))
			{
				for (auto& [c, ad] : v) fprintf(f, "%08x %llu\n", ad, (unsigned long long)c);
				fclose(f);
			}
	tb.clear(); aotN = tbN = 0;
}

	// way 1 of the slot (kTBVictim builds): on a hit, swap it into way 0 and return true
	__attribute__((noinline, cold)) inline bool tbVictimSwap(TBCacheEntry* ce, uint32 ip)
	{
		TBCacheEntry& ve = ce[kTBCacheSize];
		if (ve.ip != ip || ve.generation != s_tbGeneration.load(std::memory_order_relaxed))
			return false;
		std::swap(*ce, ve);
		return true;
	}
	__attribute__((always_inline)) inline const PPCTBEntry* tbNextBlock(PPCInterpreter_t* hCPU)
	{
		auto cntExit = [](uint32) {};
		if (hCPU->remainingCycles <= 0 || s_tbVerify() || s_aotVerifyOn)
		{
			cntExit(2);
			return nullptr;
		}
		const uint32 ip = hCPU->instructionPointer;
		TBCacheEntry& ce = ((TBCacheEntry*)hCPU->tbCache)[(ip >> 2) & (kTBCacheSize - 1)];
		if (ce.ip != ip || ce.generation != s_tbGeneration.load(std::memory_order_relaxed))
		{
			if constexpr (kTBVictim)
			{
				// out of line, so the hit path of every exit step keeps its old code (an inlined swap made each
				// exit step save registers on its hit path: +1.8% instructions on the Mac)
				if (tbVictimSwap(&ce, ip))
					goto hit;
			}
			cntExit(1);
			return nullptr;
		}
	hit:
		cntExit(0);
		hCPU->remainingCycles -= (sint32)tbBlockCount(ce.steps);
		tbCountExec(hCPU, ce.steps);
		return ce.steps;
	}
}
#endif

template <typename ppcItpCtrl>
class PPCInterpreterContainer
{
public:
#include "PPCInterpreterSPR.hpp"
#include "PPCInterpreterOPC.hpp"
#include "PPCInterpreterLoadStore.hpp"
#include "PPCInterpreterALU.hpp"
#ifdef CEMU_TBI
	template <PPCInstrFn F>
	TB_CC static void tbStep(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		// Write the known address instead of letting each handler load-add-store it after the
		// previous one: breaks the store-to-load chain through memory between instructions.
		hCPU->instructionPointer = e->address;
		F(hCPU, e->opcode);
		[[clang::musttail]] return e[1].fn(hCPU, e + 1, hCPU->gpr[1]); // the handler may have written r1
	}
	template <PPCInstrFn F>
	TB_CC static void tbLast(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		hCPU->instructionPointer = e->address;
		F(hCPU, e->opcode);
		// Plain branches go straight on to the next block; HLE calls, sc, rfi and tw return to the run loop.
		if constexpr (F == &PPCInterpreter_BCX || F == &PPCInterpreter_BX || F == &PPCInterpreter_BCLRX || F == &PPCInterpreter_BCCTR)
		{
			IRIDIA_CNT_EXITKIND(F == &PPCInterpreter_BCLRX ? 1 : F == &PPCInterpreter_BCCTR ? 2 : 3);
			if (const PPCTBEntry* next = tbNextBlock(hCPU))
				[[clang::musttail]] return next->fn(hCPU, next, hCPU->gpr[1]);
		}
	}

	// Specialized steps for very common instructions: operands are decoded once when the block is
	// built (tbSpecialize) and the instruction pointer isn't touched (generic steps and the block's
	// exit step set it). Semantics match the handlers they replace.
#define TB_NEXT() [[clang::musttail]] return e[1].fn(hCPU, e + 1, pr1)
#define TB_BODY(name) __attribute__((always_inline)) static inline void name(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32& pr1)
	TB_BODY(bRlwinm) // SH != 0
	{
		const uint32 v = hCPU->gpr[e->r0];
		hCPU->gpr[e->r1] = ((v << e->r2) | (v >> (32 - e->r2))) & e->imm;
	}
	TB_BODY(bRlwinmMask) // SH == 0 (clrlwi, clrrwi, ...)
	{
		hCPU->gpr[e->r1] = hCPU->gpr[e->r0] & e->imm;
	}
	TB_BODY(bRlwinmRc)
	{
		hCPU->gpr[e->r1] = ppc_word_rotl(hCPU->gpr[e->r0], e->r2) & e->imm;
		ppc_update_cr0(hCPU, hCPU->gpr[e->r1]);
	}
	TB_BODY(bLoadImm) // li / lis (rA = 0)
	{
		hCPU->gpr[e->r0] = e->imm;
	}
	TB_BODY(bAddImm)  // addi / addis
	{
		hCPU->gpr[e->r0] = hCPU->gpr[e->r1] + e->imm;
	}
	TB_BODY(bOri)
	{
		hCPU->gpr[e->r1] = hCPU->gpr[e->r0] | e->imm;
	}
	TB_BODY(bLwz)
	{
		hCPU->gpr[e->r0] = ppcItpCtrl::ppcMem_readDataU32(hCPU, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm);
	}
	TB_BODY(bStw) // rA != 0 only
	{
		ppcItpCtrl::ppcMem_writeDataU32(hCPU, hCPU->gpr[e->r1] + e->imm, hCPU->gpr[e->r0]);
	}
	// lfs: same as PPCInterpreter_LFS (user mode, LSQE: both paired-single halves), with the
	// normal-number case of ConvertToDoubleNoFTZ inline and the rest (denormals, NaN, zero) out of line.
	__attribute__((noinline)) static uint64 tbConvertToDoubleSlow(uint32 v) { return ConvertToDoubleNoFTZ(v); }
	__attribute__((always_inline)) static inline void tbLfsAt(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 ea)
	{
		const uint32 raw = _swapEndianU32(*(volatile uint32*)(memory_base + ea));
		const uint32 exp = (raw >> 23) & 0xFF;
		uint64 v;
		if (exp > 0 && exp < 255) [[likely]]
		{
			const uint64 x = raw;
			const uint64 y = !(exp >> 7);
			v = ((x & 0xc0000000) << 32) | (y << 61 | y << 60 | y << 59) | ((x & 0x3fffffff) << 29);
		}
		else if ((raw & 0x7fffffff) == 0) // +-0.0: ConvertToDoubleNoFTZ gives the sign bit alone (0.6% of core time out of line)
			v = (uint64)raw << 32;
		else
			v = tbConvertToDoubleSlow(raw);
		hCPU->fpr[e->r0].fp0int = v;
		hCPU->fpr[e->r0].fp1int = v;
	}
	TB_BODY(bLfs) { tbLfsAt(hCPU, e, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm); }
	__attribute__((always_inline)) static inline void tbStfsAt(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 ea)
	{
		IRIDIA_LOG_STORE(ea, 4);
		*(volatile uint32*)(memory_base + ea) = _swapEndianU32(ConvertToSingleNoFTZ(hCPU->fpr[e->r0].fp0int));
	}
	TB_BODY(bStfs) { tbStfsAt(hCPU, e, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm); }
	// psq_l / psq_st: the float GQR types (anything but 4-7) inline, exactly like dequantize/quantize do them
	// (host float<->double conversion); quantized types go through the original handler. r0 = frD, r1 = rA,
	// r2 = GQR index, r3 = W (one value), imm = sign-extended 12-bit displacement.
	// Iridia: on arm64 a float pair (W = 0) is one 8-byte access and one 2-lane conversion (fcvtl / fcvtn, the same
	// IEEE conversions under the same FPCR as the scalar fcvt); an address that would wrap past 4 GB takes the two
	// 4-byte accesses. On by default (Nov 4, PS_WORK.md). Both forms are built (Wide = true / false); the decoder picks
	// one when it builds a block (narrow with IRIDIA_PS_FAST=0, see s_tbPsFast), so the step itself has no switch.
	__attribute__((noinline)) static void tbPsqLSlow(PPCInterpreter_t* hCPU, uint32 opcode) { PPCInterpreter_PSQ_L(hCPU, opcode); }
	__attribute__((noinline)) static void tbPsqStSlow(PPCInterpreter_t* hCPU, uint32 opcode) { PPCInterpreter_PSQ_ST(hCPU, opcode); }
	// Quantized types out of line by value (user mode memory access does not use the CPU state), so passing the
	// state pointer to a call does not force an AOT block's local copy of it into memory. Same steps as
	// PPCInterpreter_PSQ_L / PPCInterpreter_PSQ_ST. IRIDIA_PSQ_SLOW_STATE builds keep the old calls (A/B).
	struct TbPair { double a, b; };
	__attribute__((noinline)) static TbPair tbPsqLQuant(uint32 ea, uint32 gqr, uint32 w)
	{
		const sint32 type = (gqr >> 16) & 7;
		const uint8 scale = (uint8)((gqr >> 24) & 0x3f);
		uint32 data0 = 0, data1 = 0;
		if ((type == 4) || (type == 6)) { data0 = ppcItpCtrl::ppcMem_readDataU8(nullptr, ea); if (!w) data1 = ppcItpCtrl::ppcMem_readDataU8(nullptr, ea + 1); }
		else if ((type == 5) || (type == 7)) { data0 = ppcItpCtrl::ppcMem_readDataU16(nullptr, ea); if (!w) data1 = ppcItpCtrl::ppcMem_readDataU16(nullptr, ea + 2); }
		else { data0 = ppcItpCtrl::ppcMem_readDataU32(nullptr, ea); if (!w) data1 = ppcItpCtrl::ppcMem_readDataU32(nullptr, ea + 4); }
		if (type == 6) { if (data0 & 0x80) data0 |= 0xffffff00; if (data1 & 0x80) data1 |= 0xffffff00; }
		if (type == 7) { if (data0 & 0x8000) data0 |= 0xffff0000; if (data1 & 0x8000) data1 |= 0xffff0000; }
		return { (double)dequantize(data0, type, scale), w ? (double)1.0f : (double)dequantize(data1, type, scale) };
	}
	__attribute__((noinline)) static void tbPsqStQuant(uint32 ea, uint32 gqr, uint32 w, double a, double b)
	{
		const sint32 type = gqr & 7;
		const uint8 scale = (uint8)((gqr >> 8) & 0x3f);
		if ((type == 4) || (type == 6)) ppcItpCtrl::ppcMem_writeDataU8(nullptr, ea, quantize((float)a, type, scale));
		else if ((type == 5) || (type == 7)) ppcItpCtrl::ppcMem_writeDataU16(nullptr, ea, quantize((float)a, type, scale));
		else ppcItpCtrl::ppcMem_writeDataU32(nullptr, ea, quantize((float)a, type, scale));
		if (w)
			return;
		if ((type == 4) || (type == 6)) ppcItpCtrl::ppcMem_writeDataU8(nullptr, ea + 1, quantize((float)b, type, scale));
		else if ((type == 5) || (type == 7)) ppcItpCtrl::ppcMem_writeDataU16(nullptr, ea + 2, quantize((float)b, type, scale));
		else ppcItpCtrl::ppcMem_writeDataU32(nullptr, ea + 4, quantize((float)b, type, scale));
	}
	static constexpr bool kPsqByValue = !ppcItpCtrl::allowSupervisorMode; // user mode memory access only
	template<bool Wide>
	__attribute__((always_inline)) static inline void tbPsqLAt(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 ea)
	{
		if (!((hCPU->spr.UGQR[e->r2] >> 16) & 4)) [[likely]]
		{
#if TB_PSQ_WIDE
			if (Wide && !e->r3 && ea <= 0xfffffff8) [[likely]] // pair: one 8-byte load, byteswap each word, widen both lanes
			{
				const uint64 raw = *(volatile uint64*)(memory_base + ea);
				vst1q_f64(&hCPU->fpr[e->r0].fp0, vcvt_f64_f32(vreinterpret_f32_u8(vrev32_u8(vcreate_u8(raw)))));
				return;
			}
#endif
			const uint32 d0 = ppcItpCtrl::ppcMem_readDataU32(hCPU, ea);
			hCPU->fpr[e->r0].fp0 = (double)std::bit_cast<float>(d0);
			if (e->r3)
				hCPU->fpr[e->r0].fp1 = 1.0f;
			else
				hCPU->fpr[e->r0].fp1 = (double)std::bit_cast<float>(ppcItpCtrl::ppcMem_readDataU32(hCPU, ea + 4));
		}
		else if constexpr (kPsqByValue)
		{
			const TbPair v = tbPsqLQuant(ea, hCPU->spr.UGQR[e->r2], e->r3);
			hCPU->fpr[e->r0].fp0 = v.a;
			hCPU->fpr[e->r0].fp1 = v.b;
		}
		else
			tbPsqLSlow(hCPU, e->opcode);
	}
	TB_BODY(bPsqL) { tbPsqLAt<true>(hCPU, e, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm); }
	TB_BODY(bPsqLN) { tbPsqLAt<false>(hCPU, e, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm); } // IRIDIA_PS_FAST=0
	template<bool Wide>
	__attribute__((always_inline)) static inline void tbPsqStAt(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 ea)
	{
		if (!(hCPU->spr.UGQR[e->r2] & 4)) [[likely]]
		{
#if TB_PSQ_WIDE
			if (Wide && !e->r3 && ea <= 0xfffffff8) [[likely]] // pair: narrow both lanes, byteswap each word, one 8-byte store
			{
				const float32x2_t f = vcvt_f32_f64(vld1q_f64(&hCPU->fpr[e->r0].fp0));
				IRIDIA_LOG_STORE(ea, 4);
				IRIDIA_LOG_STORE(ea + 4, 4);
				*(volatile uint64*)(memory_base + ea) = vget_lane_u64(vreinterpret_u64_u8(vrev32_u8(vreinterpret_u8_f32(f))), 0);
				return;
			}
#endif
			ppcItpCtrl::ppcMem_writeDataU32(hCPU, ea, std::bit_cast<uint32>((float)hCPU->fpr[e->r0].fp0));
			if (!e->r3)
				ppcItpCtrl::ppcMem_writeDataU32(hCPU, ea + 4, std::bit_cast<uint32>((float)hCPU->fpr[e->r0].fp1));
		}
		else if constexpr (kPsqByValue)
			tbPsqStQuant(ea, hCPU->spr.UGQR[e->r2], e->r3, hCPU->fpr[e->r0].fp0, hCPU->fpr[e->r0].fp1);
		else
			tbPsqStSlow(hCPU, e->opcode);
	}
	TB_BODY(bPsqSt) { tbPsqStAt<true>(hCPU, e, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm); }
	TB_BODY(bPsqStN) { tbPsqStAt<false>(hCPU, e, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm); } // IRIDIA_PS_FAST=0
	TB_BODY(bOr) // or rA, rS, rB without Rc (mr when rS == rB)
	{
		hCPU->gpr[e->r1] = hCPU->gpr[e->r0] | hCPU->gpr[e->r2];
	}
	// Batch 2 (same semantics as the stock handlers): r0 = rD/rS/frD, r1 = rA, r2 = rB or CR field, imm = displacement.
	TB_BODY(bMtlr) { hCPU->spr.LR = hCPU->gpr[e->r0]; }
	TB_BODY(bMtctr) { hCPU->spr.CTR = hCPU->gpr[e->r0]; }
	TB_BODY(bMflr) { hCPU->gpr[e->r0] = hCPU->spr.LR; }
	TB_BODY(bMfctr) { hCPU->gpr[e->r0] = hCPU->spr.CTR; }
	TB_BODY(bStwu)
	{
		ppcItpCtrl::ppcMem_writeDataU32(hCPU, hCPU->gpr[e->r1] + e->imm, hCPU->gpr[e->r0]);
		hCPU->gpr[e->r1] += e->imm;
	}
	TB_BODY(bLbz) { hCPU->gpr[e->r0] = ppcItpCtrl::ppcMem_readDataU8(hCPU, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm); }
	TB_BODY(bLhz) { hCPU->gpr[e->r0] = ppcItpCtrl::ppcMem_readDataU16(hCPU, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm); }
	TB_BODY(bStb) { ppcItpCtrl::ppcMem_writeDataU8(hCPU, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm, (uint8)hCPU->gpr[e->r0]); }
	TB_BODY(bSth) { ppcItpCtrl::ppcMem_writeDataU16(hCPU, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm, (uint16)hCPU->gpr[e->r0]); }
	TB_BODY(bLfd) { hCPU->fpr[e->r0].fpr = ppcItpCtrl::ppcMem_readDataDouble(hCPU, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm); }
	TB_BODY(bStfd) { ppcItpCtrl::ppcMem_writeDataDouble(hCPU, (e->r1 ? hCPU->gpr[e->r1] : 0) + e->imm, hCPU->fpr[e->r0].fpr); }
	TB_BODY(bAdd) { hCPU->gpr[e->r0] = hCPU->gpr[e->r1] + hCPU->gpr[e->r2]; }
	TB_BODY(bSubf) { hCPU->gpr[e->r0] = hCPU->gpr[e->r2] - hCPU->gpr[e->r1]; }
	TB_BODY(bMulli) { hCPU->gpr[e->r0] = hCPU->gpr[e->r1] * e->imm; }
	template <bool Signed, bool Imm>
	TB_BODY(bCmp) // cmp / cmpl / cmpi / cmpli not followed by a fusable bc: r1 = rA, r2 = rB, r3 = CR field
	{
		const uint32 a = hCPU->gpr[e->r1];
		const uint32 b = Imm ? e->imm : hCPU->gpr[e->r2];
		const bool lt = Signed ? (sint32)a < (sint32)b : a < b;
		const bool gt = Signed ? (sint32)a > (sint32)b : a > b;
		ppc_setCRField(hCPU, e->r3, lt, gt, !lt && !gt, hCPU->xer_so);
	}
	// Pinned r1 variants (see PPCTBFn): the base register is r1, read from pr1. Same operands as above; the
	// destination is never r1 except in bStwuP and bAddImmPP, which update both copies.
	TB_BODY(bLwzP) { hCPU->gpr[e->r0] = ppcItpCtrl::ppcMem_readDataU32(hCPU, pr1 + e->imm); }
	TB_BODY(bStwP) { ppcItpCtrl::ppcMem_writeDataU32(hCPU, pr1 + e->imm, hCPU->gpr[e->r0]); }
	TB_BODY(bStwuP) // stwu rS, d(r1): the stored value is read before r1 changes
	{
		ppcItpCtrl::ppcMem_writeDataU32(hCPU, pr1 + e->imm, hCPU->gpr[e->r0]);
		pr1 += e->imm;
		hCPU->gpr[1] = pr1;
	}
	TB_BODY(bAddImmP) { hCPU->gpr[e->r0] = pr1 + e->imm; }
	TB_BODY(bAddImmPP) { pr1 += e->imm; hCPU->gpr[1] = pr1; } // addi / addis r1, r1, imm
	TB_BODY(bLbzP) { hCPU->gpr[e->r0] = ppcItpCtrl::ppcMem_readDataU8(hCPU, pr1 + e->imm); }
	TB_BODY(bLhzP) { hCPU->gpr[e->r0] = ppcItpCtrl::ppcMem_readDataU16(hCPU, pr1 + e->imm); }
	TB_BODY(bStbP) { ppcItpCtrl::ppcMem_writeDataU8(hCPU, pr1 + e->imm, (uint8)hCPU->gpr[e->r0]); }
	TB_BODY(bSthP) { ppcItpCtrl::ppcMem_writeDataU16(hCPU, pr1 + e->imm, (uint16)hCPU->gpr[e->r0]); }
	TB_BODY(bLfdP) { hCPU->fpr[e->r0].fpr = ppcItpCtrl::ppcMem_readDataDouble(hCPU, pr1 + e->imm); }
	TB_BODY(bStfdP) { ppcItpCtrl::ppcMem_writeDataDouble(hCPU, pr1 + e->imm, hCPU->fpr[e->r0].fpr); }
	TB_BODY(bLfsP) { tbLfsAt(hCPU, e, pr1 + e->imm); }
	TB_BODY(bStfsP) { tbStfsAt(hCPU, e, pr1 + e->imm); }
	TB_BODY(bPsqLP) { tbPsqLAt<true>(hCPU, e, pr1 + e->imm); }
	TB_BODY(bPsqStP) { tbPsqStAt<true>(hCPU, e, pr1 + e->imm); }
	TB_BODY(bPsqLPN) { tbPsqLAt<false>(hCPU, e, pr1 + e->imm); }
	TB_BODY(bPsqStPN) { tbPsqStAt<false>(hCPU, e, pr1 + e->imm); }

	// Iridia: paired-single math as specialized steps: registers decoded when the block is built, no instruction
	// pointer store or r1 reload (like the other specialized steps). The bodies are the stock handlers' C expressions
	// from PPCInterpreterPS.cpp, statement for statement, so clang makes the same fused / separate multiply-add
	// choices (ffp-contract=on contracts per expression) and the same 2-lane code. r0 = frD, r1 = frA, r2 = frB,
	// r3 = frC. On by default; IRIDIA_PS_FAST=0 (read when a block is built) keeps the stock handlers; see tbPsFastOn.
	// roundTo25BitAccuracy: (v & ~(2^27 - 1)) + (v & 2^27) == ((v + 2^27) >> 28) << 28 for every v (mod 2^64; checked
	// by IRIDIA_PS_SELFTEST), one rounding shift pair instead of two masks and an add.
	__attribute__((always_inline)) static inline double tbRound25(double d)
	{
		const uint64 v = std::bit_cast<uint64>(d);
		return std::bit_cast<double>(((v + (1ULL << 27)) >> 28) << 28);
	}
	// both lanes of an FPR at once: urshr #28 (the rounding shift computes v + 2^27 without overflow) + shl #28.
	// Reading frC up front is exact: every stock handler that rounds frC reads it before writing frD's same lane.
	struct TbD2 { double a, b; };
	__attribute__((always_inline)) static inline TbD2 tbRound25x2(const FPR_t& r)
	{
#if defined(__aarch64__)
		const float64x2_t v = vreinterpretq_f64_u64(vshlq_n_u64(vrshrq_n_u64(vld1q_u64(&r.fp0int), 28), 28));
		return { vgetq_lane_f64(v, 0), vgetq_lane_f64(v, 1) };
#else
		return { tbRound25(r.fp0), tbRound25(r.fp1) };
#endif
	}
#define TB_PS_REGS [[maybe_unused]] const uint32 frD = e->r0, frA = e->r1, frB = e->r2, frC = e->r3
	TB_BODY(bPsAdd) { TB_PS_REGS;
		hCPU->fpr[frD].fp0 = (float)(hCPU->fpr[frA].fp0 + hCPU->fpr[frB].fp0);
		hCPU->fpr[frD].fp1 = (float)(hCPU->fpr[frA].fp1 + hCPU->fpr[frB].fp1); }
	TB_BODY(bPsSub) { TB_PS_REGS;
		hCPU->fpr[frD].fp0 = (float)(hCPU->fpr[frA].fp0 - hCPU->fpr[frB].fp0);
		hCPU->fpr[frD].fp1 = (float)(hCPU->fpr[frA].fp1 - hCPU->fpr[frB].fp1); }
	TB_BODY(bPsMul) { TB_PS_REGS;
		const TbD2 c = tbRound25x2(hCPU->fpr[frC]);
		hCPU->fpr[frD].fp0 = flushDenormalToZero((float)(hCPU->fpr[frA].fp0 * c.a));
		hCPU->fpr[frD].fp1 = flushDenormalToZero((float)(hCPU->fpr[frA].fp1 * c.b)); }
	TB_BODY(bPsDiv) { TB_PS_REGS;
		hCPU->fpr[frD].fp0 = (float)(hCPU->fpr[frA].fp0 / hCPU->fpr[frB].fp0);
		hCPU->fpr[frD].fp1 = (float)(hCPU->fpr[frA].fp1 / hCPU->fpr[frB].fp1); }
	TB_BODY(bPsMadd) { TB_PS_REGS;
		const TbD2 c = tbRound25x2(hCPU->fpr[frC]);
		float s0 = (float)((float)(hCPU->fpr[frA].fp0 * c.a) + hCPU->fpr[frB].fp0);
		float s1 = (float)((float)(hCPU->fpr[frA].fp1 * c.b) + hCPU->fpr[frB].fp1);
		hCPU->fpr[frD].fp0 = flushDenormalToZero(s0);
		hCPU->fpr[frD].fp1 = flushDenormalToZero(s1); }
	TB_BODY(bPsNmadd) { TB_PS_REGS;
		const TbD2 c = tbRound25x2(hCPU->fpr[frC]);
		float s0 = (float)-(hCPU->fpr[frA].fp0 * c.a + hCPU->fpr[frB].fp0);
		float s1 = (float)-(hCPU->fpr[frA].fp1 * c.b + hCPU->fpr[frB].fp1);
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
	TB_BODY(bPsMsub) { TB_PS_REGS;
		const TbD2 c = tbRound25x2(hCPU->fpr[frC]);
		float s0 = (float)(hCPU->fpr[frA].fp0 * c.a - hCPU->fpr[frB].fp0);
		float s1 = (float)(hCPU->fpr[frA].fp1 * c.b - hCPU->fpr[frB].fp1);
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
	TB_BODY(bPsNmsub) { TB_PS_REGS;
		const TbD2 c = tbRound25x2(hCPU->fpr[frC]);
		float s0 = (float)-(hCPU->fpr[frA].fp0 * c.a - hCPU->fpr[frB].fp0);
		float s1 = (float)-(hCPU->fpr[frA].fp1 * c.b - hCPU->fpr[frB].fp1);
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
	TB_BODY(bPsMadds0) { TB_PS_REGS;
		double c = tbRound25(hCPU->fpr[frC].fp0);
		float s0 = (float)(hCPU->fpr[frA].fp0 * c + hCPU->fpr[frB].fp0);
		float s1 = (float)(hCPU->fpr[frA].fp1 * c + hCPU->fpr[frB].fp1);
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
	TB_BODY(bPsMadds1) { TB_PS_REGS;
		double c = tbRound25(hCPU->fpr[frC].fp1);
		float s0 = (float)(hCPU->fpr[frA].fp0 * c + hCPU->fpr[frB].fp0);
		float s1 = (float)(hCPU->fpr[frA].fp1 * c + hCPU->fpr[frB].fp1);
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
	TB_BODY(bPsSel) { TB_PS_REGS;
		if( hCPU->fpr[frA].fp0 >= -0.0f )
			hCPU->fpr[frD].fp0 = hCPU->fpr[frC].fp0;
		else
			hCPU->fpr[frD].fp0 = hCPU->fpr[frB].fp0;
		if( hCPU->fpr[frA].fp1 >= -0.0f )
			hCPU->fpr[frD].fp1 = hCPU->fpr[frC].fp1;
		else
			hCPU->fpr[frD].fp1 = hCPU->fpr[frB].fp1; }
	TB_BODY(bPsSum0) { TB_PS_REGS;
		float s0 = (float)(hCPU->fpr[frA].fp0 + hCPU->fpr[frB].fp1);
		float s1 = (float)hCPU->fpr[frC].fp1;
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
	TB_BODY(bPsSum1) { TB_PS_REGS;
		float s0 = (float)hCPU->fpr[frC].fp0;
		float s1 = (float)(hCPU->fpr[frA].fp0 + hCPU->fpr[frB].fp1);
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
	TB_BODY(bPsMuls0) { TB_PS_REGS;
		double c = tbRound25(hCPU->fpr[frC].fp0);
		float s0 = (float)(hCPU->fpr[frA].fp0 * c);
		float s1 = (float)(hCPU->fpr[frA].fp1 * c);
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
	TB_BODY(bPsMuls1) { TB_PS_REGS;
		double c = tbRound25(hCPU->fpr[frC].fp1);
		float s0 = (float)(hCPU->fpr[frA].fp0 * c);
		float s1 = (float)(hCPU->fpr[frA].fp1 * c);
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
	TB_BODY(bPsMr) { TB_PS_REGS;
		hCPU->fpr[frD].fp0 = hCPU->fpr[frB].fp0;
		hCPU->fpr[frD].fp1 = hCPU->fpr[frB].fp1; }
	TB_BODY(bPsNeg) { TB_PS_REGS;
		hCPU->fpr[frD].fp0 = -hCPU->fpr[frB].fp0;
		hCPU->fpr[frD].fp1 = -hCPU->fpr[frB].fp1; }
	TB_BODY(bPsAbs) { TB_PS_REGS;
		hCPU->fpr[frD].fp0int = hCPU->fpr[frB].fp0int & ~(1ULL << 63);
		hCPU->fpr[frD].fp1int = hCPU->fpr[frB].fp1int & ~(1ULL << 63); }
	TB_BODY(bPsNabs) { TB_PS_REGS;
		hCPU->fpr[frD].fp0int = hCPU->fpr[frB].fp0int | (1ULL << 63);
		hCPU->fpr[frD].fp1int = hCPU->fpr[frB].fp1int | (1ULL << 63); }
	TB_BODY(bPsMerge00) { TB_PS_REGS;
		double s0 = hCPU->fpr[frA].fp0;
		double s1 = hCPU->fpr[frB].fp0;
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
	TB_BODY(bPsMerge01) { TB_PS_REGS;
		double s0 = hCPU->fpr[frA].fp0;
		double s1 = hCPU->fpr[frB].fp1;
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
	TB_BODY(bPsMerge10) { TB_PS_REGS;
		double s0 = hCPU->fpr[frA].fp1;
		double s1 = hCPU->fpr[frB].fp0;
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
	TB_BODY(bPsMerge11) { TB_PS_REGS;
		double s0 = hCPU->fpr[frA].fp1;
		double s1 = hCPU->fpr[frB].fp1;
		hCPU->fpr[frD].fp0 = s0;
		hCPU->fpr[frD].fp1 = s1; }
#undef TB_PS_REGS

	// One specialized instruction per step, or two back to back (pair fusion: BuildBlock merges neighbouring
	// specialized steps; e[1] then holds the second instruction's operands and is data only).
	using TBBody = void(*)(PPCInterpreter_t*, const PPCTBEntry*, uint32&);
	template <TBBody B>
	TB_CC static void tbOne(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		B(hCPU, e, pr1);
		TB_NEXT();
	}
	template <TBBody B1, TBBody B2>
	TB_CC static void tbTwo(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		B1(hCPU, e, pr1);
		B2(hCPU, e + 1, pr1);
		[[clang::musttail]] return e[2].fn(hCPU, e + 2, pr1);
	}
	static constexpr TBBody kTBPairable[] = { &bRlwinm, &bRlwinmMask, &bRlwinmRc, &bLoadImm, &bAddImm, &bOri, &bLwz, &bStw, &bLfs, &bStfs, &bPsqL, &bPsqSt, &bOr, &bMtlr, &bMtctr, &bMflr, &bMfctr, &bStwu, &bLbz, &bLhz, &bStb, &bSth, &bLfd, &bStfd, &bAdd, &bSubf, &bMulli, &bCmp<true, true>, &bCmp<false, true>, &bCmp<true, false>, &bCmp<false, false>,
		&bLwzP, &bStwP, &bStwuP, &bAddImmP, &bAddImmPP, &bLbzP, &bLhzP, &bStbP, &bSthP, &bLfdP, &bStfdP, &bLfsP, &bStfsP, &bPsqLP, &bPsqStP,
		&bPsqLN, &bPsqStN, &bPsqLPN, &bPsqStPN };
	static constexpr size_t kTBPairableCount = sizeof(kTBPairable) / sizeof(kTBPairable[0]);
	template <size_t I>
	static constexpr PPCTBFn tbOneAt() { return &tbOne<kTBPairable[I]>; }
	template <size_t I, size_t... J>
	static constexpr std::array<PPCTBFn, kTBPairableCount> tbTwoRow(std::index_sequence<J...>) { return { &tbTwo<kTBPairable[I], kTBPairable[J]>... }; }
	template <size_t... I>
	static constexpr std::array<std::array<PPCTBFn, kTBPairableCount>, kTBPairableCount> tbTwoTable(std::index_sequence<I...>) { return { tbTwoRow<I>(std::make_index_sequence<kTBPairableCount>())... }; }
	template <size_t... I>
	static constexpr std::array<PPCTBFn, kTBPairableCount> tbOneTable(std::index_sequence<I...>) { return { tbOneAt<I>()... }; }
	// Index of a single specialized step in kTBPairable, or -1.
	static int tbPairIndex(PPCTBFn fn)
	{
		static constexpr auto ones = tbOneTable(std::make_index_sequence<kTBPairableCount>());
		for (size_t i = 0; i < kTBPairableCount; i++)
			if (ones[i] == fn) return (int)i;
		return -1;
	}
	static PPCTBFn tbPairFn(int a, int b)
	{
		static constexpr auto table = tbTwoTable(std::make_index_sequence<kTBPairableCount>());
		return table[a][b];
	}
#undef TB_NEXT
#undef TB_BODY

	// Fused compare + conditional branch at the end of a block (cmp/cmpl/cmpi/cmpli, then bc without
	// LK, AA or a CTR update). Writes the CR field like the compare, then branches on the computed bit.
	// e: the compare (r0 = rA, r1 = rB, r2 = CR field, imm = immediate). e[1]: the branch (address,
	// imm = target, r0 = BO, r1 = BI). e[1] is data only, never run.
	// Side = the block goes on after a not-taken branch (e[2] is the next step); a taken one gives back
	// the cycles of the rest of the block (e[1].r2).
	template <bool Signed, bool Imm, bool Side>
	TB_CC static void tbCmpBc(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		const uint32 a = hCPU->gpr[e->r0];
		const uint32 b = Imm ? e->imm : hCPU->gpr[e->r1];
		const bool lt = Signed ? (sint32)a < (sint32)b : a < b;
		const bool gt = Signed ? (sint32)a > (sint32)b : a > b;
		const bool eq = a == b;
		const uint8 so = hCPU->xer_so;
		ppc_setCRField(hCPU, e->r2, lt, gt, eq, so);
		const PPCTBEntry* br = e + 1;
		const uint32 bo = br->r0, bi = br->r1;
		bool bit;
		if ((bi >> 2) == e->r2)
		{
			const uint32 sub = bi & 3;
			bit = sub == CR_BIT_LT ? lt : sub == CR_BIT_GT ? gt : sub == CR_BIT_EQ ? eq : so;
		}
		else
			bit = hCPU->cr[bi];
		const bool taken = (bo & 16) || (bit == ((bo & 8) != 0));
		if constexpr (Side)
		{
			if (!taken)
				[[clang::musttail]] return e[2].fn(hCPU, e + 2, pr1);
			hCPU->remainingCycles += br->r2;
			IRIDIA_CNT_SIDE(hCPU, br);
			hCPU->instructionPointer = br->imm;
		}
		else
			hCPU->instructionPointer = taken ? br->imm : br->address + 4;
		if (const PPCTBEntry* next = tbNextBlock(hCPU))
			[[clang::musttail]] return next->fn(hCPU, next, pr1);
	}
	// Iridia: fused fcmpu + conditional branch, like tbCmpBc. Same CR field, FPSCR (FPCC, VXSNAN) and branch as
	// running PPCInterpreter_FCMPU then the bc. e: the compare (r0 = frA, r1 = frB, r2 = CR field). e[1]: the branch.
	template <bool Side>
	TB_CC static void tbFcmpuBc(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		const double a = hCPU->fpr[e->r0].fp0, b = hCPU->fpr[e->r1].fp0;
		const uint64 ia = *(const uint64*)&a, ib = *(const uint64*)&b;
		const bool un = IS_NAN(ia) || IS_NAN(ib);
		const bool lt = !un && a < b;
		const bool gt = !un && a > b;
		const bool eq = !un && !lt && !gt;
		ppc_setCRField(hCPU, e->r2, lt, gt, eq, un);
		if (IS_SNAN(ia) || IS_SNAN(ib))
			hCPU->fpscr |= FPSCR_VXSNAN;
		const uint32 c = un ? 1 : lt ? 8 : gt ? 4 : 2;
		hCPU->fpscr = (hCPU->fpscr & 0xffff0fff) | (c << 12);
		const PPCTBEntry* br = e + 1;
		const uint32 bo = br->r0, bi = br->r1;
		bool bit;
		if ((bi >> 2) == e->r2)
		{
			const uint32 sub = bi & 3;
			bit = sub == CR_BIT_LT ? lt : sub == CR_BIT_GT ? gt : sub == CR_BIT_EQ ? eq : un;
		}
		else
			bit = hCPU->cr[bi];
		const bool taken = (bo & 16) || (bit == ((bo & 8) != 0));
		if constexpr (Side)
		{
			if (!taken)
				[[clang::musttail]] return e[2].fn(hCPU, e + 2, pr1);
			hCPU->remainingCycles += br->r2;
			IRIDIA_CNT_SIDE(hCPU, br);
			hCPU->instructionPointer = br->imm;
		}
		else
			hCPU->instructionPointer = taken ? br->imm : br->address + 4;
		if (const PPCTBEntry* next = tbNextBlock(hCPU))
			[[clang::musttail]] return next->fn(hCPU, next, pr1);
	}
	// Plain bc (no LK, AA or CTR update) inside a block: not taken goes on to the next step; taken
	// refunds the rest of the block's cycles (r2) and leaves. imm = target, r0 = BO, r1 = BI.
	TB_CC static void tbBcSide(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		const uint32 bo = e->r0;
		const bool taken = (bo & 16) || ((hCPU->cr[e->r1] != 0) == ((bo & 8) != 0));
		if (!taken)
			[[clang::musttail]] return e[1].fn(hCPU, e + 1, pr1);
		hCPU->remainingCycles += e->r2;
		IRIDIA_CNT_SIDE(hCPU, e);
		hCPU->instructionPointer = e->imm;
		if (const PPCTBEntry* next = tbNextBlock(hCPU))
			[[clang::musttail]] return next->fn(hCPU, next, pr1);
	}
	// Conditional blr (no LK, no CTR update) inside a block, like tbBcSide; taken jumps to LR.
	TB_CC static void tbBclrSide(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		const uint32 bo = e->r0;
		const bool taken = (bo & 16) || ((hCPU->cr[e->r1] != 0) == ((bo & 8) != 0));
		if (!taken)
			[[clang::musttail]] return e[1].fn(hCPU, e + 1, pr1);
		hCPU->remainingCycles += e->r2;
		IRIDIA_CNT_SIDE(hCPU, e);
		hCPU->instructionPointer = hCPU->spr.LR & 0xfffffffc;
		IRIDIA_CNT_EXITKIND(1);
		if (const PPCTBEntry* next = tbNextBlock(hCPU))
			[[clang::musttail]] return next->fn(hCPU, next, pr1);
	}
	// Iridia: the byte copy loop `lbzu rX,1(rS) / stbu rX,1(rD) / bdnz -8` (LZ-style decompressors: copy a
	// back-reference) as one block of one step. Runs up to 4096 iterations at once with the loop's exact result:
	// bytes go in forward order (a destination that overlaps the source just ahead of it repeats bytes, as the
	// loop does), registers end as after the last iteration, and each iteration costs its 3 cycles. Operands:
	// r0 = rX, r1 = rS, r2 = rD (all different, rS and rD not r0), address = the loop start.
	TB_CC static void tbByteCopyLoop(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		const uint32 ctr = hCPU->spr.CTR;
		uint32 n = ctr == 0 ? 1 : std::min<uint32>(ctr, 4096); // CTR = 0 means 2^32 iterations: one per step
		const uint32 s = hCPU->gpr[e->r1] + 1, d = hCPU->gpr[e->r2] + 1;
		if ((uint64)s + n > 0x100000000ull || (uint64)d + n > 0x100000000ull)
			n = 1; // would wrap around the address space: one iteration at a time
		uint8* src = memory_base + s;
		uint8* dst = memory_base + d;
		if (d - s >= n)
			memmove(dst, src, n); // destination not inside (src, src + n): same as the forward byte loop
		else
			for (uint32 i = 0; i < n; i++)
				dst[i] = src[i];
		hCPU->gpr[e->r0] = dst[n - 1];
		hCPU->gpr[e->r1] = s + n - 1;
		hCPU->gpr[e->r2] = d + n - 1;
		hCPU->spr.CTR = ctr - n;
		hCPU->remainingCycles -= (sint32)(3 * (n - 1)); // entering the block charged one iteration
		hCPU->instructionPointer = (ctr - n) != 0 ? e->address : e->address + 12;
		if (const PPCTBEntry* next = tbNextBlock(hCPU))
			[[clang::musttail]] return next->fn(hCPU, next, hCPU->gpr[1]);
	}
	// lbzu rX,1(rS) / stbu rX,1(rD) / bdnz -8 with usable registers?
	static bool tbIsByteCopyLoop(uint32 op0, uint32 op1, uint32 op2, PPCTBEntry& out, uint32 address)
	{
		if ((op0 >> 26) != 35 || (op0 & 0xFFFF) != 1 || (op1 >> 26) != 39 || (op1 & 0xFFFF) != 1 || op2 != 0x4200FFF8)
			return false;
		const uint32 rX = (op0 >> 21) & 31, rS = (op0 >> 16) & 31, rX2 = (op1 >> 21) & 31, rD = (op1 >> 16) & 31;
		if (rX != rX2 || rS == 0 || rD == 0 || rS == rX || rD == rX || rS == rD)
			return false;
		out = { &tbByteCopyLoop, op0, address, 0, (uint8)rX, (uint8)rS, (uint8)rD, 0 };
		return true;
	}
	static bool tbFcmpuFuseOn() // IRIDIA_FCMPU_FUSE=0 turns the fused fcmpu + bc off (A/B)
	{
		static const bool v = !(iridia_getenv("IRIDIA_FCMPU_FUSE") && iridia_getenv("IRIDIA_FCMPU_FUSE")[0] == '0');
		return v;
	}
	// The compare + branch pair at a and a + 4, if it can be fused.
	static PPCTBFn tbFuseCmpBc(uint32 cmp, uint32 bc, uint32 a, PPCTBEntry& ce, PPCTBEntry& be, bool side)
	{
		if ((bc >> 26) != 16 || (bc & (PPC_OPC_AA | PPC_OPC_LK)))
			return nullptr;
		uint32 BO, BI, BD;
		PPC_OPC_TEMPL_B(bc, BO, BI, BD);
		if (!(BO & 4))
			return nullptr; // decrements CTR
		PPCTBFn fn;
		const uint32 primary = cmp >> 26;
		const uint32 crf = (cmp >> 23) & 7, rA = (cmp >> 16) & 0x1f, rB = (cmp >> 11) & 0x1f;
		uint32 imm = 0;
		if (primary == 11) { fn = side ? &tbCmpBc<true, true, true> : &tbCmpBc<true, true, false>; imm = (uint32)(sint32)(sint16)(cmp & 0xffff); }
		else if (primary == 10) { fn = side ? &tbCmpBc<false, true, true> : &tbCmpBc<false, true, false>; imm = cmp & 0xffff; }
		else if (primary == 31 && ((cmp >> 1) & 0x3ff) == 0) fn = side ? &tbCmpBc<true, false, true> : &tbCmpBc<true, false, false>;
		else if (primary == 31 && ((cmp >> 1) & 0x3ff) == 32) fn = side ? &tbCmpBc<false, false, true> : &tbCmpBc<false, false, false>;
		else if (primary == 63 && (cmp & 0x7ff) == 0 && !((cmp >> 21) & 3) && tbFcmpuFuseOn()) fn = side ? &tbFcmpuBc<true> : &tbFcmpuBc<false>; // fcmpu (crfD low bits 0)
		else return nullptr;
		ce = { fn, cmp, a, imm, (uint8)rA, (uint8)rB, (uint8)crf, 0 };
		be = { nullptr, bc, a + 4, a + 4 + BD, (uint8)BO, (uint8)BI, 0, 0 };
		return fn;
	}

	// IRIDIA_PS_FAST=0 is the off switch for the paired-single work: stock paired-single handlers and narrow psq_l /
	// psq_st steps. Read once, when the first block is built (after the phone app's -cafeEnv has set it; a static
	// initializer would run before that); only the decoder looks at it, never a step.
	static bool tbPsFastOn() { static const bool v = [] { const char* s = iridia_getenv("IRIDIA_PS_FAST"); return !(s && s[0] == '0'); }(); return v; }
	static bool tbSpecializeUnpinned(uint32 opcode, PPCTBEntry& e)
	{
		switch (opcode >> 26)
		{
		case 21: // rlwinm
		{
			sint32 rS, rA, SH, MB, ME;
			PPC_OPC_TEMPL_M(opcode, rS, rA, SH, MB, ME);
			e.imm = ppc_mask(MB, ME); e.r0 = rS; e.r1 = rA; e.r2 = SH;
			e.fn = (opcode & 1) ? &tbOne<&bRlwinmRc> : SH ? &tbOne<&bRlwinm> : &tbOne<&bRlwinmMask>;
			return true;
		}
		case 14: // addi
		case 15: // addis
		{
			sint32 rD, rA;
			uint32 imm;
			if ((opcode >> 26) == 14) { PPC_OPC_TEMPL_D_SImm(opcode, rD, rA, imm); }
			else { PPC_OPC_TEMPL_D_Shift16(opcode, rD, rA, imm); }
			e.imm = imm; e.r0 = rD; e.r1 = rA;
			e.fn = rA ? &tbOne<&bAddImm> : &tbOne<&bLoadImm>;
			return true;
		}
		case 24: // ori
		{
			int rS, rA;
			uint32 imm;
			PPC_OPC_TEMPL_D_UImm(opcode, rS, rA, imm);
			e.imm = imm; e.r0 = rS; e.r1 = rA;
			e.fn = &tbOne<&bOri>;
			return true;
		}
		case 32: // lwz
		{
			sint32 rD, rA;
			uint32 imm;
			PPC_OPC_TEMPL_D_SImm(opcode, rD, rA, imm);
			e.imm = imm; e.r0 = rD; e.r1 = rA;
			e.fn = &tbOne<&bLwz>;
			return true;
		}
		case 48: // lfs
		case 52: // stfs
		{
			sint32 fr, rA;
			uint32 imm;
			PPC_OPC_TEMPL_D_SImm(opcode, fr, rA, imm);
			e.imm = imm; e.r0 = fr; e.r1 = rA;
			e.fn = ((opcode >> 26) == 48) ? &tbOne<&bLfs> : &tbOne<&bStfs>;
			return true;
		}
		case 4: // paired-single math (the stock handlers ignore Rc, and so do these)
		{
			if (!tbPsFastOn())
				return false;
			e.r0 = (opcode >> 21) & 0x1f; e.r1 = (opcode >> 16) & 0x1f; e.r2 = (opcode >> 11) & 0x1f; e.r3 = (opcode >> 6) & 0x1f;
			switch ((opcode >> 1) & 0x1f)
			{
			case 8:
				switch ((opcode >> 6) & 0x1f)
				{
				case 1: e.fn = &tbOne<&bPsNeg>; return true;
				case 2: e.fn = &tbOne<&bPsMr>; return true;
				case 4: e.fn = &tbOne<&bPsNabs>; return true;
				case 8: e.fn = &tbOne<&bPsAbs>; return true;
				}
				return false;
			case 10: e.fn = &tbOne<&bPsSum0>; return true;
			case 11: e.fn = &tbOne<&bPsSum1>; return true;
			case 12: e.fn = &tbOne<&bPsMuls0>; return true;
			case 13: e.fn = &tbOne<&bPsMuls1>; return true;
			case 14: e.fn = &tbOne<&bPsMadds0>; return true;
			case 15: e.fn = &tbOne<&bPsMadds1>; return true;
			case 16:
				switch ((opcode >> 6) & 0x1f)
				{
				case 16: e.fn = &tbOne<&bPsMerge00>; return true;
				case 17: e.fn = &tbOne<&bPsMerge01>; return true;
				case 18: e.fn = &tbOne<&bPsMerge10>; return true;
				case 19: e.fn = &tbOne<&bPsMerge11>; return true;
				}
				return false;
			case 18: e.fn = &tbOne<&bPsDiv>; return true;
			case 20: e.fn = &tbOne<&bPsSub>; return true;
			case 21: e.fn = &tbOne<&bPsAdd>; return true;
			case 23: e.fn = &tbOne<&bPsSel>; return true;
			case 25: e.fn = &tbOne<&bPsMul>; return true;
			case 28: e.fn = &tbOne<&bPsMsub>; return true;
			case 29: e.fn = &tbOne<&bPsMadd>; return true;
			case 30: e.fn = &tbOne<&bPsNmsub>; return true;
			case 31: e.fn = &tbOne<&bPsNmadd>; return true;
			}
			return false;
		}
		case 56: // psq_l
		case 60: // psq_st
		{
			e.r0 = (opcode >> 21) & 0x1f; e.r1 = (opcode >> 16) & 0x1f; e.r2 = (opcode >> 12) & 7; e.r3 = (opcode & 0x8000) ? 1 : 0;
			e.imm = (uint32)(((sint32)(opcode << 20)) >> 20);
			if (tbPsFastOn())
				e.fn = ((opcode >> 26) == 56) ? &tbOne<&bPsqL> : &tbOne<&bPsqSt>;
			else
				e.fn = ((opcode >> 26) == 56) ? &tbOne<&bPsqLN> : &tbOne<&bPsqStN>;
			return true;
		}
		case 31:
		{
			const uint32 rD = (opcode >> 21) & 0x1f, rA = (opcode >> 16) & 0x1f, rB = (opcode >> 11) & 0x1f;
			const uint32 xo = (opcode >> 1) & 0x3ff;
			if ((opcode & 0x7ff) == (444 << 1)) // or (no Rc)
			{
				e.r0 = rD; e.r1 = rA; e.r2 = rB;
				e.fn = &tbOne<&bOr>;
				return true;
			}
			if (opcode & 1)
				return false; // Rc forms keep the original handlers
			e.r0 = rD; e.r1 = rA; e.r2 = rB;
			const uint32 spr = rA | (rB << 5);
			switch (xo)
			{
			case 266: e.fn = &tbOne<&bAdd>; return true;  // add (no OE)
			case 40: e.fn = &tbOne<&bSubf>; return true;  // subf (no OE)
			case 0: case 32: // cmp / cmpl (L = 0)
				if (opcode & (1 << 21)) return false;
				e.r1 = rA; e.r2 = rB; e.r3 = rD >> 2;
				e.fn = xo == 0 ? &tbOne<&bCmp<true, false>> : &tbOne<&bCmp<false, false>>;
				return true;
			case 467: // mtspr
				if (spr == 8) { e.fn = &tbOne<&bMtlr>; return true; }
				if (spr == 9) { e.fn = &tbOne<&bMtctr>; return true; }
				return false;
			case 339: // mfspr
				if (spr == 8) { e.fn = &tbOne<&bMflr>; return true; }
				if (spr == 9) { e.fn = &tbOne<&bMfctr>; return true; }
				return false;
			}
			return false;
		}
		case 7: // mulli
		case 37: // stwu
		case 34: // lbz
		case 40: // lhz
		case 38: // stb
		case 44: // sth
		case 50: // lfd
		case 54: // stfd
		{
			sint32 rD, rA;
			uint32 imm;
			PPC_OPC_TEMPL_D_SImm(opcode, rD, rA, imm);
			e.imm = imm; e.r0 = rD; e.r1 = rA;
			switch (opcode >> 26)
			{
			case 7: e.fn = &tbOne<&bMulli>; break;
			case 37: e.fn = &tbOne<&bStwu>; break;
			case 34: e.fn = &tbOne<&bLbz>; break;
			case 40: e.fn = &tbOne<&bLhz>; break;
			case 38: e.fn = &tbOne<&bStb>; break;
			case 44: e.fn = &tbOne<&bSth>; break;
			case 50: e.fn = &tbOne<&bLfd>; break;
			case 54: e.fn = &tbOne<&bStfd>; break;
			}
			return true;
		}
		case 10: // cmpli
		case 11: // cmpi
		{
			if (opcode & (1 << 21)) return false; // L = 1
			e.r1 = (opcode >> 16) & 0x1f; e.r3 = (opcode >> 23) & 7;
			e.imm = (opcode >> 26) == 11 ? (uint32)(sint32)(sint16)(opcode & 0xffff) : (opcode & 0xffff);
			e.fn = (opcode >> 26) == 11 ? &tbOne<&bCmp<true, true>> : &tbOne<&bCmp<false, true>>;
			return true;
		}
		case 36: // stw
		{
			sint32 rS, rA;
			uint32 imm;
			PPC_OPC_TEMPL_D_SImm(opcode, rS, rA, imm);
			if (rA == 0)
				return false; // odd form: keep the original handler
			e.imm = imm; e.r0 = rS; e.r1 = rA;
			e.fn = &tbOne<&bStw>;
			return true;
		}
		}
		return false;
	}
	// Iridia study: IRIDIA_PS_SELFTEST=<millions of cases per op> runs the specialized paired-single steps and the
	// psq_l / psq_st steps against the stock handlers (PPCInterpreterPS.cpp, PPCInterpreter_PSQ_L / _ST) from the same
	// random states, with the core thread's FPCR (flush-to-zero on) and again with flush-to-zero off, compares every
	// FPR bit, FPSCR, CR and the stored bytes, prints one line per op and exits. Inputs: float values, float and
	// double denormals, +-0, +-inf, quiet and signalling NaNs with random payloads, float rounding ties and their
	// neighbours, raw random bits. Also checks tbRound25 against roundTo25BitAccuracy. Called from BuildBlock. With
	// IRIDIA_PS_FAST=0 it checks the narrow psq steps; the paired-single ops are then not specialized and are reported
	// as skipped (an op that fails to specialize with the switch on counts as a mismatch).
#if defined(__aarch64__)
	TB_CC static void tbTestStop(PPCInterpreter_t*, const PPCTBEntry*, uint32) {}
	static void tbPsSelfTest(PPCInterpreter_t* live)
	{
		const char* env = iridia_getenv("IRIDIA_PS_SELFTEST");
		const uint64 n = (uint64)std::max(1L, strtol(env, nullptr, 10)) * 1000000;
		uint64 rs = 0x9e3779b97f4a7c15ULL;
		auto rnd = [&] { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; };
		auto fval = [&]() -> uint32 { // float bit patterns
			const uint32 r = rnd(), k = (uint32)(rnd() % 16), sign = r & 0x80000000;
			switch (k)
			{
			case 0: return sign | (r & 0x007fffff);                                      // denormal (or 0)
			case 1: return sign | 0x7f800000 | (r & 0x007fffff);                         // inf / NaN, any payload
			case 2: return sign | 0x7fc00000 | (r & 0x003fffff);                         // quiet NaN
			case 3: return sign | ((r & 1) ? 0 : 0x7f800000);                            // +-0 / +-inf
			case 4: return sign | ((uint32)(1 + rnd() % 3) << 23) | (r & 0x007fffff);   // tiny normals
			case 5: return sign | ((uint32)(250 + rnd() % 4) << 23) | (r & 0x007fffff); // huge normals
			case 6: return r;
			default: return sign | ((uint32)(100 + rnd() % 56) << 23) | (r & 0x007fffff); // ordinary values
			}
		};
		auto dval = [&]() -> uint64 { // double bit patterns as they sit in an FPR
			const uint32 k = (uint32)(rnd() % 16);
			const uint64 r = rnd(), sign = r & (1ULL << 63);
			const uint64 f = std::bit_cast<uint64>((double)std::bit_cast<float>(fval()));
			switch (k)
			{
			case 0: return r;                                                             // raw bits
			case 1: return sign | (r & 0x000fffffffffffffULL);                           // double denormal
			case 2: return sign | 0x7ff0000000000000ULL | (r & 0x000fffffffffffffULL);   // double inf / NaN
			case 3: return f ^ (1ULL << 28);                                              // float rounding tie
			case 4: return (f ^ (1ULL << 28)) + 1;                                        // just above a tie
			case 5: return (f ^ (1ULL << 28)) - 1;                                        // just below a tie
			case 6: return f | (1ULL << 27);                                              // round-to-25-bit tie
			case 7: return sign | ((uint64)(1023 - 126 - (rnd() % 30)) << 52) | (r & 0x000fffffffffffffULL); // around float denormals
			case 8: return sign | ((uint64)(1023 + 120 + (rnd() % 16)) << 52) | (r & 0x000fffffffffffffULL); // around float overflow
			case 9: return f + (r & 0x0fffffff);                                          // not a float
			default: return f;                                                            // a float value
			}
		};
		uint64 bad25 = 0;
		for (uint64 i = 0; i < n * 20; i++)
		{
			uint64 v = rnd();
			if (i < 64) v = (i & 1 ? ~0ULL : 0) ^ (((1ULL << 27) - 1) << (i / 2 % 32)); // edges, carries
			FPR_t r; r.fp0int = v; r.fp1int = ~v;
			const TbD2 c = tbRound25x2(r);
			if (std::bit_cast<uint64>(roundTo25BitAccuracy(std::bit_cast<double>(v))) != std::bit_cast<uint64>(tbRound25(std::bit_cast<double>(v))) ||
				std::bit_cast<uint64>(roundTo25BitAccuracy(r.fp0)) != std::bit_cast<uint64>(c.a) || std::bit_cast<uint64>(roundTo25BitAccuracy(r.fp1)) != std::bit_cast<uint64>(c.b))
				bad25++;
		}
		fprintf(stderr, "IRIDIA_PS_SELFTEST round25 %llu inputs (scalar and 2-lane), %llu mismatches\n", (unsigned long long)(n * 40), (unsigned long long)bad25);
		struct Op { const char* name; uint32 xo; PPCInstrFn stock; };
		static const Op ops[] = {
			{ "ps_neg", 40 << 1, &PPCInterpreter_PS_NEG }, { "ps_mr", 72 << 1, &PPCInterpreter_PS_MR }, { "ps_nabs", 136 << 1, &PPCInterpreter_PS_NABS },
			{ "ps_abs", 264 << 1, &PPCInterpreter_PS_ABS }, { "ps_sum0", 10 << 1, &PPCInterpreter_PS_SUM0 }, { "ps_sum1", 11 << 1, &PPCInterpreter_PS_SUM1 },
			{ "ps_muls0", 12 << 1, &PPCInterpreter_PS_MULS0 }, { "ps_muls1", 13 << 1, &PPCInterpreter_PS_MULS1 }, { "ps_madds0", 14 << 1, &PPCInterpreter_PS_MADDS0 },
			{ "ps_madds1", 15 << 1, &PPCInterpreter_PS_MADDS1 }, { "ps_merge00", 528 << 1, &PPCInterpreter_PS_MERGE00 }, { "ps_merge01", 560 << 1, &PPCInterpreter_PS_MERGE01 },
			{ "ps_merge10", 592 << 1, &PPCInterpreter_PS_MERGE10 }, { "ps_merge11", 624 << 1, &PPCInterpreter_PS_MERGE11 }, { "ps_div", 18 << 1, &PPCInterpreter_PS_DIV },
			{ "ps_sub", 20 << 1, &PPCInterpreter_PS_SUB }, { "ps_add", 21 << 1, &PPCInterpreter_PS_ADD }, { "ps_sel", 23 << 1, &PPCInterpreter_PS_SEL },
			{ "ps_mul", 25 << 1, &PPCInterpreter_PS_MUL }, { "ps_msub", 28 << 1, &PPCInterpreter_PS_MSUB }, { "ps_madd", 29 << 1, &PPCInterpreter_PS_MADD },
			{ "ps_nmsub", 30 << 1, &PPCInterpreter_PS_NMSUB }, { "ps_nmadd", 31 << 1, &PPCInterpreter_PS_NMADD },
		};
		auto* a = (PPCInterpreter_t*)malloc(sizeof(PPCInterpreter_t));
		auto* b = (PPCInterpreter_t*)malloc(sizeof(PPCInterpreter_t));
		auto same = [&] { return memcmp(a->fpr, b->fpr, sizeof(a->fpr)) == 0 && a->fpscr == b->fpscr && memcmp(a->cr, b->cr, sizeof(a->cr)) == 0; };
		auto randomize = [&] { memcpy(a, live, sizeof(PPCInterpreter_t)); for (int r = 0; r < 8; r++) { a->fpr[r].fp0int = dval(); a->fpr[r].fp1int = dval(); } };
		const uint64 fpcr0 = __arm_rsr64("fpcr");
		uint64 total = 0, skippedOps = 0;
		for (int pass = 0; pass < 2; pass++)
		{
			const uint64 fpcr = pass == 0 ? fpcr0 : (fpcr0 & ~(1ULL << 24));
			__arm_wsr64("fpcr", fpcr);
			for (const Op& op : ops)
			{
				uint64 bad = 0, skipped = 0;
				for (uint64 i = 0; i < n; i++)
				{
					const uint32 frC = op.xo > (31 << 1) ? 0 : (uint32)(rnd() % 8) << 6; // X-form ops: those bits are the extended opcode
					const uint32 opcode = (4u << 26) | ((uint32)(rnd() % 8) << 21) | ((uint32)(rnd() % 8) << 16) | ((uint32)(rnd() % 8) << 11) | frC | op.xo | (uint32)(rnd() & 1);
					randomize();
					memcpy(b, a, sizeof(PPCInterpreter_t));
					op.stock(a, opcode);
					PPCTBEntry e[2] = { { nullptr, opcode, 0, 0, 0, 0, 0, 0 }, { &tbTestStop, 0, 0, 0, 0, 0, 0, 0 } };
					if (!tbSpecializeUnpinned(opcode, e[0])) { if (tbPsFastOn()) bad++; else skipped++; continue; }
					e[0].fn(b, e, b->gpr[1]);
					if (!same() && bad++ < 3)
						fprintf(stderr, "IRIDIA_PS_SELFTEST mismatch %s op %08x\n", op.name, opcode);
				}
				total += bad;
				if (skipped)
				{
					skippedOps++;
					fprintf(stderr, "IRIDIA_PS_SELFTEST fz=%d %-10s skipped (not specialized, IRIDIA_PS_FAST=0), %llu mismatches\n", (int)((fpcr >> 24) & 1), op.name, (unsigned long long)bad);
				}
				else
					fprintf(stderr, "IRIDIA_PS_SELFTEST fz=%d %-10s %llu cases, %llu mismatches\n", (int)((fpcr >> 24) & 1), op.name, (unsigned long long)n, (unsigned long long)bad);
			}
			// psq_l / psq_st: every GQR type and scale, W = 0 and 1, unaligned addresses in the guest stack area
			const uint32 base = (live->gpr[1] - 0x2000) & ~0xfffu;
			for (int st = 0; st < 2; st++)
			{
				uint64 bad = 0, pairs = 0;
				for (uint64 i = 0; i < n; i++)
				{
					randomize();
					const uint32 gqrIdx = (uint32)(rnd() % 8);
					const uint32 type = (rnd() % 4) ? 0 : (uint32)(rnd() % 8), scale = (uint32)(rnd() % 64);
					a->spr.UGQR[gqrIdx] = st ? (type | (scale << 8)) : ((type << 16) | (scale << 24));
					const uint32 w = (uint32)(rnd() % 4 == 0), off = (uint32)(rnd() % 0x400), rA = 3 + (uint32)(rnd() % 4);
					a->gpr[rA] = base + 0x200;
					const uint32 d = (off - 0x200) & 0xfff;
					const uint32 opcode = ((st ? 60u : 56u) << 26) | ((uint32)(rnd() % 8) << 21) | (rA << 16) | (w << 15) | (gqrIdx << 12) | d;
					for (uint32 k = 0; k < 0x410; k += 4)
						*(uint32*)(memory_base + base + k) = (rnd() % 2) ? fval() : (uint32)rnd();
					memcpy(b, a, sizeof(PPCInterpreter_t));
					uint8 mem0[0x410], memA[0x410];
					memcpy(mem0, memory_base + base, sizeof(mem0));
					if (st) PPCInterpreter_PSQ_ST(a, opcode); else PPCInterpreter_PSQ_L(a, opcode);
					memcpy(memA, memory_base + base, sizeof(memA));
					memcpy(memory_base + base, mem0, sizeof(mem0)); // b starts from the same memory
					PPCTBEntry e[2] = { { nullptr, opcode, 0, 0, 0, 0, 0, 0 }, { &tbTestStop, 0, 0, 0, 0, 0, 0, 0 } };
					(void)tbSpecializeUnpinned(opcode, e[0]);
					pairs += !w && !(a->spr.UGQR[gqrIdx] & (st ? 4u : 4u << 16));
					e[0].fn(b, e, b->gpr[1]);
					const bool memSame = memcmp(memA, memory_base + base, sizeof(memA)) == 0;
					if ((!same() || !memSame) && bad++ < 3)
						fprintf(stderr, "IRIDIA_PS_SELFTEST mismatch %s op %08x gqr %08x\n", st ? "psq_st" : "psq_l", opcode, a->spr.UGQR[gqrIdx]);
				}
				total += bad;
				fprintf(stderr, "IRIDIA_PS_SELFTEST fz=%d %-10s %llu cases (%llu float pairs), %llu mismatches\n", (int)((fpcr >> 24) & 1), st ? "psq_st" : "psq_l", (unsigned long long)n, (unsigned long long)pairs, (unsigned long long)bad);
			}
		}
		__arm_wsr64("fpcr", fpcr0);
		fprintf(stderr, "IRIDIA_PS_SELFTEST done, %llu mismatches in total, %llu op lines skipped (fpcr %llx)\n", (unsigned long long)total, (unsigned long long)skippedOps, (unsigned long long)fpcr0);
		fflush(stderr);
		_exit(total || bad25 ? 1 : 0);
	}
#endif
	// Specialized step with pinned r1 (see PPCTBFn): r1-based loads and stores take a pinned variant; a step that
	// writes r1 without one is refused, so the stock handler runs it (and reloads pr1).
	static bool tbSpecialize(uint32 opcode, PPCTBEntry& e)
	{
		if (!tbSpecializeUnpinned(opcode, e))
			return false;
		// IRIDIA_TB_PIN=0 never picks the pinned variants at run time (same as -DIRIDIA_TB_NO_PIN; one binary for
		// phone A/Bs). Read once; only consulted when a block is built.
		static const bool s_pin = [] { const char* v = iridia_getenv("IRIDIA_TB_PIN"); return !(v && v[0] == '0'); }();
		if (!s_pin)
			return true;
		const uint32 primary = opcode >> 26, rD = (opcode >> 21) & 0x1f, rA = (opcode >> 16) & 0x1f;
		if (rA == 1)
		{
			switch (primary)
			{
			case 32: if (rD == 1) return false; e.fn = &tbOne<&bLwzP>; return true;
			case 34: if (rD == 1) return false; e.fn = &tbOne<&bLbzP>; return true;
			case 40: if (rD == 1) return false; e.fn = &tbOne<&bLhzP>; return true;
			case 14: case 15: e.fn = rD == 1 ? &tbOne<&bAddImmPP> : &tbOne<&bAddImmP>; return true;
			case 36: e.fn = &tbOne<&bStwP>; return true;
			case 37: e.fn = &tbOne<&bStwuP>; return true;
			case 38: e.fn = &tbOne<&bStbP>; return true;
			case 44: e.fn = &tbOne<&bSthP>; return true;
			case 48: e.fn = &tbOne<&bLfsP>; return true;
			case 52: e.fn = &tbOne<&bStfsP>; return true;
			case 50: e.fn = &tbOne<&bLfdP>; return true;
			case 54: e.fn = &tbOne<&bStfdP>; return true;
			case 56: e.fn = tbPsFastOn() ? &tbOne<&bPsqLP> : &tbOne<&bPsqLPN>; return true;
			case 60: e.fn = tbPsFastOn() ? &tbOne<&bPsqStP> : &tbOne<&bPsqStPN>; return true;
			}
		}
		// the general register this specialized step writes (-1: none)
		sint32 written = -1;
		switch (primary)
		{
		case 21: case 24: case 37: written = (sint32)rA; break; // rlwinm, ori: rA; stwu: the updated base
		case 7: case 14: case 15: case 32: case 34: case 40: written = (sint32)rD; break;
		case 31:
		{
			const uint32 xo = (opcode >> 1) & 0x3ff;
			if (xo == 444) written = (sint32)rA; // or
			else if (xo == 266 || xo == 40 || xo == 339) written = (sint32)rD; // add, subf, mflr / mfctr
			break;
		}
		}
		return written != 1;
	}
#include "PPCInterpreterDecode.hpp"
#endif

	static void executeInstruction(PPCInterpreter_t* hCPU)
	{
		if constexpr(ppcItpCtrl::allowSupervisorMode)
		{
			hCPU->global->tb++;
		}

#ifdef __DEBUG_OUTPUT_INSTRUCTION
		debug_printf("%08x: ", hCPU->instructionPointer);
#endif

		uint32 opcode = ppcItpCtrl::memory_readCodeU32(hCPU, hCPU->instructionPointer);

		switch ((opcode >> 26))
		{
		case 0:
			debug_printf("ZERO[NOP] | 0x%08X\n", (unsigned int)hCPU->instructionPointer);
	#ifdef CEMU_DEBUG_ASSERT		
			assert_dbg();
			while (true) std::this_thread::sleep_for(std::chrono::seconds(1));
	#endif
			hCPU->instructionPointer += 4;
			break;
		case 1: // virtual HLE
			PPCInterpreter_virtualHLE(hCPU, opcode);
			break;
		case 3:
			cemuLog_logDebug(LogType::Force, "Unsupported TWI instruction executed at {:08x}", hCPU->instructionPointer);
			PPCInterpreter_nextInstruction(hCPU);
			break;
		case 4:
			switch (PPC_getBits(opcode, 30, 5))
			{
			case 0: // subcategory compare
				switch (PPC_getBits(opcode, 25, 5))
				{
				case 0: // Sonic All Stars Racing
					PPCInterpreter_PS_CMPU0(hCPU, opcode);
					break;
				case 1:
					PPCInterpreter_PS_CMPO0(hCPU, opcode);
					break;
				case 2: // Assassin's Creed 3, Sonic All Stars Racing
					PPCInterpreter_PS_CMPU1(hCPU, opcode);
					break;
				default:
					cemuLog_logDebug(LogType::Force, "Unknown execute {:04x} as [4->0] at {:08x}", PPC_getBits(opcode, 25, 5), hCPU->instructionPointer);
					cemu_assert_unimplemented();
					hCPU->instructionPointer += 4;
					break;
				}
				break;
			case 6:
				PPCInterpreter_PSQ_LX(hCPU, opcode);
				break;
			case 7:
				PPCInterpreter_PSQ_STX(hCPU, opcode);
				break;
			case 8:
				switch (PPC_getBits(opcode, 25, 5))
				{
				case 1:
					PPCInterpreter_PS_NEG(hCPU, opcode);
					break;
				case 2:
					PPCInterpreter_PS_MR(hCPU, opcode);
					break;
				case 4:
					PPCInterpreter_PS_NABS(hCPU, opcode);
					break;
				case 8:
					PPCInterpreter_PS_ABS(hCPU, opcode);
					break;
				default:
					cemuLog_logDebug(LogType::Force, "Unknown execute {:04x} as [4->8] at {:08x}", PPC_getBits(opcode, 25, 5), hCPU->instructionPointer);
					cemu_assert_unimplemented();
					hCPU->instructionPointer += 4;
					break;
				}
				break;
			case 10:
				PPCInterpreter_PS_SUM0(hCPU, opcode);
				break;
			case 11:
				PPCInterpreter_PS_SUM1(hCPU, opcode);
				break;
			case 12:
				PPCInterpreter_PS_MULS0(hCPU, opcode);
				break;
			case 13:
				PPCInterpreter_PS_MULS1(hCPU, opcode);
				break;
			case 14:
				PPCInterpreter_PS_MADDS0(hCPU, opcode);
				break;
			case 15:
				PPCInterpreter_PS_MADDS1(hCPU, opcode);
				break;
			case 16: // sub category - merge
				switch (PPC_getBits(opcode, 25, 5))
				{
				case 16:
					PPCInterpreter_PS_MERGE00(hCPU, opcode);
					break;
				case 17:
					PPCInterpreter_PS_MERGE01(hCPU, opcode);
					break;
				case 18:
					PPCInterpreter_PS_MERGE10(hCPU, opcode);
					break;
				case 19:
					PPCInterpreter_PS_MERGE11(hCPU, opcode);
					break;
				default:
					cemuLog_logDebug(LogType::Force, "Unknown execute {:04x} as [4->16] at {:08x}", PPC_getBits(opcode, 25, 5), hCPU->instructionPointer);
					cemu_assert_unimplemented();
					hCPU->instructionPointer += 4;
					break;
				}
				break;
			case 18:
				PPCInterpreter_PS_DIV(hCPU, opcode);
				break;
			case 20:
				PPCInterpreter_PS_SUB(hCPU, opcode);
				break;
			case 21:
				PPCInterpreter_PS_ADD(hCPU, opcode);
				break;
			case 22:
				PPCInterpreter_DCBZL(hCPU, opcode);
				break;
			case 23:
				PPCInterpreter_PS_SEL(hCPU, opcode);
				break;
			case 24:
				PPCInterpreter_PS_RES(hCPU, opcode);
				break;
			case 25:
				PPCInterpreter_PS_MUL(hCPU, opcode);
				break;
			case 26: // sub category with only one entry - RSQRTE
				PPCInterpreter_PS_RSQRTE(hCPU, opcode);
				break;
			case 28:
				PPCInterpreter_PS_MSUB(hCPU, opcode);
				break;
			case 29:
				PPCInterpreter_PS_MADD(hCPU, opcode);
				break;
			case 30:
				PPCInterpreter_PS_NMSUB(hCPU, opcode);
				break;
			case 31:
				PPCInterpreter_PS_NMADD(hCPU, opcode);
				break;
			default:
				cemuLog_logDebug(LogType::Force, "Unknown execute {:04x} as [4] at {:08x}", PPC_getBits(opcode, 30, 5), hCPU->instructionPointer);
				cemu_assert_unimplemented();
				hCPU->instructionPointer += 4;
				break;
			}
			break;
		case 7:
			PPCInterpreter_MULLI(hCPU, opcode);
			break;
		case 8:
			PPCInterpreter_SUBFIC(hCPU, opcode);
			break;
		case 10:
			PPCInterpreter_CMPLI(hCPU, opcode);
			break;
		case 11:
			PPCInterpreter_CMPI(hCPU, opcode);
			break;
		case 12:
			PPCInterpreter_ADDIC(hCPU, opcode);
			break;
		case 13:
			PPCInterpreter_ADDIC_(hCPU, opcode);
			break;
		case 14:
			PPCInterpreter_ADDI(hCPU, opcode);
			break;
		case 15:
			PPCInterpreter_ADDIS(hCPU, opcode);
			break;
		case 16:
			PPCInterpreter_BCX(hCPU, opcode);
			break;
		case 17:
			if (PPC_getBits(opcode, 30, 1) == 1)
			{
				PPCInterpreter_SC(hCPU, opcode);
			}
			else
			{
				cemuLog_logDebug(LogType::Force, "Unsupported Opcode [0x17 --> 0x0]");
				cemu_assert_unimplemented();
				hCPU->instructionPointer += 4;
			}
			break;
		case 18:
			PPCInterpreter_BX(hCPU, opcode);
			break;
		case 19: // opcode category
			switch (PPC_getBits(opcode, 30, 10))
			{
			case 0:
				PPCInterpreter_MCRF(hCPU, opcode);
				break;
			case 16:
				PPCInterpreter_BCLRX(hCPU, opcode);
				break;
			case 33:
				PPCInterpreter_CRNOR(hCPU, opcode);
				break;
			case 50:
				PPCInterpreter_RFI(hCPU, opcode);
				break;
			case 129:
				PPCInterpreter_CRANDC(hCPU, opcode);
				break;
			case 150:
				PPCInterpreter_ISYNC(hCPU, opcode);
				break;
			case 193:
				PPCInterpreter_CRXOR(hCPU, opcode);
				break;
			case 225:
				PPCInterpreter_CRNAND(hCPU, opcode);
				break;
			case 257:
				PPCInterpreter_CRAND(hCPU, opcode);
				break;
			case 289:
				PPCInterpreter_CREQV(hCPU, opcode);
				break;
			case 417:
				PPCInterpreter_CRORC(hCPU, opcode);
				break;
			case 449:
				PPCInterpreter_CROR(hCPU, opcode);
				break;
			case 528:
				PPCInterpreter_BCCTR(hCPU, opcode);
				break;
			default:
				cemuLog_logDebug(LogType::Force, "Unknown execute {:04x} as [19] at {:08x}\n", PPC_getBits(opcode, 30, 10), hCPU->instructionPointer);
				cemu_assert_unimplemented();
				hCPU->instructionPointer += 4;
				break;
			}
			break;
		case 20:
			PPCInterpreter_RLWIMI(hCPU, opcode);
			break;
		case 21:
			PPCInterpreter_RLWINM(hCPU, opcode);
			break;
		case 23:
			PPCInterpreter_RLWNM(hCPU, opcode);
			break;
		case 24:
			PPCInterpreter_ORI(hCPU, opcode);
			break;
		case 25:
			PPCInterpreter_ORIS(hCPU, opcode);
			break;
		case 26:
			PPCInterpreter_XORI(hCPU, opcode);
			break;
		case 27:
			PPCInterpreter_XORIS(hCPU, opcode);
			break;
		case 28:
			PPCInterpreter_ANDI_(hCPU, opcode);
			break;
		case 29:
			PPCInterpreter_ANDIS_(hCPU, opcode);
			break;
		case 31: // opcode category
			switch (PPC_getBits(opcode, 30, 10))
			{
			case 0:
				PPCInterpreter_CMP(hCPU, opcode);
				break;
			case 4:
				PPCInterpreter_TW(hCPU, opcode);
				break;
			case 8:
				PPCInterpreter_SUBFC(hCPU, opcode);
				break;
			case 10:
				PPCInterpreter_ADDC(hCPU, opcode);
				break;
			case 11:
				PPCInterpreter_MULHWU_(hCPU, opcode);
				break;
			case 19:
				PPCInterpreter_MFCR(hCPU, opcode);
				break;
			case 20:
				PPCInterpreter_LWARX(hCPU, opcode);
				break;
			case 23:
				PPCInterpreter_LWZX(hCPU, opcode);
				break;
			case 24:
				PPCInterpreter_SLWX(hCPU, opcode);
				break;
			case 26:
				PPCInterpreter_CNTLZW(hCPU, opcode);
				break;
			case 28:
				PPCInterpreter_ANDX(hCPU, opcode);
				break;
			case 32:
				PPCInterpreter_CMPL(hCPU, opcode);
				break;
			case 40:
				PPCInterpreter_SUBF(hCPU, opcode);
				break;
			case 54:
				PPCInterpreter_DCBST(hCPU, opcode);
				break;
			case 55:
				PPCInterpreter_LWZXU(hCPU, opcode);
				break;
			case 60:
				PPCInterpreter_ANDCX(hCPU, opcode);
				break;
			case 75:
				PPCInterpreter_MULHW_(hCPU, opcode);
				break;
			case 83:
				PPCInterpreter_MFMSR(hCPU, opcode);
				break;
			case 86:
				PPCInterpreter_DCBF(hCPU, opcode);
				break;
			case 87:
				PPCInterpreter_LBZX(hCPU, opcode);
				break;
			case 104:
				PPCInterpreter_NEG(hCPU, opcode);
				break;
			case 119: // Sonic Lost World
				PPCInterpreter_LBZXU(hCPU, opcode);
				break;
			case 124:
				PPCInterpreter_NORX(hCPU, opcode);
				break;
			case 136:
				PPCInterpreter_SUBFE(hCPU, opcode);
				break;
			case 138:
				PPCInterpreter_ADDE(hCPU, opcode);
				break;
			case 144:
				PPCInterpreter_MTCRF(hCPU, opcode);
				break;
			case 146:
				PPCInterpreter_MTMSR(hCPU, opcode);
				break;
			case 150:
				PPCInterpreter_STWCX(hCPU, opcode);
				break;
			case 151:
				PPCInterpreter_STWX(hCPU, opcode);
				break;
			case 183:
				PPCInterpreter_STWUX(hCPU, opcode);
				break;
			case 200:
				PPCInterpreter_SUBFZE(hCPU, opcode);
				break;
			case 202:
				PPCInterpreter_ADDZE(hCPU, opcode);
				break;
			case 210:
				PPCInterpreter_MTSR(hCPU, opcode);
				break;
			case 215:
				PPCInterpreter_STBX(hCPU, opcode);
				break;
			case 232: // Trine 2
				PPCInterpreter_SUBFME(hCPU, opcode);
				break;
			case 234:
				PPCInterpreter_ADDME(hCPU, opcode);
				break;
			case 235:
				PPCInterpreter_MULLW(hCPU, opcode);
				break;
			case 247:
				PPCInterpreter_STBUX(hCPU, opcode);
				break;
			case 266:
				PPCInterpreter_ADD(hCPU, opcode);
				break;
			case 278:
				PPCInterpreter_DCBT(hCPU, opcode);
				break;
			case 279:
				PPCInterpreter_LHZX(hCPU, opcode);
				break;
			case 284:
				PPCInterpreter_EQV(hCPU, opcode);
				break;
			case 306:
				PPCInterpreter_TLBIE(hCPU, opcode);
				break;
			case 311: // Wii U Menu v177 (US)
				PPCInterpreter_LHZUX(hCPU, opcode);
				break;
			case 316:
				PPCInterpreter_XOR(hCPU, opcode);
				break;
			case 339:
				PPCInterpreter_MFSPR(hCPU, opcode);
				break;
			case 343:
				PPCInterpreter_LHAX(hCPU, opcode);
				break;
			case 371:
				PPCInterpreter_MFTB(hCPU, opcode);
				break;
			case 375: // Wii U Menu v177 (US)
				PPCInterpreter_LHAUX(hCPU, opcode);
				break;
			case 407:
				PPCInterpreter_STHX(hCPU, opcode);
				break;
			case 412:
				PPCInterpreter_ORC(hCPU, opcode);
				break;
			case 439:
				PPCInterpreter_STHUX(hCPU, opcode);
				break;
			case 444:
				PPCInterpreter_OR(hCPU, opcode);
				break;
			case 459:
				PPCInterpreter_DIVWU(hCPU, opcode);
				break;
			case 467:
				PPCInterpreter_MTSPR(hCPU, opcode);
				break;
			case 470:
				PPCInterpreter_DCBI(hCPU, opcode);
				break;
			case 476:
				PPCInterpreter_NANDX(hCPU, opcode);
				break;
			case 491:
				PPCInterpreter_DIVW(hCPU, opcode);
				break;
			case 512:
				PPCInterpreter_MCRXR(hCPU, opcode);
				break;
			case 520: // Affordable Space Adventures + other Unity games
				PPCInterpreter_SUBFCO(hCPU, opcode);
				break;
			case 522:
				PPCInterpreter_ADDCO(hCPU, opcode);
				break;
			case 523: // 11 | OE
				PPCInterpreter_MULHWU_(hCPU, opcode); // OE is ignored
				break;
			case 533:
				PPCInterpreter_LSWX(hCPU, opcode);
				break;
			case 534:
				PPCInterpreter_LWBRX(hCPU, opcode);
				break;
			case 535:
				PPCInterpreter_LFSX(hCPU, opcode);
				break;
			case 536:
				PPCInterpreter_SRWX(hCPU, opcode);
				break;
			case 552:
				PPCInterpreter_SUBFO(hCPU, opcode);
				break;
			case 566:
				PPCInterpreter_TLBSYNC(hCPU, opcode);
				break;
			case 567:
				PPCInterpreter_LFSUX(hCPU, opcode);
				break;
			case 587: // 75 | OE
				PPCInterpreter_MULHW_(hCPU, opcode); // OE is ignored for MULHW
				break;
			case 595:
				PPCInterpreter_MFSR(hCPU, opcode);
				break;
			case 597:
				PPCInterpreter_LSWI(hCPU, opcode);
				break;
			case 598:
				PPCInterpreter_SYNC(hCPU, opcode);
				break;
			case 599:
				PPCInterpreter_LFDX(hCPU, opcode);
				break;
			case 616:
				PPCInterpreter_NEGO(hCPU, opcode);
				break;
			case 631:
				PPCInterpreter_LFDUX(hCPU, opcode);
				break;
			case 648: // 136 | OE
				PPCInterpreter_SUBFEO(hCPU, opcode);
				break;
			case 650: // 138 | OE
				PPCInterpreter_ADDEO(hCPU, opcode);
				break;
			case 662:
				PPCInterpreter_STWBRX(hCPU, opcode);
				break;
			case 663:
				PPCInterpreter_STFSX(hCPU, opcode);
				break;
			case 661:
				PPCInterpreter_STSWX(hCPU, opcode);
				break;
			case 695:
				PPCInterpreter_STFSUX(hCPU, opcode);
				break;
			case 712: // 200 | OE
				PPCInterpreter_SUBFZEO(hCPU, opcode);
				break;
			case 714: // 202 | OE
				PPCInterpreter_ADDZEO(hCPU, opcode);
				break;
			case 725:
				PPCInterpreter_STSWI(hCPU, opcode);
				break;
			case 727:
				PPCInterpreter_STFDX(hCPU, opcode);
				break;
			case 744: // 232 | OE
				PPCInterpreter_SUBFMEO(hCPU, opcode);
				break;
			case 746: // 234 | OE
				PPCInterpreter_ADDMEO(hCPU, opcode);
				break;
			case 747:
				PPCInterpreter_MULLWO(hCPU, opcode);
				break;
			case 759:
				PPCInterpreter_STFDUX(hCPU, opcode);
				break;
			case 778:
				PPCInterpreter_ADDO(hCPU, opcode);
				break;
			case 790:
				PPCInterpreter_LHBRX(hCPU, opcode);
				break;
			case 792:
				PPCInterpreter_SRAW(hCPU, opcode);
				break;
			case 824:
				PPCInterpreter_SRAWI(hCPU, opcode);
				break;
			case 854:
				PPCInterpreter_EIEIO(hCPU, opcode);
				break;
			case 918:
				PPCInterpreter_STHBRX(hCPU, opcode);
				break;
			case 922:
				PPCInterpreter_EXTSH(hCPU, opcode);
				break;
			case 954:
				PPCInterpreter_EXTSB(hCPU, opcode);
				break;
			case 971:
				PPCInterpreter_DIVWUO(hCPU, opcode);
				break;
			case 982:
				PPCInterpreter_ICBI(hCPU, opcode);
				break;
			case 983:
				PPCInterpreter_STFIWX(hCPU, opcode);
				break;
			case 1003:
				PPCInterpreter_DIVWO(hCPU, opcode);
				break;
			case 1014:
				PPCInterpreter_DCBZ(hCPU, opcode);
				break;
			default:
				cemuLog_logDebug(LogType::Force, "Unknown execute {:04x} as [31] at {:08x}\n", PPC_getBits(opcode, 30, 10), hCPU->instructionPointer);
				cemu_assert_unimplemented();
				hCPU->instructionPointer += 4;
				break;
			}
			break;
		case 32:
			PPCInterpreter_LWZ(hCPU, opcode);
			break;
		case 33:
			PPCInterpreter_LWZU(hCPU, opcode);
			break;
		case 34:
			PPCInterpreter_LBZ(hCPU, opcode);
			break;
		case 35:
			PPCInterpreter_LBZU(hCPU, opcode);
			break;
		case 36:
			PPCInterpreter_STW(hCPU, opcode);
			break;
		case 37:
			PPCInterpreter_STWU(hCPU, opcode);
			break;
		case 38:
			PPCInterpreter_STB(hCPU, opcode);
			break;
		case 39:
			PPCInterpreter_STBU(hCPU, opcode);
			break;
		case 40:
			PPCInterpreter_LHZ(hCPU, opcode);
			break;
		case 41:
			PPCInterpreter_LHZU(hCPU, opcode);
			break;
		case 42:
			PPCInterpreter_LHA(hCPU, opcode);
			break;
		case 43:
			PPCInterpreter_LHAU(hCPU, opcode);
			break;
		case 44:
			PPCInterpreter_STH(hCPU, opcode);
			break;
		case 45:
			PPCInterpreter_STHU(hCPU, opcode);
			break;
		case 46:
			PPCInterpreter_LMW(hCPU, opcode);
			break;
		case 47:
			PPCInterpreter_STMW(hCPU, opcode);
			break;
		case 48:
			PPCInterpreter_LFS(hCPU, opcode);
			break;
		case 49:
			PPCInterpreter_LFSU(hCPU, opcode);
			break;
		case 50:
			PPCInterpreter_LFD(hCPU, opcode);
			break;
		case 51:
			PPCInterpreter_LFDU(hCPU, opcode);
			break;
		case 52:
			PPCInterpreter_STFS(hCPU, opcode);
			break;
		case 53:
			PPCInterpreter_STFSU(hCPU, opcode);
			break;
		case 54:
			PPCInterpreter_STFD(hCPU, opcode);
			break;
		case 55:
			PPCInterpreter_STFDU(hCPU, opcode);
			break;
		case 56:
			PPCInterpreter_PSQ_L(hCPU, opcode);
			break;
		case 57:
			PPCInterpreter_PSQ_LU(hCPU, opcode);
			break;
		case 59: // opcode category
			switch (PPC_getBits(opcode, 30, 5))
			{
			case 18:
				PPCInterpreter_FDIVS(hCPU, opcode);
				break;
			case 20:
				PPCInterpreter_FSUBS(hCPU, opcode);
				break;
			case 21:
				PPCInterpreter_FADDS(hCPU, opcode);
				break;
			case 24:
				PPCInterpreter_FRES(hCPU, opcode);
				break;
			case 25:
				PPCInterpreter_FMULS(hCPU, opcode);
				break;
			case 28:
				PPCInterpreter_FMSUBS(hCPU, opcode);
				break;
			case 29:
				PPCInterpreter_FMADDS(hCPU, opcode);
				break;
			case 30:
				PPCInterpreter_FNMSUBS(hCPU, opcode);
				break;
			case 31:
				PPCInterpreter_FNMADDS(hCPU, opcode);
				break;
			default:
				cemuLog_logDebug(LogType::Force, "Unknown execute {:04x} as [59] at {:08x}\n", PPC_getBits(opcode, 30, 10), hCPU->instructionPointer);
				cemu_assert_unimplemented();
				hCPU->instructionPointer += 4;
				break;
			}
			break;
		case 60:
			PPCInterpreter_PSQ_ST(hCPU, opcode);
			break;
		case 61:
			PPCInterpreter_PSQ_STU(hCPU, opcode);
			break;
		case 63: // opcode category
			switch (PPC_getBits(opcode, 30, 5))
			{
			case 0:
				PPCInterpreter_FCMPU(hCPU, opcode);
				break;
			case 12:
				PPCInterpreter_FRSP(hCPU, opcode);
				break;
			case 15:
				PPCInterpreter_FCTIWZ(hCPU, opcode);
				break;
			case 18:
				PPCInterpreter_FDIV(hCPU, opcode);
				break;
			case 20:
				PPCInterpreter_FSUB(hCPU, opcode);
				break;
			case 21:
				PPCInterpreter_FADD(hCPU, opcode);
				break;
			case 23:
				PPCInterpreter_FSEL(hCPU, opcode);
				break;
			case 25:
				PPCInterpreter_FMUL(hCPU, opcode);
				break;
			case 26:
				PPCInterpreter_FRSQRTE(hCPU, opcode);
				break;
			case 28:
				PPCInterpreter_FMSUB(hCPU, opcode);
				break;
			case 29:
				PPCInterpreter_FMADD(hCPU, opcode);
				break;
			case 30:
				PPCInterpreter_FNMSUB(hCPU, opcode);
				break;
			case 31:
				PPCInterpreter_FNMADD(hCPU, opcode);
				break;
			default:
				switch (PPC_getBits(opcode, 30, 10))
				{
				case 14:
					PPCInterpreter_FCTIW(hCPU, opcode);
					break;
				case 32:
					PPCInterpreter_FCMPO(hCPU, opcode);
					break;
				case 38:
					PPCInterpreter_MTFSB1X(hCPU, opcode);
					break;
				case 40:
					PPCInterpreter_FNEG(hCPU, opcode);
					break;
				case 72:
					PPCInterpreter_FMR(hCPU, opcode);
					break;
				case 136: // Darksiders 2
					PPCInterpreter_FNABS(hCPU, opcode);
					break;
				case 264:
					PPCInterpreter_FABS(hCPU, opcode);
					break;
				case 583:
					PPCInterpreter_MFFS(hCPU, opcode);
					break;
				case 711:
					PPCInterpreter_MTFSF(hCPU, opcode);
					break;
				default:
					cemuLog_logDebug(LogType::Force, "Unknown execute {:04x} as [63] at {:08x}\n", PPC_getBits(opcode, 30, 10), hCPU->instructionPointer);
					cemu_assert_unimplemented();
					PPCInterpreter_nextInstruction(hCPU);
					break;
				}
			}
			break;
		default:
			cemuLog_logDebug(LogType::Force, "Unknown execute {:04x} at {:08x}\n", PPC_getBits(opcode, 5, 6), (unsigned int)hCPU->instructionPointer);
			cemu_assert_unimplemented();
		}
	}
#ifdef CEMU_TBI
	// Iridia AOT generator: specialized step bodies by name (the generated code calls them with constant operands)
	static constexpr std::pair<PPCTBFn, const char*> kAotBodies[] = {
		{ &tbOne<&bAdd>, "bAdd" },
		{ &tbOne<&bAddImm>, "bAddImm" },
		{ &tbOne<&bCmp<false, false>>, "bCmp<false, false>" },
		{ &tbOne<&bCmp<false, true>>, "bCmp<false, true>" },
		{ &tbOne<&bCmp<true, false>>, "bCmp<true, false>" },
		{ &tbOne<&bCmp<true, true>>, "bCmp<true, true>" },
		{ &tbOne<&bLbz>, "bLbz" },
		{ &tbOne<&bLfd>, "bLfd" },
		{ &tbOne<&bLfs>, "bLfs" },
		{ &tbOne<&bLhz>, "bLhz" },
		{ &tbOne<&bLoadImm>, "bLoadImm" },
		{ &tbOne<&bLwz>, "bLwz" },
		{ &tbOne<&bMfctr>, "bMfctr" },
		{ &tbOne<&bMflr>, "bMflr" },
		{ &tbOne<&bMtctr>, "bMtctr" },
		{ &tbOne<&bMtlr>, "bMtlr" },
		{ &tbOne<&bMulli>, "bMulli" },
		{ &tbOne<&bOr>, "bOr" },
		{ &tbOne<&bOri>, "bOri" },
		{ &tbOne<&bPsqL>, "bPsqL" },
		{ &tbOne<&bPsqLN>, "bPsqLN" },
		{ &tbOne<&bPsqSt>, "bPsqSt" },
		{ &tbOne<&bPsqStN>, "bPsqStN" },
		{ &tbOne<&bRlwinm>, "bRlwinm" },
		{ &tbOne<&bRlwinmMask>, "bRlwinmMask" },
		{ &tbOne<&bRlwinmRc>, "bRlwinmRc" },
		{ &tbOne<&bStb>, "bStb" },
		{ &tbOne<&bStfd>, "bStfd" },
		{ &tbOne<&bStfs>, "bStfs" },
		{ &tbOne<&bSth>, "bSth" },
		{ &tbOne<&bStw>, "bStw" },
		{ &tbOne<&bStwu>, "bStwu" },
		{ &tbOne<&bSubf>, "bSubf" },
	};
#endif
#ifdef CEMU_TBI
	// Iridia: hooks left from the AOT research build. That build and its generator are not part of this tree, so
	// the table below is always empty and `if constexpr (kAotCount == 0)` compiles the lookup out.
#define AOT_CHAIN { if (const PPCTBEntry* aotNext = tbNextBlock(hCPU)) [[clang::musttail]] return aotNext->fn(hCPU, aotNext, hCPU->gpr[1]); return; }
	// Iridia AOT direct chaining: an exit whose target is itself a compiled block (table index i, n instructions) goes
	// straight there when that block was validated in the current block-cache generation and the time slice goes on
	// (the same checks tbNextBlock makes); otherwise through the cache as usual
#define AOT_JUMP(i, n, fn) { if (hCPU->remainingCycles > 0 && s_aotValidGen[i] == s_tbGeneration.load(std::memory_order_relaxed) && !s_tbVerify() && !s_aotVerifyOn) { hCPU->remainingCycles -= (n); [[clang::musttail]] return fn(hCPU, e, hCPU->gpr[1]); } AOT_CHAIN }
	// Inline copies of two stock handlers (PPCInterpreterOPC.cpp / PPCInterpreterFPU.cpp) for the generated blocks:
	// the stock ones live in another file, and calling them with the state pointer forces a block's local copy of
	// the state into memory. Same steps, including the instruction pointer step.
	__attribute__((always_inline)) static void tbAotMfcr(PPCInterpreter_t* hCPU, uint32 Opcode)
	{
		int rD, rA, rB;
		PPC_OPC_TEMPL_X(Opcode, rD, rA, rB);
		uint32 cr = 0;
		for (sint32 i = 0; i < 32; i++)
		{
			cr <<= 1;
			if (ppc_getCRBit(hCPU, i) != 0)
				cr |= 1;
		}
		hCPU->gpr[rD] = cr;
		PPCInterpreter_nextInstruction(hCPU);
	}
	__attribute__((always_inline)) static void tbAotFcmpu(PPCInterpreter_t* hCPU, uint32 Opcode)
	{
		int crfD, frA, frB;
		PPC_OPC_TEMPL_X(Opcode, crfD, frA, frB);
		const double a = hCPU->fpr[frA].fp0, b = hCPU->fpr[frB].fp0;
		uint32 c;
		ppc_setCRBit(hCPU, crfD + 0, 0);
		ppc_setCRBit(hCPU, crfD + 1, 0);
		ppc_setCRBit(hCPU, crfD + 2, 0);
		ppc_setCRBit(hCPU, crfD + 3, 0);
		if (IS_NAN(*(uint64*)&a) || IS_NAN(*(uint64*)&b)) { c = 1; ppc_setCRBit(hCPU, crfD + CR_BIT_SO, 1); }
		else if (a < b) { c = 8; ppc_setCRBit(hCPU, crfD + CR_BIT_LT, 1); }
		else if (a > b) { c = 4; ppc_setCRBit(hCPU, crfD + CR_BIT_GT, 1); }
		else { c = 2; ppc_setCRBit(hCPU, crfD + CR_BIT_EQ, 1); }
		if (IS_SNAN(*(uint64*)&a) || IS_SNAN(*(uint64*)&b))
			hCPU->fpscr |= FPSCR_VXSNAN;
		hCPU->fpscr = (hCPU->fpscr & 0xffff0fff) | (c << 12);
		PPCInterpreter_nextInstruction(hCPU);
	}
#define PPCInterpreter_MFCR tbAotMfcr
#define PPCInterpreter_FCMPU tbAotFcmpu
// research builds only (IRIDIA_AOT_RESEARCH): translated game code can not ship
	struct AotEntry { uint32 address, count, words, nwords; PPCTBFn fn; };
	static constexpr AotEntry kAotEntries[] = { { 0, 0, 0, 0, nullptr } };
	static constexpr uint32 kAotWords[] = { 0 };
	static constexpr uint32 kAotCount = 0;
	static inline uint32 s_aotValidGen[1] = {};
#undef PPCInterpreter_MFCR
#undef PPCInterpreter_FCMPU
#undef AOT_CHAIN
#undef AOT_JUMP
#endif
};

// Slim interpreter, trades some features for extra performance
// Used when emulator runs in CafeOS HLE mode
// Assumes the following:
// - No MMU (linear memory with 1:1 mapping of physical to virtual)
// - No interrupts
// - Always runs in user mode
// - Paired single mode is always enabled
#ifdef CEMU_TBI
namespace
{
	constexpr uint32 kTBPageShift = 12;                        // blocks never cross a 4 KB page
	constexpr uint32 kTBPageSlots = 1u << (kTBPageShift - 2);  // one slot per instruction address
	constexpr uint32 kTBMaxBlock = 64;

	struct PPCTBBlock
	{
		uint32 version;      // page version the block was decoded from
		uint32 count;        // instructions in the block
		PPCTBEntry steps[1]; // count steps (+ an exit step unless the last one ends the block)
	};
	static_assert(offsetof(PPCTBBlock, steps) == offsetof(PPCTBBlock, count) + 4, "tbBlockCount reads count just before steps");
	struct PPCTBPage
	{
		std::atomic<uint32> version{0};
		std::atomic<PPCTBBlock*> blocks[kTBPageSlots];
	};
	std::atomic<PPCTBPage*> s_tbPages[1u << (32 - kTBPageShift)];

	TB_CC void tbExit(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		hCPU->instructionPointer = e->address;
		if (const PPCTBEntry* next = tbNextBlock(hCPU))
			[[clang::musttail]] return next->fn(hCPU, next, pr1);
	}
#include "IridiaSzs.hpp"
	// Iridia: first step of the block at the start of the Yaz0 stream routine (IridiaSzs.hpp). Runs it natively
	// and returns to the caller; falls through to the guest code when the native version doesn't apply.
	// Opt-in, IRIDIA_SZS=1: exact (IRIDIA_SZS_CHECK, 0 mismatches in 3000+ BotW calls) but no measured fps gain:
	// BotW's slow phase stays CPU-bound on core 2 without it. IRIDIA_SZS_CHECK=1 (implies on): every call also runs
	// the guest code from the same starting memory and compares output range, context and return value.
	static bool s_szsOn() { static const bool v = (iridia_getenv("IRIDIA_SZS") && atoi(iridia_getenv("IRIDIA_SZS")) != 0) || iridia_getenv("IRIDIA_SZS_CHECK"); return v; } // read on first use: the app sets study switches after load
	static bool s_szsCheck() { static const bool v = iridia_getenv("IRIDIA_SZS_CHECK") != nullptr; return v; } // read on first use: the app sets study switches after load
	thread_local bool t_szsInCheck = false;
	std::atomic<uint64> s_szsCalls{0}, s_szsChecked{0}, s_szsBad{0};
	// Check mode: native run, then the guest code from the same memory; compare. false = native didn't apply.
	__attribute__((noinline)) bool tbSzsCheck(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32& ret)
	{
		const uint32 ctx = hCPU->gpr[3], src = hCPU->gpr[4], srcLen = hCPU->gpr[5];
		const uint32 dst = memory_readU32(ctx), left = memory_readU32(ctx + 4);
		const uint32 win = ((sint32)left > 0 ? std::min<uint32>(left, 64u << 20) : 0) + 64;
		std::vector<uint8> ctx0(memory_base + ctx, memory_base + ctx + 0x18), dst0(memory_base + dst, memory_base + dst + win);
		uint64 instrs = 0;
		if (!IridiaSzs_Run(ctx, src, srcLen, ret, instrs))
			return false;
		std::vector<uint8> ctxN(memory_base + ctx, memory_base + ctx + 0x18), dstN(memory_base + dst, memory_base + dst + win);
		memcpy(memory_base + dst, dst0.data(), win);
		memcpy(memory_base + ctx, ctx0.data(), 0x18);
		hCPU->gpr[3] = ctx; hCPU->gpr[4] = src; hCPU->gpr[5] = srcLen;
		hCPU->instructionPointer = e->address;
		const sint32 cyclesLeft = hCPU->remainingCycles;
		t_szsInCheck = true;
		const uint32 guestRet = PPCCore_executeCallbackInternal(e->address)->gpr[3];
		t_szsInCheck = false;
		hCPU->remainingCycles = cyclesLeft;
		const bool ctxSame = memcmp(ctxN.data(), memory_base + ctx, 0x18) == 0;
		const bool same = guestRet == ret && ctxSame && memcmp(dstN.data(), memory_base + dst, win) == 0;
		const uint64 checked = ++s_szsChecked;
		if (!same)
		{
			const uint64 bad = ++s_szsBad;
			if (bad <= 20)
			{
				uint32 firstDiff = 0;
				while (firstDiff < win && dstN[firstDiff] == memory_base[dst + firstDiff]) firstDiff++;
				fprintf(stderr, "IRIDIA_SZS_CHECK MISMATCH ret native %08x guest %08x ctx %s, first output difference at +%u of %u\n", ret, guestRet,
					ctxSame ? "same" : "differs", firstDiff, win);
			}
		}
		if ((checked % 500) == 0)
			fprintf(stderr, "IRIDIA_SZS_CHECK %llu calls compared, %llu mismatches\n", (unsigned long long)checked, (unsigned long long)s_szsBad.load());
		ret = guestRet; // the guest's result is what's in memory now
		return true;
	}
	TB_CC void tbSzsHook(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		if (t_szsInCheck)
			[[clang::musttail]] return e[1].fn(hCPU, e + 1, pr1);
		uint32 ret = 0;
		uint64 instrs = 0;
		const bool handled = s_szsCheck() ? tbSzsCheck(hCPU, e, ret) : IridiaSzs_Run(hCPU->gpr[3], hCPU->gpr[4], hCPU->gpr[5], ret, instrs);
		if (!handled)
			[[clang::musttail]] return e[1].fn(hCPU, e + 1, pr1);
		s_szsCalls.fetch_add(1, std::memory_order_relaxed);
		hCPU->gpr[3] = ret;
		hCPU->remainingCycles -= (sint32)std::min<uint64>(instrs, 0x10000000);
		hCPU->instructionPointer = hCPU->spr.LR & 0xfffffffc;
		if (const PPCTBEntry* next = tbNextBlock(hCPU))
			[[clang::musttail]] return next->fn(hCPU, next, pr1);
	}

#include "IridiaDiv64.hpp"
	// Iridia: first step of the block at the start of the 64-bit division routine (IridiaDiv64.hpp). IRIDIA_DIV64=1
	// turns it on; IRIDIA_DIV64_CHECK=1 (implies on) also runs the guest code for every call and compares the
	// result; IRIDIA_DIV64_CALLERS=1 prints the busiest callers every 5 s.
	static bool s_div64Check() { static const bool v = iridia_getenv("IRIDIA_DIV64_CHECK") != nullptr; return v; } // read on first use: the app sets study switches after load
	static bool s_div64Callers() { static const bool v = iridia_getenv("IRIDIA_DIV64_CALLERS") != nullptr; return v; } // read on first use: the app sets study switches after load
	static bool s_div64On() { static const bool v = (iridia_getenv("IRIDIA_DIV64") && atoi(iridia_getenv("IRIDIA_DIV64")) != 0) || s_div64Check() || s_div64Callers(); return v; } // read on first use: the app sets study switches after load
	thread_local bool t_div64InCheck = false;
	std::atomic<uint64> s_div64Calls{0}, s_div64Bad{0};
	__attribute__((noinline)) void tbDiv64Callers(uint32 lr)
	{
		static std::mutex m;
		static std::unordered_map<uint32, uint64> hits;
		static auto last = std::chrono::steady_clock::now();
		std::lock_guard<std::mutex> lock(m);
		hits[lr]++;
		const auto now = std::chrono::steady_clock::now();
		if (now - last < std::chrono::seconds(5))
			return;
		last = now;
		std::vector<std::pair<uint64, uint32>> top;
		uint64 total = 0;
		for (auto& [a, c] : hits) { top.emplace_back(c, a); total += c; }
		std::sort(top.rbegin(), top.rend());
		std::string line = "IRIDIA_DIV64_CALLERS " + std::to_string(total / 5) + "/s:";
		for (size_t i = 0; i < top.size() && i < 8; i++)
		{
			char buf[48];
			snprintf(buf, sizeof(buf), " %08x=%.0f%%", top[i].second, 100.0 * top[i].first / total);
			line += buf;
		}
		fprintf(stderr, "%s\n", line.c_str());
		hits.clear();
	}
	__attribute__((noinline)) void tbDiv64Check(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint64 q)
	{
		const uint32 r3 = hCPU->gpr[3], r4 = hCPU->gpr[4], r5 = hCPU->gpr[5], r6 = hCPU->gpr[6];
		const sint32 cyclesLeft = hCPU->remainingCycles;
		t_div64InCheck = true;
		PPCInterpreter_t* r = PPCCore_executeCallbackInternal(e->address);
		t_div64InCheck = false;
		const uint64 guest = ((uint64)r->gpr[3] << 32) | r->gpr[4];
		hCPU->remainingCycles = cyclesLeft;
		const uint64 calls = s_div64Calls.load();
		if (guest != q && ++s_div64Bad <= 20)
			fprintf(stderr, "IRIDIA_DIV64_CHECK MISMATCH %08x%08x / %08x%08x: native %016llx guest %016llx\n", r3, r4, r5, r6, (unsigned long long)q, (unsigned long long)guest);
		if ((calls % 100000) == 0)
			fprintf(stderr, "IRIDIA_DIV64_CHECK %llu calls compared, %llu mismatches\n", (unsigned long long)calls, (unsigned long long)s_div64Bad.load());
	}
	TB_CC void tbDiv64Hook(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		if (t_div64InCheck)
			[[clang::musttail]] return e[1].fn(hCPU, e + 1, pr1);
		uint64 q, instrs;
		if (!IridiaDiv64_Run(((uint64)hCPU->gpr[3] << 32) | hCPU->gpr[4], ((uint64)hCPU->gpr[5] << 32) | hCPU->gpr[6], q, instrs))
			[[clang::musttail]] return e[1].fn(hCPU, e + 1, pr1);
		s_div64Calls.fetch_add(1, std::memory_order_relaxed);
		if (s_div64Callers())
			tbDiv64Callers(hCPU->spr.LR);
		if (s_div64Check())
			tbDiv64Check(hCPU, e, q);
		hCPU->gpr[3] = (uint32)(q >> 32);
		hCPU->gpr[4] = (uint32)q;
		hCPU->remainingCycles -= (sint32)instrs;
		hCPU->instructionPointer = hCPU->spr.LR & 0xfffffffc;
		if (const PPCTBEntry* next = tbNextBlock(hCPU))
			[[clang::musttail]] return next->fn(hCPU, next, pr1);
	}

	// A folded `bl` inside the block: set the link register, then carry on at the call target.
	TB_CC void tbSetLR(PPCInterpreter_t* hCPU, const PPCTBEntry* e, uint32 pr1)
	{
		hCPU->spr.LR = e->imm;
		[[clang::musttail]] return e[1].fn(hCPU, e + 1, pr1);
	}

	PPCTBPage* GetTBPage(uint32 address)
	{
		std::atomic<PPCTBPage*>& slot = s_tbPages[address >> kTBPageShift];
		// Relaxed: everything read through the pointer depends on it (address dependency), which
		// ARM64 orders in hardware; the writers publish with release. Avoids LDAR on the hot path.
		PPCTBPage* page = slot.load(std::memory_order_relaxed);
		if (page)
			return page;
		PPCTBPage* fresh = new PPCTBPage();
		for (auto& b : fresh->blocks) b.store(nullptr, std::memory_order_relaxed);
		if (slot.compare_exchange_strong(page, fresh, std::memory_order_acq_rel))
			return fresh;
		delete fresh;
		return page;
	}

	// Iridia AOT: the compiled block starting at address, if there is one and every guest instruction it was made
	// from is still the same (the generated table keeps (address, opcode) pairs). nullptr otherwise.
	std::atomic<uint64> s_aotHits{0}, s_aotMisses{0};
	PPCTBBlock* AotBlock(PPCInterpreter_t* hCPU, uint32 address, uint32 version)
	{
		using Container = PPCInterpreterContainer<PPCItpCafeOSUsermode>;
		if constexpr (Container::kAotCount == 0)
			return nullptr;
		static const bool s_on = !iridia_getenv("IRIDIA_AOT") || atoi(iridia_getenv("IRIDIA_AOT")) != 0;
		if (!s_on)
			return nullptr;
		static const std::unordered_map<uint32, uint32>* s_index = [] {
			auto* m = new std::unordered_map<uint32, uint32>();
			for (uint32 i = 0; i < Container::kAotCount; i++)
				m->emplace(Container::kAotEntries[i].address, i);
			fprintf(stderr, "IRIDIA_AOT %u compiled blocks\n", Container::kAotCount);
			return m;
		}();
		auto it = s_index->find(address);
		if (it == s_index->end())
			return nullptr;
		const auto& en = Container::kAotEntries[it->second];
		for (uint32 k = 0; k < en.nwords; k++)
		{
			const uint32 a = Container::kAotWords[en.words + 2 * k], w = Container::kAotWords[en.words + 2 * k + 1];
			if (PPCItpCafeOSUsermode::memory_readCodeU32(hCPU, a) != w)
			{
				s_aotMisses.fetch_add(1, std::memory_order_relaxed);
				return nullptr;
			}
		}
		s_aotHits.fetch_add(1, std::memory_order_relaxed);
		Container::s_aotValidGen[it->second] = s_tbGeneration.load(std::memory_order_relaxed); // for direct chaining (AOT_JUMP)
		auto* block = (PPCTBBlock*)malloc(sizeof(PPCTBBlock));
		block->version = version;
		block->count = en.count;
		block->steps[0] = { en.fn, 0, address, it->second, 0xA0, 0, 0, 0 }; // r0 = 0xA0: compiled block (imm = table index)
		return block;
	}

	// Decodes the block starting at address, up to a control-flow instruction, an undecodable opcode,
	// the page end or kTBMaxBlock instructions. nullptr if the first instruction can't be decoded.
	PPCTBBlock* BuildBlock(PPCInterpreter_t* hCPU, uint32 address, uint32 version)
	{
		using Container = PPCInterpreterContainer<PPCItpCafeOSUsermode>;
#if defined(__aarch64__)
		static const bool s_psTest = iridia_getenv("IRIDIA_PS_SELFTEST") != nullptr;
		if (s_psTest) [[unlikely]]
			Container::tbPsSelfTest(hCPU); // exits
#endif
		PPCTBEntry steps[2 * kTBMaxBlock + 1];
		uint32 count = 0;  // instructions (cycles), folded branches included
		uint32 nsteps = 0;
		bool ended = false;
		struct { uint32 step, countAfter; } sideExits[kTBMaxBlock];
		uint32 nside = 0;
		const uint32 pageEnd = ((address >> kTBPageShift) + 1) << kTBPageShift;
		uint32 a = address;
		// Iridia: byte copy loop as one step (tbByteCopyLoop). Opt-in, IRIDIA_TB_COPYLOOP=1: correct, but no
		// measured BotW gain (its LZ matches are short: the decoder's own code dominates).
		static const bool s_copyLoop = iridia_getenv("IRIDIA_TB_COPYLOOP") != nullptr;
		if (s_copyLoop && !s_tbVerify() && address + 12 <= pageEnd &&
			Container::tbIsByteCopyLoop(PPCItpCafeOSUsermode::memory_readCodeU32(hCPU, address), PPCItpCafeOSUsermode::memory_readCodeU32(hCPU, address + 4),
				PPCItpCafeOSUsermode::memory_readCodeU32(hCPU, address + 8), steps[0], address))
		{
			nsteps = 1;
			count = 3;
			ended = true;
			a = pageEnd; // skip the decode loop
		}
		// Iridia: native Yaz0 stream routine (tbSzsHook), recognized by its machine code
		if (s_szsOn() && !s_tbVerify() && PPCItpCafeOSUsermode::memory_readCodeU32(hCPU, address) == kIridiaSzsSig[0] && IridiaSzs_Matches(address))
		{
			steps[nsteps++] = { &tbSzsHook, 0, address, 0, 0, 0, 0, 0 };
			static std::atomic<bool> s_logged{false};
			if (!s_logged.exchange(true))
				fprintf(stderr, "IRIDIA_SZS native Yaz0 stream routine at %08x\n", address);
		}
		// Iridia AOT: a compiled block for this address whose guest code is unchanged (IRIDIA_AOT=0: off)
		if (nsteps == 0)
			if (PPCTBBlock* aot = AotBlock(hCPU, address, version))
				return aot;
		// Iridia: native 64-bit division routine (tbDiv64Hook), recognized by its machine code
		if (s_div64On() && !s_tbVerify() && nsteps == 0 && PPCItpCafeOSUsermode::memory_readCodeU32(hCPU, address) == kIridiaDiv64Sig[0] && IridiaDiv64_Matches(address))
		{
			steps[nsteps++] = { &tbDiv64Hook, 0, address, 0, 0, 0, 0, 0 };
			static std::atomic<bool> s_logged{false};
			if (!s_logged.exchange(true))
				fprintf(stderr, "IRIDIA_DIV64 native 64-bit division routine at %08x\n", address);
		}
		while (!ended && count < kTBMaxBlock && a != pageEnd)
		{
			const uint32 opcode = PPCItpCafeOSUsermode::memory_readCodeU32(hCPU, a);
			// Unconditional relative branch to the same page: keep decoding at the target instead of
			// ending the block (the page's version covers everything the block decoded).
			if ((opcode >> 26) == 18 && (opcode & PPC_OPC_AA) == 0)
			{
				uint32 li;
				PPC_OPC_TEMPL_I(opcode, li);
				const uint32 target = a + li;
				if ((target >> kTBPageShift) == (address >> kTBPageShift))
				{
					if (opcode & PPC_OPC_LK)
						steps[nsteps++] = { &tbSetLR, opcode, a, a + 4, 0, 0, 0, 0 };
					count++;
					a = target;
					continue;
				}
			}
			if (count + 2 <= kTBMaxBlock && a + 4 != pageEnd)
			{
				// Side exit when the block can go on after the branch; otherwise the block ends here.
				const bool side = count + 3 <= kTBMaxBlock && a + 8 != pageEnd;
				if (Container::tbFuseCmpBc(opcode, PPCItpCafeOSUsermode::memory_readCodeU32(hCPU, a + 4), a, steps[nsteps], steps[nsteps + 1], side))
				{
					nsteps += 2; // the branch entry is data for the fused step
					count += 2;
					if (!side) { ended = true; break; }
					sideExits[nside++] = { nsteps - 1, count };
					a += 8;
					continue;
				}
			}
			// bclr with a condition (BO without "always"), no LK, no CTR update
			if ((opcode >> 26) == 19 && ((opcode >> 1) & 0x3ff) == 16 && !(opcode & PPC_OPC_LK) &&
				((opcode >> 21) & 4) && !((opcode >> 21) & 16) && count + 2 <= kTBMaxBlock && a + 4 != pageEnd)
			{
				steps[nsteps++] = { &Container::tbBclrSide, opcode, a, 0, (uint8)((opcode >> 21) & 0x1f), (uint8)((opcode >> 16) & 0x1f), 0, 0 };
				count++;
				sideExits[nside++] = { nsteps - 1, count };
				a += 4;
				continue;
			}
			if ((opcode >> 26) == 16 && !(opcode & (PPC_OPC_AA | PPC_OPC_LK)) && ((opcode >> 21) & 4) &&
				count + 2 <= kTBMaxBlock && a + 4 != pageEnd)
			{
				uint32 BO, BI, BD;
				PPC_OPC_TEMPL_B(opcode, BO, BI, BD);
				steps[nsteps++] = { &Container::tbBcSide, opcode, a, a + BD, (uint8)BO, (uint8)BI, 0, 0 };
				count++;
				sideExits[nside++] = { nsteps - 1, count };
				a += 4;
				continue;
			}
			PPCTBEntry special{ nullptr, opcode, a, 0, 0, 0, 0, 0 };
			if (Container::tbSpecialize(opcode, special))
			{
				steps[nsteps++] = special;
				count++;
				a += 4;
				continue;
			}
			bool endsBlock = false;
			PPCTBFn fn = Container::decodeTB(opcode, endsBlock);
			if (!fn)
				break;
			steps[nsteps++] = { fn, opcode, a, 0, 0, 0, 0, 0 };
			count++;
			a += 4;
			if (endsBlock) { ended = true; break; }
		}
		if (nsteps == 0)
			return nullptr; // also a block of only folded branches: let the slow path run them
		// Pair fusion: two neighbouring specialized steps become one (the second entry stays as its data).
		static const bool s_noPairs = iridia_getenv("IRIDIA_TB_NOPAIRS") != nullptr;
		for (uint32 k = 0; !s_noPairs && k + 1 < nsteps; k++)
		{
			const int ia = Container::tbPairIndex(steps[k].fn);
			if (ia < 0) continue;
			const int ib = Container::tbPairIndex(steps[k + 1].fn);
			if (ib < 0) continue;
			steps[k].fn = Container::tbPairFn(ia, ib);
			k++;
		}
		for (uint32 i = 0; i < nside; i++)
			steps[sideExits[i].step].r2 = (uint8)(count - sideExits[i].countAfter); // cycles not run when taken
		if (!ended)
			steps[nsteps] = { &tbExit, 0, a, 0, 0, 0, 0, 0 };
		const uint32 stepCount = nsteps + (ended ? 0 : 1);
		auto* block = (PPCTBBlock*)malloc(sizeof(PPCTBBlock) + sizeof(PPCTBEntry) * (stepCount - 1));
		block->version = version;
		block->count = count;
		memcpy(block->steps, steps, sizeof(PPCTBEntry) * stepCount);
		return block;
	}
}


// Iridia study: dynamic instruction mix (IRIDIA_TB_COUNT builds only). Each line: core, kind (S = specialized or
// fused step, G = generic step), weight, opcode key; then pairs of consecutive steps. Counts assume every step of
// a block ran (side exits make it approximate).
void PPCInterpreter_tbCountSet(bool on)
{
}
void PPCInterpreter_tbCountDump(const char* path)
{
}

// Code changed: bump the version of every page in the range, so their blocks are decoded again.
// (Old blocks are not freed: another core may still be running one. Code changes are rare.)
void PPCInterpreter_invalidateDecodeCache(uint32 startAddr, uint32 endAddr)
{
	if (endAddr <= startAddr)
		return;
	s_tbGeneration.fetch_add(1, std::memory_order_acq_rel);
	if (tbStatsOn()) [[unlikely]]
	{
		s_tbStatInval.fetch_add(1, std::memory_order_relaxed);
		s_tbStatBytes.fetch_add(endAddr - startAddr, std::memory_order_relaxed);
	}
	for (uint64 page = startAddr >> kTBPageShift; page <= (uint64)((endAddr - 1) >> kTBPageShift); page++)
		if (PPCTBPage* p = s_tbPages[page].load(std::memory_order_acquire))
		{
			p->version.fetch_add(1, std::memory_order_acq_rel);
			if (tbStatsOn()) [[unlikely]]
				s_tbStatPages.fetch_add(1, std::memory_order_relaxed);
		}
	if (tbStatsOn()) [[unlikely]]
		tbStatsReport();
}

static bool TBVerifySkippable(uint32 op)
{
	const uint32 primary = op >> 26;
	if (primary == 1 || primary == 17 || primary == 19 && ((op >> 1) & 0x3FF) == 50) // HLE, sc, rfi
		return true;
	if (primary == 31)
	{
		const uint32 xo = (op >> 1) & 0x3FF;
		// mfspr / mtspr of LR or CTR are plain register moves: checkable (other SPRs have side effects)
		const uint32 spr = ((op >> 16) & 31) | (((op >> 11) & 31) << 5);
		if ((xo == 339 || xo == 467) && (spr == 8 || spr == 9))
			return false;
		return xo == 20 || xo == 150 || xo == 339 || xo == 371 || xo == 467 || xo == 83 || xo == 146 || xo == 4; // lwarx stwcx mfspr mftb mtspr mfmsr mtmsr tw
	}
	return primary == 3; // twi
}


static void TBVerifyBlock(PPCInterpreter_t* hCPU, const PPCTBEntry* steps)
{
	const uint32 count = tbBlockCount(steps);
	const uint32 start = hCPU->instructionPointer;
	bool skip = false;
	for (uint32 i = 0; i < count && !skip; i++)
		skip = TBVerifySkippable(memory_readU32(start + i * 4));
	if (skip)
	{
		hCPU->remainingCycles -= (sint32)count;
		steps[0].fn(hCPU, steps, hCPU->gpr[1]);
		return;
	}
	PPCInterpreter_t snap = *hCPU;
	const sint32 before = hCPU->remainingCycles;
	hCPU->remainingCycles -= (sint32)count;
	steps[0].fn(hCPU, steps, hCPU->gpr[1]);
	PPCInterpreter_t tb = *hCPU;
	const sint32 executed = before - tb.remainingCycles;
	*hCPU = snap;
	for (sint32 i = 0; i < executed; i++)
		PPCInterpreterContainer<PPCItpCafeOSUsermode>::executeInstruction(hCPU);
	std::string diff;
	if (tb.instructionPointer != hCPU->instructionPointer) diff += fmt::format(" ip {:08x}/{:08x}", tb.instructionPointer, hCPU->instructionPointer);
	for (int r = 0; r < 32; r++)
	{
		if (tb.gpr[r] != hCPU->gpr[r]) diff += fmt::format(" r{} {:08x}/{:08x}", r, tb.gpr[r], hCPU->gpr[r]);
		if (tb.fpr[r].fp0int != hCPU->fpr[r].fp0int) diff += fmt::format(" f{}.0 {:016x}/{:016x}", r, tb.fpr[r].fp0int, hCPU->fpr[r].fp0int);
		if (tb.fpr[r].fp1int != hCPU->fpr[r].fp1int) diff += fmt::format(" f{}.1 {:016x}/{:016x}", r, tb.fpr[r].fp1int, hCPU->fpr[r].fp1int);
		if (tb.cr[r] != hCPU->cr[r]) diff += fmt::format(" cr{} {}/{}", r, tb.cr[r], hCPU->cr[r]);
	}
	if (tb.xer_ca != hCPU->xer_ca || tb.xer_so != hCPU->xer_so || tb.xer_ov != hCPU->xer_ov) diff += " xer";
	if (tb.spr.LR != hCPU->spr.LR) diff += fmt::format(" lr {:08x}/{:08x}", tb.spr.LR, hCPU->spr.LR);
	if (tb.spr.CTR != hCPU->spr.CTR) diff += fmt::format(" ctr {:08x}/{:08x}", tb.spr.CTR, hCPU->spr.CTR);
	if (tb.fpscr != hCPU->fpscr) diff += fmt::format(" fpscr {:08x}/{:08x}", tb.fpscr, hCPU->fpscr);
	static std::atomic<uint32> s_reports{0};
	static std::atomic<uint64> s_checked{0};
	uint64 n = ++s_checked;
	if (n % 5000000 == 0)
		fprintf(stderr, "IRIDIA_TBV checked %llu blocks, %u mismatches (AOT blocks used %llu, stale %llu)\n", (unsigned long long)n, s_reports.load(), (unsigned long long)s_aotHits.load(), (unsigned long long)s_aotMisses.load());
	if (!diff.empty() && s_reports.fetch_add(1) < 200)
	{
		std::string ops;
		for (sint32 i = 0; i < executed && i < 40; i++)
			ops += fmt::format(" {:08x}", memory_readU32(start + i * 4));
		fprintf(stderr, "IRIDIA_TBV MISMATCH block %08x n=%d (tb/stock):%s | ops:%s\n", start, executed, diff.c_str(), ops.c_str());
	}
	hCPU->remainingCycles = tb.remainingCycles; // keep the stock result (correct) and the same cycle accounting
}

// Runs blocks until the timeslice is used up (remainingCycles <= 0). Same exit points as the
// per-instruction loop: HLE calls that end the slice set remainingCycles to -1.
// The block cache belongs to the emulated core, not the host thread: a guest thread that blocks inside an HLE
// call can resume on another host thread (multi-core affinity, or 2-thread mode moving cores between host
// threads), and only one host thread runs a given core at a time, so a per-core cache is never shared.
static TBCacheEntry* s_tbCoreCache[4] = { new TBCacheEntry[kTBCacheAlloc](), new TBCacheEntry[kTBCacheAlloc](), new TBCacheEntry[kTBCacheAlloc](), nullptr }; // generation 0 = empty

void PPCInterpreter_bindTBCache(PPCInterpreter_t* hCPU, uint32 coreIndex)
{
	hCPU->tbCache = coreIndex < 3 ? s_tbCoreCache[coreIndex] : nullptr;
}

void PPCInterpreterSlim_run(PPCInterpreter_t* hCPU)
{
	if (!hCPU->tbCache) [[unlikely]]
	{
		// not started by the scheduler (no core bound): private cache for this host thread
		static thread_local TBCacheEntry* t_cache = nullptr;
		if (!t_cache)
			t_cache = new TBCacheEntry[kTBCacheAlloc]();
		hCPU->tbCache = t_cache;
	}
	while (hCPU->remainingCycles > 0)
	{
		TBCacheEntry* cache = (TBCacheEntry*)hCPU->tbCache; // re-read: an HLE call may have resumed us on another core
		const uint32 ip = hCPU->instructionPointer;
		TBCacheEntry& ce = cache[(ip >> 2) & (kTBCacheSize - 1)];
		const uint32 generation = s_tbGeneration.load(std::memory_order_relaxed);
		IRIDIA_CNT(CNT_LOOP_PROBES, 1);
		if (ce.ip != ip || ce.generation != generation) [[unlikely]]
		{
			IRIDIA_CNT(CNT_LOOP_CACHE_MISS, 1);
			if (tbStatsOn()) [[unlikely]]
			{
				s_tbStatMiss.fetch_add(1, std::memory_order_relaxed);
				// victim shadow: per cache, the last address pushed out of each slot
				static thread_local const void* t_vicOwner = nullptr;
				static thread_local uint32* t_vic = nullptr;
				if (t_vicOwner != cache) { t_vic = new uint32[kTBCacheSize](); t_vicOwner = cache; }
				const uint32 idx = (ip >> 2) & (kTBCacheSize - 1);
				if (ce.ip == ip) s_tbMissGen.fetch_add(1, std::memory_order_relaxed);
				else if (ce.generation == 0) s_tbMissEmpty.fetch_add(1, std::memory_order_relaxed);
				else
				{
					s_tbMissEvict.fetch_add(1, std::memory_order_relaxed);
					if (t_vic[idx] == ip) s_tbMissVictimHit.fetch_add(1, std::memory_order_relaxed);
					t_vic[idx] = ce.ip;
				}
				tbStatsReport();
			}
			if constexpr (kTBVictim)
			{
				TBCacheEntry& ve = (&ce)[kTBCacheSize];
				if (ve.ip == ip && ve.generation == generation)
				{
					std::swap(ce, ve);
					goto filled;
				}
				if (ce.generation == generation)
					ve = ce; // way 0 moves to way 1, the new block goes to way 0
			}
			{
			PPCTBPage* page = GetTBPage(ip);
			std::atomic<PPCTBBlock*>& slot = page->blocks[(ip >> 2) & (kTBPageSlots - 1)];
			const uint32 version = page->version.load(std::memory_order_relaxed);
			PPCTBBlock* block = slot.load(std::memory_order_relaxed);
			if (!block || block->version != version)
			{
				PPCTBBlock* const old = block;
				IRIDIA_CNT(CNT_LOOP_BUILDS, 1);
				block = BuildBlock(hCPU, ip, version);
				if (tbStatsOn()) [[unlikely]]
				{
					(old ? s_tbStatStale : s_tbStatNew).fetch_add(1, std::memory_order_relaxed);
					if (old && block && old->count == block->count)
					{
						bool same = true;
						for (uint32 i = 0; i < block->count && same; i++)
							same = old->steps[i].opcode == block->steps[i].opcode && old->steps[i].address == block->steps[i].address;
						if (same)
							s_tbStatSame.fetch_add(1, std::memory_order_relaxed);
					}
					tbStatsReport();
				}
				if (!block)
				{
					hCPU->remainingCycles--;
					PPCInterpreterContainer<PPCItpCafeOSUsermode>::executeInstruction(hCPU); // unusual opcode
					continue;
				}
				slot.store(block, std::memory_order_release);
			}
			ce.ip = ip;
			ce.generation = generation;
			ce.steps = block->steps;
			}
		filled:;
		}
		if (s_tbVerify()) [[unlikely]]
		{
			TBVerifyBlock(hCPU, ce.steps);
			continue;
		}
		hCPU->remainingCycles -= (sint32)tbBlockCount(ce.steps);
		tbCountExec(hCPU, ce.steps);
		if (s_tbHistOn()) [[unlikely]]
			TBHistAdd(ip, ce.steps[0].r0 == 0xA0, tbBlockCount(ce.steps));
		ce.steps[0].fn(hCPU, ce.steps, hCPU->gpr[1]);
	}
}

void PPCInterpreterSlim_executeInstruction(PPCInterpreter_t* hCPU)
{
	PPCInterpreterContainer<PPCItpCafeOSUsermode>::executeInstruction(hCPU);
}
#else
void PPCInterpreter_invalidateDecodeCache(uint32 startAddr, uint32 endAddr) {}
void PPCInterpreter_tbCountSet(bool on) {}
void PPCInterpreter_tbCountDump(const char* path) {}

void PPCInterpreterSlim_executeInstruction(PPCInterpreter_t* hCPU)
{
	PPCInterpreterContainer<PPCItpCafeOSUsermode>::executeInstruction(hCPU);
}
#endif

// Full interpreter, supports most PowerPC features
// Used when emulator runs in LLE mode
void PPCInterpreterFull_executeInstruction(PPCInterpreter_t* hCPU)
{
	PPCInterpreterContainer<PPCItpSupervisorWithMMU>::executeInstruction(hCPU);
}

