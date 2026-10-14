// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The texture-pack warning, shown under Prefetch Custom Textures. A custom row renders only its view, so it carries the text.
struct TexturePackWarningRow: View {
  let text: String

  var body: some View {
    Label(text, systemImage: "exclamationmark.triangle.fill")
      .font(.footnote)
      .foregroundStyle(.red)
  }
}

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum GraphicsAdvancedModelBuilder {
  typealias Apply = (GraphicsAdvancedChange) -> Void

  static func make(state: GraphicsAdvancedState, apply: @escaping Apply) -> MenuModel {
    func flag(_ id: String, _ title: String, _ flag: GraphicsAdvancedFlag, _ description: String, enabled: Bool = true) -> MenuItem {
      SettingsRow.toggle(id, title, state[keyPath: flag.keyPath], description, enabled: enabled, set: { apply(.flag(flag, $0)) })
    }

    let statistics = MenuSection(id: "performance-statistics", header: L("Performance Statistics"),
                                 footer: L("These overlays can also be toggled in-game from the pause menu."), items: [
      flag("show-fps", L("Show FPS"), .showFPS, L("Frames per second actually presented to the display.")),
      flag("show-vps", L("Show VPS"), .showVPS, L("The game's own frame rate.")),
      flag("show-speed", L("Show Speed"), .showSpeed, L("Emulation speed as a percentage of full speed.")),
      flag("show-frame-times", L("Show Frame Times"), .showFrameTimes, L("Per-frame render time in milliseconds. Useful for spotting hitches.")),
      flag("show-vblank-times", L("Show VBlank Times"), .showVBlankTimes, L("Time between emulated vertical-blank interrupts.")),
      flag("show-graphs", L("Show Graphs"), .showGraphs, L("Draws the timing stats as live graphs instead of numbers.")),
      flag("log-render-time", L("Log Render Time to File"), .logRenderTime, L("Writes per-frame render times to a log file for offline analysis.")),
      flag("speed-colors", L("Speed Colors"), .speedColors, L("Color-codes the speed readout (green = full speed, red = slow).")),
    ])

    let debugging = MenuSection(id: "debugging", header: L("Debugging"), items: [
      flag("overlay-stats", L("Overlay Stats"), .overlayStats, L("Detailed rendering statistics overlay for developers.")),
      flag("api-validation-layer", L("API Validation Layer"), .validationLayer, L("Extra error checking for debugging. Slows things down.")),
    ])

    let threadRange = 1 ... Double(state.maxThreads)
    let threads = MenuSection(id: "shader-threads", header: L("Shader Threads"), items: [
      SettingsRow.stepper("compiler-threads", L("Compiler Threads"), Double(state.compilerThreads), range: threadRange, step: 1,
                          format: { "\(Int($0))" },
                          L("How many threads build shaders while you play. 2 to 4 works well."),
                          set: { apply(.compilerThreads(Int($0))) }),
      SettingsRow.stepper("precompiler-threads", L("Precompiler Threads"), Double(state.precompilerThreads), range: threadRange, step: 1,
                          format: { "\(Int($0))" },
                          L("Threads used to pre-build shaders before a game starts."),
                          set: { apply(.precompilerThreads(Int($0))) }),
    ])

    var utilityItems = [
      flag("load-custom-textures", L("Load Custom Textures"), .hiresTextures, L("Loads installed high-resolution texture packs in place of the originals.")),
      flag("prefetch-custom-textures", L("Prefetch Custom Textures"), .prefetchTextures,
           L("Loads all custom textures into memory up front for smoother play, at higher memory use."), enabled: state.hiresTextures),
    ]
    if state.showsTexturePackWarning {
      let text = String(format: L("Installed texture packs total %@, a large share of this device's memory. Prefetching them can crash the game; turn Prefetch off or remove packs you don't use."),
                        ByteCountFormatter.string(fromByteCount: state.texturePackBytes, countStyle: .file))
      utilityItems.append(SettingsRow.custom("texture-pack-warning", text, AnyView(TexturePackWarningRow(text: text)), text, enabled: false))
    }
    utilityItems += [
      flag("disable-efb-copy-to-vram", L("Disable EFB Copy to VRAM"), .disableEfbToVRAM, L("Slower. Only for the rare game that needs it.")),
      flag("graphics-mods", L("Enable Graphics Mods"), .graphicsMods, L("Enables community-created graphics mods for supported games.")),
    ]
    let utility = MenuSection(id: "utility", header: L("Utility"), items: utilityItems)

    let misc = MenuSection(id: "misc", header: L("Misc"), items: [
      flag("crop", L("Crop"), .cropPicture, L("Crops the black borders some games render around the picture.")),
      flag("progressive-scan", L("Progressive Scan"), .progressiveScan, L("Enables 480p progressive output for games that support it, reducing flicker.")),
    ])

    let rendering = MenuSection(id: "rendering", header: L("Rendering"), items: [
      flag("fast-depth", L("Fast Depth Calculation"), .fastDepth, L("Slightly faster. Can cause small depth glitches in a few games.")),
      flag("per-pixel-lighting", L("Per-Pixel Lighting"), .pixelLighting, L("Smoother lighting than the original hardware. Uses more battery.")),
      flag("backend-multithreading", L("Backend Multithreading"), .backendMT,
           L("Prepares drawing work on a separate thread. Usually faster.")),
      flag("shader-cache", L("Enable Shader Cache"), .shaderCache, L("Keeps built shaders so they don't have to be rebuilt each time.")),
      flag("save-texture-cache-to-state", L("Save Texture Cache to State"), .saveTexCache, L("More accurate save states, but bigger files.")),
      flag("prefer-vs-for-lines", L("Prefer Vertex Shader for Line/Point Expansion"), .preferVSForLines,
           L("Another way of drawing lines and points. Can be faster on some devices.")),
      flag("cpu-culling", L("CPU Culling"), .cpuCull, L("Skips drawing things that are off screen. Usually makes Iridia slower, so leave it off.")),
    ])

    let experimental = MenuSection(id: "experimental", header: L("Experimental"),
                                   footer: L("Experimental. May cause glitches in some games."), items: [
      flag("defer-efb-invalidation", L("Defer EFB Cache Invalidation"), .deferEfbInvalidation,
           L("Can speed things up, but may show out-of-date graphics.")),
      SettingsRow.cycle("use-present-drawable", L("Use Present Drawable"), triStateOptions(including: state.usePresentDrawable), state.usePresentDrawable,
                        L("Leave on Auto."),
                        set: { apply(.presentDrawable($0)) }),
      SettingsRow.cycle("manually-upload-buffers", L("Manually Upload Buffers"), triStateOptions(including: state.manuallyUploadBuffers), state.manuallyUploadBuffers,
                        L("Leave on Auto."),
                        set: { apply(.manuallyUploadBuffers($0)) }),
    ])

    return MenuModel(sections: [statistics, debugging, threads, utility, misc, rendering, experimental])
  }

  private static func triStateOptions(including stored: Int) -> [(String, Int)] {
    GraphicsAdvancedState.triStateRawValues(including: stored).map { raw in
      (MetalTriState(rawValue: raw)?.label ?? "\(raw)", raw)
    }
  }
}

private extension MetalTriState {
  var label: String {
    switch self {
    case .off: return L("Off")
    case .on: return L("On")
    case .auto: return L("Auto")
    }
  }
}
