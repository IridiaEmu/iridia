// Iridia study: BC1-BC5 -> ASTC 4x4 transcoder (see IridiaAstc.h). Written from the ASTC format description in the
// Khronos Data Format Specification; the decoder model below is checked against the GPU's own ASTC decoder by
// tools/astc_check (Mac).
#include "IridiaAstc.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>

namespace IridiaAstc
{
Stats g_stats[5];
namespace
{
	// ---- integer sequence encoding (BISE) ----
	struct Quant { int levels, bits, trits, quints; };
	// all ASTC quantisation levels, in increasing order
	constexpr Quant kQuants[] = {
		{2, 1, 0, 0}, {3, 0, 1, 0}, {4, 2, 0, 0}, {5, 0, 0, 1}, {6, 1, 1, 0}, {8, 3, 0, 0}, {10, 1, 0, 1},
		{12, 2, 1, 0}, {16, 4, 0, 0}, {20, 2, 0, 1}, {24, 3, 1, 0}, {32, 5, 0, 0}, {40, 3, 0, 1}, {48, 4, 1, 0},
		{64, 6, 0, 0}, {80, 4, 0, 1}, {96, 5, 1, 0}, {128, 7, 0, 0}, {160, 5, 0, 1}, {192, 6, 1, 0}, {256, 8, 0, 0}};

	int BiseBits(const Quant& q, int n)
	{
		return n * q.bits + (q.trits ? (8 * n + 4) / 5 : 0) + (q.quints ? (7 * n + 2) / 3 : 0);
	}

	// trit / quint packing tables, built by running the spec's unpacking procedure over every packed value
	uint8_t g_tritPack[3][3][3][3][3];
	uint8_t g_quintPack[5][5][5];
	uint8_t g_tritUnpack[256][5];
	uint8_t g_quintUnpack[128][3];

	inline int Bit(int v, int i) { return (v >> i) & 1; }
	inline int Bits(int v, int hi, int lo) { return (v >> lo) & ((1 << (hi - lo + 1)) - 1); }

	void UnpackTrits(int T, uint8_t t[5])
	{
		int C, t4, t3;
		if (Bits(T, 4, 2) == 7)
		{
			C = (Bits(T, 7, 5) << 2) | Bits(T, 1, 0);
			t4 = 2; t3 = 2;
		}
		else
		{
			C = Bits(T, 4, 0);
			if (Bits(T, 6, 5) == 3) { t4 = 2; t3 = Bit(T, 7); }
			else { t4 = Bit(T, 7); t3 = Bits(T, 6, 5); }
		}
		int t2, t1, t0;
		if (Bits(C, 1, 0) == 3)
		{
			t2 = 2; t1 = Bit(C, 4);
			t0 = (Bit(C, 3) << 1) | (Bit(C, 2) & ~Bit(C, 3) & 1);
		}
		else if (Bits(C, 3, 2) == 3)
		{
			t2 = 2; t1 = 2; t0 = Bits(C, 1, 0);
		}
		else
		{
			t2 = Bit(C, 4); t1 = Bits(C, 3, 2);
			t0 = (Bit(C, 1) << 1) | (Bit(C, 0) & ~Bit(C, 1) & 1);
		}
		t[0] = t0; t[1] = t1; t[2] = t2; t[3] = t3; t[4] = t4;
	}

	void UnpackQuints(int Q, uint8_t q[3])
	{
		int q0, q1, q2;
		if (Bits(Q, 2, 1) == 3 && Bits(Q, 6, 5) == 0)
		{
			q2 = (Bit(Q, 0) << 2) | ((Bit(Q, 4) & ~Bit(Q, 0) & 1) << 1) | (Bit(Q, 3) & ~Bit(Q, 0) & 1);
			q1 = 4; q0 = 4;
		}
		else
		{
			int C;
			if (Bits(Q, 2, 1) == 3)
			{
				q2 = 4;
				C = (Bits(Q, 4, 3) << 3) | ((~Bits(Q, 6, 5) & 3) << 1) | Bit(Q, 0);
			}
			else
			{
				q2 = Bits(Q, 6, 5);
				C = Bits(Q, 4, 0);
			}
			if (Bits(C, 2, 0) == 5) { q1 = 4; q0 = Bits(C, 4, 3); }
			else { q1 = Bits(C, 4, 3); q0 = Bits(C, 2, 0); }
		}
		q[0] = q0; q[1] = q1; q[2] = q2;
	}

	struct Bits128
	{
		uint64_t w[2] = {0, 0};
		void Put(int pos, int n, uint64_t v)
		{
			if (n <= 0) return;
			v &= (n >= 64) ? ~0ull : ((1ull << n) - 1);
			if (pos < 64)
			{
				w[0] |= v << pos;
				if (pos + n > 64) w[1] |= v >> (64 - pos);
			}
			else
				w[1] |= v << (pos - 64);
		}
		uint32_t Get(int pos, int n) const
		{
			uint64_t v;
			if (pos >= 64) v = w[1] >> (pos - 64);
			else if (pos + n <= 64) v = w[0] >> pos;
			else v = (w[0] >> pos) | (w[1] << (64 - pos));
			return (uint32_t)(v & ((1ull << n) - 1));
		}
		void Store(uint8_t out[16]) const { std::memcpy(out, w, 16); } // little-endian hosts (arm64)
		void Load(const uint8_t in[16]) { std::memcpy(w, in, 16); }
	};

