// Builds the icon-option mockups from the current app icon (IridiaIcon.png). Run from the repo root:
//   swift icon-options/make_icons.swift
// The glass cube is lifted off its background (light above the background, plus the darker parts), then
// recomposed: tinted copies, new positions, new backgrounds. Same art and style as the current icon.
import AppKit
import CoreGraphics
import CoreText
import Foundation

let N = 1024
let src = "Source/iOS/App/DolphiniOS/Assets.xcassets/AppIcon.appiconset/IridiaIcon.png"
let outDir = "icon-options"

struct Img {
  var w: Int, h: Int
  var p: [Float]   // RGB, 0..1
  init(w: Int, h: Int) { self.w = w; self.h = h; p = [Float](repeating: 0, count: w * h * 3) }
  subscript(x: Int, y: Int, c: Int) -> Float {
    get { p[(y * w + x) * 3 + c] }
    set { p[(y * w + x) * 3 + c] = newValue }
  }
}

func load(_ path: String) -> Img {
  let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: path)))!
  let cg = rep.cgImage!
  var img = Img(w: cg.width, h: cg.height)
  var raw = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
  let ctx = CGContext(data: &raw, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
  for i in 0..<(cg.width * cg.height) { for c in 0..<3 { img.p[i * 3 + c] = Float(raw[i * 4 + c]) / 255 } }
  return img
}

