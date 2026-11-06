#pragma once

// Iridia: audio stretching for uneven sound production (IRIDIA_AUDIO_STRETCH=1, off by default).
// When the emulator makes sound in bursts (a throttled phone, variable frame timing), the output queue runs dry and
// the output callback plays silence (a gap). With stretching on, the callback watches how much sound is queued:
// while it runs low, the queued sound is played slower with its pitch kept (WSOLA: overlapping 10.7 ms windows,
// each placed where it best matches the previous one), so it lasts until the next burst arrives; when too much has
// piled up, it is played faster the same way, to bring latency back. In between it is a plain copy (bit-exact),
// so steady sound is untouched.
// Switches: IRIDIA_STRETCH_LOW=<frames> (default 2304 = 48 ms: stretch below this), IRIDIA_STRETCH_HIGH=<frames>
// (default 4608 = 96 ms: compress above), IRIDIA_STRETCH_MIN=<rate> (default 0.5: slowest playback).
// Used by the iOS (IOSAudioAPI) and cubeb (Mac) outputs; the caller holds the queue's lock.

#include <vector>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <atomic>
#include <cstdio>

extern std::atomic<uint32_t> g_iridiaAudioStretched; // IAudioAPI.cpp: callbacks that stretched or compressed

inline bool IridiaStretchEnabled()
{
	static const bool v = getenv("IRIDIA_AUDIO_STRETCH") && getenv("IRIDIA_AUDIO_STRETCH")[0] == '1';
	return v;
}

// test switch IRIDIA_AUDIO_WAV=<path>: the Mac output also writes what it plays to a 48 kHz 16-bit WAV file (to listen
// to an A/B afterwards; file I/O in the audio callback, so test only)
inline void IridiaAudioWavDump(const void* data, size_t bytes, uint32_t channels)
{
	static FILE* s_f = [] { const char* p = getenv("IRIDIA_AUDIO_WAV"); return p ? fopen(p, "wb") : nullptr; }();
	static uint32_t s_bytes = 0, s_sinceHeader = 0;
	if (!s_f)
		return;
	auto header = [&] {
		const uint32_t riff = 36 + s_bytes, fmtLen = 16, rate = 48000, br = rate * channels * 2;
		const uint16_t pcm = 1, ch = (uint16_t)channels, ba = (uint16_t)(channels * 2), bits = 16;
		fseek(s_f, 0, SEEK_SET);
		fwrite("RIFF", 1, 4, s_f); fwrite(&riff, 4, 1, s_f); fwrite("WAVEfmt ", 1, 8, s_f); fwrite(&fmtLen, 4, 1, s_f);
		fwrite(&pcm, 2, 1, s_f); fwrite(&ch, 2, 1, s_f); fwrite(&rate, 4, 1, s_f); fwrite(&br, 4, 1, s_f);
		fwrite(&ba, 2, 1, s_f); fwrite(&bits, 2, 1, s_f); fwrite("data", 1, 4, s_f); fwrite(&s_bytes, 4, 1, s_f);
		fseek(s_f, 0, SEEK_END);
	};
	if (s_bytes == 0)
		header();
	fwrite(data, 1, bytes, s_f);
	s_bytes += (uint32_t)bytes;
	if ((s_sinceHeader += (uint32_t)bytes) > 192000) // about once a second: keep the header's sizes current
	{
		s_sinceHeader = 0;
		header();
		fflush(s_f);
	}
}

class IridiaStretch
{
public:
	static constexpr int kHop = 256;    // output frames per step (5.3 ms at 48 kHz); window = 2 hops
	static constexpr int kSearch = 128; // +- frames searched for the best match (2.7 ms)
	static constexpr int kFloor = 3 * kHop + 2 * kSearch; // queued frames one step needs; playback is slowest here

	explicit IridiaStretch(int channels) : m_ch(channels)
	{
		m_low = std::max(envInt("IRIDIA_STRETCH_LOW", 2304), 2 * kFloor);
		m_high = std::max(envInt("IRIDIA_STRETCH_HIGH", 4608), m_low * 2);
		m_minRate = std::clamp(getenv("IRIDIA_STRETCH_MIN") ? atof(getenv("IRIDIA_STRETCH_MIN")) : 0.5, 0.3, 1.0);
		m_w.resize(2 * kHop);
		for (int i = 0; i < 2 * kHop; i++)
			m_w[i] = 0.5f - 0.5f * std::cos(6.283185307f * (float)i / (float)(2 * kHop)); // periodic Hann: w[i] + w[i+hop] = 1
		m_tail.assign((size_t)kHop * m_ch, 0.0f);
	}

