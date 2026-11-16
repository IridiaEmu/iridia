// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Iridia's own popup, used in place of the system alert. It's drawn like the "Welcome to Iridia" card:
// the turning cube, a title, the message and rounded buttons on a card over a dimmed screen. Three looks: the
// GameCube side's dark glass, the Wii tab's grey and white, and the Wii U tab's white and blue. Each popup gets its own window above
// everything else, so Swift, SwiftUI and Objective-C code can all show one; more than one waits its turn.

import SwiftUI
import UIKit

@objc enum IridiaAlertRole: Int {
  /// A plain choice. The first one in a popup is drawn as the main button.
  case normal
  /// Cancel, OK on a question, Not Now: drawn last and quieter.
  case cancel
  /// Delete and the like: red.
  case destructive
}

@objc(IridiaAlertButton) final class IridiaAlertButton: NSObject {
  @objc let title: String
  @objc let role: IridiaAlertRole
  let action: (() -> Void)?

  @objc init(title: String, role: IridiaAlertRole, action: (() -> Void)?) {
    self.title = title
    self.role = role
    self.action = action
  }

  convenience init(_ title: String, _ role: IridiaAlertRole = .normal, action: (() -> Void)? = nil) {
    self.init(title: title, role: role, action: action)
  }

  static func ok(_ action: (() -> Void)? = nil) -> IridiaAlertButton { IridiaAlertButton(L("OK"), action: action) }
  static func cancel(_ action: (() -> Void)? = nil) -> IridiaAlertButton { IridiaAlertButton(L("Cancel"), .cancel, action: action) }
}

@objc(IridiaAlert) final class IridiaAlert: NSObject {
  @objc enum Look: Int { case gameCube, wiiU, wii }

  /// Used instead of .gameCube while the Wii tab is showing, so shared and in-game popups match it.
  nonisolated(unsafe) static var tabLook: Look = .gameCube

  /// The optional text box: what it shows when empty and the text it starts with. What the player typed is in
  /// `text` when a button runs.
  final class Field {
    let placeholder: String
    var text: String
    init(placeholder: String, text: String) { self.placeholder = placeholder; self.text = text }
  }

  private struct Pending {
    let title: String
    let message: String?
    let buttons: [IridiaAlertButton]
    let look: Look
    let field: Field?
  }

  @MainActor private static var queue: [Pending] = []
  @MainActor private static var window: UIWindow?

  /// Shows a popup. With no buttons it gets an OK. Safe to call from any thread.
  @objc static func show(title: String, message: String?, buttons: [IridiaAlertButton], look: Look) {
    show(title: title, message: message, buttons: buttons, look: look, field: nil)
  }

  static func show(title: String, message: String?, buttons: [IridiaAlertButton], look: Look, field: Field?) {
    let pending = Pending(title: title, message: message?.isEmpty == true ? nil : message,
                          buttons: buttons.isEmpty ? [.ok()] : buttons, look: look == .gameCube ? tabLook : look,
                          field: field)
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        queue.append(pending)
        if window == nil { showNext() }
      }
    }
  }

  @objc static func show(title: String, message: String?, buttons: [IridiaAlertButton]) {
    show(title: title, message: message, buttons: buttons, look: .gameCube)
  }

  static func show(_ title: String, _ message: String? = nil, look: Look = .gameCube, buttons: [IridiaAlertButton] = []) {
    show(title: title, message: message, buttons: buttons, look: look)
  }

  /// True while a popup is up (or waiting), for code that shouldn't pile another screen on top.
  @MainActor static var isShowing: Bool { window != nil }

  @MainActor private static func showNext() {
    guard !queue.isEmpty else { return }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
      queue.removeAll(); return
    }
    let next = queue.removeFirst()
    let host = UIHostingController(rootView: IridiaAlertView(
      title: next.title, message: next.message, buttons: next.buttons, look: next.look, field: next.field,
      finish: { button in finish(button) }))
    host.view.backgroundColor = .clear
    let w = UIWindow(windowScene: scene)
    w.windowLevel = UIWindow.Level(rawValue: (scene.windows.map(\.windowLevel.rawValue).max() ?? UIWindow.Level.alert.rawValue) + 1)
    w.rootViewController = host
    w.backgroundColor = .clear
    w.makeKeyAndVisible()
    window = w
    #if !APPSTORE
    // -alertPick "Copy,Yes": a test run presses the first button with one of these titles after 3 s.
    let picks = (UserDefaults.standard.string(forKey: "alertPick") ?? "").split(separator: ",").map(String.init)
    if let button = next.buttons.first(where: { picks.contains($0.title) }) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if window === w { finish(button) } }
    }
    #endif
  }

  @MainActor private static func finish(_ button: IridiaAlertButton) {
    window?.isHidden = true
    window = nil
    button.action?()
    showNext()
  }
}

