// Copyright 2026 Iridia
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

namespace IOS::HLE
{
// gc-emu: Iridia keeps the Wii offline (no WiiConnect24, no online play). The network devices
// stay so games find them, but they report no connection and never reach the host network.
constexpr bool WII_ONLINE_OFF = true;
}  // namespace IOS::HLE
