// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: one switch for every vibration the app makes on the device itself: on-screen controller
// presses and the small taps around the interface. Off by default (Settings > Controllers > Touch
// Controls > Vibration). Rumble sent to a physical controller is separate.

import Foundation

enum IridiaHaptics {
  static let key = "iridia_haptics"

  static var enabled: Bool {
    get { UserDefaults.standard.bool(forKey: key) }   // never set = off
    set { UserDefaults.standard.set(newValue, forKey: key) }
  }
}
