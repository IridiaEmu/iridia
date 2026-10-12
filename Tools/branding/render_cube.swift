// SPDX-License-Identifier: GPL-2.0-or-later
//
// Iridia's glass cube, modelled and rendered from scratch (no downloaded or generated art).
//   swift Tools/branding/render_cube.swift <out.png> [size] [--bg | --icon]
// A chamfered cube with a clear physically-based glass material, an iridescent thin-film sheen
// at grazing angles, and a procedural studio environment (soft light strips) for reflections.
// Without --bg the PNG has a transparent background; with --bg it sits on the Iridia indigo;
// --icon makes the App Store icon: cube centred with margin on an indigo glow, no alpha channel.
// The same scene description is what the app's live 3D menu uses (SceneKit).

import AppKit
import Foundation
import Metal
import SceneKit

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage: render_cube.swift <out.png> [size] [--bg]\n", stderr); exit(1) }
let outPath = args[1]
let size = args.count >= 3 ? Int(args[2]) ?? 1024 : 1024
let asIcon = args.contains("--icon")
let withBackground = args.contains("--bg")

// MARK: Environment: a dark room with three soft light strips, drawn into an equirect image.
func studioEnvironment(width: Int = 2048, height: Int = 1024) -> NSImage {
  let img = NSImage(size: NSSize(width: width, height: height))
  img.lockFocus()
  let ctx = NSGraphicsContext.current!.cgContext
  // Deep violet room, a bit brighter toward the horizon.
  let room = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [CGColor(red: 0.03, green: 0.02, blue: 0.08, alpha: 1),
                                 CGColor(red: 0.16, green: 0.10, blue: 0.34, alpha: 1),
                                 CGColor(red: 0.04, green: 0.03, blue: 0.10, alpha: 1)] as CFArray,
                        locations: [0, 0.5, 1])!
  ctx.drawLinearGradient(room, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
  // Soft boxes: a big key strip top-left, a cool rim strip right, a warm low strip.
  func strip(_ rect: CGRect, _ color: CGColor) {
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: color)
    ctx.setFillColor(color)
    ctx.fill(rect)
    ctx.restoreGState()
  }
  strip(CGRect(x: 260, y: 640, width: 520, height: 150), CGColor(red: 1, green: 1, blue: 1, alpha: 1))
  strip(CGRect(x: 1380, y: 520, width: 120, height: 330), CGColor(red: 0.6, green: 0.85, blue: 1, alpha: 1))
  strip(CGRect(x: 900, y: 430, width: 360, height: 60), CGColor(red: 1, green: 0.75, blue: 0.95, alpha: 1))
  img.unlockFocus()
  return img
}

// MARK: Scene
let scene = SCNScene()
scene.lightingEnvironment.contents = studioEnvironment()
scene.lightingEnvironment.intensity = 3.0
// Always render on clear: SceneKit's snapshot replaces the framebuffer alpha with the glass's own alpha,
// so an in-scene background would come out washed white once the PNG is un-premultiplied. The indigo
// is composited afterwards instead.
scene.background.contents = NSColor.clear

let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.11)
box.chamferSegmentCount = 16

