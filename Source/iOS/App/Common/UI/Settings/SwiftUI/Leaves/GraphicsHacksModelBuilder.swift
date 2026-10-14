// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum GraphicsHacksModelBuilder {
  static func make(state: GraphicsHacksState, apply: @escaping (GraphicsHacksChange) -> Void) -> MenuModel {
    let skipDuplicateEnabled = !state.immediateXfb && state.viSkipMode == ViSkipMode.off.rawValue
    let deferEfbEnabled = !(state.skipEfbToRam && state.skipXfbToRam)
    let bbox = state.backendSupportsBbox

    let general = MenuSection(id: "general-hacks", header: L("General Hacks"), items: [
      SettingsRow.cycle("texture-cache", L("Texture Cache Accuracy"), [(L("Safe"), TextureCacheSamples.safe.rawValue), (L("Default"), TextureCacheSamples.standard.rawValue), (L("Fast"), TextureCacheSamples.fast.rawValue)], state.textureCacheSamples,
            L("Safer is slower but avoids garbled text in some games."), set: { apply(.textureCacheSamples($0)) }),
      SettingsRow.toggle("bbox", L("Bounding Box Emulation"), state.bboxEnabled,
             bbox ? L("Needed by a few games. Leave off unless a game needs it.")
                  : L("The current graphics backend does not support bounding box emulation on this device."),
             enabled: bbox, set: { apply(.bboxEnabled($0)) }),
      SettingsRow.cycle("bbox-sync", L("Bounding Box Sync"), [(L("Latched"), BboxSyncMode.latched.rawValue), (L("Force Sync"), BboxSyncMode.forceSync.rawValue)], state.bboxSyncMode,
            L("Latched is faster. Try Force Sync if parts of a game's menus or 2D effects look wrong."),
            enabled: state.bboxEnabled && bbox, set: { apply(.bboxSyncMode($0)) }),
      SettingsRow.toggle("efb-access", L("Enable EFB Access"), state.efbAccess,
             L("Needed by some effects, but slow. Most games run fine, and faster, with it off."), set: { apply(.efbAccess($0)) }),
      SettingsRow.toggle("skip-efb-ram", L("Skip EFB Copy to RAM"), state.skipEfbToRam,
             L("Keeps graphics work on the GPU. Faster, but breaks a few effects."), set: { apply(.skipEfbToRam($0)) }),
      SettingsRow.toggle("skip-xfb-ram", L("Skip XFB Copy to RAM"), state.skipXfbToRam,
             L("Keeps the final picture on the GPU. Faster, but can break a few games."), set: { apply(.skipXfbToRam($0)) }),
      SettingsRow.toggle("immediate-xfb", L("Immediate XFB"), state.immediateXfb,
             L("Shows frames as soon as they're drawn. Less lag, but uneven frame timing and flicker in some games."), set: { apply(.immediateXfb($0)) }),
      SettingsRow.toggle("copy-efb-scaled", L("Copy EFB Scaled"), state.copyEfbScaled,
             L("Keeps effects sharp at higher resolutions."), set: { apply(.copyEfbScaled($0)) }),
      SettingsRow.toggle("early-xfb", L("Early XFB Output"), state.earlyXfbOutput,
             L("Shows each frame a little sooner for less lag. Turn off if a game glitches."), set: { apply(.earlyXfbOutput($0)) }),
      SettingsRow.toggle("skip-duplicate-xfb", L("Skip Duplicate XFBs"), state.skipDuplicateXFBs,
             skipDuplicateEnabled ? L("Skips drawing frames that haven't changed. Saves power.")
                                  : L("Not available while Immediate XFB or VI Skip is on."),
             enabled: skipDuplicateEnabled, set: { apply(.skipDuplicateXFBs($0)) }),
      SettingsRow.toggle("efb-format-changes", L("Emulate EFB Format Changes"), state.efbFormatChanges,
             L("Needed for correct colours in some games. Costs very little."), set: { apply(.efbFormatChanges($0)) }),
      SettingsRow.toggle("vertex-rounding", L("Vertex Rounding"), state.vertexRounding,
             L("Fixes thin lines between tiles at higher resolutions. Does nothing at 1x."), set: { apply(.vertexRounding($0)) }),
      SettingsRow.toggle("force-progressive", L("Force Progressive Scan"), state.forceProgressive,
             L("Forces 480p output where games allow it, for a cleaner image."), set: { apply(.forceProgressive($0)) }),
      SettingsRow.toggle("defer-efb-copies", L("Defer EFB Copies"), state.deferEfbCopies,
             deferEfbEnabled ? L("Groups some graphics work together. Faster in most games.")
                             : L("Not available while both copy options keep work on the GPU."),
             enabled: deferEfbEnabled, set: { apply(.deferEfbCopies($0)) }),
      SettingsRow.cycle("vi-skip", L("VI Skip Mode"), [(L("Off"), ViSkipMode.off.rawValue), (L("On"), ViSkipMode.on.rawValue), (L("Auto"), ViSkipMode.auto.rawValue)], state.viSkipMode,
            L("Skips frames when the game falls behind. Auto is the safe choice. On can cause flicker."), set: { apply(.viSkipMode($0)) }),
      SettingsRow.toggle("fast-texture-sampling", L("Fast Texture Sampling"), state.fastTextureSampling,
             L("Slightly faster texture drawing. Rarely causes small texture glitches."), set: { apply(.fastTextureSampling($0)) }),
      SettingsRow.toggle("fast-math", L("Fast Math (Metal Shaders)"), state.fastMath,
             L("Faster, slightly less precise GPU maths. Can cause small visual differences."), set: { apply(.fastMath($0)) }),
      SettingsRow.toggle("compute-efb-xfb", L("Use Compute for EFB/XFB"), state.useComputeEfbXfb,
             L("Experimental GPU speed-up. Takes effect the next time you start a game."), set: { apply(.useComputeEfbXfb($0)) }),
      SettingsRow.toggle("compute-vertex-decode", L("Use Compute for Vertex Decode"), state.useComputeVertexDecode,
             L("Experimental. Moves some work from the CPU to the GPU. Most games won't change yet. Takes effect the next time you start a game."), set: { apply(.useComputeVertexDecode($0)) }),
      SettingsRow.toggle("no-mipmapping", L("No Mipmapping (iOS)"), state.noMipmapping,
             L("Saves a little memory but makes distant textures shimmer."), set: { apply(.noMipmapping($0)) }),
      SettingsRow.toggle("gpu-efb-peek", L("GPU EFB Peek Resolve"), state.gpuEfbPeekResolve,
             L("Experimental. Can speed up games that read back the picture. Check that games still look right."), set: { apply(.gpuEfbPeekResolve($0)) }),
    ])
    let interlace = MenuSection(id: "interlace", items: [
      SettingsRow.toggle("vi-decimate-interlace", L("Interlaced Field Decimation"), state.viDecimateInterlace,
             L("Skips every other interlaced field for higher FPS. May reduce temporal resolution or cause flicker in some games."), set: { apply(.viDecimateInterlace($0)) }),
    ])
    return MenuModel(sections: [general, interlace])
  }
}
