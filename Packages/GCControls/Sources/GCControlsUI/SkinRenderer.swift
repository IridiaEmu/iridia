// SPDX-License-Identifier: GPL-2.0-or-later
//
// Draws the skin from our own primitives in a matte-plastic style:
//   one light source (top-left), diffuse shading, bevelled edges, fine grain,
//   ambient-occlusion shadows, recessed wells in the shell, debossed labels.
// Everything is rendered once per (item, size, scale) into static images; the
// shell is one image for the whole controller. Gameplay only swaps layer contents.

#if canImport(UIKit)
import GCControlsCore
import UIKit

extension UIColor {
  /// "#RRGGBB" or "#RRGGBBAA".
  convenience init(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    let hasAlpha = s.count == 8
    let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
    let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
    let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
    let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
    self.init(red: r, green: g, blue: b, alpha: a)
  }

  func adjusted(brightness f: CGFloat, saturation sf: CGFloat = 1) -> UIColor {
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
    return UIColor(hue: h, saturation: min(max(s * sf, 0), 1), brightness: min(max(b * f, 0), 1), alpha: a)
  }
}

@MainActor
final class SkinRenderer {
  struct Key: Hashable {
    let skin: String, item: String, w: Int, h: Int, scale: Int, variant: Int
  }
  enum Variant: Int { case normal, pressed, knob, knobPressed }

  private var cache: [Key: UIImage] = [:]
  private let skin: ControllerSkin

  /// Light comes from the top-left everywhere.
  private static let lightDir = CGVector(dx: -0.55, dy: -0.85)

  init(skin: ControllerSkin) { self.skin = skin }

  /// Transparent margin around item images so AO shadows aren't clipped.
  /// Layers are framed at `rect.insetBy(-pad, -pad)`; touch areas use `rect`.
  static func padding(for size: CGSize) -> CGFloat {
    (min(size.width, size.height) * 0.16).rounded(.up) + 2
  }

  // MARK: Item images

  func image(for item: SkinItem, size: CGSize, scale: CGFloat, variant: Variant) -> UIImage {
    let key = Key(
      skin: skin.identifier, item: item.id, w: Int(size.width.rounded()), h: Int(size.height.rounded()),
      scale: Int(scale), variant: variant.rawValue)
    if let img = cache[key] { return img }
    let pad = Self.padding(for: size)
    let full = CGSize(width: size.width + pad * 2, height: size.height + pad * 2)

    // Custom skins may supply their own images (drawn into the padded canvas).
    if let name = (variant == .pressed ? (item.pressedImage ?? item.image) : item.image),
      let data = skin.images?[name], let src = UIImage(data: data, scale: scale)
    {
      let img = render(full, scale) { _ in src.draw(in: CGRect(x: pad, y: pad, width: size.width, height: size.height)) }
      cache[key] = img
      return img
    }

    let img = render(full, scale) { ctx in
      self.draw(item, in: CGRect(x: pad, y: pad, width: size.width, height: size.height), variant: variant, ctx: ctx)
    }
    cache[key] = img
    return img
  }

  private func render(_ size: CGSize, _ scale: CGFloat, _ body: (CGContext) -> Void) -> UIImage {
    let fmt = UIGraphicsImageRendererFormat.preferred()
    fmt.scale = scale
    fmt.opaque = false
    return UIGraphicsImageRenderer(size: size, format: fmt).image { body($0.cgContext) }
  }

  private func color(_ role: String?) -> UIColor { UIColor(hex: skin.palette.resolve(role)) }

