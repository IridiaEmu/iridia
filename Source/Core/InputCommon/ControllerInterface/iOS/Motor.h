// Copyright 2020 Dolphin Emulator Project
// Licensed under GPLv2+
// Refer to the license.txt file included.

#pragma once

#include <mutex>

#include "InputCommon/ControllerInterface/ControllerInterface.h"

@class CHHapticEngine;
@protocol CHHapticAdvancedPatternPlayer;

namespace ciface::iOS
{
class Motor : public Core::Device::Output
{
public:
  // gc-emu: `on_device` = this motor is the iPhone/iPad itself (the touchscreen pad), which only
  // rumbles when the player turns on Game Rumble.
  Motor(CHHapticEngine* engine, const std::string name, bool on_device = false);
  ~Motor();

  bool StartEngine();

  std::string GetName() const override;
  void SetState(ControlState state) override;

private:
  std::mutex m_lock;

  bool m_player_created = false;
  bool m_player_needs_restart = false;

  CHHapticEngine* m_haptic_engine;
  id<CHHapticAdvancedPatternPlayer> m_haptic_player;

  const std::string m_name;
  const bool m_on_device;
  ControlState m_last_state = 0.0;
};
}  // namespace ciface::iOS