	inline uint64_t Rev64(uint64_t x)
	{
#if defined(__clang__)
		return __builtin_bitreverse64(x);
#else
		uint64_t r = 0;
		for (int i = 0; i < 64; i++) r |= ((x >> i) & 1) << (63 - i);
		return r;
#endif
	}

	// write n BISE values (each value = (trit/quint << bits) | low bits) as a bit stream into bits [0, BiseBits)
	void BiseWrite(const Quant& q, const int* v, int n, Bits128& out, int pos)
	{
		const int end = pos + BiseBits(q, n);
		auto put = [&](int nb, uint32_t val) {
			int take = std::min(nb, end - pos);
			if (take > 0) out.Put(pos, take, val);
			pos += nb;
		};
		const int mask = (1 << q.bits) - 1;
		if (q.trits)
		{
			for (int g = 0; g < n; g += 5)
			{
				int m[5] = {}, t[5] = {};
				for (int i = 0; i < 5 && g + i < n; i++) { m[i] = v[g + i] & mask; t[i] = v[g + i] >> q.bits; }
				int T = g_tritPack[t[0]][t[1]][t[2]][t[3]][t[4]];
				put(q.bits, m[0]); put(2, Bits(T, 1, 0));
				put(q.bits, m[1]); put(2, Bits(T, 3, 2));
				put(q.bits, m[2]); put(1, Bit(T, 4));
				put(q.bits, m[3]); put(2, Bits(T, 6, 5));
				put(q.bits, m[4]); put(1, Bit(T, 7));
			}
		}
		else if (q.quints)
		{
			for (int g = 0; g < n; g += 3)
			{
				int m[3] = {}, t[3] = {};
				for (int i = 0; i < 3 && g + i < n; i++) { m[i] = v[g + i] & mask; t[i] = v[g + i] >> q.bits; }
				int Q = g_quintPack[t[0]][t[1]][t[2]];
				put(q.bits, m[0]); put(3, Bits(Q, 2, 0));
				put(q.bits, m[1]); put(2, Bits(Q, 4, 3));
				put(q.bits, m[2]); put(2, Bits(Q, 6, 5));
			}
		}
		else
		{
			for (int i = 0; i < n; i++) put(q.bits, v[i]);
		}
	}

	void BiseRead(const Quant& q, int* v, int n, const Bits128& in, int pos)
	{
		const int end = pos + BiseBits(q, n);
		auto get = [&](int nb) -> uint32_t {
			int take = std::min(nb, end - pos);
			uint32_t r = take > 0 ? in.Get(pos, take) : 0;
			pos += nb;
			return r;
		};
		if (q.trits)
		{
			for (int g = 0; g < n; g += 5)
			{
				int m[5], T = 0;
				m[0] = get(q.bits); T |= get(2);
				m[1] = get(q.bits); T |= get(2) << 2;
				m[2] = get(q.bits); T |= get(1) << 4;
				m[3] = get(q.bits); T |= get(2) << 5;
				m[4] = get(q.bits); T |= get(1) << 7;
				for (int i = 0; i < 5 && g + i < n; i++) v[g + i] = (g_tritUnpack[T][i] << q.bits) | m[i];
			}
		}
		else if (q.quints)
		{
			for (int g = 0; g < n; g += 3)
			{
				int m[3], Q = 0;
				m[0] = get(q.bits); Q |= get(3);
				m[1] = get(q.bits); Q |= get(2) << 3;
				m[2] = get(q.bits); Q |= get(2) << 5;
				for (int i = 0; i < 3 && g + i < n; i++) v[g + i] = (g_quintUnpack[Q][i] << q.bits) | m[i];
			}
		}
		else
		{
			for (int i = 0; i < n; i++) v[i] = get(q.bits);
		}
	}

	// ---- unquantisation ----
	// colour endpoint value (BISE code) -> 0..255
	int UnquantColor(const Quant& q, int code)
	{
		if (!q.trits && !q.quints)
		{
			int v = code << (8 - q.bits); // bit replication
			for (int s = q.bits; s < 8; s += q.bits) v |= (code << (8 - q.bits)) >> s;
			return v & 0xFF;
		}
		const int b = q.bits, m = code & ((1 << b) - 1), D = code >> b;
		const int A = (m & 1) ? 0x1FF : 0;
		auto bit = [&](int i) { return (m >> i) & 1; };
		int B = 0, C = 0;
		// B is a 9-bit pattern of the low bits; written MSB first (a = bit 0 of m, b = bit 1, ...)
		auto pat = [&](const char* p) {
			int r = 0;
			for (int i = 0; i < 9; i++) r = (r << 1) | (p[i] == '0' ? 0 : bit(p[i] - 'a'));
			return r;
		};
		if (q.trits)
		{
			switch (b)
			{
			case 1: B = 0; C = 204; break;
			case 2: B = pat("b000b0bb0"); C = 93; break;
			case 3: B = pat("cb000cbcb"); C = 44; break;
			case 4: B = pat("dcb000dcb"); C = 22; break;
			case 5: B = pat("edcb000ed"); C = 11; break;
			case 6: B = pat("fedcb000f"); C = 5; break;
			}
		}
		else
		{
			switch (b)
			{
			case 1: B = 0; C = 113; break;
			case 2: B = pat("b0000bb00"); C = 54; break;
			case 3: B = pat("cb0000cbc"); C = 26; break;
			case 4: B = pat("dcb0000dc"); C = 13; break;
			case 5: B = pat("edcb0000e"); C = 6; break;
			}
		}
		if (b == 0) return 0;
		int T = D * C + B;
		T ^= A;
		return (A & 0x80) | (T >> 2);
	}

