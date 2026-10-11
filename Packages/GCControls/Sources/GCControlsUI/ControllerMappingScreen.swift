// SPDX-License-Identifier: GPL-2.0-or-later
//
// Visual mapping screen: a generic schematic of the detected controller type (our
// own drawing; no product art or logos), each physical button shown with the
// system's GameController glyph and labeled with its GameCube function.

#if canImport(UIKit)
import GameController
import GCControlsCore
import SwiftUI

public struct ControllerMappingScreen: View {
  @Bindable var session: ControllerSession
  let controllerID: ObjectIdentifier
  @State private var forGame = false
  @State private var confirmReset = false

  public init(session: ControllerSession, controllerID: ObjectIdentifier) {
    self.session = session
    self.controllerID = controllerID
  }

  private var info: ConnectedController? { session.physical.controllers.first { $0.id == controllerID } }

  public var body: some View {
    if let info, let profile = session.physical.profile(for: controllerID) {
      ScrollView {
        VStack(spacing: 18) {
          header(info)
          TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            schematic(info, profile: profile, held: session.physical.heldElements(for: controllerID))
          }
          .aspectRatio(info.family == .joyConSingle ? 2.0 : 1.55, contentMode: .fit)
          .padding(.horizontal)
          controls(info, profile: profile)
        }
        .padding(.vertical)
      }
      .navigationTitle("Player \(info.player + 1) Mapping")
      .confirmationDialog("Reset to smart defaults?", isPresented: $confirmReset, titleVisibility: .visible) {
        Button("Reset", role: .destructive) {
          session.physical.resetToSmartDefaults(for: controllerID, includingGame: forGame)
        }
      } message: {
        Text("Your custom mapping for \(info.family.displayName) will be removed.")
      }
    } else {
      ContentUnavailableView("Controller disconnected", systemImage: "gamecontroller")
    }
  }

  // MARK: Header

  private func header(_ info: ConnectedController) -> some View {
    VStack(spacing: 6) {
      Text(info.name).font(.title3.bold())
      Text(sourceText(info)).font(.subheadline).foregroundStyle(.secondary)
      Picker("Smart mapping", selection: Binding(
        get: { session.physical.profiles.style(for: info.family) },
        set: { session.physical.setStyle($0, for: controllerID) })
      ) {
        ForEach(MappingStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .disabled({ if case .smart = info.mappingSource { return false }; return true }())
      if info.labelFallback {
        Text("This controller has no letter labels, so By position is used.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func sourceText(_ info: ConnectedController) -> String {
    switch info.mappingSource {
    case .gameOverride: "Custom mapping for this game"
    case .custom: "Custom mapping (edited)"
    case .smart(let s): "Smart mapping · \(s.displayName)"
    }
  }

  // MARK: Schematic

  private struct Spot { let element: PhysicalElement; let at: CGPoint }

  private func spots(_ f: ControllerFamily) -> [Spot] {
    func s(_ e: PhysicalElement, _ x: Double, _ y: Double) -> Spot { Spot(element: e, at: CGPoint(x: x, y: y)) }
    switch f {
    case .joyConSingle:
      return [s(.leftStick, 0.28, 0.52), s(.buttonNorth, 0.72, 0.30), s(.buttonSouth, 0.72, 0.74),
              s(.buttonWest, 0.60, 0.52), s(.buttonEast, 0.84, 0.52),
              s(.leftShoulder, 0.30, 0.08), s(.rightShoulder, 0.70, 0.08), s(.buttonMenu, 0.50, 0.30)]
    case .dualSense, .dualShock:
      return common + [s(.dpadUp, 0.24, 0.30), s(.dpadDown, 0.24, 0.50), s(.dpadLeft, 0.16, 0.40), s(.dpadRight, 0.32, 0.40),
                       s(.leftStick, 0.38, 0.64), s(.rightStick, 0.62, 0.64)] + face(0.76, 0.40)
    default:
      return common + [s(.leftStick, 0.25, 0.38), s(.rightStick, 0.62, 0.64),
                       s(.dpadUp, 0.38, 0.56), s(.dpadDown, 0.38, 0.76), s(.dpadLeft, 0.30, 0.66), s(.dpadRight, 0.46, 0.66)]
        + face(0.76, 0.38)
    }
  }

  private var common: [Spot] {
    [Spot(element: .leftTrigger, at: CGPoint(x: 0.20, y: 0.04)), Spot(element: .leftShoulder, at: CGPoint(x: 0.24, y: 0.15)),
     Spot(element: .rightTrigger, at: CGPoint(x: 0.80, y: 0.04)), Spot(element: .rightShoulder, at: CGPoint(x: 0.76, y: 0.15)),
     Spot(element: .buttonOptions, at: CGPoint(x: 0.41, y: 0.34)), Spot(element: .buttonMenu, at: CGPoint(x: 0.59, y: 0.34)),
     Spot(element: .buttonHome, at: CGPoint(x: 0.50, y: 0.50))]
  }

  private func face(_ cx: Double, _ cy: Double) -> [Spot] {
    [Spot(element: .buttonNorth, at: CGPoint(x: cx, y: cy - 0.12)), Spot(element: .buttonSouth, at: CGPoint(x: cx, y: cy + 0.12)),
     Spot(element: .buttonWest, at: CGPoint(x: cx - 0.08, y: cy)), Spot(element: .buttonEast, at: CGPoint(x: cx + 0.08, y: cy))]
  }

  private func schematic(_ info: ConnectedController, profile: MappingProfile, held: UInt32) -> some View {
    GeometryReader { geo in
      let size = geo.size
      ZStack {
        padShape(info.family).fill(.indigo.gradient.opacity(0.45))
        padShape(info.family).stroke(.white.opacity(0.25), lineWidth: 1.5)
        ForEach(spots(info.family), id: \.element) { spot in
          let isHeld = held & (1 << UInt32(spot.element.rawValue)) != 0
          badge(spot.element, target: profile.target(for: spot.element), held: isHeld, profile: profile)
            .position(x: spot.at.x * size.width, y: spot.at.y * size.height + 12)
        }
      }
    }
  }

  /// Generic outline: a rounded body with two grips (no specific product's shape).
  private func padShape(_ f: ControllerFamily) -> some Shape {
    GenericPadShape(single: f == .joyConSingle, wide: f == .backbone)
  }

  private func glyph(_ e: PhysicalElement) -> String {
    let key: String = switch e {
    case .buttonSouth: GCInputButtonA
    case .buttonEast: GCInputButtonB
    case .buttonWest: GCInputButtonX
    case .buttonNorth: GCInputButtonY
    case .leftShoulder: GCInputLeftShoulder
    case .rightShoulder: GCInputRightShoulder
    case .leftTrigger: GCInputLeftTrigger
    case .rightTrigger: GCInputRightTrigger
    case .dpadUp, .dpadDown, .dpadLeft, .dpadRight: GCInputDirectionPad
    case .leftStick: GCInputLeftThumbstick
    case .rightStick: GCInputRightThumbstick
    case .leftStickButton: GCInputLeftThumbstickButton
    case .rightStickButton: GCInputRightThumbstickButton
    case .buttonMenu: GCInputButtonMenu
    case .buttonOptions: GCInputButtonOptions
    case .buttonHome: GCInputButtonHome
    }
    let el = session.physical.controller(controllerID)?.physicalInputProfile.elements[key]
    switch e {
    case .dpadUp: return "arrowtriangle.up.fill"
    case .dpadDown: return "arrowtriangle.down.fill"
    case .dpadLeft: return "arrowtriangle.left.fill"
    case .dpadRight: return "arrowtriangle.right.fill"
    default: return el?.sfSymbolsName ?? "circle"
    }
  }

  private func badge(_ e: PhysicalElement, target: GCTarget, held: Bool, profile: MappingProfile) -> some View {
    Menu {
      Picker("Maps to", selection: Binding(get: { target }, set: { remap(e, to: $0, profile: profile) })) {
        ForEach(allowedTargets(e), id: \.self) { Text($0.displayName).tag($0) }
      }
    } label: {
      VStack(spacing: 2) {
        Image(systemName: glyph(e)).font(.title3)
        Text(target.displayName).font(.caption2.bold()).lineLimit(1).fixedSize()
      }
      .padding(6)
      .background(held ? AnyShapeStyle(.green.opacity(0.6)) : AnyShapeStyle(.ultraThinMaterial), in: .rect(cornerRadius: 10))
      .scaleEffect(held ? 1.12 : 1)
    }
    .accessibilityLabel("\(e.name) maps to \(target.displayName)")
  }

  private func allowedTargets(_ e: PhysicalElement) -> [GCTarget] {
    if e.isStick { return [.mainStick, .cStick, .dpadUp, .none] }  // any D-pad target = use the stick as a D-pad
    return GCTarget.allCases.filter { $0 != .mainStick && $0 != .cStick }
  }

  private func remap(_ e: PhysicalElement, to t: GCTarget, profile: MappingProfile) {
    var p = profile
    p.bindings[e] = t
    session.physical.saveEdited(p, for: controllerID, forGame: forGame)
  }

  // MARK: Controls

  private func controls(_ info: ConnectedController, profile: MappingProfile) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      if session.physical.gameID != nil {
        Toggle("Save changes for this game only", isOn: $forGame)
      }
      LabeledContent("Stick dead zone") {
        Slider(value: Binding(get: { profile.stick.deadZone }, set: { v in
          var p = profile; p.stick.deadZone = v; session.physical.saveEdited(p, for: controllerID, forGame: forGame)
        }), in: 0...0.5)
      }
      LabeledContent("Stick sensitivity") {
        Slider(value: Binding(get: { profile.stick.sensitivity }, set: { v in
          var p = profile; p.stick.sensitivity = v; session.physical.saveEdited(p, for: controllerID, forGame: forGame)
        }), in: 0.5...2.0)
      }
      if info.supportsAdaptiveTriggers {
        Label("Adaptive triggers on for L/R", systemImage: "dial.medium").font(.footnote).foregroundStyle(.secondary)
      }
      Button("Reset to Smart Defaults", role: .destructive) { confirmReset = true }
        .disabled(info.mappingSource != .custom && info.mappingSource != .gameOverride)
    }
    .padding()
    .glassEffect(.regular, in: .rect(cornerRadius: 20))
    .padding(.horizontal)
  }
}

/// A plain two-grip gamepad outline drawn from arcs and curves.
struct GenericPadShape: Shape {
  var single = false
  var wide = false

  func path(in r: CGRect) -> Path {
    var p = Path()
    let rect = r.insetBy(dx: r.width * 0.02, dy: r.height * 0.1).offsetBy(dx: 0, dy: r.height * 0.05)
    if single {
      p.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.height * 0.4, height: rect.height * 0.4))
      return p
    }
    let w = rect.width, h = rect.height
    let gripW = w * (wide ? 0.2 : 0.3)
    p.move(to: CGPoint(x: rect.minX + gripW * 0.6, y: rect.minY))
    p.addLine(to: CGPoint(x: rect.maxX - gripW * 0.6, y: rect.minY))
    p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.45), control: CGPoint(x: rect.maxX, y: rect.minY))
    p.addQuadCurve(to: CGPoint(x: rect.maxX - gripW * 0.35, y: rect.maxY), control: CGPoint(x: rect.maxX + w * 0.02, y: rect.maxY))
    p.addQuadCurve(to: CGPoint(x: rect.maxX - gripW, y: rect.minY + h * 0.68), control: CGPoint(x: rect.maxX - gripW * 0.9, y: rect.maxY))
    p.addQuadCurve(to: CGPoint(x: rect.minX + gripW, y: rect.minY + h * 0.68), control: CGPoint(x: rect.midX, y: rect.minY + h * 0.58))
    p.addQuadCurve(to: CGPoint(x: rect.minX + gripW * 0.35, y: rect.maxY), control: CGPoint(x: rect.minX + gripW * 0.9, y: rect.maxY))
    p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.45), control: CGPoint(x: rect.minX - w * 0.02, y: rect.maxY))
    p.addQuadCurve(to: CGPoint(x: rect.minX + gripW * 0.6, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
    p.closeSubpath()
    return p
  }
}
#endif
