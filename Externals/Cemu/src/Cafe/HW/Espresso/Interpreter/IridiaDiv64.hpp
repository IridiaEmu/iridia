#pragma once
// Iridia: native version of a compiler runtime routine, unsigned 64-bit division (r3:r4 / r5:r6 -> r3:r4), which
// the guest code does one quotient bit at a time (about 14 guest instructions per bit). Found by its exact
// machine code (368 bytes), so it applies in any game built with the same runtime. Division by zero runs the
// guest code (its result there is whatever the bit loop leaves).

static constexpr uint32 kIridiaDiv64Sig[92] = {
		0x9421ffe8, 0x93c10010, 0x7c6b1b79, 0x93e10014, 0x7d6c5b78, 0x7caa2b78, 0x93a1000c, 0x40820018, 0x2c0a0000, 0x40820030, 0x7c843396, 0x38600000, 0x4800012c, 0x3d008000, 0x3be0003f, 0x7d096039, 0x40820030, 0x5508f87f, 0x3bffffff, 0x4082fff0, 0x48000020, 0x3d008000, 0x3be0001f, 0x7d0c2039, 0x40820010, 0x5508f87f, 0x3bffffff, 0x4082fff0, 0x2c0a0000, 0x3d008000, 0x41820020, 0x3920003f, 0x7d0c5039, 0x4082002c, 0x5508f87f, 0x3929ffff, 0x4082fff0, 0x4800001c, 0x3920001f, 0x7d0c3039, 0x40820010, 0x5508f87f, 0x3929ffff, 0x4082fff0, 0x3ba00000, 0x7c1f4800, 0x7fbeeb78, 0x41800098, 0x7fe9f851, 0x7c872378, 0x41820024, 0x215f0020, 0x7ca8f830, 0x399f0020, 0x7cc95430, 0x7cca6030, 0x7d0c4b78, 0x7cc6f830, 0x7d456378, 0x7ca92b78, 0x2c1f0000, 0x399f0001, 0x7cca3378, 0x41800058, 0x7d8903a6, 0x57ac083c, 0x57c80ffe, 0x57de083c, 0x7c0b4840, 0x7d9d4378, 0x41810010, 0x41800024, 0x7c075040, 0x4180001c, 0x7d8a3810, 0x7d8c6110, 0x7cea3850, 0x7d8c4850, 0x63de0001, 0x7d6c5850, 0x5528f800, 0x554cf87e, 0x5529f87e, 0x7d8a4378, 0x4200ffb4, 0x7fa3eb78, 0x7fc4f378, 0x83a1000c, 0x83e10014, 0x83c10010, 0x38210018, 0x4e800020
};

static bool IridiaDiv64_Matches(uint32 address)
{
	if ((address >> 12) != ((address + sizeof(kIridiaDiv64Sig) - 1) >> 12))
		return false; // the whole routine must sit in the block's code page (its version covers it)
	for (uint32 i = 0; i < 92; i++)
		if (_swapEndianU32(*(uint32*)(memory_base + address + i * 4)) != kIridiaDiv64Sig[i])
			return false;
	return true;
}

// false = not handled (division by zero). instrs = about how many guest instructions the routine would run.
static bool IridiaDiv64_Run(uint64 n, uint64 d, uint64& q, uint64& instrs)
{
	if (d == 0)
		return false;
	if ((n >> 32) == 0 && (d >> 32) == 0)
	{
		q = (uint32)n / (uint32)d;
		instrs = 13;
		return true;
	}
	q = n / d;
	// leading-bit scans (3 instructions per bit) and the shift-subtract loop (about 14 per quotient bit)
	const int msbN = 63 - __builtin_clzll(n), msbD = 63 - __builtin_clzll(d);
	const int scanN = (n >> 32) ? 63 - msbN : 31 - msbN, scanD = (d >> 32) ? 63 - msbD : 31 - msbD;
	instrs = 30 + 3ull * (scanN + scanD) + (msbN >= msbD ? 14ull * (msbN - msbD + 1) + 14 : 0);
	return true;
}