	// weight value -> 0..64 (only the weight levels used here: 3, 4, 8, 16)
	int UnquantWeight(const Quant& q, int code)
	{
		if (q.trits && q.bits == 0) return code * 32; // 0, 32, 64
		int v = code << (6 - q.bits);
		for (int s = q.bits; s < 6; s += q.bits) v |= (code << (6 - q.bits)) >> s;
		v &= 0x3F;
		return v > 32 ? v + 1 : v;
	}

	const Quant& QuantByLevels(int levels)
	{
		for (const auto& q : kQuants) if (q.levels == levels) return q;
		return kQuants[0];
	}

	// highest endpoint quantisation that fits the bits left
	const Quant* EndpointQuant(int nValues, int bitsAvail)
	{
		const Quant* best = nullptr;
		for (const auto& q : kQuants)
			if (BiseBits(q, nValues) <= bitsAvail) best = &q;
		return best;
	}

	struct Tables
	{
		// per endpoint quant level: code -> value, and value -> nearest code
		int unq[21][256];
		uint8_t nearest[21][256];
	} g_t;
	std::once_flag g_once;

	int QuantIndex(const Quant* q) { return (int)(q - kQuants); }

	void Init()
	{
		std::memset(g_tritPack, 0, sizeof(g_tritPack));
		std::memset(g_quintPack, 0, sizeof(g_quintPack));
		bool tSeen[3][3][3][3][3] = {};
		for (int T = 0; T < 256; T++)
		{
			uint8_t t[5];
			UnpackTrits(T, t);
			std::memcpy(g_tritUnpack[T], t, 5);
			if (!tSeen[t[0]][t[1]][t[2]][t[3]][t[4]]) { tSeen[t[0]][t[1]][t[2]][t[3]][t[4]] = true; g_tritPack[t[0]][t[1]][t[2]][t[3]][t[4]] = (uint8_t)T; }
		}
		bool qSeen[5][5][5] = {};
		for (int Q = 0; Q < 128; Q++)
		{
			uint8_t q[3];
			UnpackQuints(Q, q);
			std::memcpy(g_quintUnpack[Q], q, 3);
			if (!qSeen[q[0]][q[1]][q[2]]) { qSeen[q[0]][q[1]][q[2]] = true; g_quintPack[q[0]][q[1]][q[2]] = (uint8_t)Q; }
		}
		for (int i = 0; i < 21; i++)
		{
			const Quant& q = kQuants[i];
			for (int c = 0; c < q.levels; c++) g_t.unq[i][c] = UnquantColor(q, c);
			for (int v = 0; v < 256; v++)
			{
				int bc = 0, be = 1 << 30;
				for (int c = 0; c < q.levels; c++)
				{
					int e = std::abs(g_t.unq[i][c] - v);
					if (e < be) { be = e; bc = c; }
				}
				g_t.nearest[i][v] = (uint8_t)bc;
			}
		}
	}

	// ---- block layout ----
	// CEM 8 = RGB direct (6 values), CEM 12 = RGBA direct (8 values); single partition, 4x4 weight grid
	struct Mode
	{
		int cem;          // 8 or 12
		bool dual;        // second weight plane
		int ccs;          // channel of the second plane (0..3)
		int wLevels;      // weight levels (3, 4, 8 or 16)
	};

	int BlockModeBits(const Mode& m)
	{
		// 2D block mode, layout with bits[1:0] != 0 and bits[3:2] == 0: width = B + 4, height = A + 2
		// weight range R = (bits[1:0] << 1) | bit4, high precision H = bit9: quant index = R - 2 + 6 * H
		int qi = QuantIndex(&QuantByLevels(m.wLevels)); // index in kQuants == ASTC weight quant index for these levels
		int H = qi >= 6 ? 1 : 0;
		int R = qi - 6 * H + 2;
		const int A = 2, B = 0; // 4 x 4
		return ((R >> 1) & 3) | ((R & 1) << 4) | (A << 5) | (B << 7) | (H << 9) | ((m.dual ? 1 : 0) << 10);
	}

	struct Layout { int weightBits, colorBits; const Quant* wq; const Quant* cq; int nColor, nWeights; };

	bool GetLayout(const Mode& m, Layout& L)
	{
		L.wq = &QuantByLevels(m.wLevels);
		L.nWeights = 16 * (m.dual ? 2 : 1);
		L.weightBits = BiseBits(*L.wq, L.nWeights);
		L.nColor = m.cem == 12 ? 8 : 6;
		int avail = 128 - 17 - L.weightBits - (m.dual ? 2 : 0);
		L.cq = EndpointQuant(L.nColor, avail);
		if (!L.cq || L.weightBits < 24 || L.weightBits > 96) return false;
		L.colorBits = BiseBits(*L.cq, L.nColor);
		return true;
	}

	// expand to 16 bits and interpolate like the decoder (LDR), result as 8-bit
	inline int Interp(int e0, int e1, int w, bool srgb)
	{
		int E0 = srgb ? ((e0 << 8) | 0x80) : ((e0 << 8) | e0);
		int E1 = srgb ? ((e1 << 8) | 0x80) : ((e1 << 8) | e1);
		int c = (E0 * (64 - w) + E1 * w + 32) >> 6;
		return c >> 8;
	}

