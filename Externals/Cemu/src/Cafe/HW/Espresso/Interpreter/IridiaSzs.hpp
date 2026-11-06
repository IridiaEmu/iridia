#pragma once
// Iridia: native version of a Nintendo library routine, a resumable Yaz0 (SZS) stream decompressor (BotW: about
// a third of the busiest emulated core while the game streams the world). Found by its exact machine code (684
// bytes, position independent), so it applies in any game that contains the same routine. The native code
// reproduces the routine's whole visible effect: output bytes, the dcbz cache-line zeroing ahead of the output,
// the 24-byte context it updates and the return value. Not used while the stream header is still being parsed
// (the routine calls a helper for that): the guest code runs then.
// Guest call: r3 = context, r4 = input, r5 = input size. Context: +0 output pointer, +4 output bytes left (s32),
// +8 "clamp allowed" flag, +0xc group bit mask (u8), +0xd group header (u8), +0xe first byte of a pending
// back-reference (u8), +0x10 token state (0 = next token, 1 = second back-reference byte, 2 = extra length byte),
// +0x14 back-reference distance (u16), +0x16 header bytes still to parse (u8).

static constexpr uint32 kIridiaSzsSig[171] = {
		0x9421ffd8, 0xbf21000c, 0x7c0802a6, 0x7c7e1b78, 0x7c862378, 0x7cbf2b78, 0x9001002c, 0x881e0016,
		0x2c000000, 0x4182003c, 0x7fe5fb78, 0x7cc43378, 0x7fc3f378, 0x4bfffedd, 0x2c030000, 0x4180025c,
		0x7fe3f851, 0x7cc61a14, 0x40820018, 0x88fe0016, 0x2c070000, 0x4082022c, 0x807e0004, 0x4800023c,
		0x807e0004, 0x8bbe000e, 0x837e0000, 0x8b9e000d, 0x2c030000, 0x8b5e000c, 0x815e0010, 0xa33e0014,
		0x408101c8, 0x2c0a0002, 0x40820088, 0x89060000, 0x38880012, 0x38c60001, 0x7c041840, 0x3bffffff,
		0x40810014, 0x813e0008, 0x2c090000, 0x418200b8, 0x5464043e, 0x28040020, 0x39800020, 0x7c641850,
		0x40810014, 0x7c1b67ec, 0x398c0020, 0x7c0c2040, 0x4180fff4, 0x34a4ffff, 0x40820008, 0x38800001,
		0x7d99d850, 0x7c8903a6, 0x398cffff, 0x3b7bffff, 0x8d6c0001, 0x9d7b0001, 0x4200fff8, 0x2c1f0000,
		0x39400000, 0x3b7b0001, 0x40820138, 0x4800013c, 0x2c0a0001, 0x408200c0, 0x88060000, 0x57ac402e,
		0x3bffffff, 0x7d850378, 0x38c60001, 0x54a4053e, 0x54a5a33f, 0x3b240001, 0x40820014, 0x2c1f0000,
		0x39400002, 0x408200fc, 0x48000100, 0x38a50002, 0x7c051840, 0x4081002c, 0x80fe0008, 0x2c070000,
		0x4082001c, 0xbb21000c, 0x8001002c, 0x7c0803a6, 0x38210028, 0x3860fffe, 0x4e800020, 0x5465043e,
		0x576906fe, 0x7d692a14, 0x280b0020, 0x7c651850, 0x40810008, 0x7c1b2fec, 0x3545ffff, 0x40820008,
		0x38a00001, 0x7cf9d850, 0x7ca903a6, 0x38e7ffff, 0x3b7bffff, 0x8d870001, 0x9d9b0001, 0x4200fff8,
		0x2c1f0000, 0x39400000, 0x3b7b0001, 0x40820074, 0x48000078, 0x2c1a0000, 0x40820018, 0x37ffffff,
		0x3b400080, 0x8b860000, 0x38c60001, 0x4182005c, 0x7f80d039, 0x41820030, 0x576506ff, 0x40820008,
		0x7c00dfec, 0x89060000, 0x38c60001, 0x3863ffff, 0x3bffffff, 0x991b0000, 0x3b7b0001, 0x575af87e,
		0x48000018, 0x8ba60000, 0x575af87e, 0x3bffffff, 0x39400001, 0x38c60001, 0x2c1f0000, 0x4182000c,
		0x2c030000, 0x4181fe40, 0x937e0000, 0x2c030000, 0x9b9e000d, 0x9b5e000c, 0x915e0010, 0x9bbe000e,
		0x907e0004, 0xb33e0014, 0x40820030, 0x801e0008, 0x2c000000, 0x40820024, 0x281f0020, 0x4081001c,
		0xbb21000c, 0x8001002c, 0x7c0803a6, 0x38210028, 0x3860ffff, 0x4e800020, 0xbb21000c, 0x8001002c,
		0x7c0803a6, 0x38210028, 0x4e800020,
};

