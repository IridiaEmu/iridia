// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Wii U touch control art in Iridia's matte-plastic style (ported from GCControlsUI/SkinRenderer):
//   one light source (top-left), diffuse shading, bevelled edges, fine grain, contact shadows,
//   recessed wells in the shell, debossed labels. Every image is rendered once per size and cached;
//   gameplay only swaps images.
import UIKit

#if os(iOS) && canImport(IridiaCafeCore)

enum PadPalette {
  static let shellTop = UIColor(red: 0.97, green: 0.98, blue: 0.99, alpha: 1)
  static let shellBottom = UIColor(red: 0.84, green: 0.88, blue: 0.93, alpha: 1)
  static let silver = UIColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1)
  static let slate = UIColor(red: 0.29, green: 0.33, blue: 0.38, alpha: 1)
  static let stickBase = UIColor(red: 0.16, green: 0.19, blue: 0.23, alpha: 1)
  static let blue = UIColor(red: 0.0, green: 0.60, blue: 0.86, alpha: 1)
}

enum PadShape { case circle, tab, dpad }

@MainActor
final class PadArt {
  static let shared = PadArt()
  private var cache: [String: UIImage] = [:]
  private static let lightDir = CGVector(dx: -0.55, dy: -0.85)

  /// Transparent margin around part images so contact shadows aren't clipped.
  static func padding(for size: CGSize) -> CGFloat { (min(size.width, size.height) * 0.16).rounded(.up) + 2 }

  private func cached(_ key: String, _ size: CGSize, _ body: (CGContext) -> Void) -> UIImage {
    if let img = cache[key] { return img }
    let fmt = UIGraphicsImageRendererFormat.preferred()
    fmt.opaque = false
    let img = UIGraphicsImageRenderer(size: size, format: fmt).image { body($0.cgContext) }
    cache[key] = img
    return img
  }

  // MARK: Parts