	struct Candidate
	{
		Mode mode;
		Layout L;
		int codes[8];      // endpoint codes, in block order (r0 r1 g0 g1 b0 b1 [a0 a1])
		int wcodes[32];    // weight codes (interleaved planes for dual)
		uint64_t err = ~0ull;
	};

	// endpoint values after the decoder's ordering rule (no blue contraction: we always store s1 >= s0)
	void EndpointsFromCodes(const Candidate& c, int e0[4], int e1[4])
	{
		const int qi = QuantIndex(c.L.cq);
		int v[8];
		for (int i = 0; i < c.L.nColor; i++) v[i] = g_t.unq[qi][c.codes[i]];
		e0[0] = v[0]; e1[0] = v[1]; e0[1] = v[2]; e1[1] = v[3]; e0[2] = v[4]; e1[2] = v[5];
		if (c.mode.cem == 12) { e0[3] = v[6]; e1[3] = v[7]; }
		else { e0[3] = 255; e1[3] = 255; }
	}

	// fit: line endpoints per plane from the texels (PCA for the main plane, min/max for the second plane),
	// quantise, order, choose weights; returns error
	void Fit(Candidate& c, const uint8_t px[64], const bool chanUsed[4], bool srgb)
	{
		const Mode& m = c.mode;
		const int nch = m.cem == 12 ? 4 : 3;
		// main-plane channels
		bool inMain[4];
		for (int ch = 0; ch < 4; ch++) inMain[ch] = ch < nch && !(m.dual && ch == m.ccs);
		// texels that shape the main-plane line: with alpha in its own plane, the colour of fully transparent texels
		// (BC1 punch-through decodes them as black) is mostly invisible, so the line follows the visible ones
		bool fitTexel[16];
		int nFit = 0;
		for (int i = 0; i < 16; i++) { fitTexel[i] = !(m.dual && m.ccs == 3 && px[i * 4 + 3] == 0); nFit += fitTexel[i]; }
		if (nFit == 0) { for (int i = 0; i < 16; i++) fitTexel[i] = true; nFit = 16; }
		// PCA axis of the main plane
		float mean[4] = {};
		for (int i = 0; i < 16; i++) if (fitTexel[i]) for (int ch = 0; ch < 4; ch++) mean[ch] += px[i * 4 + ch];
		for (int ch = 0; ch < 4; ch++) mean[ch] /= (float)nFit;
		float cov[4][4] = {};
		for (int i = 0; i < 16; i++)
			if (fitTexel[i])
				for (int a = 0; a < 4; a++) for (int b = 0; b < 4; b++)
					if (inMain[a] && inMain[b]) cov[a][b] += (px[i * 4 + a] - mean[a]) * (px[i * 4 + b] - mean[b]);
		// start from the covariance column of the channel with the largest variance (a fixed start such as (1,1,1)
		// can be orthogonal to the main axis, e.g. red -> blue, and the iteration then collapses to the mean)
		int maxCh = 0;
		for (int ch = 1; ch < 4; ch++) if (cov[ch][ch] > cov[maxCh][maxCh]) maxCh = ch;
		float axis[4];
		for (int ch = 0; ch < 4; ch++) axis[ch] = inMain[ch] ? cov[ch][maxCh] : 0.0f;
		if (cov[maxCh][maxCh] <= 0.0f) for (int ch = 0; ch < 4; ch++) axis[ch] = inMain[ch] ? 1.0f : 0.0f;
		for (int it = 0; it < 8; it++)
		{
			float n[4] = {};
			for (int a = 0; a < 4; a++) for (int b = 0; b < 4; b++) n[a] += cov[a][b] * axis[b];
			float len = std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2] + n[3] * n[3]);
			if (len < 1e-6f) break;
			for (int a = 0; a < 4; a++) axis[a] = n[a] / len;
		}
		float tmin = 1e30f, tmax = -1e30f;
		for (int i = 0; i < 16; i++)
		{
			if (!fitTexel[i]) continue;
			float t = 0;
			for (int ch = 0; ch < 4; ch++) if (inMain[ch]) t += (px[i * 4 + ch] - mean[ch]) * axis[ch];
			tmin = std::min(tmin, t); tmax = std::max(tmax, t);
		}
		float lo[4], hi[4];
		for (int ch = 0; ch < 4; ch++)
		{
			if (inMain[ch]) { lo[ch] = mean[ch] + axis[ch] * tmin; hi[ch] = mean[ch] + axis[ch] * tmax; }
			else if (ch < nch) // second plane: its own min / max
			{
				int mn = 255, mx = 0;
				for (int i = 0; i < 16; i++) { mn = std::min<int>(mn, px[i * 4 + ch]); mx = std::max<int>(mx, px[i * 4 + ch]); }
				lo[ch] = (float)mn; hi[ch] = (float)mx;
			}
			else { lo[ch] = hi[ch] = 255; }
			if (!chanUsed[ch]) { lo[ch] = hi[ch] = (ch == 3 ? 255.0f : 0.0f); }
		}
		const int qi = QuantIndex(c.L.cq);
		auto q8 = [&](float f) { return (int)g_t.nearest[qi][std::clamp((int)std::lround(f), 0, 255)]; };
		int c0[4], c1[4];
		for (int ch = 0; ch < 4; ch++) { c0[ch] = q8(lo[ch]); c1[ch] = q8(hi[ch]); }
		// decoder rule: if sum(rgb of endpoint 1) < sum(rgb of endpoint 0) it swaps and blue-contracts; keep s1 >= s0
		auto sumv = [&](const int* cc) { return g_t.unq[qi][cc[0]] + g_t.unq[qi][cc[1]] + g_t.unq[qi][cc[2]]; };
		if (sumv(c1) < sumv(c0)) std::swap(c0, c1);
		c.codes[0] = c0[0]; c.codes[1] = c1[0]; c.codes[2] = c0[1]; c.codes[3] = c1[1]; c.codes[4] = c0[2]; c.codes[5] = c1[2];
		if (m.cem == 12) { c.codes[6] = c0[3]; c.codes[7] = c1[3]; }
		// weights: per texel and plane, the level with the lowest error
		int e0[4], e1[4];
		EndpointsFromCodes(c, e0, e1);
		const Quant& wq = *c.L.wq;
		uint64_t err = 0;
		for (int i = 0; i < 16; i++)
		{
			for (int plane = 0; plane < (m.dual ? 2 : 1); plane++)
			{
				uint64_t be = ~0ull; int bw = 0;
				for (int w = 0; w < wq.levels; w++)
				{
					int wv = UnquantWeight(wq, w);
					uint64_t e = 0;
					for (int ch = 0; ch < 4; ch++)
					{
						bool mine = m.dual ? ((ch == m.ccs) == (plane == 1)) : (plane == 0);
						if (!mine) continue;
						int d = Interp(e0[ch], e1[ch], wv, srgb && ch < 3) - px[i * 4 + ch];
						// the colour of a fully transparent texel only breaks ties (same rule for every candidate)
						e += (uint64_t)(d * d) * (ch < 3 && px[i * 4 + 3] == 0 ? 1 : 16);
					}
					if (e < be) { be = e; bw = w; }
				}
				c.wcodes[m.dual ? i * 2 + plane : i] = bw;
				err += be / 16;
			}
		}
		c.err = err;
	}

	void Emit(const Candidate& c, uint8_t out[16])
	{
		Bits128 b;
		b.Put(0, 11, BlockModeBits(c.mode));
		b.Put(11, 2, 0);                 // one partition
		b.Put(13, 4, c.mode.cem);
		BiseWrite(*c.L.cq, c.codes, c.L.nColor, b, 17);
		if (c.mode.dual) b.Put(128 - c.L.weightBits - 2, 2, c.mode.ccs);
		// weights are stored from the top bit down, bit-reversed: weight bit i -> block bit 127 - i
		Bits128 w;
		BiseWrite(*c.L.wq, c.wcodes, c.L.nWeights, w, 0);
		b.w[0] |= Rev64(w.w[1]);
		b.w[1] |= Rev64(w.w[0]);
		b.Store(out);
	}

	bool MakeCandidate(Candidate& c, int cem, bool dual, int ccs, int wLevels)
	{
		c.mode = {cem, dual, ccs, wLevels};
		return GetLayout(c.mode, c.L);
	}

	// ---- fast paths: map BC blocks straight onto fixed ASTC modes (no search) ----
	enum { T_RGB4, T_RGB3, T_RGBA_D3, T_RGBA_D4, T_R8, T_RG_D4, T_COUNT };
	Candidate g_tmpl[T_COUNT];
	std::once_flag g_tmplOnce;
	void InitTemplates()
	{
		std::call_once(g_once, Init);
		MakeCandidate(g_tmpl[T_RGB4], 8, false, 0, 4);     // BC1 4-colour: endpoints 8-bit, weights 0 21 43 64
		MakeCandidate(g_tmpl[T_RGB3], 8, false, 0, 3);     // BC1 3-colour: weights 0 32 64
		MakeCandidate(g_tmpl[T_RGBA_D3], 12, true, 3, 3);  // BC1 with transparent texels: endpoints 7-bit
		MakeCandidate(g_tmpl[T_RGBA_D4], 12, true, 3, 4);  // BC2 / BC3: colour 4 levels, alpha 4 levels, endpoints 48 levels
		MakeCandidate(g_tmpl[T_R8], 8, false, 0, 8);       // BC4: 8 levels
		MakeCandidate(g_tmpl[T_RG_D4], 8, true, 1, 4);     // BC5: R and G planes, 4 levels each
	}

	inline void Expand565(uint16_t c, int out[3])
	{
		int r = (c >> 11) & 31, g = (c >> 5) & 63, b = c & 31;
		out[0] = (r << 3) | (r >> 2); out[1] = (g << 2) | (g >> 4); out[2] = (b << 3) | (b >> 2);
	}

	// nearest weight level (of a QUANT_4 / QUANT_8 / ... bits-only weight range) for value v between e0 and e1
	inline int NearestWeight(const Quant& wq, int e0, int e1, int v, bool srgb)
	{
		int best = 0, be = 1 << 30;
		for (int w = 0; w < wq.levels; w++)
		{
			int d = Interp(e0, e1, UnquantWeight(wq, w), srgb) - v;
			d = d < 0 ? -d : d;
			if (d < be) { be = d; best = w; }
		}
		return best;
	}

	// colour part of a BC1 / BC2 / BC3 block into plane-0 weights + RGB endpoint codes of candidate c.
	// four = 4-colour mode (always for BC2/BC3); stride / plane: where the colour weights go (2 / 0 with dual plane)
	void ColorPlane(Candidate& c, const uint8_t* p, bool four, int stride, int plane)
	{
		uint16_t c0 = p[0] | (p[1] << 8), c1 = p[2] | (p[3] << 8);
		int e0[3], e1[3];
		Expand565(c0, e0); Expand565(c1, e1);
		const int qi = QuantIndex(c.L.cq);
		for (int ch = 0; ch < 3; ch++) { c.codes[ch * 2] = g_t.nearest[qi][e0[ch]]; c.codes[ch * 2 + 1] = g_t.nearest[qi][e1[ch]]; }
		uint32_t idx = p[4] | (p[5] << 8) | (p[6] << 16) | ((uint32_t)p[7] << 24);
		// BC1 palette order 0, 1, 2/3 c0 + 1/3 c1, 1/3 c0 + 2/3 c1 (4-colour) or 0, 1, half, transparent (3-colour)
		static const int map4[4] = {0, 3, 1, 2}, map3[4] = {0, 2, 1, 0};
		for (int i = 0; i < 16; i++)
		{
			int k = (idx >> (2 * i)) & 3;
			c.wcodes[i * stride + plane] = four ? map4[k] : map3[k];
		}
	}

	// keep sum(rgb endpoint 1) >= sum(rgb endpoint 0), or the decoder swaps and blue-contracts: swap every channel's
	// endpoints and mirror every weight instead
	void FixOrder(Candidate& c)
	{
		const int qi = QuantIndex(c.L.cq);
		int s0 = g_t.unq[qi][c.codes[0]] + g_t.unq[qi][c.codes[2]] + g_t.unq[qi][c.codes[4]];
		int s1 = g_t.unq[qi][c.codes[1]] + g_t.unq[qi][c.codes[3]] + g_t.unq[qi][c.codes[5]];
		if (s1 >= s0) return;
		for (int k = 0; k < c.L.nColor; k += 2) std::swap(c.codes[k], c.codes[k + 1]);
		for (int i = 0; i < c.L.nWeights; i++) c.wcodes[i] = c.L.wq->levels - 1 - c.wcodes[i];
	}

	// one channel (values v[16]) into plane `plane` with min / max endpoints at codes[k], codes[k + 1]
	void ChannelPlane(Candidate& c, const uint8_t* v, int vstride, int k, int stride, int plane, bool srgb)
	{
		int mn = 255, mx = 0;
		for (int i = 0; i < 16; i++) { mn = std::min<int>(mn, v[i * vstride]); mx = std::max<int>(mx, v[i * vstride]); }
		const int qi = QuantIndex(c.L.cq);
		c.codes[k] = g_t.nearest[qi][mn]; c.codes[k + 1] = g_t.nearest[qi][mx];
		const int e0 = g_t.unq[qi][c.codes[k]], e1 = g_t.unq[qi][c.codes[k + 1]];
		for (int i = 0; i < 16; i++) c.wcodes[i * stride + plane] = NearestWeight(*c.L.wq, e0, e1, v[i * vstride], srgb);
	}

	bool FastEncode(Src src, const uint8_t* blk, uint8_t out[16], bool srgb)
	{
		std::call_once(g_tmplOnce, InitTemplates);
		switch (src)
		{
		case Src::BC1:
		{
			uint16_t c0 = blk[0] | (blk[1] << 8), c1 = blk[2] | (blk[3] << 8);
			uint32_t idx = blk[4] | (blk[5] << 8) | (blk[6] << 16) | ((uint32_t)blk[7] << 24);
			bool transparent = false;
			if (c0 <= c1) for (int i = 0; i < 16; i++) transparent |= ((idx >> (2 * i)) & 3) == 3;
			if (c0 > c1 || !transparent)
			{
				Candidate c = g_tmpl[c0 > c1 ? T_RGB4 : T_RGB3];
				ColorPlane(c, blk, c0 > c1, 1, 0);
				FixOrder(c);
				Emit(c, out);
				return true;
			}
			// transparent texels: alpha in its own plane (0 or 1), colour weights as in the 3-colour mode
			Candidate c = g_tmpl[T_RGBA_D3];
			ColorPlane(c, blk, false, 2, 0);
			// transparent texels decode to black on BC1: give them the darker endpoint's colour (filtering blends
			// it into the edges of alpha-tested foliage)
			{
				int e0[3], e1[3];
				Expand565(c0, e0); Expand565(c1, e1);
				const int dark = (e0[0] + e0[1] + e0[2] <= e1[0] + e1[1] + e1[2]) ? 0 : 2;
				for (int i = 0; i < 16; i++) if (((idx >> (2 * i)) & 3) == 3) c.wcodes[i * 2] = dark;
			}
			const int qi = QuantIndex(c.L.cq);
			c.codes[6] = g_t.nearest[qi][0]; c.codes[7] = g_t.nearest[qi][255];
			for (int i = 0; i < 16; i++) c.wcodes[i * 2 + 1] = ((idx >> (2 * i)) & 3) == 3 ? 0 : 2;
			FixOrder(c);
			Emit(c, out);
			return true;
		}
		case Src::BC2:
		case Src::BC3:
		{
			uint8_t px[64];
			DecodeBC(src, blk, px);
			bool opaque = true;
			for (int i = 0; i < 16; i++) opaque &= px[i * 4 + 3] == 255;
			if (opaque)
			{
				Candidate c = g_tmpl[T_RGB4];
				ColorPlane(c, blk + 8, true, 1, 0);
				FixOrder(c);
				Emit(c, out);
				return true;
			}
			Candidate c = g_tmpl[T_RGBA_D4];
			ColorPlane(c, blk + 8, true, 2, 0);
			ChannelPlane(c, px + 3, 4, 6, 2, 1, false);
			FixOrder(c);
			Emit(c, out);
			return true;
		}
		case Src::BC4:
		{
			if (blk[0] <= blk[1])
				return false; // 6-level mode with fixed 0 / 255: the search below handles it
			// 8-level mode: palette i = a0 + (a1 - a0) * w / 7 with w = 0 (index 0), 7 (index 1), index - 1 (2..7)
			Candidate c = g_tmpl[T_R8];
			const int qi = QuantIndex(c.L.cq);
			c.codes[0] = blk[0]; c.codes[1] = blk[1];
			for (int k = 2; k < 6; k++) c.codes[k] = g_t.nearest[qi][0];
			uint64_t idx = 0;
			for (int i = 0; i < 6; i++) idx |= (uint64_t)blk[2 + i] << (8 * i);
			for (int i = 0; i < 16; i++)
			{
				int k = (idx >> (3 * i)) & 7;
				c.wcodes[i] = k == 0 ? 0 : (k == 1 ? 7 : k - 1);
			}
			FixOrder(c); // a0 > a1: endpoint 1 is darker, so this swaps
			Emit(c, out);
			return true;
		}
		case Src::BC5:
		{
			uint8_t px[64];
			DecodeBC(src, blk, px);
			Candidate c = g_tmpl[T_RG_D4];
			ChannelPlane(c, px + 0, 4, 0, 2, 0, false);
			ChannelPlane(c, px + 1, 4, 2, 2, 1, false);
			const int qi = QuantIndex(c.L.cq);
			c.codes[4] = c.codes[5] = g_t.nearest[qi][0];
			Emit(c, out); // min / max endpoints: sums never decrease, no swap needed
			return true;
		}
		}
		return false;
	}
} // namespace