func cgImage(_ img: Img) -> CGImage {
  var raw = [UInt8](repeating: 255, count: img.w * img.h * 4)
  for i in 0..<(img.w * img.h) { for c in 0..<3 { raw[i * 4 + c] = UInt8(max(0, min(1, img.p[i * 3 + c])) * 255 + 0.5) } }
  let provider = CGDataProvider(data: Data(raw) as CFData)!
  return CGImage(width: img.w, height: img.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.w * 4,
                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

// MARK: Background model: quadratic in x, y per channel, fitted outside the cube's box.

let icon = load(src)
let box = (x0: 120, y0: 180, x1: 900, y1: 1000)   // cube plus its floor glow
func features(_ x: Int, _ y: Int) -> [Double] {
  let u = Double(x) / Double(N) - 0.5, v = Double(y) / Double(N) - 0.5
  return [1, u, v, u * u, v * v, u * v, u * u * v, u * v * v, u * u * u * u + v * v * v * v]
}
var coef = [[Double]](repeating: [], count: 3)
do {
  let k = 9
  for c in 0..<3 {
    var a = [Double](repeating: 0, count: k * k), b = [Double](repeating: 0, count: k)
    for y in stride(from: 0, to: N, by: 4) { for x in stride(from: 0, to: N, by: 4) {
      if x >= box.x0 && x < box.x1 && y >= box.y0 && y < box.y1 { continue }
      let f = features(x, y), t = Double(icon[x, y, c])
      for i in 0..<k { b[i] += f[i] * t; for j in 0..<k { a[i * k + j] += f[i] * f[j] } }
    } }
    // Gaussian elimination
    for i in 0..<k {
      let piv = a[i * k + i]
      for j in 0..<k { a[i * k + j] /= piv }; b[i] /= piv
      for r in 0..<k where r != i {
        let m = a[r * k + i]
        for j in 0..<k { a[r * k + j] -= m * a[i * k + j] }; b[r] -= m * b[i]
      }
    }
    coef[c] = b
  }
}
func bgAt(_ x: Int, _ y: Int, _ c: Int) -> Float {
  let f = features(x, y); var s = 0.0; for i in 0..<f.count { s += f[i] * coef[c][i] }; return Float(s)
}

// The cube as light added to (lift) and taken from (shade) the background, with a soft box edge.
var lift = Img(w: N, h: N), shade = Img(w: N, h: N)
for y in 0..<N { for x in 0..<N {
  let ex = min(Float(x - box.x0), Float(box.x1 - x)), ey = min(Float(y - box.y0), Float(box.y1 - y))
  let edge = max(0, min(1, min(ex, ey) / 140))
  for c in 0..<3 {
    let d = icon[x, y, c] - bgAt(x, y, c)
    lift[x, y, c] = max(0, d) * edge
    shade[x, y, c] = max(0, -d) * edge
  }
} }

func sample(_ img: Img, _ fx: Float, _ fy: Float, _ c: Int) -> Float {
  guard fx >= 0, fy >= 0, fx < Float(img.w - 1), fy < Float(img.h - 1) else { return 0 }
  let x0 = Int(fx), y0 = Int(fy), tx = fx - Float(x0), ty = fy - Float(y0)
  let a = img[x0, y0, c] * (1 - tx) + img[x0 + 1, y0, c] * tx
  let b = img[x0, y0 + 1, c] * (1 - tx) + img[x0 + 1, y0 + 1, c] * tx
  return a * (1 - ty) + b * ty
}

typealias Tint = [[Float]]   // 3x3 colour matrix
let keep: Tint = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
/// Purple glass to sky-blue glass.
let blue: Tint = [[0.35, 0.05, 0.0], [0.25, 0.80, 0.25], [0.0, 0.25, 1.05]]
/// Purple glass to teal glass.
let teal: Tint = [[0.25, 0.0, 0.0], [0.20, 0.85, 0.35], [0.0, 0.40, 0.75]]

/// Adds the cube at centre (cx, cy) in output pixels, `scale` of its size, tinted, at `strength`.
func place(_ out: inout Img, cx: Float, cy: Float, scale: Float, tint: Tint, strength: Float = 1, shadeStrength: Float = 1) {
  let ccx: Float = 505, ccy: Float = 560   // the cube's centre in the source
  for y in 0..<out.h { for x in 0..<out.w {
    let sx = (Float(x) - cx) / scale + ccx, sy = (Float(y) - cy) / scale + ccy
    guard sx >= Float(box.x0), sx < Float(box.x1), sy >= Float(box.y0), sy < Float(box.y1) else { continue }
    let l = (0..<3).map { sample(lift, sx, sy, $0) }, s = (0..<3).map { sample(shade, sx, sy, $0) }
    for c in 0..<3 {
      let lt = tint[c][0] * l[0] + tint[c][1] * l[1] + tint[c][2] * l[2]
      out[x, y, c] = out[x, y, c] + lt * strength - s[c] * shadeStrength
    }
  } }
}

/// The current icon's background, optionally recoloured.
func background(tint: Tint = keep, lighten: Float = 0) -> Img {
  var out = Img(w: N, h: N)
  for y in 0..<N { for x in 0..<N {
    let v = (0..<3).map { bgAt(x, y, $0) }
    for c in 0..<3 { out[x, y, c] = (tint[c][0] * v[0] + tint[c][1] * v[1] + tint[c][2] * v[2]) * (1 + lighten) }
  } }
  return out
}

/// A diagonal split background: the indigo stage on the left, a deep blue stage on the right.
func splitBackground() -> Img {
  let left = background(), right = background(tint: blue, lighten: 0.35)
  var out = Img(w: N, h: N)
  for y in 0..<N { for x in 0..<N {
    // soft diagonal from top right to bottom left
    let d = (Float(x) + Float(y) * 0.55 - 760) / 90
    let t = 1 / (1 + exp(-d))
    for c in 0..<3 { out[x, y, c] = left[x, y, c] * (1 - t) + right[x, y, c] * t }
  } }
  return out
}

// MARK: The three options

var options: [(file: String, title: String, idea: String, img: Img)] = []

do {  // A: two cubes, the purple one in front, a blue one behind and to the right
  var img = background()
  place(&img, cx: 640, cy: 470, scale: 0.62, tint: blue, strength: 0.95, shadeStrength: 0.6)
  place(&img, cx: 430, cy: 600, scale: 0.78, tint: keep)
  options.append(("option-a-pair.png", "A. Pair", "Two glass cubes, the purple one in front and a blue one behind it: one app, more than one console.", img))
}
do {  // B: the cube on a stage that is half indigo, half blue
  var img = splitBackground()
  place(&img, cx: 512, cy: 520, scale: 0.86, tint: keep)
  options.append(("option-b-two-lights.png", "B. Two lights", "The same cube on a stage lit half indigo and half blue: the app's two sides in one picture.", img))
}
do {  // C: a row of three cubes like the library shelf, the centre one large
  var img = background()
  place(&img, cx: 190, cy: 560, scale: 0.40, tint: teal, strength: 0.85, shadeStrength: 0.5)
  place(&img, cx: 834, cy: 560, scale: 0.40, tint: blue, strength: 0.85, shadeStrength: 0.5)
  place(&img, cx: 512, cy: 545, scale: 0.66, tint: keep)
  options.append(("option-c-shelf.png", "C. Shelf", "Three cubes in a row like the library shelf, the centre one large and lit: a collection, not one system.", img))
}

// MARK: Mockups: each option next to the current icon, large and at home-screen size

func roundedIcon(_ ctx: CGContext, _ image: CGImage, _ rect: CGRect) {
  ctx.saveGState()
  let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.2237, cornerHeight: rect.width * 0.2237, transform: nil)
  ctx.addPath(path); ctx.clip()
  ctx.draw(image, in: rect)
  ctx.restoreGState()
}

func text(_ ctx: CGContext, _ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, width: CGFloat) {
  let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
  let frameSetter = CTFramesetterCreateWithAttributedString(attr)
  let path = CGPath(rect: CGRect(x: x, y: y - 400, width: width, height: 400), transform: nil)
  let frame = CTFramesetterCreateFrame(frameSetter, CFRange(location: 0, length: 0), path, nil)
  CTFrameDraw(frame, ctx)
}

let current = cgImage(icon)
for o in options {
  let W = 2000, H = 1240
  let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setFillColor(NSColor(calibratedWhite: 0.93, alpha: 1).cgColor)
  ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
  let opt = cgImage(o.img)
  // large icons (CG origin is bottom left)
  roundedIcon(ctx, current, CGRect(x: 120, y: 300, width: 760, height: 760))
  roundedIcon(ctx, opt, CGRect(x: 1120, y: 300, width: 760, height: 760))
  // home-screen size (60 pt at 2x = 120 px)
  roundedIcon(ctx, current, CGRect(x: 120, y: 120, width: 120, height: 120))
  roundedIcon(ctx, opt, CGRect(x: 1120, y: 120, width: 120, height: 120))
  let ink = NSColor(calibratedWhite: 0.12, alpha: 1), soft = NSColor(calibratedWhite: 0.38, alpha: 1)
  text(ctx, "Current icon (unchanged)", 120, 1170, size: 44, weight: .semibold, color: ink, width: 800)
  text(ctx, "Option \(o.title)", 1120, 1170, size: 44, weight: .semibold, color: ink, width: 800)
  text(ctx, "Home screen size", 270, 225, size: 30, weight: .regular, color: soft, width: 600)
  text(ctx, o.idea, 1270, 245, size: 28, weight: .regular, color: soft, width: 620)
  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(o.file)"))
  // the bare 1024 icon too, for a closer look
  let bare = NSBitmapImageRep(cgImage: opt)
  try! bare.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(o.file.replacingOccurrences(of: ".png", with: "-1024.png"))"))
  print("wrote \(o.file)")
}