	// Fills 'frames' frames of 16-bit interleaved sound into out from queue (bytes, consumed from the front).
	// Returns false when part of it had to be silence (a gap).
	bool Render(int16_t* out, uint32_t frames, std::vector<uint8_t>& queue)
	{
		const size_t frameBytes = (size_t)m_ch * 2;
		bool full = true, stretched = false;
		uint32_t done = 0;
		while (done < frames)
		{
			// sound already made by the stretcher
			if (m_outPos < m_out.size())
			{
				const size_t n = std::min<size_t>((m_out.size() - m_outPos) / m_ch, frames - done);
				memcpy(out + (size_t)done * m_ch, m_out.data() + m_outPos, n * frameBytes);
				m_outPos += n * m_ch;
				done += (uint32_t)n;
				continue;
			}
			m_out.clear();
			m_outPos = 0;
			const int avail = (int)(queue.size() / frameBytes);
			if (!m_active)
			{
				const double want = wantedRate(avail);
				if (m_rebuffer && avail < m_low)
				{
					// after a gap, wait until there's enough to stretch from instead of playing scraps (which would
					// keep the queue empty and make many short gaps)
					memset(out + (size_t)done * m_ch, 0, (size_t)(frames - done) * frameBytes);
					full = false;
					break;
				}
				m_rebuffer = false;
				if (want == 1.0 || avail < 3 * kHop + kSearch)
				{
					// plain copy (also when there's too little to stretch: then the rest is a gap)
					const uint32_t n = std::min<uint32_t>((uint32_t)avail, frames - done);
					memcpy(out + (size_t)done * m_ch, queue.data(), (size_t)n * frameBytes);
					queue.erase(queue.begin(), queue.begin() + (size_t)n * frameBytes);
					done += n;
					if (done < frames)
					{
						memset(out + (size_t)done * m_ch, 0, (size_t)(frames - done) * frameBytes);
						full = false;
						done = frames;
						m_rebuffer = true;
					}
					continue;
				}
				// start: play the first hop as it is, fade out the next one into the first stretched window
				const int16_t* x = (const int16_t*)queue.data();
				m_out.assign(x, x + (size_t)kHop * m_ch);
				for (int i = 0; i < kHop; i++)
					for (int c = 0; c < m_ch; c++)
						m_tail[(size_t)i * m_ch + c] = m_w[kHop + i] * x[(size_t)(kHop + i) * m_ch + c];
				m_prev = 0;
				m_rate = want;
				m_nominal = kHop * m_rate;
				m_active = true;
				stretched = true;
				continue;
			}
			// active: one step
			stretched = true;
			const int fill = avail - (int)m_nominal;
			const double want = wantedRate(fill);
			m_rate += 0.25 * (want - m_rate);
			if (want == 1.0 && std::abs(m_rate - 1.0) < 0.02 && m_prev + 2 * kHop <= avail)
			{
				exitHop(queue);
				continue;
			}
			const int nat = m_prev + kHop; // where the previous window naturally continues
			const int center = (int)m_nominal;
			const int lo = std::max(0, center - kSearch), hi = center + kSearch;
			if (hi + 2 * kHop > avail || nat + kHop > avail)
			{
				// ran dry even stretched: fade out (the tail is already a fade-out), then a gap
				m_out.resize((size_t)kHop * m_ch);
				for (size_t i = 0; i < m_out.size(); i++)
					m_out[i] = clamp16(m_tail[i]);
				const size_t drop = std::min<size_t>((size_t)(nat + kHop) * frameBytes, queue.size());
				queue.erase(queue.begin(), queue.begin() + drop);
				m_active = false;
				m_rebuffer = true;
				continue;
			}
			const int16_t* x = (const int16_t*)queue.data();
			const int best = bestMatch(x, nat, lo, hi);
			m_out.resize((size_t)kHop * m_ch);
			for (int i = 0; i < kHop; i++)
				for (int c = 0; c < m_ch; c++)
				{
					const size_t o = (size_t)i * m_ch + c;
					m_out[o] = clamp16(m_tail[o] + m_w[i] * x[(size_t)(best + i) * m_ch + c]);
					m_tail[o] = m_w[kHop + i] * x[(size_t)(best + kHop + i) * m_ch + c];
				}
			m_prev = best;
			m_nominal += kHop * m_rate;
			// drop what no later step can use
			const int keep = std::max(0, std::min(m_prev + kHop, (int)m_nominal - kSearch));
			if (keep > 0)
			{
				queue.erase(queue.begin(), queue.begin() + (size_t)keep * frameBytes);
				m_prev -= keep;
				m_nominal -= keep;
			}
		}
		if (stretched)
			g_iridiaAudioStretched.fetch_add(1, std::memory_order_relaxed);
		return full;
	}