void DecodeBC(Src src, const uint8_t* blk, uint8_t rgba[64])
{
	auto color565 = [](uint16_t c, int out[3]) {
		int r = (c >> 11) & 31, g = (c >> 5) & 63, b = c & 31;
		out[0] = (r << 3) | (r >> 2); out[1] = (g << 2) | (g >> 4); out[2] = (b << 3) | (b >> 2);
	};
	auto bc1 = [&](const uint8_t* p, bool forceFour) {
		uint16_t c0 = p[0] | (p[1] << 8), c1 = p[2] | (p[3] << 8);
		int pal[4][4];
		color565(c0, pal[0]); color565(c1, pal[1]);
		pal[0][3] = pal[1][3] = 255;
		if (c0 > c1 || forceFour)
		{
			for (int ch = 0; ch < 3; ch++) { pal[2][ch] = (2 * pal[0][ch] + pal[1][ch] + 1) / 3; pal[3][ch] = (pal[0][ch] + 2 * pal[1][ch] + 1) / 3; }
			pal[2][3] = pal[3][3] = 255;
		}
		else
		{
			for (int ch = 0; ch < 3; ch++) { pal[2][ch] = (pal[0][ch] + pal[1][ch] + 1) / 2; pal[3][ch] = 0; }
			pal[2][3] = 255; pal[3][3] = 0;
		}
		uint32_t idx = p[4] | (p[5] << 8) | (p[6] << 16) | ((uint32_t)p[7] << 24);
		for (int i = 0; i < 16; i++) for (int ch = 0; ch < 4; ch++) rgba[i * 4 + ch] = (uint8_t)pal[(idx >> (2 * i)) & 3][ch];
	};
	auto bc4 = [](const uint8_t* p, uint8_t out[16]) {
		int a0 = p[0], a1 = p[1], pal[8];
		pal[0] = a0; pal[1] = a1;
		if (a0 > a1) for (int i = 1; i < 7; i++) pal[i + 1] = ((7 - i) * a0 + i * a1 + 3) / 7;
		else { for (int i = 1; i < 5; i++) pal[i + 1] = ((5 - i) * a0 + i * a1 + 2) / 5; pal[6] = 0; pal[7] = 255; }
		uint64_t idx = 0;
		for (int i = 0; i < 6; i++) idx |= (uint64_t)p[2 + i] << (8 * i);
		for (int i = 0; i < 16; i++) out[i] = (uint8_t)pal[(idx >> (3 * i)) & 7];
	};
	switch (src)
	{
	case Src::BC1: bc1(blk, false); break;
	case Src::BC2:
		bc1(blk + 8, true);
		for (int i = 0; i < 16; i++) { int a = (blk[i / 2] >> ((i & 1) * 4)) & 15; rgba[i * 4 + 3] = (uint8_t)(a * 17); }
		break;
	case Src::BC3:
	{
		bc1(blk + 8, true);
		uint8_t a[16];
		bc4(blk, a);
		for (int i = 0; i < 16; i++) rgba[i * 4 + 3] = a[i];
		break;
	}
	case Src::BC4:
	{
		uint8_t r[16];
		bc4(blk, r);
		for (int i = 0; i < 16; i++) { rgba[i * 4] = r[i]; rgba[i * 4 + 1] = 0; rgba[i * 4 + 2] = 0; rgba[i * 4 + 3] = 255; }
		break;
	}
	case Src::BC5:
	{
		uint8_t r[16], g[16];
		bc4(blk, r); bc4(blk + 8, g);
		for (int i = 0; i < 16; i++) { rgba[i * 4] = r[i]; rgba[i * 4 + 1] = g[i]; rgba[i * 4 + 2] = 0; rgba[i * 4 + 3] = 255; }
		break;
	}
	}
}

