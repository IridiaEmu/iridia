// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the pieces of the Wii U screen layouts: the GamePad touch view, the layout button and its menu, the
// small window's handle, the one-time tip and the layout pictures. The pictures are plain rounded rectangles
// (TV wide, GamePad screen with a darker frame), our own drawing.

#if os(iOS) && canImport(IridiaCafeCore)
import IridiaCafeCore
import SwiftUI
import UIKit

// MARK: - State

/// The play screen's layout state: the game's saved screen settings plus what is only temporary (the enlarged
/// small window, the menu, the short label after a change).
@MainActor
final class WiiUScreenModel: ObservableObject {
  let game: WiiUGame
  @Published var prefs: WiiUScreenPrefs { didSet { if persist && prefs != oldValue { prefs.save(game.settingsKey) } } }
  @Published var expanded = false
  @Published var showOptions = false
  @Published private(set) var banner: String?
  /// Test runs try layouts without saving them.
  var persist = true

  private var bannerHide: DispatchWorkItem?
  private var shrink: DispatchWorkItem?
  private let haptic = UISelectionFeedbackGenerator()

  init(game: WiiUGame) {
    self.game = game
    prefs = WiiUScreenPrefs.load(game.settingsKey, titleId: game.title.titleId)
  }

  func set(_ mode: WiiULayoutMode) {
    expanded = false
    prefs.windowHidden = false
    prefs.layout = mode
    let isPad = UIDevice.current.userInterfaceIdiom == .pad
    if mode == .split && !WiiULayoutMode.splitOffered(isPad: isPad, portrait: Self.portrait) {
      changed(String(format: L("%@ (Split shows when the iPhone is upright)"), WiiULayoutMode.pip.label))
    } else {
      changed(mode.label)
    }
  }

  static var portrait: Bool {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    guard let b = scene?.windows.first?.bounds else { return false }
    return b.height > b.width
  }

  func cycle(isPad: Bool, portrait: Bool) {
    let next = prefs.layout.next(isPad: isPad, portrait: portrait)
    set(next)
  }

  func toggleSwap() {
    expanded = false
    prefs.swap.toggle()
    changed(L("Screens swapped"))
  }

  /// A short label for a second, a light tap, and the same words for VoiceOver.
  func changed(_ text: String) {
    if UserDefaults.standard.object(forKey: "cafeHaptics") as? Bool ?? true { haptic.selectionChanged() }
    UIAccessibility.post(notification: .announcement, argument: text)
    withAnimation(.easeOut(duration: 0.15)) { banner = text }
    bannerHide?.cancel()
    let hide = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.25)) { self?.banner = nil } }
    bannerHide = hide
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: hide)
  }

  /// The small GamePad window shown large for precise touch; it shrinks back 4 s after the last touch.
  func expand() {
    withAnimation(.easeOut(duration: 0.2)) { expanded = true }
    touched()
  }

  func touched() {
    guard expanded else { return }
    shrink?.cancel()
    let s = DispatchWorkItem { [weak self] in withAnimation(.easeIn(duration: 0.2)) { self?.expanded = false } }
    shrink = s
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: s)
  }

  func collapse() {
    shrink?.cancel()
    withAnimation(.easeIn(duration: 0.2)) { expanded = false }
  }
}

// MARK: - GamePad touch

/// Over the GamePad picture (exactly its frame): the first finger (or Apple Pencil) goes to the GamePad touch
/// screen, other fingers are ignored. Every point, including the in-between points UIKit coalesces, goes to the
/// core at once (no timer), so the game reads the newest point every frame. A drag that leaves the picture stays
/// at its edge, like a finger at the edge of the real screen.
final class GamePadTouchUIView: UIView {
  /// Called when a touch starts; return false to keep this touch from the game (the first tap on a small
  /// window only enlarges it).
  var onBegin: (() -> Bool)?
  var onActivity: (() -> Void)?
  private weak var active: UITouch?
  private var sending = false
  private(set) var lastSent = CGPoint.zero

