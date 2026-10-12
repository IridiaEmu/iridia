// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Iridia's interface sounds (synthesised by Tools/branding/make_sounds.swift; see ASSETS.md).
// Played as system sounds: preloaded, no audio session work, near-zero latency and battery cost, and
// they follow the Ring/Silent switch like other UI sounds. Game audio is separate and unaffected.

import AudioToolbox
import Foundation

enum IridiaSound: String, CaseIterable {
  case tick = "iridia_tick"
  case press = "iridia_press"
  case open = "iridia_open"
  case close = "iridia_close"
  case launch = "iridia_launch"
  case error = "iridia_error"

  /// Settings > Audio > Interface Sounds (on by default).
  static let defaultsKey = "iridia_interface_sounds"

  static var enabled: Bool {
    UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
  }

  private static let ids: [IridiaSound: SystemSoundID] = {
    var map: [IridiaSound: SystemSoundID] = [:]
    for sound in IridiaSound.allCases {
      guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "wav") else { continue }
      var id: SystemSoundID = 0
      if AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError { map[sound] = id }
    }
    return map
  }()

  func play() {
    guard Self.enabled, let id = Self.ids[self] else { return }
    AudioServicesPlaySystemSound(id)
  }

  /// Load the sounds ahead of the first tap (call at launch).
  static func preload() { NSLog("[Sound] %d interface sounds loaded", ids.count) }
}
