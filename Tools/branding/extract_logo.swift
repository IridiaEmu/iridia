// SPDX-License-Identifier: GPL-2.0-or-later
//
// Cut the Iridia logo out of its flat dark background into transparent PNGs.
//   swift Tools/branding/extract_logo.swift <logo.jpg> <outdir>
// Writes IridiaMark.png (the cube, square) and IridiaWordmark.png (cube + "Iridia").
// Alpha comes from each pixel's distance to the background colour; colour is then "un-blended"
// from the background, so soft glows and glass edges composite correctly on any backdrop.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3,
      let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
  fputs("usage: extract_logo.swift <logo.jpg> <outdir>\n", stderr); exit(1)
}
let w = image.width, h = image.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

// The background is a soft vignette, so estimate it per pixel from a heavily blurred copy of the
// image's border (a 4-corner bilinear blend of local averages is enough for this gradient).
func avg(_ x0: Int, _ y0: Int, _ s: Int) -> (Double, Double, Double) {
  var r = 0.0, g = 0.0, b = 0.0, n = 0.0
  for y in y0 ..< min(h, y0 + s) { for x in x0 ..< min(w, x0 + s) {
    let i = (y * w + x) * 4; r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2]); n += 1 } }
  return (r / n, g / n, b / n)
}
let s = 120
let c00 = avg(0, 0, s), c10 = avg(w - s, 0, s), c01 = avg(0, h - s, s), c11 = avg(w - s, h - s, s)
func bg(_ x: Int, _ y: Int) -> (Double, Double, Double) {
  let u = Double(x) / Double(w - 1), v = Double(y) / Double(h - 1)
  func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
  return (lerp(lerp(c00.0, c10.0, u), lerp(c01.0, c11.0, u), v),
          lerp(lerp(c00.1, c10.1, u), lerp(c01.1, c11.1, u), v),
          lerp(lerp(c00.2, c10.2, u), lerp(c01.2, c11.2, u), v))
}

// Distance at which a pixel counts as fully opaque. Below `t0` it's background (noise/vignette).
let t0 = 24.0, t1 = 130.0
var out = [UInt8](repeating: 0, count: w * h * 4)
for y in 0 ..< h { for x in 0 ..< w {
  let i = (y * w + x) * 4
  let (br, bgc, bb) = bg(x, y)
  let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
  let d = max(abs(r - br), abs(g - bgc), abs(b - bb))
  let a = min(1, max(0, (d - t0) / (t1 - t0)))
  guard a > 0 else { continue }
  // Un-blend: observed = a*fg + (1-a)*bg  ->  fg = (observed - (1-a)*bg) / a ; store premultiplied.
  func fg(_ o: Double, _ k: Double) -> UInt8 { UInt8(min(255, max(0, (o - (1 - a) * k) / a)) * a) }
  out[i] = fg(r, br); out[i + 1] = fg(g, bgc); out[i + 2] = fg(b, bb); out[i + 3] = UInt8(a * 255)
} }

func write(_ name: String, _ rect: CGRect, size: Int? = nil) {
  let full = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
  var img = full.cropping(to: rect)!
  if let size {
    let c = CGContext(data: nil, width: size, height: Int(Double(size) * rect.height / rect.width), bitsPerComponent: 8,
                      bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(img, in: CGRect(x: 0, y: 0, width: c.width, height: c.height))
    img = c.makeImage()!
  }
  let url = URL(fileURLWithPath: args[2]).appendingPathComponent(name)
  let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dst, img, nil)
  CGImageDestinationFinalize(dst)
  print("wrote \(url.path) \(img.width)x\(img.height)")
}

// Crops in source pixels (2752x1536 original). CGImage cropping uses a top-left origin.
write("IridiaMark.png", CGRect(x: 383, y: 380, width: 820, height: 820), size: 512)
write("IridiaWordmark.png", CGRect(x: 383, y: 380, width: 2080, height: 820), size: 1600)
