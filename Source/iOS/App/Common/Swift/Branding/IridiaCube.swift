// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Iridia's glass cube as a real 3D model (SceneKit), not artwork. The same scene backs
// the live, slowly turning cube (IridiaCubeView) and a crisp image of it for small places
// (IridiaCube.mark), rendered once on first use. Tuned offline with Tools/branding/render_cube.swift.
//
// The glass is a custom shader: the view ray is refracted into the cube, traced to the face it
// leaves through, refracted out and used to sample a small studio panorama, per colour channel
// with a slightly different index of refraction (dispersion). Output is opaque, so there are no
// transparency halos, and a ~2k-triangle cube costs next to nothing. Menus only, never in-game.

import SceneKit
import SwiftUI
import UIKit

enum IridiaCube {
  // MARK: Scene

  /// A fresh scene with the cube at the origin, framed by a three-quarter camera.
  static func makeScene() -> (scene: SCNScene, cube: SCNNode, camera: SCNNode) {
    let scene = SCNScene()
    scene.background.contents = UIColor.clear

    let box = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0.11)
    box.chamferSegmentCount = 12
    box.materials = [glassMaterial]
    let cube = SCNNode(geometry: box)
    cube.eulerAngles = SCNVector3(0, 0.14, 0)
    scene.rootNode.addChildNode(cube)

    let cam = SCNNode()
    cam.camera = SCNCamera()
    cam.camera!.fieldOfView = 28
    cam.position = SCNVector3(2.25, 1.95, 2.55)
    cam.look(at: SCNVector3(0, 0, 0))
    scene.rootNode.addChildNode(cam)
    return (scene, cube, cam)
  }

  private static let glassMaterial: SCNMaterial = {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = UIColor.black
    m.isDoubleSided = false
    m.setValue(SCNMaterialProperty(contents: studioPanorama), forKey: "envMap")
    m.shaderModifiers = [.fragment: glassShader]
    return m
  }()

  /// A dark violet room with three soft light strips (equirectangular), for reflections and refraction.
  private static let studioPanorama: UIImage = {
    let size = CGSize(width: 1024, height: 512)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { r in
      let ctx = r.cgContext
      let room = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [UIColor(red: 0.03, green: 0.02, blue: 0.08, alpha: 1).cgColor,
                                     UIColor(red: 0.16, green: 0.10, blue: 0.34, alpha: 1).cgColor,
                                     UIColor(red: 0.04, green: 0.03, blue: 0.10, alpha: 1).cgColor] as CFArray,
                            locations: [0, 0.5, 1])!
      ctx.drawLinearGradient(room, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
      func strip(_ rect: CGRect, _ color: UIColor) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 20, color: color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
        ctx.restoreGState()
      }
      // Same layout as the offline tool (which draws bottom-up), mirrored to UIKit's top-down y.
      strip(CGRect(x: 130, y: 512 - 395, width: 260, height: 75), .white)
      strip(CGRect(x: 690, y: 512 - 425, width: 60, height: 165), UIColor(red: 0.6, green: 0.85, blue: 1, alpha: 1))
      strip(CGRect(x: 450, y: 512 - 245, width: 180, height: 30), UIColor(red: 1, green: 0.75, blue: 0.95, alpha: 1))
    }
  }()

  private static let glassShader = """
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
      float3 ap = abs(pe);
      float mx = max(ap.x, max(ap.y, ap.z)), mn = min(ap.x, min(ap.y, ap.z));
      inner = smoothstep(0.36, 0.47, ap.x + ap.y + ap.z - mx - mn);
    }
  }
  float3 refl = iridiaPano(envMap, reflect(-v, n));
  float3 film = 0.5 + 0.5 * cos(6.2831 * (float3(0.0, 0.33, 0.67) + 2.0 * (1.0 - ndv) + 0.1));
  float edge = pow(1.0 - ndv, 2.0);
  float3 c = col * float3(0.74, 0.68, 1.0) * (1.0 - f) + refl * f * 1.6 + film * edge * 0.35
           + inner * (float3(0.55, 0.50, 1.0) * 0.30 + film * 0.12);
  _output.color = float4(c, 1.0);
  """

  // MARK: Still image

  /// The cube as an Image for small places (toolbar, covers, loading). Rendered once, 512 px.
  static var mark: Image { Image(uiImage: markImage) }

  static let markImage: UIImage = {
    let (scene, _, cam) = makeScene()
    let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    renderer.scene = scene
    renderer.pointOfView = cam
    return renderer.snapshot(atTime: 0, with: CGSize(width: 512, height: 512), antialiasingMode: .multisampling4X)
  }()
}

/// The live cube: turns slowly; 30 fps is plenty for a slow spin and saves battery.
struct IridiaCubeView: UIViewRepresentable {
  var spins = true

  func makeUIView(context: Context) -> SCNView {
    let (scene, cube, cam) = IridiaCube.makeScene()
    let view = SCNView(frame: .zero)
    view.scene = scene
    view.pointOfView = cam
    view.backgroundColor = .clear
    view.isOpaque = false
    view.antialiasingMode = .multisampling4X
    view.preferredFramesPerSecond = 30
    view.isUserInteractionEnabled = false
    view.accessibilityElementsHidden = true
    if spins {
      let spin = SCNAction.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 24))
      cube.runAction(spin)
      view.rendersContinuously = true
    }
    return view
  }

  func updateUIView(_ view: SCNView, context: Context) {}

  static func dismantleUIView(_ view: SCNView, coordinator: ()) {
    view.scene?.rootNode.childNodes.forEach { $0.removeAllActions() }
    view.rendersContinuously = false
  }
}