  /// A button (circle or shoulder tab) with a debossed text or SF Symbol label. Image includes padding.
  func button(_ shape: PadShape, size: CGSize, base: UIColor, text: String? = nil, symbol: String? = nil, pressed: Bool) -> UIImage {
    let pad = Self.padding(for: size)
    let key = "b|\(shape)|\(Int(size.width))x\(Int(size.height))|\(base.hashValue)|\(text ?? "")|\(symbol ?? "")|\(pressed)"
    return cached(key, CGSize(width: size.width + pad * 2, height: size.height + pad * 2)) { ctx in
      let r = CGRect(x: pad, y: pad, width: size.width, height: size.height).insetBy(dx: 1, dy: 1)
      let path = self.shapePath(shape, in: r)
      self.part(path, base: base, pressed: pressed, ctx: ctx) { b in
        if shape == .tab {
          // faint ridge across the curved face
          ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.10).cgColor)
          ctx.setLineWidth(max(0.75, b.height * 0.02))
          ctx.move(to: CGPoint(x: b.minX + b.width * 0.14, y: b.minY + b.height * 0.28))
          ctx.addLine(to: CGPoint(x: b.maxX - b.width * 0.14, y: b.minY + b.height * 0.28))
          ctx.strokePath()
        }
        let lb = shape == .tab ? b.offsetBy(dx: 0, dy: b.height * 0.06) : b
        if let text { self.deboss(text, in: lb, size: min(b.width, b.height) * (shape == .tab ? 0.44 : 0.42), on: base, ctx: ctx) }
        if let symbol { self.debossSymbol(symbol, in: lb, size: min(b.width, b.height) * 0.40, on: base, ctx: ctx) }
      }
    }
  }

  /// The D-pad cross (image includes padding).
  func dpad(size: CGSize, base: UIColor) -> UIImage {
    let pad = Self.padding(for: size)
    return cached("d|\(Int(size.width))|\(base.hashValue)", CGSize(width: size.width + pad * 2, height: size.height + pad * 2)) { ctx in
      let r = CGRect(x: pad, y: pad, width: size.width, height: size.height).insetBy(dx: 2, dy: 2)
      self.part(self.dpadPath(in: r), base: base, pressed: false, ctx: ctx) { b in self.dpadDetails(in: b, base: base, ctx: ctx) }
    }
  }

  /// One pressed D-pad arm (0 up, 1 down, 2 left, 3 right), unpadded size: the arm sinks into the shell.
  func dpadArm(size: CGSize, direction: Int) -> UIImage {
    cached("a|\(Int(size.width))|\(direction)", size) { ctx in
      let rr = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
      let a = rr.width * 0.34, len = rr.width / 2
      let rect: CGRect = switch direction {
      case 0: CGRect(x: rr.midX - a / 2, y: rr.minY, width: a, height: len)
      case 1: CGRect(x: rr.midX - a / 2, y: rr.midY, width: a, height: len)
      case 2: CGRect(x: rr.minX, y: rr.midY - a / 2, width: len, height: a)
      default: CGRect(x: rr.midX, y: rr.midY - a / 2, width: len, height: a)
      }
      ctx.addPath(self.dpadPath(in: rr).cgPath)
      ctx.clip()
      let arm = UIBezierPath(rect: rect)
      ctx.addPath(arm.cgPath)
      ctx.setFillColor(UIColor.black.withAlphaComponent(0.22).cgColor)
      ctx.fillPath()
      ctx.addPath(arm.cgPath)
      ctx.clip()
      self.innerShadow(self.dpadPath(in: rr), offset: CGSize(width: 1.0, height: 1.6), blur: a * 0.12, alpha: 0.45, ctx: ctx)
    }
  }

  /// Stick housing: concave bowl and gate ring (unpadded size).
  func stickWell(size: CGSize) -> UIImage {
    cached("w|\(Int(size.width))", size) { ctx in
      let r = CGRect(origin: .zero, size: size)
      let well = r.insetBy(dx: r.width * 0.02, dy: r.height * 0.02)
      let dark = PadPalette.stickBase
      ctx.saveGState()
      ctx.addEllipse(in: well)
      ctx.clip()
      self.linearGradient(ctx, [dark.adjusted(brightness: 0.55), dark, dark.adjusted(brightness: 1.45)], [0, 0.55, 1],
                          from: CGPoint(x: well.minX, y: well.minY), to: CGPoint(x: well.maxX, y: well.maxY))
      self.grain(ctx, in: well, alpha: 0.05)
      self.innerShadow(UIBezierPath(ovalIn: well), offset: CGSize(width: 1.6, height: 2.6), blur: well.width * 0.08, alpha: 0.65, ctx: ctx)
      ctx.restoreGState()
      let g = well.insetBy(dx: r.width * 0.07, dy: r.height * 0.07)
      ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.30).cgColor)
      ctx.setLineWidth(max(1, r.width * 0.018))
      ctx.strokeEllipse(in: g.offsetBy(dx: -0.4, dy: -0.6))
    }
  }

  /// Stick cap: matte disc, knurled rim, concave dish (image includes padding).
  func stickCap(size: CGSize, base: UIColor, pressed: Bool) -> UIImage {
    let pad = Self.padding(for: size)
    return cached("k|\(Int(size.width))|\(base.hashValue)|\(pressed)", CGSize(width: size.width + pad * 2, height: size.height + pad * 2)) { ctx in
      let r = CGRect(x: pad, y: pad, width: size.width, height: size.height).insetBy(dx: 2, dy: 2)
      self.part(UIBezierPath(ovalIn: r), base: base, pressed: pressed, ctx: ctx) { b in
        let center = CGPoint(x: b.midX, y: b.midY)
        let ro = b.width / 2 * 0.94, ri = b.width / 2 * 0.80
        ctx.setLineWidth(max(0.5, b.width * 0.008))
        for i in 0..<40 {
          let a = CGFloat(i) / 40 * .pi * 2
          let facing = -(cos(a) * Self.lightDir.dx + sin(a) * Self.lightDir.dy)
          ctx.setStrokeColor((facing > 0 ? UIColor.white.withAlphaComponent(0.07 + 0.08 * facing)
                                          : UIColor.black.withAlphaComponent(0.10 - 0.08 * facing)).cgColor)
          ctx.move(to: CGPoint(x: center.x + cos(a) * ri, y: center.y + sin(a) * ri))
          ctx.addLine(to: CGPoint(x: center.x + cos(a) * ro, y: center.y + sin(a) * ro))
          ctx.strokePath()
        }
        let dish = b.insetBy(dx: b.width * 0.21, dy: b.height * 0.21)
        ctx.saveGState()
        ctx.addEllipse(in: dish)
        ctx.clip()
        self.linearGradient(ctx, [base.adjusted(brightness: 0.74), base.adjusted(brightness: 0.95), base.adjusted(brightness: 1.12)], [0, 0.5, 1],
                            from: CGPoint(x: dish.minX, y: dish.minY), to: CGPoint(x: dish.maxX, y: dish.maxY))
        self.grain(ctx, in: dish, alpha: 0.07)
        self.innerShadow(UIBezierPath(ovalIn: dish), offset: CGSize(width: 0.8, height: 1.4), blur: dish.width * 0.08, alpha: 0.30, ctx: ctx)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: dish)
        ctx.setLineWidth(max(0.75, b.width * 0.012))
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        self.linearGradient(ctx, [UIColor.black.withAlphaComponent(0.18), .clear, UIColor.white.withAlphaComponent(0.18)], [0, 0.5, 1],
                            from: CGPoint(x: dish.minX, y: dish.minY), to: CGPoint(x: dish.maxX, y: dish.maxY))
        ctx.restoreGState()
      }
    }
  }

  // MARK: Shell

  struct Well { let shape: PadShape; let rect: CGRect }

  /// One GamePad grip: white matte plastic, rounded on the inner side, running off the outer screen edge,
  /// with a recessed well under every control. Rendered when the size changes, never per frame.
  func shell(size: CGSize, left: Bool, radius: CGFloat, wells: [Well], key: String) -> UIImage {
    cached("s|\(key)|\(Int(size.width))x\(Int(size.height))|\(left)", size) { ctx in
      let r = CGRect(origin: .zero, size: size)
      let inset = r.insetBy(dx: 6, dy: 6)
      let corners: UIRectCorner = left ? [.topRight, .bottomRight] : [.topLeft, .bottomLeft]
      let shellPath = UIBezierPath(roundedRect: inset, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
      // contact shadow onto the game
      ctx.saveGState()
      ctx.setShadow(offset: CGSize(width: left ? 2 : -2, height: 3), blur: 6, color: UIColor.black.withAlphaComponent(0.35).cgColor)
      ctx.addPath(shellPath.cgPath)
      ctx.setFillColor(PadPalette.shellBottom.cgColor)
      ctx.fillPath()
      ctx.restoreGState()

      ctx.saveGState()
      ctx.addPath(shellPath.cgPath)
      ctx.clip()
      self.linearGradient(ctx, [PadPalette.shellTop, PadPalette.shellBottom], [0, 1], from: CGPoint(x: r.midX, y: r.minY), to: CGPoint(x: r.midX, y: r.maxY))
      self.linearGradient(ctx, [UIColor.white.withAlphaComponent(0.10), .clear, UIColor.black.withAlphaComponent(0.08)], [0, 0.5, 1],
                          from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.maxX, y: r.maxY))
      // the grip rounds away from the light toward its inner edge
      let edge = left ? inset.maxX : inset.minX
      self.linearGradient(ctx, [.clear, UIColor(red: 0.2, green: 0.35, blue: 0.5, alpha: 0.16)], [0.6, 1],
                          from: CGPoint(x: left ? inset.minX : inset.maxX, y: r.midY), to: CGPoint(x: edge, y: r.midY))
      self.grain(ctx, in: r, alpha: 0.06)
      _ = wells  // no recesses: they read as light outlines around each control
      ctx.restoreGState()

      // lit lip along the top edge and a thin parting line
      ctx.saveGState()
      ctx.addPath(shellPath.cgPath)
      ctx.setLineWidth(3)
      ctx.replacePathWithStrokedPath()
      ctx.clip()
      self.linearGradient(ctx, [UIColor.white.withAlphaComponent(0.9), .clear], [0, 1],
                          from: CGPoint(x: r.midX, y: inset.minY), to: CGPoint(x: r.midX, y: inset.minY + radius * 1.5))
      ctx.restoreGState()
      ctx.addPath(shellPath.cgPath)
      ctx.setStrokeColor(UIColor(red: 0.2, green: 0.35, blue: 0.5, alpha: 0.30).cgColor)
      ctx.setLineWidth(0.7)
      ctx.strokePath()
    }
  }

  /// A soft recess hugging the part: shadowed on the top-left inner wall, no rim line.
  private func well(_ w: Well, ctx: CGContext) {
    let isStick = w.shape == .circle && w.rect.width > 90
    let e = max(2, min(w.rect.width, w.rect.height) * 0.05)
    let path = shapePath(w.shape, in: w.rect.insetBy(dx: isStick ? -e * 0.3 : -e, dy: isStick ? -e * 0.3 : -e))
    ctx.saveGState()
    ctx.addPath(path.cgPath)
    ctx.clip()
    ctx.addPath(path.cgPath)
    ctx.setFillColor(UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.12).cgColor)
    ctx.fillPath()
    innerShadow(path, offset: CGSize(width: 1.2, height: 2.0), blur: e * 1.4, alpha: 0.40, ctx: ctx)
    ctx.restoreGState()
  }

  // MARK: Shapes

  func shapePath(_ shape: PadShape, in r: CGRect) -> UIBezierPath {
    switch shape {
    case .circle: UIBezierPath(ovalIn: r)
    case .tab: UIBezierPath(roundedRect: r, cornerRadius: r.height * 0.42)
    case .dpad: dpadPath(in: r)
    }
  }

  /// One continuous cross outline (12 corners) so fill, shading and bevel have no seams.
  private func dpadPath(in r: CGRect) -> UIBezierPath {
    let a = r.width * 0.34 / 2
    let cx = r.midX, cy = r.midY
    let pts: [CGPoint] = [
      CGPoint(x: cx - a, y: r.minY), CGPoint(x: cx + a, y: r.minY), CGPoint(x: cx + a, y: cy - a), CGPoint(x: r.maxX, y: cy - a),
      CGPoint(x: r.maxX, y: cy + a), CGPoint(x: cx + a, y: cy + a), CGPoint(x: cx + a, y: r.maxY), CGPoint(x: cx - a, y: r.maxY),
      CGPoint(x: cx - a, y: cy + a), CGPoint(x: r.minX, y: cy + a), CGPoint(x: r.minX, y: cy - a), CGPoint(x: cx - a, y: cy - a),
    ]
    let outer = a * 0.55, inner = a * 0.25
    let p = CGMutablePath()
    p.move(to: CGPoint(x: (pts[0].x + pts[1].x) / 2, y: pts[0].y))
    for i in 1...pts.count {
      let corner = pts[i % pts.count], next = pts[(i + 1) % pts.count]
      p.addArc(tangent1End: corner, tangent2End: next, radius: (i % pts.count) % 3 == 2 ? inner : outer)
    }
    p.closeSubpath()
    return UIBezierPath(cgPath: p)
  }

  // MARK: Material

  /// A matte plastic part: contact shadow, diffuse shading lit from the top-left, grain, bevelled edge.
  /// Pressed parts sink: they move down a little, shrink a hair, darken, and their shadow tightens.
  private func part(_ path: UIBezierPath, base: UIColor, pressed: Bool, ctx: CGContext, details: (CGRect) -> Void) {
    var p = path
    let b0 = path.bounds
    let k = min(b0.width, b0.height) / 50
    if pressed {
      var t = CGAffineTransform(translationX: b0.midX, y: b0.midY + 1.2 * k).scaledBy(x: 0.965, y: 0.965).translatedBy(x: -b0.midX, y: -b0.midY)
      if let moved = path.cgPath.copy(using: &t) { p = UIBezierPath(cgPath: moved) }
    }
    let b = p.bounds
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: (pressed ? 0.4 : 1.4) * k, height: (pressed ? 0.8 : 2.6) * k),
                  blur: (pressed ? 2.0 : 7.0) * k, color: UIColor.black.withAlphaComponent(pressed ? 0.50 : 0.42).cgColor)
    ctx.addPath(p.cgPath)
    ctx.setFillColor(base.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0.3 * k, height: 0.7 * k), blur: 1.2 * k, color: UIColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(p.cgPath)
    ctx.setFillColor(base.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(p.cgPath)
    ctx.clip()
    let lit = base.adjusted(brightness: pressed ? 1.0 : 1.10)
    let mid = base.adjusted(brightness: pressed ? 0.92 : 1.0)
    let shade = base.adjusted(brightness: pressed ? 0.74 : 0.82)
    linearGradient(ctx, [lit, mid, shade], [0, 0.45, 1], from: CGPoint(x: b.minX, y: b.minY), to: CGPoint(x: b.maxX, y: b.maxY))
    radialGradient(ctx, [UIColor.white.withAlphaComponent(0.05), .clear], center: CGPoint(x: b.minX + b.width * 0.35, y: b.minY + b.height * 0.3),
                   radius: max(b.width, b.height) * 0.75)
    grain(ctx, in: b, alpha: 0.055)
    details(b)
    let bw = max(1.0, min(b.width, b.height) * 0.07)
    ctx.addPath(p.cgPath)
    ctx.setLineWidth(bw * 2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linearGradient(ctx, [UIColor.white.withAlphaComponent(pressed ? 0.10 : 0.20), .clear, UIColor.black.withAlphaComponent(pressed ? 0.30 : 0.24)], [0, 0.5, 1],
                   from: CGPoint(x: b.minX, y: b.minY), to: CGPoint(x: b.maxX, y: b.maxY))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(p.cgPath)
    ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.28).cgColor)
    ctx.setLineWidth(0.6)
    ctx.strokePath()
    ctx.restoreGState()
  }

  /// Label pressed into the plastic: dark glyph, faint highlight on its lower-right lip.
  private func deboss(_ text: String, in r: CGRect, size: CGFloat, on base: UIColor, ctx: CGContext) {
    let ui = UIFont.systemFont(ofSize: max(size, 7), weight: .semibold)
    let font = ui.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: ui.pointSize) } ?? ui
    func attributed(_ c: UIColor) -> NSAttributedString { NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: c]) }
    let sz = attributed(.black).size()
    let o = CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2)
    let px = max(0.5, size * 0.035)
    attributed(UIColor.white.withAlphaComponent(0.30)).draw(at: CGPoint(x: o.x + px, y: o.y + px * 1.4))
    attributed(labelColor(on: base)).draw(at: o)
    attributed(UIColor.black.withAlphaComponent(0.18)).draw(at: CGPoint(x: o.x - px * 0.5, y: o.y - px * 0.6))
  }

  private func debossSymbol(_ name: String, in r: CGRect, size: CGFloat, on base: UIColor, ctx: CGContext) {
    let cfg = UIImage.SymbolConfiguration(pointSize: max(size, 7), weight: .bold)
    guard let sym = UIImage(systemName: name, withConfiguration: cfg) else { return }
    let o = CGPoint(x: r.midX - sym.size.width / 2, y: r.midY - sym.size.height / 2)
    let px = max(0.5, size * 0.035)
    sym.withTintColor(UIColor.white.withAlphaComponent(0.30), renderingMode: .alwaysOriginal).draw(at: CGPoint(x: o.x + px, y: o.y + px * 1.4))
    sym.withTintColor(labelColor(on: base), renderingMode: .alwaysOriginal).draw(at: o)
  }

  /// Dark label on light plastic, light label on dark plastic.
  private func labelColor(on base: UIColor) -> UIColor {
    var w: CGFloat = 0
    base.getWhite(&w, alpha: nil)
    return w > 0.6 ? base.adjusted(brightness: 0.42, saturation: 1.6).withAlphaComponent(0.92)
                   : UIColor.white.withAlphaComponent(0.88)
  }

  private func dpadDetails(in r: CGRect, base: UIColor, ctx: CGContext) {
    let d = r.width * 0.2
    let c = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
    ctx.saveGState()
    ctx.addEllipse(in: c)
    ctx.clip()
    linearGradient(ctx, [base.adjusted(brightness: 0.72), base.adjusted(brightness: 1.06)], [0, 1], from: CGPoint(x: c.minX, y: c.minY), to: CGPoint(x: c.maxX, y: c.maxY))
    ctx.restoreGState()
    let t = r.width * 0.055
    for (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)] {
      let cx = r.midX + dx * r.width * 0.36, cy = r.midY + dy * r.height * 0.36
      let p = UIBezierPath()
      p.move(to: CGPoint(x: cx + dx * t, y: cy + dy * t))
      p.addLine(to: CGPoint(x: cx - dy * t - dx * t * 0.4, y: cy - dx * t - dy * t * 0.4))
      p.addLine(to: CGPoint(x: cx + dy * t - dx * t * 0.4, y: cy + dx * t - dy * t * 0.4))
      p.close()
      ctx.saveGState()
      ctx.translateBy(x: 0.6, y: 0.8)
      ctx.addPath(p.cgPath)
      ctx.setFillColor(UIColor.white.withAlphaComponent(0.16).cgColor)
      ctx.fillPath()
      ctx.restoreGState()
      ctx.addPath(p.cgPath)
      ctx.setFillColor(base.adjusted(brightness: 0.5).withAlphaComponent(0.85).cgColor)
      ctx.fillPath()
    }
  }

  // MARK: Primitives

  private func linearGradient(_ ctx: CGContext, _ colors: [UIColor], _ locs: [CGFloat], from: CGPoint, to: CGPoint) {
    guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: locs) else { return }
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  }

  private func radialGradient(_ ctx: CGContext, _ colors: [UIColor], center: CGPoint, radius: CGFloat) {
    guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
  }

  private func innerShadow(_ path: UIBezierPath, offset: CGSize, blur: CGFloat, alpha: CGFloat, ctx: CGContext) {
    ctx.saveGState()
    let outer = UIBezierPath(rect: path.bounds.insetBy(dx: -blur * 4 - 20, dy: -blur * 4 - 20))
    outer.append(path)
    outer.usesEvenOddFillRule = true
    ctx.setShadow(offset: offset, blur: blur, color: UIColor.black.withAlphaComponent(alpha).cgColor)
    ctx.addPath(outer.cgPath)
    ctx.setFillColor(UIColor.black.cgColor)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
  }

  private func grain(_ ctx: CGContext, in r: CGRect, alpha: CGFloat) {
    guard let tile = Self.grainTile else { return }
    ctx.saveGState()
    ctx.setAlpha(alpha / 0.06)
    ctx.clip(to: r)
    let ts = CGFloat(tile.width) / 3
    var y = (r.minY / ts).rounded(.down) * ts
    while y < r.maxY {
      var x = (r.minX / ts).rounded(.down) * ts
      while x < r.maxX { ctx.draw(tile, in: CGRect(x: x, y: y, width: ts, height: ts)); x += ts }
      y += ts
    }
    ctx.restoreGState()
  }

  /// 128x128 tile of luminance noise at about 6% alpha (deterministic, so every render looks the same).
  private static let grainTile: CGImage? = {
    let w = 128, h = 128
    var px = [UInt8](repeating: 0, count: w * h * 4)
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    for i in 0..<(w * h) {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      let v = UInt8(truncatingIfNeeded: seed >> 56)
      let alpha = 15 * abs(Int(v) - 128) / 128
      let premul = UInt8(v > 127 ? alpha : 0)
      px[i * 4] = premul; px[i * 4 + 1] = premul; px[i * 4 + 2] = premul
      px[i * 4 + 3] = UInt8(alpha)
    }
    guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }()
}

fileprivate extension UIColor {
  func adjusted(brightness f: CGFloat, saturation sf: CGFloat = 1) -> UIColor {
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
    return UIColor(hue: h, saturation: min(max(s * sf, 0), 1), brightness: min(max(b * f, 0), 1), alpha: a)
  }
}
#endif