let envImage = studioEnvironment()
let glass = SCNMaterial()
glass.lightingModel = .constant          // all shading is ours: refraction + reflection + film
glass.diffuse.contents = NSColor.black
glass.isDoubleSided = false
// Real-time glass: refract the view ray through the surface and sample the studio panorama,
// once per colour channel with a slightly different IOR (dispersion), mix with the mirror
// reflection by Fresnel, and add a thin-film sheen at grazing angles. Opaque output, so no
// blending artifacts; a cube is ~2k triangles, so this costs nothing on any iPhone.
glass.setValue(SCNMaterialProperty(contents: envImage), forKey: "envMap")
glass.shaderModifiers = [.fragment: """
#pragma arguments
texture2d<float> envMap;
#pragma declaration
inline float3 iridiaPano(texture2d<float> t, float3 d) {
  constexpr sampler smp(filter::linear, address::repeat);
  float2 uv = float2(atan2(d.z, d.x) / 6.28318 + 0.5, acos(clamp(d.y, -1.0, 1.0)) / 3.14159);
  return t.sample(smp, uv).rgb;
}
#pragma body
float4x4 inv = scn_frame.inverseViewTransform;
float3 n = normalize((inv * float4(normalize(_surface.normal), 0.0)).xyz);
float3 v = normalize((inv * float4(normalize(_surface.view), 0.0)).xyz);
float ndv = clamp(dot(n, v), 0.0, 1.0);
float f = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
// Trace through the solid block in object space (a unit cube centred at 0): refract in, find
// the exit face analytically, refract out (or reflect on total internal reflection).
float4x4 toObj = scn_node.inverseModelViewTransform;
float3 pO = (toObj * float4(_surface.position, 1.0)).xyz;
float3 nO = normalize((toObj * float4(normalize(_surface.normal), 0.0)).xyz);
float3 vO = normalize((toObj * float4(normalize(_surface.view), 0.0)).xyz);
float3 col = float3(0.0);
float inner = 0.0;
float iors[3] = {1.47, 1.51, 1.56};
for (int k = 0; k < 3; k++) {
  float3 d = refract(-vO, nO, 1.0 / iors[k]);
  float3 sd = sign(d);
  float3 tm = (sd * 0.5 - pO) / select(d, float3(1e-5) * sd, abs(d) < float3(1e-5));
  float t = min(tm.x, min(tm.y, tm.z));
  float3 pe = pO + d * max(t, 0.0);
  float3 ne = (t == tm.x) ? float3(sd.x, 0, 0) : ((t == tm.y) ? float3(0, sd.y, 0) : float3(0, 0, sd.z));
  float3 dOut = refract(d, -ne, iors[k]);
  if (dot(dOut, dOut) < 1e-6) dOut = reflect(d, -ne);
  float3 dW = normalize((scn_node.modelTransform * float4(dOut, 0.0)).xyz);
  col[k] = iridiaPano(envMap, dW)[k];
  if (k == 1) {
    // Exit point near an edge of the far faces: that's the cube's inner frame catching light.
    float3 ap = abs(pe);
    float mx = max(ap.x, max(ap.y, ap.z)), mn = min(ap.x, min(ap.y, ap.z));
    float second = ap.x + ap.y + ap.z - mx - mn;
    inner = smoothstep(0.36, 0.47, second);
  }
}
float3 refl = iridiaPano(envMap, reflect(-v, n));
float3 tint = float3(0.74, 0.68, 1.0);
float3 film = 0.5 + 0.5 * cos(6.2831 * (float3(0.0, 0.33, 0.67) + 2.0 * (1.0 - ndv) + 0.1));
float edge = pow(1.0 - ndv, 2.0);
float3 c = col * tint * (1.0 - f) + refl * f * 1.6 + film * edge * 0.35
         + inner * (float3(0.55, 0.50, 1.0) * 0.30 + film * 0.12);
_output.color = float4(c, 1.0);
"""]
box.materials = [glass]

let cube = SCNNode(geometry: box)
cube.eulerAngles = SCNVector3(0, 0.14, 0)   // a slight turn so the faces catch different light
cube.renderingOrder = 2
scene.rootNode.addChildNode(cube)

// The rainbow the glass throws on the floor, and a soft contact shadow.
func floorImage(_ draw: (CGContext, Int) -> Void) -> NSImage {
  let n = 1024
  let img = NSImage(size: NSSize(width: n, height: n))
  img.lockFocus()
  draw(NSGraphicsContext.current!.cgContext, n)
  img.unlockFocus()
  return img
}
let shadowImg = floorImage { ctx, n in
  let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                     colors: [CGColor(red: 0, green: 0, blue: 0, alpha: 0.75), CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray,
                     locations: [0, 1])!
  let c = CGPoint(x: n / 2, y: n / 2)
  ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(n) * 0.42, options: [])
}
let rainbowImg = floorImage { ctx, n in
  // A fan of spectrum bands spreading away from the cube's base (toward +x), fading out.
  let bands: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.25, 0.3), (1, 0.6, 0.2), (1, 0.95, 0.3), (0.3, 1, 0.5), (0.2, 0.75, 1), (0.55, 0.35, 1)]
  let origin = CGPoint(x: CGFloat(n) * 0.5, y: CGFloat(n) * 0.5)
  for (i, b) in bands.enumerated() {
    let a0 = -0.30 + CGFloat(i) * 0.09, a1 = a0 + 0.09
    let path = CGMutablePath()
    path.move(to: origin)
    path.addArc(center: origin, radius: CGFloat(n) * 0.5, startAngle: a0, endAngle: a1, clockwise: false)
    path.closeSubpath()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [CGColor(red: b.0, green: b.1, blue: b.2, alpha: 0), CGColor(red: b.0, green: b.1, blue: b.2, alpha: 0.9),
                                CGColor(red: b.0, green: b.1, blue: b.2, alpha: 0)] as CFArray,
                       locations: [0.0, 0.55, 1.0])!
    ctx.drawRadialGradient(g, startCenter: origin, startRadius: CGFloat(n) * 0.12, endCenter: origin, endRadius: CGFloat(n) * 0.5, options: [])
    ctx.restoreGState()
  }
}
func floorPlane(_ image: NSImage, size: CGFloat, blend: SCNBlendMode) -> SCNNode {
  let plane = SCNPlane(width: size, height: size)
  let m = SCNMaterial()
  m.lightingModel = .constant
  m.diffuse.contents = image
  m.blendMode = blend
  m.writesToDepthBuffer = false
  m.isDoubleSided = true
  plane.materials = [m]
  let node = SCNNode(geometry: plane)
  node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
  node.position = SCNVector3(0, -0.501, 0)
  node.renderingOrder = 0
  return node
}
scene.rootNode.addChildNode(floorPlane(shadowImg, size: 1.9, blend: .alpha))
let rainbow = floorPlane(rainbowImg, size: 2.6, blend: .add)
rainbow.position = SCNVector3(0.45, -0.5, 0.35)
rainbow.eulerAngles = SCNVector3(-Float.pi / 2, -0.55, 0)
scene.rootNode.addChildNode(rainbow)



