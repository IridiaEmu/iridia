#pragma once
#include <atomic>
#include <cstdint>

// Iridia Wii U app: GamePad state set by the host app. Button bits are the VPAD_BUTTON_* values
// (A 0x8000, B 0x4000, X 0x2000, Y 0x1000, L 0x20, R 0x10, ZL 0x80, ZR 0x40, + 0x08, - 0x04,
// up 0x200, down 0x100, left 0x800, right 0x400, stick clicks L 0x40000 R 0x20000, HOME 0x02).
struct IridiaExternalPad
{
	std::atomic<bool> active{false};
	std::atomic<uint32_t> buttons{0};
	std::atomic<float> lx{0}, ly{0}, rx{0}, ry{0};
	// GamePad touch screen: position 0..1 on the GamePad image (0,0 top left), down while touching
	std::atomic<bool> touchDown{false};
	std::atomic<float> touchX{0}, touchY{0};
};
extern IridiaExternalPad g_iridiaExternalPad;