uint64_t EncodeBlock(Src src, const uint8_t px[64], uint8_t out[16], bool srgb)
{
	std::call_once(g_once, Init);
	bool alphaAll255 = true;
	for (int i = 0; i < 16; i++) alphaAll255 &= px[i * 4 + 3] == 255;
	bool used[4] = {true, true, true, true};
	if (src == Src::BC4) used[1] = used[2] = false;
	if (src == Src::BC5) used[2] = false;

	Candidate cands[6];
	int n = 0;
	auto add = [&](int cem, bool dual, int ccs, int wl) { if (MakeCandidate(cands[n], cem, dual, ccs, wl)) n++; };
	switch (src)
	{
	case Src::BC1:
	case Src::BC2:
	case Src::BC3:
		if (alphaAll255) { add(8, false, 0, 4); add(8, false, 0, 3); add(8, false, 0, 8); }
		else { add(12, true, 3, 3); add(12, true, 3, 4); add(12, false, 0, 4); }
		break;
	case Src::BC4: add(8, false, 0, 8); break;
	case Src::BC5: add(8, true, 1, 4); add(8, true, 1, 3); add(8, false, 0, 8); break;
	}
	int best = -1;
	for (int i = 0; i < n; i++)
	{
		Fit(cands[i], px, used, srgb);
		if (best < 0 || cands[i].err < cands[best].err) best = i;
	}
	Emit(cands[best], out);
	return cands[best].err;
}

