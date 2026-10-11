// SPDX-License-Identifier: GPL-2.0-or-later
//
// Built-in skins (matte plastic). Original layout drawn from our own primitives. Relative sizes and
// colors follow what GameCube games refer to (big green A, small red B, purple Z,
// yellow C-stick); X/Y are our own rounded pills, not the original kidney shapes.

public enum BuiltinSkins {
  public static let all: [ControllerSkin] = [indigo, midnight, orchid]
  public static var `default`: ControllerSkin { indigo }

  public static let indigo = make(
    id: "builtin.indigo", name: "Indigo",
    palette: SkinPalette(
      backgroundTop: "#30286A", backgroundBottom: "#1A1542", glassHighlight: "#E6E2FF",
      stickBase: "#18143A", neutral: "#A9A4C6", label: "#FFFFFF",
      buttonA: "#3F9D67", buttonB: "#B64B51", buttonZ: "#7461B8", cStick: "#CBA746",
      accent: "#8B80C8"))

  public static let midnight = make(
    id: "builtin.midnight", name: "Midnight",
    palette: SkinPalette(
      backgroundTop: "#22264A", backgroundBottom: "#0D0F22", glassHighlight: "#D7DCF5",
      stickBase: "#10122A", neutral: "#9AA0BE", label: "#F2F4FF",
      buttonA: "#3A8F61", buttonB: "#A8474C", buttonZ: "#645AA8", cStick: "#BE9C42",
      accent: "#7380C0"))

  public static let orchid = make(
    id: "builtin.orchid", name: "Orchid",
    palette: SkinPalette(
      backgroundTop: "#4F2E70", backgroundBottom: "#29163F", glassHighlight: "#F5E8FF",
      stickBase: "#2B1643", neutral: "#C7B6D6", label: "#FFFFFF",
      buttonA: "#43A06C", buttonB: "#BC5660", buttonZ: "#8D6BBF", cStick: "#D0AE4E",
      accent: "#C29AD6"))

  // MARK: Layouts (shared by all built-in palettes)

  static func make(id: String, name: String, palette: SkinPalette) -> ControllerSkin {
    ControllerSkin(
      formatVersion: ControllerSkin.currentFormatVersion, identifier: id, name: name,
      author: "gc-emu", palette: palette,
      portrait: portraitLayout, landscape: landscapeLayout, images: nil)
  }

  private static func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> SkinRect {
    SkinRect(x: x, y: y, width: w, height: h)
  }

  /// Bottom-half controller, 400×420 mapping space.
  static let portraitLayout = SkinLayout(
    mappingSize: SkinSize(width: 400, height: 420),
    items: [
      SkinItem(id: "l", input: .l, shape: .roundedRect, frame: r(14, 10, 112, 40), color: "neutral", label: "L"),
      SkinItem(id: "r", input: .r, shape: .roundedRect, frame: r(274, 10, 112, 40), color: "neutral", label: "R"),
      SkinItem(id: "z", input: .z, shape: .pill, frame: r(292, 52, 88, 26), color: "buttonZ", label: "Z"),
      SkinItem(id: "mainStick", input: .mainStick, shape: .stick, frame: r(18, 78, 144, 144), color: "neutral"),
      SkinItem(id: "a", input: .a, shape: .circle, frame: r(262, 124, 78, 78), color: "buttonA", label: "A"),
      SkinItem(id: "b", input: .b, shape: .circle, frame: r(214, 186, 46, 46), color: "buttonB", label: "B"),
      SkinItem(id: "x", input: .x, shape: .pill, frame: r(344, 118, 42, 64), color: "neutral", label: "X"),
      SkinItem(id: "y", input: .y, shape: .pill, frame: r(264, 84, 64, 36), color: "neutral", label: "Y"),
      SkinItem(id: "start", input: .start, shape: .pill, frame: r(172, 238, 56, 26), color: "neutral", label: "START"),
      SkinItem(id: "dpad", input: .dpad, shape: .dpad, frame: r(36, 262, 112, 112), color: "neutral"),
      SkinItem(id: "cStick", input: .cStick, shape: .stick, frame: r(246, 262, 108, 108), color: "cStick", label: "C"),
      // No logo item until the real app logo exists (Phase 5); `.logo` stays supported for custom skins.
      SkinItem(id: "menu", input: .menu, shape: .pill, frame: r(176, 380, 48, 26), color: "neutral", label: "☰"),
    ],
    defaultOpacity: 1.0, showsBackground: true)

  /// Full-screen overlay, 844×390 mapping space. Items anchor to their nearest edge
  /// at runtime, so the layout holds up on every screen width.
  static let landscapeLayout = SkinLayout(
    mappingSize: SkinSize(width: 844, height: 390),
    items: [
      SkinItem(id: "l", input: .l, shape: .roundedRect, frame: r(22, 16, 120, 40), color: "neutral", label: "L"),
      SkinItem(id: "r", input: .r, shape: .roundedRect, frame: r(702, 16, 120, 40), color: "neutral", label: "R"),
      SkinItem(id: "z", input: .z, shape: .pill, frame: r(726, 62, 96, 28), color: "buttonZ", label: "Z"),
      SkinItem(id: "mainStick", input: .mainStick, shape: .stick, frame: r(30, 92, 144, 144), color: "neutral"),
      SkinItem(id: "dpad", input: .dpad, shape: .dpad, frame: r(150, 262, 104, 104), color: "neutral"),
      SkinItem(id: "a", input: .a, shape: .circle, frame: r(700, 150, 78, 78), color: "buttonA", label: "A"),
      SkinItem(id: "b", input: .b, shape: .circle, frame: r(650, 214, 46, 46), color: "buttonB", label: "B"),
      SkinItem(id: "x", input: .x, shape: .pill, frame: r(784, 142, 42, 64), color: "neutral", label: "X"),
      SkinItem(id: "y", input: .y, shape: .pill, frame: r(702, 104, 64, 36), color: "neutral", label: "Y"),
      SkinItem(id: "cStick", input: .cStick, shape: .stick, frame: r(586, 268, 100, 100), color: "cStick", label: "C"),
      SkinItem(id: "start", input: .start, shape: .pill, frame: r(394, 346, 56, 26), color: "neutral", label: "START"),
      SkinItem(id: "menu", input: .menu, shape: .pill, frame: r(398, 14, 48, 26), color: "neutral", label: "☰"),
    ],
    defaultOpacity: 0.4, showsBackground: false)
}