static bool IridiaSzs_Matches(uint32 address)
{
	if ((address >> 12) != ((address + sizeof(kIridiaSzsSig) - 1) >> 12))
		return false; // the whole routine must sit in the block's code page (its version covers it)
	for (uint32 i = 0; i < 171; i++)
		if (_swapEndianU32(*(uint32*)(memory_base + address + i * 4)) != kIridiaSzsSig[i])
			return false;
	return true;
}

// Runs the routine natively. false = not handled (header still pending); else ret = the routine's r3 and
// instrs = about how many guest instructions it would have run (charged as cycles).
static bool IridiaSzs_Run(uint32 ctx, uint32 r6, uint32 r31, uint32& ret, uint64& instrs)
{
	uint8* const M = memory_base;
	auto B = [M](uint32 a) -> uint32 { return M[a]; };
	auto dcbz = [M](uint32 ea) { memset(M + (ea & ~31u), 0, 32); };
	auto copy = [M](uint32 dst, uint32 dist, uint32 n) {
		// forward byte copy from dst - dist (an overlap repeats bytes, like the routine's lbzu/stbu loop)
		const uint32 src = dst - dist;
		if (dist >= n)
			memmove(M + dst, M + src, n);
		else
			for (uint32 i = 0; i < n; i++)
				M[dst + i] = M[src + i];
	};
	if (M[ctx + 0x16] != 0)
		return false;
	uint64 n = 22;
	uint32 r3 = memory_readU32(ctx + 4);
	uint32 r29 = M[ctx + 0xe];
	uint32 r27 = memory_readU32(ctx + 0);
	uint32 r28 = M[ctx + 0xd];
	uint32 r26 = M[ctx + 0xc];
	uint32 r10 = memory_readU32(ctx + 0x10);
	uint32 r25 = memory_readU16(ctx + 0x14);
	if ((sint32)r3 <= 0)
		goto store;
loop:
	if (r10 == 2)
	{
		uint32 r4 = B(r6) + 0x12;
		r6++; r31--;
		if (r4 > r3)
		{
			if (memory_readU32(ctx + 8) == 0) { ret = (uint32)-2; instrs = n + 15; return true; }
			r4 = r3 & 0xffff;
		}
		r3 -= r4;
		if (r4 > 0x20)
		{
			uint32 r12 = 0x20;
			do { dcbz(r27 + r12); r12 += 0x20; n += 4; } while (r12 < r4);
		}
		copy(r27, r25, r4);
		r27 += r4;
		r10 = 0;
		n += 28 + 3ull * r4;
		if (r31 != 0) goto check;
		goto store;
	}
	else if (r10 == 1)
	{
		const uint32 r5a = (r29 << 8) | B(r6);
		r31--; r6++;
		const uint32 r4 = r5a & 0xfff;
		uint32 r5 = (r5a >> 12) & 0xfffff;
		r25 = r4 + 1;
		n += 13;
		if (r5 == 0)
		{
			r10 = 2;
			if (r31 != 0) goto check;
			goto store;
		}
		r5 += 2;
		if (r5 > r3)
		{
			if (memory_readU32(ctx + 8) == 0) { ret = (uint32)-2; instrs = n + 10; return true; }
			r5 = r3 & 0xffff;
		}
		if ((r27 & 0x1f) + r5 > 0x20)
			dcbz(r27 + r5);
		r3 -= r5;
		copy(r27, r25, r5);
		r27 += r5;
		r10 = 0;
		n += 22 + 3ull * r5;
		if (r31 != 0) goto check;
		goto store;
	}
	else
	{
		n += 3;
		if (r26 == 0)
		{
			r31--;
			r26 = 0x80;
			r28 = B(r6);
			r6++;
			n += 6;
			if (r31 == 0) goto store;
		}
		if (r28 & r26)
		{
			if ((r27 & 0x1f) == 0)
				dcbz(r27);
			M[r27] = (uint8)B(r6);
			r6++; r3--; r31--; r27++;
			r26 >>= 1;
			n += 13;
		}
		else
		{
			r29 = B(r6);
			r26 >>= 1;
			r31--;
			r10 = 1;
			r6++;
			n += 8;
		}
		if (r31 == 0) goto store;
	}
check:
	n += 2;
	if ((sint32)r3 > 0)
		goto loop;
store:
	memory_writeU32(ctx + 0, r27);
	M[ctx + 0xd] = (uint8)r28;
	M[ctx + 0xc] = (uint8)r26;
	memory_writeU32(ctx + 0x10, r10);
	M[ctx + 0xe] = (uint8)r29;
	memory_writeU32(ctx + 4, r3);
	memory_writeU16(ctx + 0x14, (uint16)r25);
	if (r3 != 0)
		ret = r3;
	else if (memory_readU32(ctx + 8) != 0)
		ret = 0;
	else
		ret = r31 > 0x20 ? (uint32)-1 : 0;
	instrs = n + 20;
	return true;
}