  private func draw(_ item: SkinItem, in r: CGRect, variant: Variant, ctx: CGContext) {
    let base = color(item.color)
    let pressed = variant == .pressed || variant == .knobPressed
    switch item.shape {
    case .circle:
      let p = shapePath(.circle, in: r.insetBy(dx: 1, dy: 1))
      part(p, base: base, pressed: pressed, ctx: ctx) { b in
        self.deboss(item.label, in: b, size: b.height * 0.40, on: base, ctx: ctx)
      }
    case .pill:
      let p = shapePath(.pill, in: r.insetBy(dx: 1, dy: 1))
      let small = (item.label?.count ?? 1) > 2
      part(p, base: base, pressed: pressed, ctx: ctx) { b in
        self.deboss(item.label, in: b, size: min(b.height, b.width) * (small ? 0.34 : 0.46), on: base, ctx: ctx, tracking: small ? 0.8 : 0)
      }
    case .roundedRect:
      let p = shapePath(.roundedRect, in: r.insetBy(dx: 1, dy: 1))
      part(p, base: base, pressed: pressed, ctx: ctx) { b in
        // A faint ridge line suggests the trigger's curved face.
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.10).cgColor)
        ctx.setLineWidth(max(0.75, b.height * 0.02))
        ctx.move(to: CGPoint(x: b.minX + b.width * 0.12, y: b.minY + b.height * 0.30))
        ctx.addLine(to: CGPoint(x: b.maxX - b.width * 0.12, y: b.minY + b.height * 0.30))
        ctx.strokePath()
        self.deboss(item.label, in: b.offsetBy(dx: 0, dy: b.height * 0.06), size: b.height * 0.42, on: base, ctx: ctx)
      }
    case .dpad:
      let p = shapePath(.dpad, in: r.insetBy(dx: 2, dy: 2))
      part(p, base: base, pressed: false, ctx: ctx) { b in self.dpadDetails(in: b, base: base, ctx: ctx) }
    case .stick:
      if variant == .knob || variant == .knobPressed {
        stickCap(in: r.insetBy(dx: 2, dy: 2), base: base, pressed: pressed, label: item.label, ctx: ctx)
      } else {
        stickHousing(in: r, ring: base, ctx: ctx)
      }
    case .logo:
      logo(in: r, tint: base, ctx: ctx)
    }
  }

  // MARK: Shapes

  func shapePath(_ shape: SkinShape, in r: CGRect) -> UIBezierPath {
    switch shape {
    case .circle, .stick, .logo: UIBezierPath(ovalIn: r)
    case .pill: UIBezierPath(roundedRect: r, cornerRadius: min(r.width, r.height) / 2)
    case .roundedRect: UIBezierPath(roundedRect: r, cornerRadius: r.height * 0.42)
    case .dpad: dpadPath(in: r)
    }
  }

  /// One continuous cross outline (12 corners) so fill, shading and bevel have no seams.
  private func dpadPath(in r: CGRect) -> UIBezierPath {
    let a = r.width * 0.34 / 2
    let cx = r.midX, cy = r.midY
    let pts: [CGPoint] = [
      CGPoint(x: cx - a, y: r.minY), CGPoint(x: cx + a, y: r.minY),
      CGPoint(x: cx + a, y: cy - a), CGPoint(x: r.maxX, y: cy - a),
      CGPoint(x: r.maxX, y: cy + a), CGPoint(x: cx + a, y: cy + a),
      CGPoint(x: cx + a, y: r.maxY), CGPoint(x: cx - a, y: r.maxY),
      CGPoint(x: cx - a, y: cy + a), CGPoint(x: r.minX, y: cy + a),
      CGPoint(x: r.minX, y: cy - a), CGPoint(x: cx - a, y: cy - a),
    ]
    let outer = a * 0.55, inner = a * 0.25
    let p = CGMutablePath()
    let n = pts.count
    p.move(to: CGPoint(x: (pts[0].x + pts[1].x) / 2, y: pts[0].y))
    for i in 1...n {
      let corner = pts[i % n], next = pts[(i + 1) % n]
      let isInner = (i % n) % 3 == 2  // indices 2, 5, 8, 11 are the inner corners
      p.addArc(tangent1End: corner, tangent2End: next, radius: isInner ? inner : outer)
    }
    p.closeSubpath()
    return UIBezierPath(cgPath: p)
  }

  // MARK: Material

  /// A matte plastic part: AO shadow onto the shell, diffuse body shading lit from
  /// the top-left, fine grain, and a bevelled edge. Pressed parts sink: they move
  /// down slightly, shrink a hair, darken, and their shadow tightens.
  private func part(_ path: UIBezierPath, base: UIColor, pressed: Bool, ctx: CGContext, details: (CGRect) -> Void) {
    var p = path
    let b0 = path.bounds
    let k = min(b0.width, b0.height) / 50  // scale unit relative to a 50pt part
    if pressed {
      let s: CGFloat = 0.965
      var t = CGAffineTransform(translationX: b0.midX, y: b0.midY + 1.2 * k)
        .scaledBy(x: s, y: s).translatedBy(x: -b0.midX, y: -b0.midY)
      if let moved = path.cgPath.copy(using: &t) { p = UIBezierPath(cgPath: moved) }
    }
    let b = p.bounds

    // Ambient occlusion: a wide soft contact shadow plus a tight core shadow.
    ctx.saveGState()
    ctx.setShadow(
      offset: CGSize(width: (pressed ? 0.4 : 1.4) * k, height: (pressed ? 0.8 : 2.6) * k),
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
    // Diffuse shading: lit top-left, falling off to the bottom-right. Pressed parts sit lower, so a touch darker.
    let lit = base.adjusted(brightness: pressed ? 1.0 : 1.10)
    let mid = base.adjusted(brightness: pressed ? 0.92 : 1.0)
    let shade = base.adjusted(brightness: pressed ? 0.74 : 0.82)
    linearGradient(ctx, [lit, mid, shade], [0, 0.45, 1], from: CGPoint(x: b.minX, y: b.minY), to: CGPoint(x: b.maxX, y: b.maxY))
    // Very soft broad falloff from the center keeps it from looking flat.
    radialGradient(ctx, [UIColor.white.withAlphaComponent(0.05), .clear], center: CGPoint(x: b.minX + b.width * 0.35, y: b.minY + b.height * 0.3), radius: max(b.width, b.height) * 0.75)
    grain(ctx, in: b, alpha: 0.055)
    details(b)

    // Bevel: inner edge band lit on the top-left, shaded on the bottom-right.
    let bw = max(1.0, min(b.width, b.height) * 0.07)
    ctx.addPath(p.cgPath)
    ctx.setLineWidth(bw * 2)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linearGradient(ctx, [UIColor.white.withAlphaComponent(pressed ? 0.10 : 0.20), .clear, UIColor.black.withAlphaComponent(pressed ? 0.30 : 0.24)], [0, 0.5, 1],
                   from: CGPoint(x: b.minX, y: b.minY), to: CGPoint(x: b.maxX, y: b.maxY))
    ctx.restoreGState()

    // Crisp parting line.
    ctx.saveGState()
    ctx.addPath(p.cgPath)
    ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.28).cgColor)
    ctx.setLineWidth(0.6)
    ctx.strokePath()
    ctx.restoreGState()
  }

  /// Label pressed into the plastic: a dark glyph with a faint highlight on its
  /// lower-right lip (where light from the top-left would catch the recess edge).
  private func deboss(_ text: String?, in r: CGRect, size: CGFloat, on base: UIColor, ctx: CGContext, tracking: CGFloat = 0) {
    guard let text, !text.isEmpty else { return }
    let ui = UIFont.systemFont(ofSize: max(size, 7), weight: .semibold)
    let font = ui.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: ui.pointSize) } ?? ui
    func attributed(_ c: UIColor) -> NSAttributedString {
      NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: c, .kern: tracking])
    }
    let sz = attributed(.black).size()
    let o = CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2)
    let px = max(0.5, size * 0.035)
    attributed(UIColor.white.withAlphaComponent(0.22)).draw(at: CGPoint(x: o.x + px, y: o.y + px * 1.4))
    attributed(base.adjusted(brightness: 0.42, saturation: 1.1).withAlphaComponent(0.92)).draw(at: o)
    // A hint of inner shadow along the glyph's top-left edge.
    attributed(UIColor.black.withAlphaComponent(0.18)).draw(at: CGPoint(x: o.x - px * 0.5, y: o.y - px * 0.6))
  }

  private func dpadDetails(in r: CGRect, base: UIColor, ctx: CGContext) {
    // Concave center dimple.
    let d = r.width * 0.2
    let c = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
    ctx.saveGState()
    ctx.addEllipse(in: c)
    ctx.clip()
    linearGradient(ctx, [base.adjusted(brightness: 0.72), base.adjusted(brightness: 1.06)], [0, 1], from: CGPoint(x: c.minX, y: c.minY), to: CGPoint(x: c.maxX, y: c.maxY))
    ctx.restoreGState()
    // Debossed direction arrows.
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

  /// Stick housing: the shell well is drawn by the shell image; here, the inner
  /// bowl and a subtle gate ring. Static, never redrawn during play.
  private func stickHousing(in r: CGRect, ring: UIColor, ctx: CGContext) {
    let well = r.insetBy(dx: r.width * 0.02, dy: r.height * 0.02)
    ctx.saveGState()
    ctx.addEllipse(in: well)
    ctx.clip()
    let dark = UIColor(hex: skin.palette.stickBase)
    // Concave bowl: shadowed on the top-left inner wall, catching light bottom-right.
    linearGradient(ctx, [dark.adjusted(brightness: 0.55), dark, dark.adjusted(brightness: 1.35)], [0, 0.55, 1],
                   from: CGPoint(x: well.minX, y: well.minY), to: CGPoint(x: well.maxX, y: well.maxY))
    grain(ctx, in: well, alpha: 0.05)
    innerShadow(UIBezierPath(ovalIn: well), offset: CGSize(width: 1.6, height: 2.6), blur: well.width * 0.08, alpha: 0.65, ctx: ctx)
    ctx.restoreGState()
    // Gate ring, muted and slightly recessed.
    let g = well.insetBy(dx: r.width * 0.07, dy: r.height * 0.07)
    ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.30).cgColor)
    ctx.setLineWidth(max(1, r.width * 0.018))
    ctx.strokeEllipse(in: g.offsetBy(dx: -0.4, dy: -0.6))
    ctx.setStrokeColor(ring.adjusted(brightness: 0.85, saturation: 0.8).withAlphaComponent(0.35).cgColor)
    ctx.strokeEllipse(in: g.offsetBy(dx: 0.4, dy: 0.6))
  }

  /// Stick cap: matte disc with a concave dish and fine knurled grip around the rim.
  private func stickCap(in r: CGRect, base: UIColor, pressed: Bool, label: String?, ctx: CGContext) {
    part(UIBezierPath(ovalIn: r), base: base, pressed: pressed, ctx: ctx) { b in
      // Knurled rim: fine radial ridges.
      let center = CGPoint(x: b.midX, y: b.midY)
      let ro = b.width / 2 * 0.94, ri = b.width / 2 * 0.80
      let n = 40
      ctx.setLineWidth(max(0.5, b.width * 0.008))
      for i in 0..<n {
        let a = CGFloat(i) / CGFloat(n) * .pi * 2
        let p0 = CGPoint(x: center.x + cos(a) * ri, y: center.y + sin(a) * ri)
        let p1 = CGPoint(x: center.x + cos(a) * ro, y: center.y + sin(a) * ro)
        // Ridges facing the light are lighter.
        let facing = -(cos(a) * Self.lightDir.dx + sin(a) * Self.lightDir.dy)
        ctx.setStrokeColor((facing > 0 ? UIColor.white.withAlphaComponent(0.07 + 0.08 * facing) : UIColor.black.withAlphaComponent(0.10 - 0.08 * facing)).cgColor)
        ctx.move(to: p0)
        ctx.addLine(to: p1)
        ctx.strokePath()
      }
      // Concave dish: dark top-left inner wall, lit bottom-right.
      let dish = b.insetBy(dx: b.width * 0.21, dy: b.height * 0.21)
      ctx.saveGState()
      ctx.addEllipse(in: dish)
      ctx.clip()
      self.linearGradient(ctx, [base.adjusted(brightness: 0.74), base.adjusted(brightness: 0.95), base.adjusted(brightness: 1.12)], [0, 0.5, 1],
                          from: CGPoint(x: dish.minX, y: dish.minY), to: CGPoint(x: dish.maxX, y: dish.maxY))
      self.grain(ctx, in: dish, alpha: 0.07)
      self.innerShadow(UIBezierPath(ovalIn: dish), offset: CGSize(width: 0.8, height: 1.4), blur: dish.width * 0.08, alpha: 0.30, ctx: ctx)
      ctx.restoreGState()
      // Dish rim highlight on the lower-right lip.
      ctx.saveGState()
      ctx.addEllipse(in: dish)
      ctx.setLineWidth(max(0.75, b.width * 0.012))
      ctx.replacePathWithStrokedPath()
      ctx.clip()
      self.linearGradient(ctx, [UIColor.black.withAlphaComponent(0.18), .clear, UIColor.white.withAlphaComponent(0.18)], [0, 0.5, 1],
                          from: CGPoint(x: dish.minX, y: dish.minY), to: CGPoint(x: dish.maxX, y: dish.maxY))
      ctx.restoreGState()
      self.deboss(label, in: dish, size: dish.height * 0.5, on: base, ctx: ctx)
    }
  }

  /// Highlight for one pressed D-pad arm (0=up,1=down,2=left,3=right): the arm
  /// looks pushed into the shell (darker, with an inner shadow on its lit edge).
  /// Image is the item's unpadded size; the view positions it inside the padding.
  func dpadArmHighlight(size: CGSize, scale: CGFloat, direction: Int) -> UIImage {
    let key = Key(skin: skin.identifier, item: "dpad.arm.\(direction)", w: Int(size.width), h: Int(size.height), scale: Int(scale), variant: 9)
    if let img = cache[key] { return img }
    let img = render(size, scale) { ctx in
      let rr = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
      let a = rr.width * 0.34
      let len = rr.width / 2
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
    cache[key] = img
    return img
  }

  /// Placeholder app mark (original): a matte disc with a debossed four-point sparkle.
  private func logo(in r: CGRect, tint: UIColor, ctx: CGContext) {
    let d = min(r.width, r.height) * 0.84
    let disc = CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)
    let base = tint.adjusted(brightness: 0.78, saturation: 0.8)
    part(UIBezierPath(ovalIn: disc), base: base, pressed: false, ctx: ctx) { b in
      let s = b.width * 0.30
      let c = CGPoint(x: b.midX, y: b.midY)
      let p = UIBezierPath()
      p.move(to: CGPoint(x: c.x, y: c.y - s))
      p.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), controlPoint: c)
      p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), controlPoint: c)
      p.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), controlPoint: c)
      p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), controlPoint: c)
      ctx.saveGState()
      ctx.translateBy(x: 0.6, y: 0.9)
      ctx.addPath(p.cgPath)
      ctx.setFillColor(UIColor.white.withAlphaComponent(0.2).cgColor)
      ctx.fillPath()
      ctx.restoreGState()
      ctx.addPath(p.cgPath)
      ctx.setFillColor(base.adjusted(brightness: 0.5).cgColor)
      ctx.fillPath()
    }
  }

  // MARK: Shell (portrait background)

  /// The whole controller shell as one image: matte plastic with soft edge shading,
  /// fine grain, and a recessed well under every control. Rendered when the size
  /// or layout changes (never per frame).
  func shellImage(size: CGSize, scale: CGFloat, cornerRadius: CGFloat, items: [(SkinItem, CGRect)]) -> UIImage {
    render(size, scale) { ctx in
      let r = CGRect(origin: .zero, size: size)
      let shellPath = UIBezierPath(roundedRect: r, byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: cornerRadius, height: cornerRadius))
      ctx.addPath(shellPath.cgPath)
      ctx.clip()

      let pal = skin.palette
      let top = UIColor(hex: pal.backgroundTop), bottom = UIColor(hex: pal.backgroundBottom)
      linearGradient(ctx, [top, bottom], [0, 1], from: CGPoint(x: r.midX, y: r.minY), to: CGPoint(x: r.midX, y: r.maxY))
      // Directional light across the shell, then darkening toward the edges.
      linearGradient(ctx, [UIColor.white.withAlphaComponent(0.06), .clear, UIColor.black.withAlphaComponent(0.10)], [0, 0.5, 1],
                     from: CGPoint(x: r.minX, y: r.minY), to: CGPoint(x: r.maxX, y: r.maxY))
      radialGradient(ctx, [.clear, UIColor.black.withAlphaComponent(0.30)], center: CGPoint(x: r.midX * 0.9, y: r.midY * 0.85),
                     radius: hypot(r.width, r.height) * 0.62, startRadius: min(r.width, r.height) * 0.35)
      grain(ctx, in: r, alpha: 0.06)

      for (item, rect) in items where item.input != .logo {
        well(for: item, rect: rect, shell: top, ctx: ctx)
      }

      // Shell edge: a soft lit lip along the top and a thin parting line.
      ctx.saveGState()
      ctx.addPath(shellPath.cgPath)
      ctx.setLineWidth(3)
      ctx.replacePathWithStrokedPath()
      ctx.clip()
      linearGradient(ctx, [UIColor(hex: pal.glassHighlight).withAlphaComponent(0.16), .clear], [0, 1],
                     from: CGPoint(x: r.midX, y: r.minY), to: CGPoint(x: r.midX, y: r.minY + cornerRadius * 2))
      ctx.restoreGState()
    }
  }

  private func well(for item: SkinItem, rect: CGRect, shell: UIColor, ctx: CGContext) {
    let e = max(3, min(rect.width, rect.height) * 0.085)
    let path = shapePath(item.shape, in: rect.insetBy(dx: item.shape == .stick ? -e * 0.4 : -e, dy: item.shape == .stick ? -e * 0.4 : -e))
    ctx.saveGState()
    ctx.addPath(path.cgPath)
    ctx.clip()
    ctx.addPath(path.cgPath)
    ctx.setFillColor(UIColor.black.withAlphaComponent(0.20).cgColor)
    ctx.fillPath()
    innerShadow(path, offset: CGSize(width: 1.4, height: 2.2), blur: e * 1.1, alpha: 0.6, ctx: ctx)
    ctx.restoreGState()
    // Lower-right lip of the recess catches the light.
    ctx.saveGState()
    ctx.addPath(path.cgPath)
    ctx.setLineWidth(1.6)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let b = path.bounds
    linearGradient(ctx, [UIColor.black.withAlphaComponent(0.25), .clear, UIColor.white.withAlphaComponent(0.13)], [0, 0.55, 1],
                   from: CGPoint(x: b.minX, y: b.minY), to: CGPoint(x: b.maxX, y: b.maxY))
    ctx.restoreGState()
  }

  // MARK: Primitives

  private func linearGradient(_ ctx: CGContext, _ colors: [UIColor], _ locs: [CGFloat], from: CGPoint, to: CGPoint) {
    guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: locs) else { return }
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  }

  private func radialGradient(_ ctx: CGContext, _ colors: [UIColor], center: CGPoint, radius: CGFloat, startRadius: CGFloat = 0) {
    guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil) else { return }
    ctx.drawRadialGradient(g, startCenter: center, startRadius: startRadius, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
  }

  /// Inner shadow along `path` (caller has already clipped to it).
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

  /// Fine monochrome grain (deterministic, so every render looks identical).
  private func grain(_ ctx: CGContext, in r: CGRect, alpha: CGFloat) {
    guard let tile = Self.grainTile else { return }
    ctx.saveGState()
    ctx.setAlpha(alpha / 0.06)
    ctx.clip(to: r)
    let ts = CGFloat(tile.width) / Self.grainScale
    var y = (r.minY / ts).rounded(.down) * ts
    while y < r.maxY {
      var x = (r.minX / ts).rounded(.down) * ts
      while x < r.maxX {
        ctx.draw(tile, in: CGRect(x: x, y: y, width: ts, height: ts))
        x += ts
      }
      y += ts
    }
    ctx.restoreGState()
  }

  private static let grainScale: CGFloat = 3
  /// 128×128 tile of luminance noise at ~6% alpha, drawn at 1/3 pt per pixel.
  private static let grainTile: CGImage? = {
    let w = 128, h = 128
    var px = [UInt8](repeating: 0, count: w * h * 4)
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    for i in 0..<(w * h) {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      let v = UInt8(truncatingIfNeeded: seed >> 56)
      // Light or dark speck; strength from distance to mid-gray, max ≈6% alpha.
      let alpha = 15 * abs(Int(v) - 128) / 128
      let premul = UInt8(v > 127 ? alpha : 0)  // white specks premultiplied, black specks = 0
      px[i * 4] = premul; px[i * 4 + 1] = premul; px[i * 4 + 2] = premul
      px[i * 4 + 3] = UInt8(alpha)
    }
    guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }()
}
#endif