  static var live: GamePadTouchUIView? { instances.allObjects.first { $0.window != nil } }
  private static let instances = NSHashTable<GamePadTouchUIView>.weakObjects()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = false
    backgroundColor = .clear
    isAccessibilityElement = true
    accessibilityLabel = L("GamePad touch screen")
    accessibilityTraits = .allowsDirectInteraction
    Self.instances.add(self)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard active == nil, let t = touches.first else { return }
    active = t
    sending = onBegin?() ?? true
    if sending { send(t.preciseLocation(in: self), down: true) }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let t = active, touches.contains(t), sending else { return }
    for c in event?.coalescedTouches(for: t) ?? [t] { send(c.preciseLocation(in: self), down: true) }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finish(touches) }

  private func finish(_ touches: Set<UITouch>) {
    guard let t = active, touches.contains(t) else { return }
    if sending { send(t.preciseLocation(in: self), down: false) }
    active = nil
    sending = false
  }

  /// The one path every touch takes (the touch tests call it too).
  func send(_ p: CGPoint, down: Bool) {
    let n = WiiUScreenLayout.touch(p, in: bounds.size)
    lastSent = n
    CemuBridge.setTouchDown(down, x: Float(n.x), y: Float(n.y))
    onActivity?()
  }
}

struct GamePadTouchArea: UIViewRepresentable {
  var onBegin: () -> Bool = { true }
  var onActivity: () -> Void = {}

  func makeUIView(context: Context) -> GamePadTouchUIView { GamePadTouchUIView() }
  func updateUIView(_ v: GamePadTouchUIView, context: Context) {
    v.onBegin = onBegin
    v.onActivity = onActivity
  }
  static func dismantleUIView(_ v: GamePadTouchUIView, coordinator: ()) {
    CemuBridge.setTouchDown(false, x: Float(v.lastSent.x), y: Float(v.lastSent.y))
  }
}

// MARK: - Layout pictures

/// A small picture of a layout: TV picture light, GamePad picture with a darker frame.
struct WiiULayoutIcon: View {
  let mode: WiiULayoutMode
  var swap = false
  var tint: Color = WiiUTheme.accent

  var body: some View {
    GeometryReader { g in
      let w = g.size.width, h = g.size.height
      ZStack(alignment: .topLeading) {
        switch mode {
        case .tvOnly:
          tv.frame(width: w, height: h)
        case .pip:
          (swap ? AnyView(pad) : AnyView(tv)).frame(width: w, height: h)
          (swap ? AnyView(tv) : AnyView(pad)).frame(width: w * 0.42, height: h * 0.42).offset(x: w * 0.54, y: h * 0.06)
        case .gamePad:
          (swap ? AnyView(tv) : AnyView(pad)).frame(width: w, height: h)
        case .split:
          (swap ? AnyView(pad) : AnyView(tv)).frame(width: w * 0.62, height: h * 0.47).offset(x: w * 0.19)
          (swap ? AnyView(tv) : AnyView(pad)).frame(width: w * 0.62, height: h * 0.47).offset(x: w * 0.19, y: h * 0.53)
        }
      }
    }
    .aspectRatio(1.5, contentMode: .fit)
    .accessibilityHidden(true)
  }

  private var tv: some View {
    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint.opacity(0.35))
      .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(tint, lineWidth: 1.5))
  }
  private var pad: some View {
    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint)
      .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.white.opacity(0.85)).padding(3))
  }
}

// MARK: - Layout button

/// Always on screen while playing: a tap goes to the next layout, a long press opens the menu.
struct WiiULayoutButton: View {
  @ObservedObject var model: WiiUScreenModel
  let shown: WiiULayoutMode
  let isPad: Bool
  let portrait: Bool

  var body: some View {
    WiiULayoutIcon(mode: shown, swap: model.prefs.swap, tint: WiiUTheme.ink)
      .frame(width: 24)
      .frame(width: 44, height: 44)
      .background(Circle().fill(.ultraThinMaterial).opacity(0.75))
      .contentShape(Circle())
      .onLongPressGesture(minimumDuration: 0.4) {
        WiiUHaptics.tap()
        withAnimation(.easeOut(duration: 0.15)) { model.showOptions = true }
      }
      .onTapGesture { model.cycle(isPad: isPad, portrait: portrait) }
      .accessibilityElement()
      .accessibilityLabel(String(format: L("Screen layout, currently %@"), shown.label))
      .accessibilityHint(L("Double-tap for the next layout. Use the actions for all layouts."))
      .accessibilityAddTraits(.isButton)
      .accessibilityAction { model.cycle(isPad: isPad, portrait: portrait) }
      .accessibilityAction(named: L("Show all layouts")) { model.showOptions = true }
      .accessibilityAction(named: L("Swap screens")) { model.toggleSwap() }
  }
}

// MARK: - Screen options (layout menu, pause menu, game settings)

