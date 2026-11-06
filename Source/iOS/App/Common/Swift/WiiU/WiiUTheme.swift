// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the Wii U tab's look. White and blue: a near-white stage with blue accents in light mode, the same
// blues on a dark navy stage in dark mode. Our own design (system font, SF Symbols, rounded cards); the
// GameCube side keeps its indigo glass look.

#if os(iOS) && canImport(IridiaCafeCore)
import SwiftUI
import UIKit

enum WiiUTheme {
  private static func dynamic(_ light: UIColor, _ dark: UIColor) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
  }
  private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor {
    UIColor(red: r, green: g, blue: b, alpha: a)
  }

  /// Text: titles, body, captions.
  static let ink = dynamic(rgb(0.08, 0.15, 0.26), rgb(0.92, 0.95, 1.0))
  static let soft = dynamic(rgb(0.30, 0.40, 0.52), rgb(0.70, 0.78, 0.90))
  static let dim = dynamic(rgb(0.45, 0.55, 0.67), rgb(0.53, 0.62, 0.76))
  /// Buttons, selection, icons.
  static let accent = dynamic(rgb(0.0, 0.47, 0.90), rgb(0.33, 0.66, 1.0))
  static let accentTop = dynamic(rgb(0.24, 0.64, 1.0), rgb(0.42, 0.72, 1.0))
  static let deep = dynamic(rgb(0.0, 0.32, 0.70), rgb(0.10, 0.40, 0.85))
  /// Text on a blue button.
  static let onAccent = Color.white
  static let warning = dynamic(rgb(0.80, 0.18, 0.18), rgb(1.0, 0.55, 0.55))

  static let stageTop = dynamic(rgb(0.985, 0.99, 1.0), rgb(0.06, 0.10, 0.19))
  static let stageBottom = dynamic(rgb(0.90, 0.94, 0.99), rgb(0.02, 0.04, 0.09))
  static let glow = dynamic(rgb(0.35, 0.65, 1.0, 0.24), rgb(0.20, 0.45, 1.0, 0.22))
  static let surfaceTop = dynamic(rgb(1, 1, 1, 0.96), rgb(1, 1, 1, 0.12))
  static let surfaceBottom = dynamic(rgb(1, 1, 1, 0.80), rgb(1, 1, 1, 0.04))
  static let rimTop = dynamic(rgb(1, 1, 1, 1), rgb(1, 1, 1, 0.35))
  static let rimBottom = dynamic(rgb(0.0, 0.47, 0.90, 0.22), rgb(0.33, 0.66, 1.0, 0.18))
  static let shadow = dynamic(rgb(0.10, 0.30, 0.55, 0.16), rgb(0, 0, 0, 0.45))

  /// The stage behind every Wii U screen: a soft top-to-bottom gradient and a blue glow behind the shelf.
  static var stage: some View {
    ZStack {
      LinearGradient(colors: [stageTop, stageBottom], startPoint: .top, endPoint: .bottom)
      RadialGradient(colors: [glow, .clear], center: UnitPoint(x: 0.5, y: 0.40), startRadius: 0, endRadius: 340)
    }
    .ignoresSafeArea()
  }
}

/// A card: bright fill (light) or faint glass (dark), blue-tinted rim, soft shadow. `prominent` = the blue
/// primary button.
struct WiiUSurface: ViewModifier {
  var radius: CGFloat
  var prominent = false

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(prominent
                ? AnyShapeStyle(LinearGradient(colors: [WiiUTheme.accentTop, WiiUTheme.accent, WiiUTheme.deep],
                                               startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(LinearGradient(colors: [WiiUTheme.surfaceTop, WiiUTheme.surfaceBottom],
                                               startPoint: .top, endPoint: .bottom)))
          .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
              .strokeBorder(LinearGradient(colors: [WiiUTheme.rimTop, prominent ? WiiUTheme.deep : WiiUTheme.rimBottom],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1)
          )
          .shadow(color: prominent ? WiiUTheme.accent.opacity(0.40) : WiiUTheme.shadow, radius: prominent ? 12 : 10, y: 6)
      }
  }
}

extension View {
  func wiiUSurface(radius: CGFloat, prominent: Bool = false) -> some View {
    modifier(WiiUSurface(radius: radius, prominent: prominent))
  }

  /// Lists and forms in the Wii U tab: the stage behind them, blue tint, clear navigation bar.
  func wiiUScreen() -> some View {
    self
      .scrollContentBackground(.hidden)
      .background(WiiUTheme.stage)
      .tint(WiiUTheme.accent)
      .toolbarBackground(.hidden, for: .navigationBar)
  }
}

struct WiiUPress: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
  }
}

/// The tab's mark: a rounded tile with a blue ring (our own art).
struct WiiUMark: View {
  var size: CGFloat = 40
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        .fill(LinearGradient(colors: [WiiUTheme.surfaceTop, WiiUTheme.surfaceBottom], startPoint: .top, endPoint: .bottom))
        .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(WiiUTheme.rimBottom, lineWidth: 1))
        .shadow(color: WiiUTheme.accent.opacity(0.25), radius: 4, y: 2)
      Circle()
        .strokeBorder(LinearGradient(colors: [WiiUTheme.accentTop, WiiUTheme.deep], startPoint: .top, endPoint: .bottom),
                      lineWidth: size * 0.12)
        .frame(width: size * 0.56, height: size * 0.56)
    }
    .frame(width: size, height: size)
  }
}
#endif