// Key light for crisp specular highlights on the chamfers.
let key = SCNNode()
key.light = SCNLight()
key.light!.type = .directional
key.light!.intensity = 600
key.light!.color = NSColor.white
key.eulerAngles = SCNVector3(-0.9, -0.6, 0)
scene.rootNode.addChildNode(key)

// Camera: a three-quarter view from slightly above, like the logo.
let cam = SCNNode()
cam.camera = SCNCamera()
cam.camera!.fieldOfView = 28
cam.camera!.wantsHDR = true
cam.camera!.wantsExposureAdaptation = false
cam.camera!.exposureOffset = 0.0
cam.camera!.bloomIntensity = 0.5
cam.camera!.bloomThreshold = 0.9
cam.camera!.bloomBlurRadius = 6
cam.position = SCNVector3(2.25, 1.95, 2.55)
cam.look(at: SCNVector3(0, 0, 0))
scene.rootNode.addChildNode(cam)

// MARK: Render
guard let device = MTLCreateSystemDefaultDevice() else { fputs("no Metal device\n", stderr); exit(1) }
let renderer = SCNRenderer(device: device, options: nil)
renderer.scene = scene
renderer.pointOfView = cam
let image = renderer.snapshot(atTime: 0, with: CGSize(width: size, height: size), antialiasingMode: .multisampling4X)
var cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
if withBackground {
  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setFillColor(CGColor(srgbRed: 0.078, green: 0.051, blue: 0.196, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
  cg = ctx.makeImage()!
}
if asIcon {
  // App icons must be opaque (no alpha channel). iOS rounds the corners itself.
  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  let s = CGFloat(size)
  let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [CGColor(srgbRed: 0.24, green: 0.16, blue: 0.55, alpha: 1),
                                 CGColor(srgbRed: 0.10, green: 0.065, blue: 0.27, alpha: 1),
                                 CGColor(srgbRed: 0.045, green: 0.03, blue: 0.13, alpha: 1)] as CFArray,
                        locations: [0, 0.55, 1])!
  ctx.drawRadialGradient(glow, startCenter: CGPoint(x: s * 0.5, y: s * 0.56), startRadius: 0,
                         endCenter: CGPoint(x: s * 0.5, y: s * 0.5), endRadius: s * 0.75, options: [.drawsAfterEndLocation])
  // Soft violet pool under the cube (CG's origin is bottom-left).
  let pool = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [CGColor(srgbRed: 0.55, green: 0.42, blue: 1.0, alpha: 0.35), CGColor(srgbRed: 0.55, green: 0.42, blue: 1.0, alpha: 0)] as CFArray,
                        locations: [0, 1])!
  ctx.saveGState()
  ctx.translateBy(x: s * 0.5, y: s * 0.2); ctx.scaleBy(x: 1, y: 0.28)
  ctx.drawRadialGradient(pool, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: s * 0.42, options: [])
  ctx.restoreGState()
  let k: CGFloat = 0.74   // cube ≈ 62% of the icon, clear of the rounded corners
  ctx.draw(cg, in: CGRect(x: s * (1 - k) / 2, y: s * (1 - k) / 2 + s * 0.015, width: s * k, height: s * k))
  cg = ctx.makeImage()!
}
let rep = NSBitmapImageRep(cgImage: cg)
guard let png = rep.representation(using: .png, properties: [:]) else { fputs("encode failed\n", stderr); exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) \(size)x\(size)")
