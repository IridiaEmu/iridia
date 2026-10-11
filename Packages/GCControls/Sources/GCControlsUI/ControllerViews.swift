// SPDX-License-Identifier: GPL-2.0-or-later

#if canImport(UIKit)
import GCControlsCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - UIKit bridge

public struct TouchControllerHost: UIViewRepresentable {
  let skin: ControllerSkin
  let orientation: SkinOrientation
  let overrides: LayoutOverrides
  let settings: TouchControllerSettings
  var isEditing = false
  var onMenu: (() -> Void)?
  var onOverridesChanged: ((LayoutOverrides) -> Void)?
  var onSelectionChanged: ((String?) -> Void)?
  var viewRef: ((TouchControllerView) -> Void)?

  public init(
    skin: ControllerSkin, orientation: SkinOrientation, overrides: LayoutOverrides,
    settings: TouchControllerSettings, isEditing: Bool = false,
    onMenu: (() -> Void)? = nil, onOverridesChanged: ((LayoutOverrides) -> Void)? = nil,
    onSelectionChanged: ((String?) -> Void)? = nil, viewRef: ((TouchControllerView) -> Void)? = nil
  ) {
    self.skin = skin; self.orientation = orientation; self.overrides = overrides
    self.settings = settings; self.isEditing = isEditing; self.onMenu = onMenu
    self.onOverridesChanged = onOverridesChanged; self.onSelectionChanged = onSelectionChanged
    self.viewRef = viewRef
  }

  public func makeUIView(context: Context) -> TouchControllerView {
    let v = TouchControllerView(frame: .zero)
    update(v)
    viewRef?(v)
    return v
  }

  public func updateUIView(_ v: TouchControllerView, context: Context) { update(v) }

  private func update(_ v: TouchControllerView) {
    v.skin = skin
    v.orientation = orientation
    v.overrides = overrides
    v.settings = settings
    v.isEditing = isEditing
    v.onMenu = onMenu
    v.onOverridesChanged = onOverridesChanged
    v.onSelectionChanged = onSelectionChanged
  }
}

// MARK: - Game + controller layout

/// Portrait: game on top, controller in the bottom half (game expands when hidden).
/// Landscape: game fills the screen, controller overlaid at the skin's opacity.
public struct ControllerScreen<Game: View>: View {
  @Bindable var session: ControllerSession
  let game: (SkinOrientation) -> Game

  public init(session: ControllerSession, @ViewBuilder game: @escaping (SkinOrientation) -> Game) {
    self.session = session
    self.game = game
  }

  public var body: some View {
    GeometryReader { geo in
      let orientation: SkinOrientation = geo.size.width > geo.size.height ? .landscape : .portrait
      let showPad = session.isOnScreenControllerVisible
      ZStack(alignment: .top) {
        if orientation == .portrait {
          VStack(spacing: 0) {
            game(orientation)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showPad {
              pad(orientation)
                .frame(height: geo.size.height * 0.5)
                .transition(.move(edge: .bottom))
            }
          }
        } else {
          game(orientation).frame(maxWidth: .infinity, maxHeight: .infinity)
          if showPad {
            pad(orientation).transition(.opacity)
          }
        }
      }
      .animation(.spring(duration: 0.35, bounce: 0.25), value: showPad)
    }
    .overlay(alignment: .top) {
      // Outside the GeometryReader so it always respects the top safe area.
      if let toast = session.toast {
        ControllerToastView(toast: toast) { session.onToastTap?(toast); session.dismissToast() }
          .frame(maxWidth: 520)
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.spring(duration: 0.3), value: session.toast)
  }

  private func pad(_ o: SkinOrientation) -> some View {
    TouchControllerHost(
      skin: session.skin, orientation: o, overrides: session.overrides(for: o),
      settings: session.settings, onMenu: { session.onMenu?() })
      .ignoresSafeArea(edges: o == .portrait ? .bottom : .all)
  }
}

public struct ControllerToastView: View {
  let toast: ControllerToast
  var onTap: () -> Void
  public init(toast: ControllerToast, onTap: @escaping () -> Void) { self.toast = toast; self.onTap = onTap }

  public var body: some View {
    Button(action: onTap) {
      HStack(spacing: 10) {
        Image(systemName: toast.controllerID == nil ? "gamecontroller" : "gamecontroller.fill")
        Text(toast.message).font(.callout.weight(.semibold)).multilineTextAlignment(.leading)
      }
      .padding(.horizontal, 16).padding(.vertical, 10)
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.tint(.indigo.opacity(0.35)).interactive(), in: .capsule)
    .accessibilityHint("Opens controller mapping")
  }
}

// MARK: - Layout editor

public struct ControllerLayoutEditor: View {
  @Bindable var session: ControllerSession
  @Environment(\.dismiss) private var dismiss
  @State private var selected: String?
  @State private var confirmReset = false

  public init(session: ControllerSession) { self.session = session }

