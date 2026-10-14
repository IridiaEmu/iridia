// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the two kinds of vibration on the device itself.
// - Button vibration: on-screen controller presses and the small taps around the interface.
//   On by default (Settings > Controllers > Touch Controls > Button Vibration).
// - Game rumble: a game's rumble played on the iPhone/iPad. Off by default (Game Rumble); read by the
//   core's iOS Motor (InputCommon/ControllerInterface/iOS/Motor.mm). Rumble on a physical
//   controller is not affected by either.

import Foundation

enum IridiaHaptics {
  static let key = "iridia_haptics"
  static let gameRumbleKey = "iridia_game_rumble"

  static var enabled: Bool {
    get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }   // never set = on
    set { UserDefaults.standard.set(newValue, forKey: key) }
  }

  static var gameRumble: Bool {
    get { UserDefaults.standard.bool(forKey: gameRumbleKey) }   // never set = off
    set { UserDefaults.standard.set(newValue, forKey: gameRumbleKey) }
  }
}

/// gc-emu: features held back from version 1 until they've been tested on a device.
enum IridiaFeatures {
  /// iCloud Sync, Wi-Fi upload / WebDAV / remote sources, and Nearby Devices (handing a game to
  /// another device). Off: their settings and buttons are hidden and none of their services start.
  static let networkSharing = false
}