/// The four layouts as pictures, Swap screens, the on-screen buttons and motion. Edits `prefs` directly; the
/// play screen passes actions so a change there also shows its label.
struct WiiUScreenOptions: View {
  @Binding var prefs: WiiUScreenPrefs
  var isPad = UIDevice.current.userInterfaceIdiom == .pad
  var portrait = true
  var onPick: ((WiiULayoutMode) -> Void)? = nil
  var onSwap: (() -> Void)? = nil
  var onRecenter: (() -> Void)? = nil
  @AppStorage("cafeTouchOpacity") private var touchOpacity = 0.55
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 2 : 4),
                spacing: 10) {
        ForEach(WiiULayoutMode.allCases) { mode in tile(mode) }
      }
      Toggle(L("Swap screens"), isOn: Binding(get: { prefs.swap }, set: { v in
        if let onSwap, v != prefs.swap { onSwap() } else { prefs.swap = v }
      }))
      if prefs.layout == .gamePad {
        Toggle(L("Show the TV picture in a small window"), isOn: Binding(get: { prefs.tvWindowInGamePad }, set: {
          prefs.tvWindowInGamePad = $0; prefs.windowHidden = false
        }))
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(L("On-screen buttons in GamePad full screen")).font(.subheadline).foregroundStyle(WiiUTheme.soft)
        Picker(L("On-screen buttons in GamePad full screen"), selection: Binding(get: { prefs.controlsStyle }, set: { prefs.controlsStyle = $0 })) {
          ForEach(WiiUControlsStyle.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Text(L("Button visibility")).font(.subheadline).foregroundStyle(WiiUTheme.soft)
        Slider(value: $touchOpacity, in: 0.15...1)
          .accessibilityLabel(L("Button visibility"))
        Text(L("On-screen buttons hide by themselves while you use a game controller."))
          .font(.footnote).foregroundStyle(WiiUTheme.dim)
      }
      Toggle(L("Motion controls"), isOn: $prefs.motion)
      if let onRecenter, prefs.motion {
        Button(action: onRecenter) { Label(L("Recenter motion"), systemImage: "scope") }
      }
    }
    .foregroundStyle(WiiUTheme.ink)
    .tint(WiiUTheme.accent)
  }

  private func tile(_ mode: WiiULayoutMode) -> some View {
    let selected = prefs.layout == mode
    let offered = mode != .split || WiiULayoutMode.splitOffered(isPad: isPad, portrait: portrait)
    return Button {
      if let onPick { onPick(mode) } else { prefs.layout = mode; prefs.windowHidden = false }
    } label: {
      VStack(spacing: 6) {
        WiiULayoutIcon(mode: mode, swap: prefs.swap, tint: selected ? WiiUTheme.accent : WiiUTheme.soft)
          .frame(maxWidth: 64)
        Text(mode.label)
          .font(.caption.weight(selected ? .semibold : .regular))
          .multilineTextAlignment(.center)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(8)
      .frame(maxWidth: .infinity, minHeight: 44)
      .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(selected ? WiiUTheme.accent : WiiUTheme.dim.opacity(0.35), lineWidth: selected ? 2 : 1))
      .opacity(offered ? 1 : 0.55)
    }
    .buttonStyle(WiiUPress())
    .accessibilityLabel(mode.label)
    .accessibilityHint(offered ? "" : L("On iPhone, Split shows when the iPhone is upright."))
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// The menu the long press opens: a card under the layout button. A tap outside closes it.
struct WiiULayoutMenu: View {
  @ObservedObject var model: WiiUScreenModel
  let isPad: Bool
  let portrait: Bool
  let anchor: CGRect
  let size: CGSize
  var onRecenter: () -> Void

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.black.opacity(0.001)
        .onTapGesture { close() }
        .accessibilityHidden(true)
      let w = min(420, size.width - 32)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text(L("Screens")).font(.headline)
            Spacer()
            Button(L("Done")) { close() }.font(.body.weight(.semibold))
          }
          WiiUScreenOptions(prefs: $model.prefs, isPad: isPad, portrait: portrait,
                            onPick: { model.set($0) }, onSwap: { model.toggleSwap() }, onRecenter: onRecenter)
          Text(WiiUShortcut.text).font(.footnote).foregroundStyle(WiiUTheme.dim)
        }
        .padding(16)
      }
      .scrollBounceBehavior(.basedOnSize)
      .frame(width: w)
      .frame(maxHeight: size.height - anchor.maxY - 24)
      .fixedSize(horizontal: false, vertical: true)
      .wiiUSurface(radius: 20)
      .offset(x: min(max(16, anchor.minX), size.width - w - 16), y: anchor.maxY + 6)
    }
    .accessibilityAddTraits(.isModal)
    .accessibilityAction(.escape) { close() }
  }

  private func close() { withAnimation(.easeIn(duration: 0.15)) { model.showOptions = false } }
}

// MARK: - Small window handle

