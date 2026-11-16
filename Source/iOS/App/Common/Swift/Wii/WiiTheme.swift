// SPDX-License-Identifier: GPL-2.0-or-later
//
// Grey and white; the same greys on a charcoal stage in dark mode.

#if os(iOS)
import SwiftUI
import UIKit

enum WiiTheme {
  private static func dynamic(_ light: UIColor, _ dark: UIColor) -> Color {
    Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
  }
  private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor {
    UIColor(red: r, green: g, blue: b, alpha: a)
  }

  /// Text: titles, body, captions.
  static let ink = dynamic(rgb(0.13, 0.14, 0.16), rgb(0.94, 0.945, 0.95))
  static let soft = dynamic(rgb(0.36, 0.38, 0.41), rgb(0.74, 0.75, 0.77))
  static let dim = dynamic(rgb(0.50, 0.52, 0.55), rgb(0.56, 0.58, 0.61))
  /// Buttons, selection, icons: soft grey.
  static let accent = dynamic(rgb(0.40, 0.42, 0.46), rgb(0.80, 0.81, 0.83))
  static let accentTop = dynamic(rgb(0.58, 0.60, 0.63), rgb(0.90, 0.905, 0.91))
  static let deep = dynamic(rgb(0.30, 0.32, 0.35), rgb(0.64, 0.65, 0.68))
  /// Text on a grey button.
  static let onAccent = dynamic(.white, rgb(0.10, 0.11, 0.12))
  static let warning = dynamic(rgb(0.72, 0.30, 0.10), rgb(1.0, 0.68, 0.48))

  static let stageTop = dynamic(rgb(0.985, 0.985, 0.99), rgb(0.12, 0.125, 0.135))
  static let stageBottom = dynamic(rgb(0.90, 0.905, 0.915), rgb(0.045, 0.05, 0.055))
  static let glow = dynamic(rgb(1, 1, 1, 0.85), rgb(0.70, 0.72, 0.76, 0.14))
  static let surfaceTop = dynamic(rgb(1, 1, 1, 0.97), rgb(1, 1, 1, 0.13))
  static let surfaceBottom = dynamic(rgb(0.955, 0.958, 0.965, 0.88), rgb(1, 1, 1, 0.05))
  static let rimTop = dynamic(rgb(1, 1, 1, 1), rgb(1, 1, 1, 0.34))
  static let rimBottom = dynamic(rgb(0.40, 0.42, 0.46, 0.22), rgb(0.80, 0.81, 0.83, 0.18))
  static let shadow = dynamic(rgb(0.20, 0.22, 0.26, 0.14), rgb(0, 0, 0, 0.45))
  static let selection = dynamic(rgb(0.40, 0.42, 0.46), rgb(0.86, 0.87, 0.88))

  /// The stage behind every Wii screen: a soft top-to-bottom gradient and a soft white glow behind the shelf.
  static var stage: some View {
    ZStack {
      LinearGradient(colors: [stageTop, stageBottom], startPoint: .top, endPoint: .bottom)
      RadialGradient(colors: [glow, .clear], center: UnitPoint(x: 0.5, y: 0.40), startRadius: 0, endRadius: 340)
    }
    .ignoresSafeArea()
  }
}

/// A card: white fill (light) or faint glass (dark), grey rim, soft shadow. `prominent` = the grey
/// primary button.
struct WiiSurface: ViewModifier {
  var radius: CGFloat
  var prominent = false

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(prominent
                ? AnyShapeStyle(LinearGradient(colors: [WiiTheme.accentTop, WiiTheme.accent, WiiTheme.deep],
                                               startPoint: .top, endPoint: .bottom))
                : AnyShapeStyle(LinearGradient(colors: [WiiTheme.surfaceTop, WiiTheme.surfaceBottom],
                                               startPoint: .top, endPoint: .bottom)))
          .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
              .strokeBorder(LinearGradient(colors: [WiiTheme.rimTop, prominent ? WiiTheme.deep : WiiTheme.rimBottom],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1)
          )
          .shadow(color: prominent ? WiiTheme.accent.opacity(0.38) : WiiTheme.shadow, radius: prominent ? 12 : 10, y: 6)
      }
  }
}

extension View {
  func wiiSurface(radius: CGFloat, prominent: Bool = false) -> some View {
    modifier(WiiSurface(radius: radius, prominent: prominent))
  }

  /// Lists and forms in the Wii section: the stage behind them, grey tint, clear navigation bar.
  func wiiScreen() -> some View {
    self
      .scrollContentBackground(.hidden)
      .background(WiiTheme.stage)
      .tint(WiiTheme.accent)
      .toolbarBackground(.hidden, for: .navigationBar)
  }
}

struct WiiPress: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
      .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: configuration.isPressed) { _, pressed in pressed && IridiaHaptics.enabled }
  }
}

/// The section's mark: a white tile holding two grey dots side by side (our own art).
struct WiiMark: View {
  var size: CGFloat = 40
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        .fill(LinearGradient(colors: [WiiTheme.surfaceTop, WiiTheme.surfaceBottom], startPoint: .top, endPoint: .bottom))
        .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(WiiTheme.rimBottom, lineWidth: 1))
        .shadow(color: WiiTheme.accent.opacity(0.25), radius: 4, y: 2)
      HStack(spacing: size * 0.08) {
        Circle().fill(LinearGradient(colors: [WiiTheme.accentTop, WiiTheme.deep], startPoint: .top, endPoint: .bottom))
        Circle().fill(LinearGradient(colors: [WiiTheme.accentTop, WiiTheme.deep], startPoint: .top, endPoint: .bottom))
          .opacity(0.55)
      }
      .frame(width: size * 0.58, height: size * 0.25)
    }
    .frame(width: size, height: size)
  }
}
#endif
