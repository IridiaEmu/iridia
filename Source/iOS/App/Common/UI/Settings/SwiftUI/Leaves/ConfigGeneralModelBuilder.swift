// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed,
/// plus the help text its pickers carried (markup stripped).
enum ConfigGeneralModelBuilder {
  static func make(state: ConfigGeneralState, apply: @escaping (ConfigGeneralChange) -> Void) -> MenuModel {
    let basic = MenuSection(id: "basic-settings", header: L("Basic Settings"), items: [
      SettingsRow.toggle("dual-core", L("Enable Dual Core (speedup)"), state.dualCore,
                         L("Runs graphics and game logic on separate threads. Can make some games freeze."),
                         set: { apply(.dualCore($0)) }),
      SettingsRow.toggle("dsp-thread", L("DSP Thread (speedup)"), state.dspThread,
                         L("Runs sound on its own thread. A little faster."),
                         set: { apply(.dspThread($0)) }),
      SettingsRow.toggle("cheats", L("Enable Cheats"), state.cheats,
                         L("Activates AR/Gecko cheat codes for the running game."),
                         set: { apply(.cheats($0)) }),
      SettingsRow.toggle("override-region", L("Override Region Mismatch"), state.overrideRegion,
                         L("Lets a game start with another region's settings. Can cause problems, so only use it if a game needs it."),
                         set: { apply(.overrideRegion($0)) }),
      SettingsRow.toggle("auto-disc-change", L("Auto Disc Change"), state.autoDiscChange,
                         L("Automatically swaps to the next disc for multi-disc games."),
                         set: { apply(.autoDiscChange($0)) }),
      SettingsRow.toggle("fast-disc-speed", L("Fast Disc Speed (speedup)"), state.fastDiscSpeed,
                         L("Loads faster than a real disc. Breaks a few games that expect real loading times."),
                         set: { apply(.fastDiscSpeed($0)) }),
      SettingsRow.toggle("resume-where-left-off", L("Resume Where I Left Off"), state.resumeWhereLeftOff,
                         L("When you leave a game, Iridia saves your spot and picks up there next time. Your numbered save slots are left alone."),
                         set: { apply(.resumeWhereLeftOff($0)) }),
    ])

    let speed = MenuSection(id: "speed", header: L("Speed"), items: [
      SettingsRow.cycle("speed-limit", L("Speed Limit"), ConfigGeneralState.speedLimitOptions(including: state.speedLimitPercent), state.speedLimitPercent,
                        described(L("How fast games run compared with a real GameCube. 100% is normal speed, Unlimited goes as fast as your device can."),
                                  L("If unsure, select 100%.")),
                        icon: "speedometer", set: { apply(.speedLimit($0)) }),
      SettingsRow.cycle("fast-forward-speed", L("Fast Forward Speed"), ConfigGeneralState.fastForwardOptions(including: state.fastForwardSpeedPercent), state.fastForwardSpeedPercent,
                        described(L("The speed while you hold fast-forward. High settings may not be reached."),
                                  L("300% (3x) is recommended for most games.")),
                        icon: "forward.fill", set: { apply(.fastForwardSpeed($0)) }),
    ])

    let region = MenuSection(id: "fallback-region", items: [
      SettingsRow.cycle("fallback-region", L("Fallback Region"), Region.selectable.map { ($0.label, $0) }, state.fallbackRegion,
                        described(L("Region used for titles whose region can't be detected automatically."),
                                  L("This setting cannot be changed while emulation is active.")),
                        set: { apply(.fallbackRegion($0)) }),
    ])

    return MenuModel(sections: [basic, speed, region])
  }

  /// The row caption followed by the help text its picker used to carry.
  private static func described(_ caption: String, _ help: String) -> String { "\(caption) \(help)" }
}