/// Next to the small window: drag the grip to move it (it snaps to a corner or the middle of an edge), drag the
/// size handle to resize it, or hide it. Kept outside the picture so GamePad touch isn't blocked.
struct WiiUWindowHandle: View {
  @ObservedObject var model: WiiUScreenModel
  let window: CGRect
  let size: CGSize
  let below: Bool
  @Binding var dragOffset: CGSize
  @State private var startScale: Double?

  var body: some View {
    HStack(spacing: 0) {
      Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
        .frame(width: 44, height: 30)
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .global)
          .onChanged { dragOffset = $0.translation }
          .onEnded { g in
            let c = CGPoint(x: window.midX + g.translation.width, y: window.midY + g.translation.height)
            dragOffset = .zero
            model.prefs.anchor = WiiUScreenLayout.nearestAnchor(to: c, in: size)
          })
        .accessibilityLabel(L("Move the small window"))
        .accessibilityAdjustableAction { dir in
          let all = WiiUWindowAnchor.allCases
          let i = all.firstIndex(of: model.prefs.anchor) ?? 0
          model.prefs.anchor = all[(i + (dir == .increment ? 1 : all.count - 1)) % all.count]
        }
      Image(systemName: "arrow.up.left.and.arrow.down.right")
        .frame(width: 44, height: 30)
        .contentShape(Rectangle())
        .gesture(DragGesture(coordinateSpace: .global)
          .onChanged { g in
            let s0 = startScale ?? model.prefs.windowScale
            if startScale == nil { startScale = s0 }
            let r = WiiUScreenPrefs.windowScaleRange
            model.prefs.windowScale = min(max(s0 + Double(g.translation.width + g.translation.height) / Double(size.width), r.lowerBound), r.upperBound)
          }
          .onEnded { _ in startScale = nil })
        .accessibilityLabel(L("Window size"))
        .accessibilityValue("\(Int(model.prefs.windowScale * 100))%")
        .accessibilityAdjustableAction { dir in
          let r = WiiUScreenPrefs.windowScaleRange
          model.prefs.windowScale = min(max(model.prefs.windowScale + (dir == .increment ? 0.05 : -0.05), r.lowerBound), r.upperBound)
        }
      Button { model.prefs.windowHidden = true; model.changed(L("Small window hidden")) } label: {
        Image(systemName: "eye.slash").frame(width: 44, height: 30)
      }
      .accessibilityLabel(L("Hide the small window"))
    }
    .font(.system(size: 13, weight: .semibold))
    .foregroundStyle(WiiUTheme.ink)
    .background(Capsule().fill(.ultraThinMaterial).opacity(0.85))
    .position(x: window.midX, y: below ? window.maxY + 19 : window.minY - 19)
    .offset(dragOffset)
  }
}

/// Where the hidden small window was: a button that brings it back.
struct WiiUWindowShowButton: View {
  @ObservedObject var model: WiiUScreenModel
  let at: CGPoint
  let screen: WiiUScreen

  var body: some View {
    Button { model.prefs.windowHidden = false; model.changed(L("Small window shown")) } label: {
      Image(systemName: "pip.exit")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(WiiUTheme.ink)
        .frame(width: 44, height: 44)
        .background(Circle().fill(.ultraThinMaterial).opacity(0.75))
    }
    .accessibilityLabel(screen == .gamePad ? L("Show the GamePad window") : L("Show the TV window"))
    .position(at)
  }
}

// MARK: - One-time tip

struct WiiULayoutTip: View {
  let anchor: CGRect
  let size: CGSize
  let onDone: () -> Void

  var body: some View {
    let w = min(300, size.width - 32)
    VStack(alignment: .leading, spacing: 10) {
      Text(L("Screen layout")).font(.headline)
      Text(L("Tap this button to change how the TV and GamePad screens are shown. Hold it for all the options."))
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
      Button(L("OK"), action: onDone)
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .foregroundStyle(WiiUTheme.ink)
    .tint(WiiUTheme.accent)
    .padding(16)
    .frame(width: w)
    .wiiUSurface(radius: 18)
    .overlay(alignment: .topLeading) {
      Image(systemName: "arrowtriangle.up.fill")
        .font(.system(size: 16))
        .foregroundStyle(.white.opacity(0.9))
        .offset(x: max(10, anchor.midX - min(max(16, anchor.minX - 10), size.width - w - 16) - 8), y: -12)
        .accessibilityHidden(true)
    }
    .offset(x: min(max(16, anchor.minX - 10), size.width - w - 16), y: anchor.maxY + 14)
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
  }
}
#endif