	bool Active() const { return m_active; }

private:
	static int envInt(const char* name, int def) { const char* v = getenv(name); return v ? std::max(1, atoi(v)) : def; }
	static int16_t clamp16(float v) { return (int16_t)std::clamp(std::lrintf(v), -32768L, 32767L); }

	// input frames to use per output frame for this much queued sound; while stretching, it goes back to a plain
	// copy only a bit past the thresholds (hysteresis, so it doesn't switch on and off at every callback)
	double wantedRate(int fill) const
	{
		const int low = m_active ? m_low + m_low / 4 : m_low;
		const int high = m_active ? m_high - m_high / 4 : m_high;
		if (fill < low)
			return std::clamp(m_minRate + (1.0 - m_minRate) * (double)(fill - kFloor) / (low - kFloor), m_minRate, 0.97); // the emptier, the slower
		if (fill > high)
			return std::clamp(1.0 + 0.25 * (double)(fill - high) / m_high, 1.03, 1.25);
		return 1.0;
	}

	// back to plain copying: the next window is the natural continuation, so tail + window = the original sound
	void exitHop(std::vector<uint8_t>& queue)
	{
		const size_t frameBytes = (size_t)m_ch * 2;
		const int nat = m_prev + kHop;
		const int16_t* x = (const int16_t*)queue.data();
		m_out.resize((size_t)kHop * m_ch);
		for (int i = 0; i < kHop; i++)
			for (int c = 0; c < m_ch; c++)
			{
				const size_t o = (size_t)i * m_ch + c;
				m_out[o] = clamp16(m_tail[o] + m_w[i] * x[(size_t)(nat + i) * m_ch + c]);
			}
		queue.erase(queue.begin(), queue.begin() + (size_t)(nat + kHop) * frameBytes);
		m_active = false;
	}

	// the start in [lo, hi] whose first hop best matches x[nat ..] (normalized cross-correlation on a mono mix;
	// coarse pass every 4 frames over every 2nd sample, then a fine pass around the best)
	int bestMatch(const int16_t* x, int nat, int lo, int hi)
	{
		auto mono = [&](int f) { int s = 0; for (int c = 0; c < m_ch && c < 2; c++) s += x[(size_t)f * m_ch + c]; return (float)s; };
		auto score = [&](int cand, int step) {
			float xy = 0, yy = 1.0f;
			for (int i = 0; i < kHop; i += step)
			{
				const float a = mono(nat + i), b = mono(cand + i);
				xy += a * b;
				yy += b * b;
			}
			return xy / std::sqrt(yy);
		};
		int best = std::clamp(nat, lo, hi);
		float bestScore = score(best, 2);
		for (int cand = lo; cand <= hi; cand += 4)
		{
			const float s = score(cand, 2);
			if (s > bestScore) { bestScore = s; best = cand; }
		}
		const int c0 = best;
		bestScore = score(c0, 1);
		for (int cand = std::max(lo, c0 - 3); cand <= std::min(hi, c0 + 3); cand++)
		{
			const float s = score(cand, 1);
			if (s > bestScore) { bestScore = s; best = cand; }
		}
		return best;
	}

	int m_ch;
	int m_low, m_high;
	double m_minRate;
	std::vector<float> m_w, m_tail;
	std::vector<int16_t> m_out;
	size_t m_outPos = 0;
	bool m_active = false;
	bool m_rebuffer = false; // a gap happened: play again once m_low frames are queued
	int m_prev = 0;        // start of the previous window, in frames from the queue front
	double m_nominal = 0;  // where the next window would start without searching
	double m_rate = 1.0;   // input frames used per output frame
};