// MARK: - The card

private struct IridiaAlertView: View {
  let title: String
  let message: String?
  let buttons: [IridiaAlertButton]
  let look: IridiaAlert.Look
  let field: IridiaAlert.Field?
  let finish: (IridiaAlertButton) -> Void
  @State private var shown = false
  @State private var chosen = false
  @State private var typed = ""
  @FocusState private var typing: Bool

  private var isWiiU: Bool { look != .gameCube }
  private var ink: Color { Self.ink(look) }
  private var soft: Color { Self.soft(look) }
  private var accent: Color { Self.accent(look) }

  /// Main choices first, in order; Cancel and the like at the bottom.
  private var ordered: [IridiaAlertButton] { buttons.filter { $0.role != .cancel } + buttons.filter { $0.role == .cancel } }
  private var main: IridiaAlertButton? { buttons.first { $0.role == .normal } }

  var body: some View {
    ZStack {
      Color.black.opacity(shown ? (isWiiU ? 0.32 : 0.5) : 0).ignoresSafeArea()
      card
        .scaleEffect(shown ? 1 : 0.94)
        .opacity(shown ? 1 : 0)
    }
    .onAppear {
      typed = field?.text ?? ""
      withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { shown = true }
      if field != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { typing = true } }
    }
  }

  private var card: some View {
    VStack(spacing: 16) {
      IridiaCubeView()
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
      Text(title)
        .font(.title3).fontWeight(.bold)
        .foregroundStyle(ink)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      if let message {
        ViewThatFits(in: .vertical) {
          messageText(message)
          ScrollView { messageText(message) }.frame(maxHeight: 320)
        }
      }
      if let field {
        TextField(field.placeholder, text: $typed)
          .focused($typing)
          .submitLabel(.done)
          .foregroundStyle(ink)
          .padding(.horizontal, 12).padding(.vertical, 10)
          .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isWiiU ? accent.opacity(0.08) : Color.white.opacity(0.12)))
      }
      VStack(spacing: 10) {
        ForEach(Array(ordered.enumerated()), id: \.offset) { _, button in
          buttonView(button)
        }
      }
      .padding(.top, 4)
    }
    .padding(22)
    .frame(maxWidth: 380)
    .modifier(IridiaCard(look: look))
    .padding(.horizontal, 24)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
    .accessibilityIdentifier("IridiaAlert")
  }

  private func messageText(_ text: String) -> some View {
    Text(text)
      .font(.subheadline)
      .foregroundStyle(soft)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 4)
  }

  private func buttonView(_ button: IridiaAlertButton) -> some View {
    let kind: PopupButtonStyle.Kind = button.role == .destructive ? .destructive : (button === main ? .main : .plain)
    return Button {
      guard !chosen else { return }
      chosen = true
      field?.text = typed
      typing = false
      withAnimation(.easeOut(duration: 0.16)) { shown = false }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) { finish(button) }
    } label: {
      Text(button.title)
        .font(.body.weight(.semibold))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 24)
    }
    .buttonStyle(PopupButtonStyle(kind: kind, look: look))
  }

  fileprivate static func ink(_ look: IridiaAlert.Look) -> Color {
    look == .wii ? wiiInk : look == .wiiU ? wiiUInk : Color(red: 0.93, green: 0.91, blue: 1.0)
  }
  fileprivate static func soft(_ look: IridiaAlert.Look) -> Color {
    look == .wii ? wiiSoft : look == .wiiU ? wiiUSoft : Color(red: 0.76, green: 0.73, blue: 0.96)
  }

  // The Wii U tab's colors (WiiUTheme, light), kept here so the GameCube-only build has them too.
  fileprivate static let wiiUBlue = Color(red: 0.0, green: 0.47, blue: 0.90)
  private static let wiiUInk = Color(red: 0.08, green: 0.15, blue: 0.26)
  private static let wiiUSoft = Color(red: 0.30, green: 0.40, blue: 0.52)
  fileprivate static let wiiUCardBottom = Color(red: 0.94, green: 0.96, blue: 0.99)
  // The Wii tab's (WiiTheme, light): grey and white.
  fileprivate static let wiiGrey = Color(red: 0.40, green: 0.42, blue: 0.46)
  private static let wiiInk = Color(red: 0.13, green: 0.14, blue: 0.16)
  private static let wiiSoft = Color(red: 0.36, green: 0.38, blue: 0.41)
  fileprivate static let wiiCardBottom = Color(red: 0.945, green: 0.948, blue: 0.955)
  fileprivate static let wiiShadow = Color(red: 0.20, green: 0.22, blue: 0.26).opacity(0.22)
  fileprivate static func accent(_ look: IridiaAlert.Look) -> Color { look == .wii ? wiiGrey : wiiUBlue }
  fileprivate static let wiiUShadow = Color(red: 0.10, green: 0.30, blue: 0.55).opacity(0.25)
}

