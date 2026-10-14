// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum GraphicsEnhancementsModelBuilder {
  static func make(state: GraphicsEnhancementsState, apply: @escaping (GraphicsEnhancementsChange) -> Void) -> MenuModel {
    let msaaOn = state.msaa > MsaaSamples.none.rawValue

    // Resolver step #3: while an auto controller or the game drives the key, the manual choice would not apply until the override clears.
    let resolution = MenuSection(id: "internal-resolution", header: L("Internal Resolution"), items: [
      SettingsRow.cycle("efb-scale", L("Internal Resolution"), efbScaleOptions(maxScale: max(state.efbMaxScale, state.efbScale)), state.efbScale,
            L("Draws the game at a higher resolution for a sharper picture. Higher settings use more battery."),
            enabled: state.efbOverride == .none, badge: ConfigOverrideBadge.title(for: state.efbOverride), set: { apply(.efbScale($0)) }),
    ])
    let filtering = MenuSection(id: "texture-filtering", header: L("Texture Filtering"), items: [
      SettingsRow.cycle("anisotropy", L("Anisotropic Filtering"), GraphicsEnhancementsState.anisotropyLadder.map { (multiplier($0), $0) }, state.anisotropy,
            L("Keeps floors and walls sharp when seen at an angle. Costs very little."), set: { apply(.anisotropy($0)) }),
      SettingsRow.cycle("msaa", L("Anti-Aliasing (MSAA)"), MsaaSamples.allCases.map { ($0 == .none ? L("None") : multiplier($0.rawValue), $0.rawValue) }, state.msaa,
            L("Smooths jagged edges. Higher settings use more battery."),
            set: { apply(.msaa($0)) }),
      SettingsRow.toggle("ssaa", L("Supersampling (SSAA)"), state.ssaa,
             msaaOn ? L("Sharpest anti-aliasing, but very demanding. Needs anti-aliasing turned on first.")
                    : L("Enable MSAA (above None) first to use supersampling."),
             enabled: msaaOn, set: { apply(.ssaa($0)) }),
      SettingsRow.cycle("output-resampling", L("Output Resampling"), OutputResamplingChoice.allCases.map { ($0.title, $0.rawValue) }, state.outputResampling,
            L("How the picture is scaled to fit the screen. Sharp Bilinear and Area Sampling can look cleaner."),
            set: { apply(.outputResampling($0)) }),
    ])
    let enhancements = MenuSection(id: "enhancements", header: L("Enhancements"), items: [
      SettingsRow.toggle("true-color", L("Force 24-bit Color"), state.trueColor,
             L("Smoother colour gradients than the original hardware, at almost no cost."),
             set: { apply(.trueColor($0)) }),
      SettingsRow.toggle("disable-copy-filter", L("Disable Copy Filter"), state.disableCopyFilter,
             L("Removes the slight blur the console added. Sharper, but a few games may look a little different."),
             set: { apply(.disableCopyFilter($0)) }),
      SettingsRow.toggle("widescreen-hack", L("Widescreen Hack"), state.widescreenHack,
             L("Makes 4:3 games widescreen. Can stretch menus or break some games."),
             set: { apply(.widescreenHack($0)) }),
      SettingsRow.toggle("hdr-output", L("HDR Output"), state.hdrOutput,
             L("Uses HDR on screens that support it. The difference is small in most games."),
             set: { apply(.hdrOutput($0)) }),
      SettingsRow.toggle("gpu-texture-decoding", L("GPU Texture Decoding"), state.gpuTextureDecoding,
             L("Decodes textures on the GPU instead of the CPU. Can help games that load a lot of textures."),
             set: { apply(.gpuTextureDecoding($0)) }),
    ])

    var compatibilityItems = [
      SettingsRow.toggle("disable-fog", L("Disable Fog"), state.disableFog,
             L("Removes distance fog. You can see further, but some scenes won't look as intended."),
             set: { apply(.disableFog($0)) }),
      SettingsRow.toggle("arbitrary-mipmap", L("Arbitrary Mipmap Detection"), state.arbitraryMipmapDetection,
             L("Fixes special effects in games that use textures in unusual ways. Leave on unless a game looks wrong."),
             set: { apply(.arbitraryMipmapDetection($0)) }),
    ]
    // Hidden, not disabled, while detection is off: the old screen only showed it then.
    if state.arbitraryMipmapDetection {
      compatibilityItems.append(
        SettingsRow.stepper("arbitrary-mipmap-threshold", L("Mipmap Detection Threshold"), state.arbitraryMipmapThreshold,
                            range: GraphicsEnhancementsState.mipmapThresholdRange, step: GraphicsEnhancementsState.mipmapThresholdStep,
                            format: { String(format: "%.2f", $0) },
                            L("Sensitivity of arbitrary-mipmap detection. Leave at the default unless a game's textures look wrong."),
                            set: { apply(.arbitraryMipmapThreshold($0)) }))
    }
    let compatibility = MenuSection(id: "compatibility", header: L("Compatibility"), items: compatibilityItems)

    return MenuModel(sections: [resolution, filtering, enhancements, compatibility])
  }

  /// "2x"; the one place a scale or sample count becomes a label.
  private static func multiplier(_ value: Int) -> String { "\(value)x" }

  /// Auto, 1x (Native), then 2x ... maxScale. Empty-safe for a maxScale below 2. The caller passes at least the stored scale, so a value above the current max keeps its real label.
  private static func efbScaleOptions(maxScale: Int) -> [(String, Int)] {
    let first = EfbScaleChoice.native.rawValue + 1
    return [(L("Auto (fit window)"), EfbScaleChoice.auto.rawValue), ("\(multiplier(EfbScaleChoice.native.rawValue)) (\(L("Native")))", EfbScaleChoice.native.rawValue)]
      + stride(from: first, through: maxScale, by: 1).map { (multiplier($0), $0) }
  }
}

private extension OutputResamplingChoice {
  var title: String {
    switch self {
    case .standard: return L("Default")
    case .bilinear: return L("Bilinear")
    case .bSpline: return L("B-Spline")
    case .mitchellNetravali: return L("Mitchell-Netravali")
    case .catmullRom: return L("Catmull-Rom")
    case .sharpBilinear: return L("Sharp Bilinear")
    case .areaSampling: return L("Area Sampling")
    }
  }
}
