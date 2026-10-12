// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum ConfigAudioModelBuilder {
  static let masterEffectsFooter = L("Effects apply post‑environment. Requires AVAudioEngine backend.")
  static let coreAudioEffectsFooter = L("Built‑in echo, EQ, and bitcrush. Does not support AUv3 plugins.")

  static func make(state: ConfigAudioState, apply: @escaping (ConfigAudioChange) -> Void) -> MenuModel {
    // The old screen's section header was the row's own label, so it is the row's title here.
    let backend = MenuSection(id: "backend", items: [
      SettingsRow.picker("backend", L("Audio Backend"), state.backendOptions, state.backend,
                        L("CoreAudio: Best for TV/HDMI speakers. AVAudioEngine: Enables AUv3 FXs."),
                        set: { apply(.backend($0)) }),
    ])

    let volume = MenuSection(id: "volume", items: [
      SettingsRow.stepper("volume", L("Volume"), Double(state.volume), range: ConfigAudioLimits.volume, step: 1,
                          format: { "\(Int($0))%" },
                          L("Output level of the emulated console. The pause menu's Mute badge reflects this value."),
                          set: { apply(.volume(Int($0))) }),
    ])

    let stretching = MenuSection(id: "stretching", header: L("Audio Stretching Settings"), items: [
      SettingsRow.toggle("stretch", L("Enable Audio Stretching"), state.stretch,
                         L("Stretches audio to follow the emulation speed instead of letting it crackle or drop out when the game runs slower than full speed."),
                         set: { apply(.stretch($0)) }),
      SettingsRow.stepper("stretch-latency", L("Stretch Latency"), Double(state.stretchLatencyMs), range: ConfigAudioLimits.stretchLatencyMs, step: 1,
                          format: milliseconds,
                          L("Audio buffered before it is played while stretching. Higher values sound smoother but lag further behind the picture."),
                          enabled: state.stretch, set: { apply(.stretchLatencyMs(Int($0))) }),
    ])

    let misc = MenuSection(id: "misc", header: L("Misc. Controls"), items: [
      SettingsRow.toggle("mute-on-no-speed-limit", L("Mute When Disabling Speed Limit"), state.muteOnNoSpeedLimit,
                         L("Silences audio while the speed limit is off (fast-forward), when it would otherwise play sped up."),
                         set: { apply(.muteOnNoSpeedLimit($0)) }),
      SettingsRow.toggle("obey-mute-switch", L("Mute in Silent Mode"), state.obeyMuteSwitch,
                         L("Follows the device's silent switch: game audio is muted while it is on."),
                         set: { apply(.obeyMuteSwitch($0)) }),
    ] + interfaceSoundsRows)

    return MenuModel(sections: [backend] + effectsSections(state) + [volume, stretching, misc])
  }

  /// gc-emu: Iridia's menu sounds (taps, chimes). iOS only; they follow the silent switch.
  private static var interfaceSoundsRows: [MenuItem] {
    #if os(iOS)
    return [SettingsRow.custom("interface-sounds", L("Interface Sounds"), AnyView(InterfaceSoundsToggle()),
                               L("Soft glass taps and chimes in the menus. They follow the silent switch; game audio doesn't."))]
    #else
    return []
    #endif
  }

  /// The effects editors the current backend supports. The old screen had them on iOS only.
  private static func effectsSections(_ state: ConfigAudioState) -> [MenuSection] {
    #if os(iOS)
    if state.showsAVAudioEngineEffects {
      let title = L("Master Effects Chain")
      return [MenuSection(id: "master-effects", header: title, footer: masterEffectsFooter, items: [
        SettingsRow.custom("effects-chain", title, AnyView(VStack { FXChainEditor() }), masterEffectsFooter),
      ])]
    }
    if state.showsCoreAudioEffects {
      let title = L("CoreAudio Effects")
      return [MenuSection(id: "coreaudio-effects", header: title, footer: coreAudioEffectsFooter, items: [
        SettingsRow.custom("coreaudio-effects", title, AnyView(CoreAudioDSPEditor(embedded: true)), coreAudioEffectsFooter),
      ])]
    }
    #endif
    return []
  }

  private static func milliseconds(_ value: Double) -> String { String(format: L("%1$ld ms"), Int(value)) }
}

#if os(iOS)
private struct InterfaceSoundsToggle: View {
  @AppStorage(IridiaSound.defaultsKey) private var enabled = true
  var body: some View {
    Toggle(L("Interface Sounds"), isOn: $enabled)
      .onChange(of: enabled) { _, on in if on { IridiaSound.press.play() } }
  }
}
#endif
