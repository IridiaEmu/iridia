// SPDX-License-Identifier: GPL-2.0-or-later
//
// Iridia's glass cube, modelled and rendered from scratch (no downloaded or generated art).
//   swift Tools/branding/render_cube.swift <out.png> [size] [--bg]
// A chamfered cube with a clear physically-based glass material, an iridescent thin-film sheen
// at grazing angles, and a procedural studio environment (soft light strips) for reflections.
// Without --bg the PNG has a transparent background; with --bg it sits on the Iridia indigo.
// The same scene description is what the app's live 3D menu uses (SceneKit).

import AppKit
import Foundation
import Metal
import SceneKit

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage: render_cube.swift <out.png> [size] [--bg]\n", stderr); exit(1) }
let outPath = args[1]
let size = args.count >= 3 ? Int(args[2]) ?? 1024 : 1024
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

let glass = SCNMaterial()
glass.lightingModel = .physicallyBased
// Clear glass: almost no diffuse, mirror-smooth, so what you see is reflections of the studio.
glass.diffuse.contents = NSColor(srgbRed: 0.05, green: 0.04, blue: 0.12, alpha: 1)
glass.metalness.contents = 0.0
glass.roughness.contents = 0.02
glass.isDoubleSided = true          // back faces show the inside edges through the front: depth
glass.transparencyMode = .dualLayer
glass.blendMode = .alpha
glass.writesToDepthBuffer = false
// Alpha follows what a real pane does: nearly clear face-on, more reflective/opaque at grazing
// angles (Fresnel) and wherever a reflection is bright. Plus a thin-film iridescent sheen.
glass.shaderModifiers = [.fragment: """
float3 n = normalize(_surface.normal);
float3 v = normalize(_surface.view);
float ndv = clamp(abs(dot(n, v)), 0.0, 1.0);
float f = 0.04 + 0.96 * pow(1.0 - ndv, 5.0);
float3 film = 0.5 + 0.5 * cos(6.2831 * (float3(0.0, 0.33, 0.67) + 2.2 * (1.0 - ndv) + 0.1));
float3 tint = float3(0.30, 0.24, 0.80);
float3 refl = _output.color.rgb;
float lum = dot(refl, float3(0.299, 0.587, 0.114));
float edge = pow(1.0 - ndv, 1.6);
float3 c = refl * (0.9 + 1.4 * f) + film * edge * 1.1 + tint * (0.18 + 0.25 * edge);
float a = clamp(0.10 + f * 0.9 + lum * 0.8 + edge * 0.45, 0.0, 1.0);
// SceneKit blends premultiplied colour: straight colour with a small alpha blows out to white.
_output.color = float4(c * a, a);
"""]
box.materials = [glass]

let cube = SCNNode(geometry: box)
cube.eulerAngles = SCNVector3(0, 0, 0)
scene.rootNode.addChildNode(cube)



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
let rep = NSBitmapImageRep(cgImage: cg)
guard let png = rep.representation(using: .png, properties: [:]) else { fputs("encode failed\n", stderr); exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) \(size)x\(size)")