/// The card itself: the shelf's indigo glass on the GameCube side, white on the Wii and Wii U tabs.
private struct IridiaCard: ViewModifier {
  let look: IridiaAlert.Look

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    let light = look != .gameCube
    content
      .background(background(shape))
      .overlay(shape.strokeBorder(light ? AnyShapeStyle(IridiaAlertView.accent(look).opacity(0.22))
                                        : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)],
                                                                       startPoint: .top, endPoint: .bottom)), lineWidth: 1))
      .environment(\.colorScheme, light ? .light : .dark)
  }

  @ViewBuilder private func background(_ shape: RoundedRectangle) -> some View {
    if look != .gameCube {
      shape.fill(LinearGradient(colors: [.white, look == .wii ? IridiaAlertView.wiiCardBottom : IridiaAlertView.wiiUCardBottom],
                                startPoint: .top, endPoint: .bottom))
        .shadow(color: look == .wii ? IridiaAlertView.wiiShadow : IridiaAlertView.wiiUShadow, radius: 20, x: 0, y: 10)
    } else {
      shape.fill(.ultraThinMaterial)
        .overlay(shape.fill(LinearGradient(colors: [Color(red: 0.20, green: 0.15, blue: 0.48).opacity(0.85),
                                                    Color(red: 0.08, green: 0.05, blue: 0.20).opacity(0.92)],
                                           startPoint: .top, endPoint: .bottom)))
        .shadow(color: Color(red: 0.49, green: 0.42, blue: 0.94).opacity(0.30), radius: 26, x: 0, y: 12)
    }
  }
}

// MARK: - Unpacking progress

/// A small card at the bottom of the screen while an archive unpacks: its name, how far it has got, about how
/// long is left, and Cancel. It doesn't block the screen behind it.
@MainActor final class UnpackCard: ObservableObject {
  static let shared = UnpackCard()

  @Published fileprivate var name = ""
  @Published fileprivate var fraction = 0.0
  @Published fileprivate var secondsLeft: Double?
  @Published fileprivate var cancelling = false
  fileprivate var look: IridiaAlert.Look = .gameCube
  /// Where the card is on screen; touches anywhere else go to the screen underneath.
  fileprivate var cardFrame: CGRect = .zero
  private var progress: UnpackProgress?
  private var started = Date()
  private var timer: Timer?
  private var window: UIWindow?

  /// Safe to call from any thread.
  nonisolated static func begin(_ name: String, progress: UnpackProgress, look: IridiaAlert.Look) {
    DispatchQueue.main.async { MainActor.assumeIsolated { shared.show(name, progress, look) } }
  }

  nonisolated static func end() {
    DispatchQueue.main.async { MainActor.assumeIsolated { shared.hide() } }
  }

  private func show(_ name: String, _ progress: UnpackProgress, _ look: IridiaAlert.Look) {
    self.name = name
    self.progress = progress
    self.look = look == .gameCube ? IridiaAlert.tabLook : look
    fraction = 0
    secondsLeft = nil
    cancelling = false
    started = Date()
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
      MainActor.assumeIsolated { UnpackCard.shared.update() }
    }
    guard window == nil else { return }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
    let host = UIHostingController(rootView: UnpackCardView(card: self))
    host.view.backgroundColor = .clear
    let w = PassThroughWindow(windowScene: scene)
    w.windowLevel = .alert
    w.rootViewController = host
    w.backgroundColor = .clear
    w.isHidden = false
    window = w
  }

  private func hide() {
    cardFrame = .zero
    timer?.invalidate()
    timer = nil
    progress = nil
    window?.isHidden = true
    window = nil
  }

  private func update() {
    guard let progress else { return }
    fraction = progress.fraction
    let elapsed = Date().timeIntervalSince(started)
    secondsLeft = elapsed > 3 && fraction > 0.01 ? elapsed / fraction * (1 - fraction) : nil
  }

  fileprivate func cancel() {
    cancelling = true
    progress?.cancel()
  }
}

