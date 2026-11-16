// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// Outline icons for the three systems, drawn on SF Symbols' 24-unit grid with round caps and joins so they
/// sit with the symbols beside them in the tab bar.
struct SystemIcon: View {
  let system: HomeSystem
  var bold = false
  var size: CGFloat = 24

  var body: some View {
    SystemIconShape(system: system, weight: bold ? 2.3 : 1.75)
      .frame(width: size, height: size)
      .animation(.snappy(duration: 0.25), value: bold)
      .accessibilityHidden(true)
  }
}

/// Filled outline of the icon, so overlapping parts can be cut away (the Wii U's second screen).
struct SystemIconShape: Shape {
  let system: HomeSystem
  /// Stroke width in grid units.
  var weight: CGFloat

  var animatableData: CGFloat {
    get { weight }
    set { weight = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let unit = min(rect.width, rect.height) / 24
    let style = StrokeStyle(lineWidth: weight * unit, lineCap: .round, lineJoin: .round)
    let place = CGAffineTransform(translationX: rect.midX - 12 * unit, y: rect.midY - 12 * unit).scaledBy(x: unit, y: unit)
    let outline: Path
    switch system {
    case .gameCube: outline = Self.cube.applying(place).strokedPath(style)
    case .wii: outline = Self.console.applying(place).strokedPath(style)
    case .wiiU:
      let gap = (weight / 2 + 1.1) * unit
      let front = Self.secondScreen.applying(place)
      let frontArea = front.boundingRect.insetBy(dx: -gap, dy: -gap)
      let back = Self.tv.applying(place).strokedPath(style)
        .subtracting(Path(roundedRect: frontArea, cornerRadius: 2.6 * unit, style: .continuous))
      outline = back.union(front.strokedPath(style))
    }
    return outline
  }

  private static let cube: Path = {
    var p = Path()
    let top = CGPoint(x: 12, y: 2.6), upperRight = CGPoint(x: 20.2, y: 7.3), lowerRight = CGPoint(x: 20.2, y: 16.7)
    let bottom = CGPoint(x: 12, y: 21.4), lowerLeft = CGPoint(x: 3.8, y: 16.7), upperLeft = CGPoint(x: 3.8, y: 7.3)
    let centre = CGPoint(x: 12, y: 12)
    p.addLines([top, upperRight, lowerRight, bottom, lowerLeft, upperLeft])
    p.closeSubpath()
    p.move(to: upperLeft); p.addLine(to: centre); p.addLine(to: upperRight)
    p.move(to: centre); p.addLine(to: bottom)
    return p
  }()

  private static let console: Path = {
    var p = Path(roundedRect: CGRect(x: 8.4, y: 2.4, width: 7.2, height: 16.2), cornerRadius: 2.2, style: .continuous)
    p.move(to: CGPoint(x: 12, y: 5.6)); p.addLine(to: CGPoint(x: 12, y: 11.4))
    p.move(to: CGPoint(x: 6.6, y: 21.6)); p.addLine(to: CGPoint(x: 17.4, y: 21.6))
    return p
  }()

  private static let tv = Path(roundedRect: CGRect(x: 2.4, y: 3.6, width: 16.4, height: 12.2), cornerRadius: 2.4, style: .continuous)
  private static let secondScreen = Path(roundedRect: CGRect(x: 12.6, y: 11.6, width: 9, height: 8.8), cornerRadius: 1.8, style: .continuous)
}
#endif
