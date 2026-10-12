// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

/// gc-emu: Config "iOS/MuteSwitchMode". 0 (the default) = game audio plays even when the
/// Ring/Silent switch is on silent, like other game apps; 1 = silent mode mutes it. These were
/// swapped before, so the default obeyed silent mode and the settings toggle showed the opposite.
@objc enum AudioMuteSwitchMode: Int {
  case ignore = 0
  case obey = 1
}
