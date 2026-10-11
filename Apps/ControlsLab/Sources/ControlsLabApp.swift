// SPDX-License-Identifier: GPL-2.0-or-later
//
// Controls Lab: try the on-screen controller and Smart Mapping without the emulator.
// The "game screen" is a live readout of exactly what the emulation thread would read.

import GCControlsCore
import GCControlsUI
import SwiftUI

@main
struct ControlsLabApp: App {
  @State private var session = ControllerSession()

  var body: some Scene {
    WindowGroup {
      LabRoot(session: session)
        .onAppear { session.start() }
        .preferredColorScheme(.dark)
    }
  }
}

struct LabRoot: View {
  @Bindable var session: ControllerSession
  @State private var showMenu = false
  @State private var editing = false
  @State private var mappingFor: MappingTarget?

  struct MappingTarget: Identifiable { let id: ObjectIdentifier }

  var body: some View {
    ControllerScreen(session: session) { orientation in
      ReadoutScreen(paused: session.pausedForDisconnect || showMenu)
        .overlay {
          if session.pausedForDisconnect {
            PausedOverlay { session.pausedForDisconnect = false }
          }
        }
        .onTapGesture(count: 2) { session.toggleOnScreenController() }
    }
    .background(Color.black.ignoresSafeArea())
    .onAppear {
      session.onMenu = { showMenu = true }
      // Testing aid: `-showPad YES` keeps the on-screen controller up even with a controller connected.
      if UserDefaults.standard.bool(forKey: "showPad") { session.manualOnScreenVisible = true }
      // Tapping the connect toast opens that controller's mapping.
      session.onToastTap = { t in if let id = t.controllerID { mappingFor = MappingTarget(id: id) } }
    }
    .onChange(of: session.physical.controllers.count) { _, _ in
      if UserDefaults.standard.bool(forKey: "showPad") { session.manualOnScreenVisible = true }
      // Testing aid: `-landscape YES` rotates the window (the Simulator can't be rotated by script).
      if UserDefaults.standard.bool(forKey: "landscape"),
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
      {
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
      }
    }
    .sheet(isPresented: $showMenu) {
      LabMenu(session: session, editLayout: { showMenu = false; editing = true },
              openMapping: { id in showMenu = false; mappingFor = MappingTarget(id: id) })
        .presentationDetents([.medium, .large])
    }
    .fullScreenCover(isPresented: $editing) {
      ControllerLayoutEditor(session: session)
    }
    .sheet(item: $mappingFor) { target in
      NavigationStack {
        ControllerMappingScreen(session: session, controllerID: target.id)
          .toolbar { Button("Done") { mappingFor = nil } }
      }
    }
  }
}

/// Stand-in for the game: shows the merged pad state for player 1, read the same
/// lock-free way the core will (PadStateStore.read), refreshed at display rate.
struct ReadoutScreen: View {
  var paused: Bool

  var body: some View {
    TimelineView(.animation(paused: paused)) { _ in
      let s = PadState(packed: PadStateStore.shared.read(player: 0))
      ZStack {
        LinearGradient(colors: [Color(red: 0.06, green: 0.04, blue: 0.16), .black], startPoint: .top, endPoint: .bottom)
        VStack(spacing: 14) {
          HStack(spacing: 24) {
            StickDot(x: s.stickX, y: s.stickY, color: .white, label: "Main")
            StickDot(x: s.cStickX, y: s.cStickY, color: .yellow, label: "C")
          }
          HStack(spacing: 6) {
            ForEach(Self.buttons, id: \.1) { b, name in
              Text(name).font(.caption.monospaced().bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(s.buttons.contains(b) ? Color.green : Color.white.opacity(0.1), in: .capsule)
            }
          }
          HStack(spacing: 16) {
            TriggerBar(value: s.triggerL, label: "L", click: s.buttons.contains(.l))
            TriggerBar(value: s.triggerR, label: "R", click: s.buttons.contains(.r))
          }
          Text(String(format: "0x%016llX", PadStateStore.shared.read(player: 0)))
            .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        .padding()
      }
    }
  }

  static let buttons: [(GCButtons, String)] = [
    (.a, "A"), (.b, "B"), (.x, "X"), (.y, "Y"), (.z, "Z"), (.start, "ST"),
    (.dpadUp, "↑"), (.dpadDown, "↓"), (.dpadLeft, "←"), (.dpadRight, "→"),
  ]
}

struct StickDot: View {
  let x: UInt8, y: UInt8, color: Color, label: String
  var body: some View {
    VStack(spacing: 4) {
      ZStack {
        Circle().stroke(.white.opacity(0.25), lineWidth: 1.5)
        Circle().fill(color).frame(width: 12, height: 12)
          .offset(x: (CGFloat(x) - 128) / 128 * 34, y: -(CGFloat(y) - 128) / 128 * 34)
      }
      .frame(width: 80, height: 80)
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
  }
}

struct TriggerBar: View {
  let value: UInt8, label: String, click: Bool
  var body: some View {
    VStack(spacing: 4) {
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.12))
        Capsule().fill(click ? Color.green : Color.indigo).frame(width: CGFloat(value) / 255 * 110)
      }
      .frame(width: 110, height: 10)
      Text("\(label) \(value)").font(.caption2.monospaced()).foregroundStyle(.secondary)
    }
  }
}

struct PausedOverlay: View {
  var resume: () -> Void
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "pause.circle.fill").font(.system(size: 44))
      Text("Paused — controller disconnected").font(.headline)
      Button("Resume", action: resume).buttonStyle(.glassProminent)
    }
    .padding(24)
    .glassEffect(.regular, in: .rect(cornerRadius: 24))
  }
}

struct LabMenu: View {
  @Bindable var session: ControllerSession
  var editLayout: () -> Void
  var openMapping: (ObjectIdentifier) -> Void

  var body: some View {
    NavigationStack {
      Form {
        Section("On-screen controller") {
          Toggle("Show on-screen controller", isOn: Binding(
            get: { session.isOnScreenControllerVisible },
            set: { session.manualOnScreenVisible = $0 }))
          Button("Edit Layout…", action: editLayout)
          NavigationLink("Skin: \(session.skin.name)") { SkinPicker(session: session) }
          Toggle("Haptic feedback", isOn: $session.settings.hapticsEnabled)
          Toggle("Digital L/R (no slide pressure)", isOn: $session.settings.digitalTriggers)
          LabeledContent("Stick dead zone") {
            Slider(value: $session.settings.stick.deadZone, in: 0...0.4)
          }
        }
        Section("Controllers") {
          if session.physical.controllers.isEmpty {
            Text("No controllers connected").foregroundStyle(.secondary)
          }
          ForEach(session.physical.controllers) { c in
            Button { openMapping(c.id) } label: {
              LabeledContent("P\(c.player + 1): \(c.family.displayName)") {
                Text(c.style.displayName)
              }
            }
          }
        }
      }
      .navigationTitle("Menu")
    }
  }
}