  public var body: some View {
    GeometryReader { geo in
      let o: SkinOrientation = geo.size.width > geo.size.height ? .landscape : .portrait
      ZStack {
        LinearGradient(colors: [.black, Color(red: 0.08, green: 0.05, blue: 0.2)], startPoint: .top, endPoint: .bottom)
          .ignoresSafeArea()
        Text(o == .portrait ? "Game screen" : "Game screen (overlay)")
          .font(.headline).foregroundStyle(.white.opacity(0.25))
          .frame(maxWidth: .infinity, maxHeight: o == .portrait ? geo.size.height * 0.5 : .infinity)
          .frame(maxHeight: .infinity, alignment: .top)

        VStack(spacing: 0) {
          if o == .portrait { Spacer(minLength: geo.size.height * 0.5) }
          TouchControllerHost(
            skin: session.skin, orientation: o, overrides: session.overrides(for: o),
            settings: session.settings, isEditing: true,
            onOverridesChanged: { session.setOverrides($0, for: o) },
            onSelectionChanged: { selected = $0 })
          .frame(height: o == .portrait ? geo.size.height * 0.5 : geo.size.height)
        }
        .ignoresSafeArea(edges: .bottom)

        VStack {
          panel(o)
          Spacer()
        }
        .padding()
      }
      .confirmationDialog("Reset the \(o.rawValue) layout to default?", isPresented: $confirmReset, titleVisibility: .visible) {
        Button("Reset to Default", role: .destructive) { session.resetLayout(o); selected = nil }
      }
    }
  }

  @ViewBuilder private func panel(_ o: SkinOrientation) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Edit \(o == .portrait ? "Portrait" : "Landscape") Layout").font(.headline)
        Spacer()
        Button("Reset") { confirmReset = true }
        Button("Done") { dismiss() }.bold()
      }
      if let id = selected, let item = session.skin.layout(o).items.first(where: { $0.id == id }) {
        let current = session.overrides(for: o).items[id] ?? ItemOverride()
        Text("\(item.label ?? item.id) — drag to move, pinch to resize").font(.caption).foregroundStyle(.secondary)
        LabeledContent("Size") {
          Slider(value: Binding(get: { current.scale }, set: { v in
            var n = current; n.scale = v; var all = session.overrides(for: o); all.items[id] = n; session.setOverrides(all, for: o)
          }), in: 0.5...2.0)
        }
        LabeledContent("Opacity") {
          Slider(value: Binding(get: { current.opacity }, set: { v in
            var n = current; n.opacity = v; var all = session.overrides(for: o); all.items[id] = n; session.setOverrides(all, for: o)
          }), in: 0.1...1.0)
        }
      } else {
        Text("Tap a control to select it. Rotate the device to edit the other orientation.")
          .font(.caption).foregroundStyle(.secondary)
      }
      LabeledContent("Controller opacity") {
        let all = session.overrides(for: o)
        Slider(value: Binding(get: { all.opacity ?? session.skin.layout(o).defaultOpacity }, set: { v in
          var n = all; n.opacity = v; session.setOverrides(n, for: o)
        }), in: 0.1...1.0)
      }
    }
    .padding()
    .glassEffect(.regular, in: .rect(cornerRadius: 20))
    .frame(maxWidth: 520)
  }
}

// MARK: - Skin picker / import

public struct SkinPicker: View {
  @Bindable var session: ControllerSession
  @State private var importing = false
  @State private var error: String?

  public init(session: ControllerSession) { self.session = session }

  public static let importTypes: [UTType] = [UTType(filenameExtension: ControllerSkin.fileExtension) ?? .json, .json]

  public var body: some View {
    List {
      Section("Skins") {
        ForEach(session.skins.all) { skin in
          Button {
            session.skin = skin
          } label: {
            HStack {
              swatch(skin)
              VStack(alignment: .leading) {
                Text(skin.name)
                if let a = skin.author { Text(a).font(.caption).foregroundStyle(.secondary) }
              }
              Spacer()
              if skin.identifier == session.skin.identifier { Image(systemName: "checkmark") }
            }
          }
          .swipeActions {
            if !BuiltinSkins.all.contains(where: { $0.identifier == skin.identifier }) {
              Button("Delete", role: .destructive) {
                if session.skin.identifier == skin.identifier { session.skin = BuiltinSkins.default }
                session.skins.delete(skin)
              }
            }
          }
        }
      }
      Section {
        Button("Import Skin from Files…") { importing = true }
      } footer: {
        Text("Skins are .gcskin files (JSON). See the skin format documentation in the app's source repository.")
      }
    }
    .navigationTitle("Controller Skin")
    .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes) { result in
      do {
        let skin = try session.skins.importSkin(from: result.get())
        session.skin = skin
      } catch let e as SkinError {
        error = e.description
      } catch {
        self.error = "Couldn't read that skin file."
      }
    }
    .alert("Couldn't import skin", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK", role: .cancel) {}
    } message: { Text(error ?? "") }
  }

  private func swatch(_ s: ControllerSkin) -> some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(LinearGradient(colors: [Color(UIColor(hex: s.palette.backgroundTop)), Color(UIColor(hex: s.palette.backgroundBottom))], startPoint: .top, endPoint: .bottom))
      .overlay(alignment: .center) {
        HStack(spacing: 3) {
          Circle().fill(Color(UIColor(hex: s.palette.buttonA))).frame(width: 12)
          Circle().fill(Color(UIColor(hex: s.palette.buttonB))).frame(width: 8)
          Circle().fill(Color(UIColor(hex: s.palette.cStick))).frame(width: 8)
        }
      }
      .frame(width: 44, height: 30)
  }
}
#endif
