// Iridia Wii U app: WindowSystem for iOS. The Swift app owns the screen; this only reports its size and keeps
// the last error message for the app to show.
#include "WindowSystem.h"
#include "Cafe/HW/Latte/Core/IridiaPerf.h"

std::string g_iridiaLastCoreError;

namespace WindowSystem
{
	static WindowInfo s_windowInfo;

	void ShowErrorDialog(std::string_view message, std::string_view title, std::optional<ErrorCategory> errorCategory)
	{
		g_iridiaLastCoreError = std::string(message);
		fprintf(stderr, "IRIDIA_CORE_ERROR %.*s\n", (int)message.size(), message.data());
	}

	void Create() {}

	WindowInfo& GetWindowInfo() { return s_windowInfo; }

	void UpdateWindowTitles(bool isIdle, bool isLoading, double fps) {}

	void GetWindowSize(int& w, int& h) { w = s_windowInfo.width; h = s_windowInfo.height; }
	void GetPadWindowSize(int& w, int& h) { w = s_windowInfo.pad_width; h = s_windowInfo.pad_height; }
	void GetWindowPhysSize(int& w, int& h) { w = s_windowInfo.phys_width; h = s_windowInfo.phys_height; }
	void GetPadWindowPhysSize(int& w, int& h) { w = s_windowInfo.phys_pad_width; h = s_windowInfo.phys_pad_height; }
	double GetWindowDPIScale() { return s_windowInfo.dpi_scale.load() > 0 ? s_windowInfo.dpi_scale.load() : 1.0; }
	double GetPadDPIScale() { return s_windowInfo.pad_dpi_scale.load() > 0 ? s_windowInfo.pad_dpi_scale.load() : 1.0; }
	bool IsPadWindowOpen() { return s_windowInfo.pad_open; }
	bool IsKeyDown(uint32 key) { return false; }
	bool IsKeyDown(PlatformKeyCodes key) { return false; }
	std::string GetKeyCodeName(uint32 key) { return ""; }
	bool InputConfigWindowHasFocus() { return false; }
	void NotifyGameLoaded() {}
	void NotifyGameExited() {}
	void RefreshGameList() {}
	bool IsFullScreen() { return true; }
	void CaptureInput(const ControllerState& currentState, const ControllerState& lastState) {}
}
