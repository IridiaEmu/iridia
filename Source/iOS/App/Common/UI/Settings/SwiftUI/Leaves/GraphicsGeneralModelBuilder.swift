// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum GraphicsGeneralModelBuilder {
  static func make(state: GraphicsGeneralState, apply: @escaping (GraphicsGeneralChange) -> Void) -> MenuModel {
    var general = [
      SettingsRow.cycle("backend", L("Backend"), GraphicsBackend.allCases.map { ($0.label, $0) }, state.backend,
            L("How frames are drawn. Metal is the fastest on this device. Vulkan and OpenGL are slower."),
            set: { apply(.backend($0)) }),
      SettingsRow.toggle("vsync", L("V-Sync"), state.vSync,
             L("Matches frames to the screen's refresh to avoid tearing. Makes little difference on iOS."),
             set: { apply(.vSync($0)) }),
      SettingsRow.toggle("auto-ir-osd", L("Show Auto IR OSD"), state.showAutoIrOSD,
             L("Shows the resolution Auto Resolution is using, on screen."),
             set: { apply(.showAutoIrOSD($0)) }),
      SettingsRow.toggle("triple-buffering", L("Triple Buffering"), state.tripleBuffering,
             L("Smoother frame pacing for a tiny bit of extra lag. Turn off only if you want the lowest possible lag."),
             set: { apply(.tripleBuffering($0)) }),
      SettingsRow.toggle("force-scale-one", L("Force scale 1.0 on non‑ProMotion"), state.forceScaleOneNonProMotion,
             L("On devices without a 120 Hz screen, draws at a lower scale to save power. Can help older devices."),
             set: { apply(.forceScaleOneNonProMotion($0)) }),
      SettingsRow.toggle("overscan-fullscreen", L("Full screen (disable overscan compensation)"), state.overscanFullscreen,
             L("Fills an external display edge to edge. Turn on if you see black borders, off if the edges get cut off."),
             set: { apply(.overscanFullscreen($0)) }),
      SettingsRow.toggle("async-present", L("Asynchronous Present"), state.asyncPresent,
             L("Shows finished frames without making the emulator wait for the screen. Usually faster."),
             set: { apply(.asyncPresent($0)) }),
      SettingsRow.toggle("auto-ir", L("Enable Auto Internal Resolution"), state.autoIR,
             L("Raises and lowers resolution between Min and Max to hold the target frame rate. Rarely helps, since the CPU is usually what limits speed."),
             set: { apply(.autoIR($0)) }),
      SettingsRow.cycle("target-fps", L("Target FPS"), TargetFPS.allCases.map { ($0.label, $0) }, state.targetFPS,
            L("The frame rate Auto Resolution tries to hold. Only used when Auto Resolution is on."),
            set: { apply(.targetFPS($0)) }),
      SettingsRow.cycle("min-scale", L("Min Scale"), InternalScale.allCases.map { ($0.label, $0) }, state.minScale,
            L("The lowest resolution Auto Resolution will drop to. 1x is the original GameCube picture."),
            set: { apply(.minScale($0)) }),
      SettingsRow.cycle("max-scale", L("Max Scale"), InternalScale.allCases.map { ($0.label, $0) }, state.maxScale,
            L("The highest resolution Auto Resolution will go up to."),
            set: { apply(.maxScale($0)) }),
    ]
    if state.isIOS {
      general.append(
        SettingsRow.cycle("frame-cap", L("Frame Rate Cap"), GraphicsGeneralState.options(GraphicsGeneralState.frameCapLadder, including: state.frameCap).map { (frameCapTitle($0), $0) }, state.frameCap,
              L("Limits how often the screen refreshes. System Default lets iOS decide. A lower cap can save battery."),
              set: { apply(.frameCap($0)) }))
    }
    // gc-emu: the two settings most people want, up top; everything else is under Advanced.
    var pictureRows: [MenuItem] = []
    #if os(iOS)
    pictureRows.append(SettingsRow.custom("power-mode", L("Power Mode"), AnyView(PowerModeRow()),
             L("Battery Saver runs cooler, Max Performance favours speed, and Balanced is tuned for this device.")))
    #endif
    let picture = MenuSection(id: "picture", header: L("Picture"), items: pictureRows + [
      SettingsRow.custom("resolution", L("Resolution"), AnyView(ResolutionSliderRow()),
             L("1x is the original GameCube picture. Higher looks sharper but uses more battery.")),
      SettingsRow.cycle("aspect-ratio", L("Aspect Ratio"), AspectRatio.allCases.map { ($0.label, $0) }, state.aspect,
            L("The shape of the picture. Auto matches the game, 4:3 and 16:9 force that shape, and Stretch fills the screen."),
            set: { apply(.aspect($0)) }),
      SettingsRow.custom("show-stats", L("Show FPS & Speed"), AnyView(StatsOverlayToggleRow()),
             L("A small frame-rate and speed readout in the corner while you play. 100% means full speed.")),
    ])
    var sections = [picture, MenuSection(id: "general", header: L("Advanced"), items: general)]

    if state.isIOS {
      sections.append(MenuSection(id: "recording", header: L("Recording"), items: [
        SettingsRow.toggle("instant-replay", L("Enable ReplayKit Instant Replay"), state.instantReplay,
               L("Keeps recording the last few seconds so you can save a clip. Can slow down older devices."),
               set: { apply(.instantReplay($0)) }),
        SettingsRow.toggle("save-clips-photos", L("Save Clips to Photos"), state.saveClipsToPhotos,
               L("Also copy saved replay clips into your Photos library."),
               set: { apply(.saveClipsToPhotos($0)) }),
        SettingsRow.toggle("save-only-photos", L("Save Only to Photos"), state.saveOnlyToPhotos,
               L("Save clips to Photos only, skipping the app's own storage."),
               set: { apply(.saveOnlyToPhotos($0)) }),
        SettingsRow.cycle("clip-length", L("Clip Length"), GraphicsGeneralState.options(GraphicsGeneralState.clipSecondsLadder, including: state.clipSeconds).map { (seconds($0), $0) }, state.clipSeconds,
              L("How many seconds of gameplay each instant-replay clip captures."),
              set: { apply(.clipSeconds($0)) }),
      ]))
    }

    sections.append(MenuSection(id: "shader-compilation", header: L("Shader Compilation"), items: [
      SettingsRow.cycle("shader-compile-type", L("Type"), ShaderCompileType.allCases.map { ($0.label, $0) }, state.shaderType,
            L("Hybrid Ubershaders (the default) avoid stutter when a game shows something new. Specialized is lighter on the GPU but can hitch the first time. Exclusive Ubershaders never hitch but run a little slower."),
            set: { apply(.shaderType($0)) }),
      SettingsRow.toggle("compile-before-start", L("Compile shaders before starting"), state.compileBeforeStart,
             L("Prepares shaders before the game starts. Loading takes longer, but the first play-through is smoother."),
             set: { apply(.compileBeforeStart($0)) }),
    ]))

    return MenuModel(sections: sections)
  }

  /// "5s"; the one place a clip length becomes a label.
  private static func seconds(_ value: Int) -> String { "\(value)s" }

  private static func frameCapTitle(_ cap: Int) -> String {
    cap == GraphicsGeneralState.systemDefaultFrameCap ? L("System Default") : "\(cap)"
  }
}