uint64_t TranscodeBlock(Src src, const uint8_t* bcBlock, uint8_t out[16], bool srgb, bool measure)
{
	if (FastEncode(src, bcBlock, out, srgb))
	{
		if (!measure) return 0;
		uint8_t px[64], dec[64];
		DecodeBC(src, bcBlock, px);
		DecodeBlock(out, dec, srgb);
		uint64_t err = 0;
		for (int i = 0; i < 16; i++)
			for (int ch = 0; ch < 4; ch++)
			{
				int d = dec[i * 4 + ch] - px[i * 4 + ch];
				if (ch < 3 && px[i * 4 + 3] == 0) continue; // colour under alpha 0: not counted (as in EncodeBlock)
				err += (uint64_t)(d * d);
			}
		return err;
	}
	uint8_t px[64];
	DecodeBC(src, bcBlock, px);
	return EncodeBlock(src, px, out, srgb);
}

bool DecodeBlock(const uint8_t in[16], uint8_t rgba[64], bool srgb)
{
	std::call_once(g_once, Init);
	Bits128 b;
	b.Load(in);
	int bm = b.Get(0, 11);
	if (b.Get(11, 2) != 0) return false;
	Candidate c;
	c.mode.cem = b.Get(13, 4);
	if (c.mode.cem != 8 && c.mode.cem != 12) return false;
	c.mode.dual = (bm >> 10) & 1;
	int R = ((bm & 3) << 1) | ((bm >> 4) & 1), H = (bm >> 9) & 1;
	if ((bm & 3) == 0 || ((bm >> 2) & 3) != 0 || ((bm >> 5) & 3) != 2 || ((bm >> 7) & 3) != 0) return false;
	c.mode.wLevels = kQuants[R - 2 + 6 * H].levels;
	if (!GetLayout(c.mode, c.L)) return false;
	BiseRead(*c.L.cq, c.codes, c.L.nColor, b, 17);
	if (c.mode.dual) c.mode.ccs = b.Get(128 - c.L.weightBits - 2, 2);
	Bits128 w;
	w.w[0] = Rev64(b.w[1]); w.w[1] = Rev64(b.w[0]);
	BiseRead(*c.L.wq, c.wcodes, c.L.nWeights, w, 0);
	int e0[4], e1[4];
	EndpointsFromCodes(c, e0, e1);
	int s0 = e0[0] + e0[1] + e0[2], s1 = e1[0] + e1[1] + e1[2];
	if (s1 < s0)
	{
		// swap + blue contraction (not produced by the encoder; modelled for completeness)
		std::swap(e0, e1);
		for (int* e : {e0, e1}) { e[0] = (e[0] + e[2]) >> 1; e[1] = (e[1] + e[2]) >> 1; }
	}
	for (int i = 0; i < 16; i++)
		for (int ch = 0; ch < 4; ch++)
		{
			int plane = (c.mode.dual && ch == c.mode.ccs) ? 1 : 0;
			int wv = UnquantWeight(*c.L.wq, c.wcodes[c.mode.dual ? i * 2 + plane : i]);
			rgba[i * 4 + ch] = (uint8_t)Interp(e0[ch], e1[ch], wv, srgb && ch < 3);
		}
	return true;
}
} // namespace IridiaAstc
