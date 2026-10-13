// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Settings > Controllers > Control Options. Inverting the camera stick (the GameCube
// C-stick) is applied in the core (GCPadEmu), so it covers the touch controls and every physical
// controller.

import SwiftUI

enum ControlOptions {
  static let invertCameraXKey = "iridia_invert_camera_x"
  static let invertCameraYKey = "iridia_invert_camera_y"

  /// Push the saved choice to the core. Call at launch and whenever it changes.
  static func apply() {
    let d = UserDefaults.standard
    DOLConfigBridge.setCStickInvertX(d.bool(forKey: invertCameraXKey), y: d.bool(forKey: invertCameraYKey))
  }

  static func model(invertX: Binding<Bool>, invertY: Binding<Bool>) -> MenuModel {
    MenuModel(sections: [
      MenuSection(id: "camera", header: L("Camera Stick"),
                  footer: L("The camera stick is the C-stick. Inverting it affects every game and every controller, touch included."),
                  items: [
        SettingsRow.toggle("invert-camera-y", L("Invert Up/Down"), invertY.wrappedValue,
                           L("Push up to look down, like a flight stick."), set: { invertY.wrappedValue = $0 }),
        SettingsRow.toggle("invert-camera-x", L("Invert Left/Right"), invertX.wrappedValue,
                           L("Push left to turn the camera right."), set: { invertX.wrappedValue = $0 }),
      ]),
    ])
  }
}

struct ControlOptionsView: View {
  @AppStorage(ControlOptions.invertCameraXKey) private var invertX = false
  @AppStorage(ControlOptions.invertCameraYKey) private var invertY = false

  var body: some View {
    SettingsLeafScreen(model: ControlOptions.model(invertX: $invertX, invertY: $invertY),
                       title: L("Control Options"), sync: {})
      .onChange(of: invertX) { _, _ in ControlOptions.apply() }
      .onChange(of: invertY) { _, _ in ControlOptions.apply() }
  }
}
