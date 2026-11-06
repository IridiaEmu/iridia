// Iridia: reads the IRIDIA_* / CEMU_* environment switches.
// The app sets a few of them as player settings before a game starts. Every other switch is a study switch used
// on test builds. With IRIDIA_SHIP (App Store builds) only the player settings are read; any other name reads as
// not set, so the study code behind it is never taken and the compiler drops it.
#pragma once

#include <cstdlib>
#include <string_view>

#ifndef IRIDIA_SHIP
#define IRIDIA_SHIP 0
#endif

constexpr bool iridia_isPlayerSetting(std::string_view name)
{
	constexpr std::string_view settings[] = {
		"IRIDIA_IPHONE_LAYOUT", // thread placement for the phone's two performance cores
		"IRIDIA_GPU_QOS",       // GPU command thread priority (utility)
		"IRIDIA_QUANTUM",       // emulated core time slice
		"IRIDIA_VRR",           // Variable frame timing
		"IRIDIA_AX_CATCHUP",    // audio catch-up, set together with variable frame timing
		"IRIDIA_AUDIO_STRETCH", // audio stretching, set together with variable frame timing
		"IRIDIA_PERF_MODE",     // Performance mode
		"IRIDIA_DRC_PRIMARY",   // GamePad screen instead of the TV screen
		"IRIDIA_BUFFER_HOST",   // Use less memory
	};
	for (std::string_view s : settings)
		if (s == name)
			return true;
	return false;
}

inline const char* iridia_getenv(const char* name)
{
#if IRIDIA_SHIP
	if (!iridia_isPlayerSetting(name))
		return nullptr;
#endif
	return std::getenv(name);
}