/// Touches outside the card reach the screen underneath.
private final class PassThroughWindow: UIWindow {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard MainActor.assumeIsolated({ UnpackCard.shared.cardFrame.contains(point) }) else { return nil }
    return super.hitTest(point, with: event)
  }
}

private struct UnpackCardView: View {
  @ObservedObject var card: UnpackCard
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  var body: some View {
    GeometryReader { geo in
      content(ShelfScale.value(geo.size, regular: horizontalSizeClass == .regular))
    }
  }

  /// `u` is the shelf's iPad scale, so the card clears the tab bar, which grows with it.
  private func content(_ u: CGFloat) -> some View {
    VStack {
      Spacer()
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text(card.cancelling ? L("Cancelling...") : String(format: L("Unpacking %@"), card.name))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(IridiaAlertView.ink(card.look))
            .lineLimit(1)
            .truncationMode(.middle)
          ProgressView(value: card.fraction)
            .tint(card.look == .gameCube ? Color(red: 0.70, green: 0.64, blue: 1.0) : IridiaAlertView.accent(card.look))
          Text(detail)
            .font(.caption)
            .foregroundStyle(IridiaAlertView.soft(card.look))
            .monospacedDigit()
        }
        Button(L("Cancel")) { card.cancel() }
          .font(.subheadline.weight(.semibold))
          .buttonStyle(PopupButtonStyle(kind: .plain, look: card.look))
          .fixedSize()
          .disabled(card.cancelling)
          .accessibilityIdentifier("UnpackCancel")
      }
      .padding(16)
      .frame(maxWidth: 420 * u)
      .modifier(IridiaCard(look: card.look))
      .background(GeometryReader { g in
        Color.clear
          .onAppear { card.cardFrame = g.frame(in: .global) }
          .onChange(of: g.frame(in: .global)) { _, frame in card.cardFrame = frame }
      })
      .padding(.horizontal, 16)
      .padding(.bottom, 96 * u)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("UnpackCard")
  }

  private var detail: String {
    let percent = "\(Int((card.fraction * 100).rounded(.down)))%"
    guard let left = card.secondsLeft else { return percent }
    let time = left < 60 ? L("less than a minute left")
      : String(format: L("about %d min left"), Int((left / 60).rounded(.up)))
    return "\(percent), \(time)"
  }
}

/// The popup's buttons, drawn like the shelf's: the main one filled (lavender glass on the GameCube side, the
/// blue gradient on the Wii U tab), the rest plain glass or white, Delete and the like in red.
private struct PopupButtonStyle: ButtonStyle {
  enum Kind { case main, plain, destructive }
  let kind: Kind
  let look: IridiaAlert.Look

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    configuration.label
      .foregroundStyle(text)
      .padding(.vertical, 13).padding(.horizontal, 16)
      .background(shape.fill(fill))
      .overlay(shape.strokeBorder(rim, lineWidth: 1))
      .shadow(color: glow, radius: kind == .plain ? 0 : 10, y: kind == .plain ? 0 : 5)
      .scaleEffect(configuration.isPressed ? 0.97 : 1)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
      .contentShape(shape)
  }

  private var wiiU: Bool { look != .gameCube }
  private var accent: Color { IridiaAlertView.accent(look) }

  private var text: Color {
    switch kind {
    case .main: return wiiU ? .white : Color(red: 0.07, green: 0.04, blue: 0.20)
    case .plain: return wiiU ? accent : Color(red: 0.93, green: 0.91, blue: 1.0)
    case .destructive: return .white
    }
  }

  private var fill: AnyShapeStyle {
    func gradient(_ colors: [Color]) -> AnyShapeStyle {
      AnyShapeStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
    }
    switch (kind, wiiU) {
    case (.main, false):
      return gradient([Color(red: 0.84, green: 0.80, blue: 1.0), Color(red: 0.61, green: 0.55, blue: 1.0), Color(red: 0.43, green: 0.36, blue: 0.90)])
    case (.main, true) where look == .wii:
      return gradient([Color(red: 0.58, green: 0.60, blue: 0.63), Color(red: 0.40, green: 0.42, blue: 0.46)])
    case (.main, true):
      return gradient([Color(red: 0.24, green: 0.64, blue: 1.0), Color(red: 0.0, green: 0.47, blue: 0.90)])
    case (.plain, false):
      return gradient([.white.opacity(0.20), .white.opacity(0.06)])
    case (.plain, true) where look == .wii:
      return gradient([.white, Color(red: 0.95, green: 0.953, blue: 0.96)])
    case (.plain, true):
      return gradient([.white, Color(red: 0.93, green: 0.96, blue: 1.0)])
    case (.destructive, _):
      return gradient([Color(red: 1.0, green: 0.45, blue: 0.48), Color(red: 0.82, green: 0.20, blue: 0.27)])
    }
  }

  private var rim: AnyShapeStyle {
    if wiiU, kind == .plain { return AnyShapeStyle(accent.opacity(0.28)) }
    return AnyShapeStyle(LinearGradient(colors: [.white.opacity(kind == .plain ? 0.45 : 0.80), .white.opacity(0.08)],
                                        startPoint: .top, endPoint: .bottom))
  }

  private var glow: Color {
    switch kind {
    case .main: return wiiU ? accent.opacity(0.35) : Color(red: 0.49, green: 0.42, blue: 0.94).opacity(0.5)
    case .plain: return .clear
    case .destructive: return Color(red: 0.82, green: 0.20, blue: 0.27).opacity(0.35)
    }
  }
}

