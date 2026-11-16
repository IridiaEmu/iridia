// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS) && canImport(IridiaCafeCore)
import GameController
import SwiftUI

/// The Wii U tab's Controllers screen, laid out like the GameCube and Wii one. Every connected controller plays
/// as the one GamePad, so there are no players or ports to choose.
struct WiiUControllersView: View {
  @AppStorage("cafeTouchOpacity") private var touchOpacity = 0.55
  @AppStorage("cafeHaptics") private var haptics = true
  @State private var pads: [Pad] = []

  struct Pad: Equatable {
    let id: ObjectIdentifier
    let name: String
    let battery: String?
  }

  static let opacityChoices = [25, 50, 75, 100]

  var body: some View {
    MenuScreen(model: model, style: .list)
      .navigationTitle(L("Controllers"))
      .toolbarBackground(.hidden, for: .navigationBar)
      .onAppear(perform: reload)
      .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in reload() }
      .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in reload() }
  }

  private var model: MenuModel {
    MenuModel(sections: [touchSection, devicesSection, buttonsSection, helpSection])
  }

  private var touchSection: MenuSection {
    let percent = Int((touchOpacity * 100).rounded())
    let nearest = Self.opacityChoices.min { abs($0 - percent) < abs($1 - percent) } ?? 50
    return MenuSection(id: "touch-controls", header: L("Touch Controls"), footer: L("Touch controls hide when you use a game controller."), items: [
      MenuItem(
        id: "touch-opacity", title: L("Opacity"), icon: "circle.lefthalf.filled",
        role: .cycle(options: Self.opacityChoices.map { ("\($0)%", AnyHashable($0)) }, selection: Binding(
          get: { AnyHashable(nearest) },
          set: { if let value = $0.base as? Int { touchOpacity = Double(value) / 100 } })),
        description: L("How see-through the on-screen controls are.")),
      MenuItem(
        id: "touch-vibration", title: L("Button Vibration"), icon: "hand.tap",
        role: .toggle($haptics),
        description: L("A light buzz when you press on-screen buttons.")),
    ])
  }

  private var devicesSection: MenuSection {
    var items = pads.map { pad in
      MenuItem(id: "pad-\(pad.name)-\(pad.id.hashValue)", title: pad.name, subtitle: pad.battery,
               icon: "gamecontroller.fill", role: .action({}))
    }
    if items.isEmpty {
      items.append(MenuItem(id: "no-pads", title: L("No controllers connected"), role: .action({}), isEnabled: false))
    }
    return MenuSection(id: "devices", header: L("Connected Devices"),
                       footer: L("Every connected controller plays as the GamePad."), items: items)
  }

  /// What `PadInput.push` sends for each controller button.
  private var buttonsSection: MenuSection {
    let rows: [(String, String, String)] = [
      ("face", L("A, B, X, Y"), L("By position: the right button is A, the bottom one B, the top one X, the left one Y")),
      ("shoulders", L("L, R"), L("The shoulder buttons")),
      ("triggers", L("ZL, ZR"), L("The triggers")),
      ("plus", L("+"), L("Menu / Options / + button")),
      ("minus", L("−"), L("View / Share / − button")),
      ("sticks", L("Sticks"), L("Both sticks, and pressing them in")),
    ]
    return MenuSection(id: "buttons", header: L("Buttons"), items: rows.map { id, action, how in
      MenuItem(id: "button-\(id)", title: action, subtitle: how, role: .action({}))
    })
  }

  private var helpSection: MenuSection {
    let rows: [(String, String, String)] = [
      ("pause", L("Pause"), L("The pause button at the top of the screen")),
      ("layout", L("Change the layout"), L("Hold Menu and press L")),
      ("swap", L("Swap screens"), L("Hold Menu and press R")),
    ]
    return MenuSection(id: "help", header: L("Help"), items: rows.map { id, action, how in
      MenuItem(id: "help-\(id)", title: action, subtitle: how, role: .action({}))
    })
  }

  private func reload() {
    pads = GCController.controllers().filter { $0.extendedGamepad != nil }.map { controller in
      var battery: String?
      if let b = controller.battery, b.batteryState != .unknown {
        let percent = Int((b.batteryLevel * 100).rounded())
        battery = b.batteryState == .charging
          ? String(format: L("Battery %d%% · Charging"), percent)
          : String(format: L("Battery %d%%"), percent)
      }
      return Pad(id: ObjectIdentifier(controller), name: controller.vendorName ?? L("Controller"), battery: battery)
    }
  }
}
#endif