// MARK: - SwiftUI

extension View {
  /// Like `.alert(_:isPresented:)`, drawn as an Iridia popup. The buttons and message are read when it opens.
  func iridiaAlert(_ title: String, isPresented: Binding<Bool>, look: IridiaAlert.Look = .gameCube,
                   message: @escaping () -> String? = { nil },
                   buttons: @escaping () -> [IridiaAlertButton] = { [] }) -> some View {
    modifier(IridiaAlertModifier(isPresented: isPresented, open: {
      IridiaAlert.show(title: title, message: message(), buttons: Self.closing(buttons(), isPresented), look: look)
    }))
  }

  /// The `.alert(_:isPresented:presenting:)` form: open while `item` isn't nil, which is cleared on any choice.
  func iridiaAlert<T>(item: Binding<T?>, look: IridiaAlert.Look = .gameCube, title: @escaping (T) -> String,
                      message: @escaping (T) -> String? = { _ in nil },
                      buttons: @escaping (T) -> [IridiaAlertButton] = { _ in [] }) -> some View {
    let shown = Binding<Bool>(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    return modifier(IridiaAlertModifier(isPresented: shown, open: {
      guard let value = item.wrappedValue else { return }
      IridiaAlert.show(title: title(value), message: message(value), buttons: Self.closing(buttons(value), shown), look: look)
    }))
  }

  /// A popup with a text box (Rename and the like). `onConfirm` gets what was typed.
  func iridiaPrompt<T>(item: Binding<T?>, look: IridiaAlert.Look = .gameCube, title: String, placeholder: String,
                       text: @escaping (T) -> String, confirm: String,
                       onConfirm: @escaping (T, String) -> Void) -> some View {
    let shown = Binding<Bool>(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    return modifier(IridiaAlertModifier(isPresented: shown, open: {
      guard let value = item.wrappedValue else { return }
      let field = IridiaAlert.Field(placeholder: placeholder, text: text(value))
      let buttons = [IridiaAlertButton(confirm) { onConfirm(value, field.text) }, .cancel()]
      IridiaAlert.show(title: title, message: nil, buttons: Self.closing(buttons, shown), look: look, field: field)
    }))
  }

  fileprivate static func closing(_ buttons: [IridiaAlertButton], _ isPresented: Binding<Bool>) -> [IridiaAlertButton] {
    (buttons.isEmpty ? [.ok()] : buttons).map { b in
      // The action first: it may still read the state the popup was opened for.
      IridiaAlertButton(title: b.title, role: b.role) { b.action?(); isPresented.wrappedValue = false }
    }
  }
}

private struct IridiaAlertModifier: ViewModifier {
  let isPresented: Binding<Bool>
  let open: () -> Void

  func body(content: Content) -> some View {
    content
      .onChange(of: isPresented.wrappedValue) { _, on in if on { open() } }
      .onAppear { if isPresented.wrappedValue { open() } }
  }
}
