// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the Wii U game screen. The TV and GamePad pictures in the player's layout (WiiULayout.swift), GamePad
// touch, touch controls on top (hidden once a game controller is used), the layout button, the speed readout,
// the pause menu, and the free play session.

#if os(iOS) && canImport(IridiaCafeCore)
import Combine
import GameController
import IridiaCafeCore
import IridiaStore
import SwiftUI
import UIKit

/// UIView backed by a CAMetalLayer; the core presents into it from its GPU thread.
final class WiiUMetalView: UIView {
  override class var layerClass: AnyClass { CAMetalLayer.self }
  var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
  var onLayout: ((CGSize) -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    metalLayer.contentsScale = window?.screen.nativeScale ?? traitCollection.displayScale
    onLayout?(bounds.size)
  }
}

/// The main picture (the TV, or the GamePad in GamePad full screen). Starts the game once the view has its size.
struct WiiUMetalHost: UIViewRepresentable {
  let game: WiiUGame
  /// What the main picture shows when the game starts (it can change while it runs).
  let showsGamePad: Bool
  let onLaunched: () -> Void
  @Binding var error: String?

  func makeUIView(context: Context) -> WiiUMetalView {
    let view = WiiUMetalView()
    view.backgroundColor = .black
    var launched = false
    let gamePad = showsGamePad
    view.onLayout = { size in
      guard size.width > 0, size.height > 0 else { return }
      if !launched {
        launched = true
        DispatchQueue.main.async {
          WiiUSettings.applyToEngine()
          CemuBridge.setGamePadOnMainScreen(gamePad)
          if let message = CemuBridge.launch(game.title, layer: view.metalLayer, width: Int32(size.width), height: Int32(size.height)) {
            error = message
          } else {
            onLaunched()
          }
        }
      } else {
        CemuBridge.resizeWidth(Int32(size.width), height: Int32(size.height))
      }
    }
    return view
  }

  func updateUIView(_ uiView: WiiUMetalView, context: Context) {}
}

/// The second picture (the GamePad, or the TV after Swap screens) in its own view, drawn by the core into a
/// second layer. It starts drawing once the game is running and stops when the view goes away (no cost while
/// only one picture is shown).
struct SecondScreenHost: UIViewRepresentable {
  final class Coordinator {
    var attached = false
    var gone = false
  }
  /// The view whose layer the core draws into now (a newer view takes over from an older one).
  @MainActor private static weak var current: WiiUMetalView?

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> WiiUMetalView {
    let view = WiiUMetalView()
    view.backgroundColor = .black
    let c = context.coordinator
    func attach(_ size: CGSize) {
      guard !c.attached, !c.gone, view.window != nil else { return }
      guard CemuBridge.isRunning() else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { attach(view.bounds.size) }
        return
      }
      c.attached = true
      if Self.current != nil && Self.current !== view { _ = CemuBridge.setGamePadLayer(nil, width: 0, height: 0) }
      Self.current = view
      _ = CemuBridge.setGamePadLayer(view.metalLayer, width: Int32(size.width), height: Int32(size.height))
    }
    view.onLayout = { size in
      guard size.width > 0, size.height > 0 else { return }
      if c.attached {
        CemuBridge.resizeGamePadWidth(Int32(size.width), height: Int32(size.height))
      } else {
        attach(size)
      }
    }
    return view
  }

  func updateUIView(_ uiView: WiiUMetalView, context: Context) {}

  static func dismantleUIView(_ view: WiiUMetalView, coordinator: Coordinator) {
    coordinator.gone = true
    guard coordinator.attached, current === view else { return }
    current = nil
    if CemuBridge.isRunning() { _ = CemuBridge.setGamePadLayer(nil, width: 0, height: 0) }
  }
}

struct WiiUPlayView: View {
  let game: WiiUGame
  @ObservedObject private var model = WiiUModel.shared
  @StateObject private var input = PadInput.shared
  @StateObject private var freePlay = WiiUFreePlaySession()
  @StateObject private var screens: WiiUScreenModel
  @State private var error: String?
  @State private var showPause = false
  @State private var fps: Float = 0
  @State private var windowDrag = CGSize.zero
  @State private var showTip = false
  @State private var testControlsHidden = false
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("cafeShowSpeed") private var showSpeed = true
  @AppStorage("cafeTouchOpacity") private var touchOpacity = 0.55
  @AppStorage("cafeShowLayoutButton") private var showLayoutButton = true
  @AppStorage("cafeLayoutTipShown") private var tipShown = false

  private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
  private let isPad = UIDevice.current.userInterfaceIdiom == .pad

  init(game: WiiUGame) {
    self.game = game
    _screens = StateObject(wrappedValue: WiiUScreenModel(game: game))
  }

  /// The game is held while the pause menu, the purchase screen or another app is in front.
  private var shouldPause: Bool { showPause || freePlay.showUnlock || scenePhase != .active }

  var body: some View {
    GeometryReader { outer in
      let insets = outer.safeAreaInsets
      let size = CGSize(width: outer.size.width + insets.leading + insets.trailing,
                        height: outer.size.height + insets.top + insets.bottom)
      let portrait = size.height > size.width
      let layout = WiiUScreenLayout.compute(prefs: screens.prefs, size: size,
                                            safe: (insets.top, insets.leading, insets.bottom, insets.trailing),
                                            isPad: isPad, expanded: screens.expanded)
      ZStack(alignment: .topLeading) {
        Color.black
        pictures(layout, size: size)
        if showControls(layout) {
          WiiUTouchControls(input: input, portrait: portrait, pictureBottom: layout.picturesBottom,
                            compact: !portrait && layout.mainShows == .gamePad && screens.prefs.controlsStyle == .edges,
                            menuRowY: layout.topBar.midY)
            .opacity(touchOpacity)
            .frame(width: size.width, height: size.height)
        }
        windowChrome(layout, size: size, insets: insets)
        topBar(layout, size: size, portrait: portrait)
        if screens.showOptions {
          WiiULayoutMenu(model: screens, isPad: isPad, portrait: portrait, anchor: layoutButtonFrame(layout),
                         size: size, onRecenter: recenter)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .transition(.opacity)
        }
        if showTip && showLayoutButton && !screens.showOptions {
          WiiULayoutTip(anchor: layoutButtonFrame(layout), size: size) {
            tipShown = true
            withAnimation { showTip = false }
          }
          .transition(.opacity)
        }
        banner(size: size)
        if let toast = freePlay.toast {
          Text(toast)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(WiiUTheme.ink)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .wiiUSurface(radius: 18)
            .padding(.horizontal, 24)
            .frame(width: size.width)
            .position(x: size.width / 2, y: size.height - (portrait ? 60 : 90))
            .transition(.opacity)
            .allowsHitTesting(false)
        }
        if let error {
          errorCard(error).position(x: size.width / 2, y: size.height / 2)
        }
      }
      .frame(width: size.width, height: size.height)
      .ignoresSafeArea()
      .onChange(of: layout.mainShows) { _, shows in CemuBridge.setGamePadOnMainScreen(shows == .gamePad) }
      .onChange(of: layout.second == nil ? nil : layout.secondShows) { _, shows in
        CemuBridge.setGamePadLayerShowsTV(shows == .tv)
      }
      .onChange(of: portrait, initial: true) { _, _ in updateMotionOrientation() }
      .onAppear {
        CemuBridge.setGamePadLayerShowsTV(layout.second != nil && layout.secondShows == .tv)
        initialMainShowsGamePad = layout.mainShows == .gamePad
      }
    }
    .statusBarHidden()
    .persistentSystemOverlays(.hidden)
    .claimsController()
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
      input.start()
      input.onShortcut = { [weak screens] shortcut in
        guard let screens else { return }
        switch shortcut {
        case .nextLayout: screens.cycle(isPad: isPad, portrait: WiiUScreenModel.portrait)
        case .swap: screens.toggleSwap()
        }
      }
      applyMotion()
      if !tipShown { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { showTip = true } } }
    }
    .onDisappear {
      UIApplication.shared.isIdleTimerDisabled = false
      input.onShortcut = nil
      input.stop()
      WiiUMotion.shared.stop()
      freePlay.end()
    }
    .onChange(of: screens.prefs.motion) { _, _ in applyMotion() }
    .onChange(of: shouldPause) { _, paused in
      if CemuBridge.isRunning() { CemuBridge.setPaused(paused) }
    }
    .onReceive(tick) { _ in
      fps = CemuBridge.perf().fps
      // The game ended by itself (its own exit): back to the library.
      if CemuBridge.hasGameEnded() { quit(); return }
      testHooks()
      if let coreError = CemuBridge.lastCoreError(), error == nil { error = coreError }
    }
    .sheet(isPresented: $showPause) {
      WiiUPauseSheet(game: game, screens: screens, onResume: { showPause = false },
                     onRecenter: recenter, onQuit: { showPause = false; quit() })
        .presentationDetents([.medium, .large])
        .claimsController()
    }
    .fullScreenCover(isPresented: $freePlay.showUnlock) {
      WiiUUnlockView(context: .sessionEnded,
                     onUnlocked: { freePlay.unlocked() },
                     onDismiss: { freePlay.showUnlock = false; quit() })
        .interactiveDismissDisabled(true)
        .claimsController()
    }
  }

  /// Set once, before the game starts: what the main picture shows at launch.
  @State private var initialMainShowsGamePad: Bool?

  // MARK: Pictures

  @ViewBuilder private func pictures(_ layout: WiiUScreenLayout, size: CGSize) -> some View {
    let main = layout.main
    // the main view is never rebuilt (the game draws into it); only its frame changes
    WiiUMetalHost(game: game, showsGamePad: initialMainShowsGamePad ?? (layout.mainShows == .gamePad),
                  onLaunched: { freePlay.begin() }, error: $error)
      .overlay { if layout.mainShows == .gamePad { GamePadTouchArea() } }
      .frame(width: main.width, height: main.height)
      .position(x: main.midX, y: main.midY)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(layout.mainShows == .tv ? L("TV picture") : L("GamePad picture"))
    if let second = layout.second {
      let small = layout.secondIsWindow && !screens.expanded
      let moving = layout.secondIsWindow ? windowDrag : .zero
      SecondScreenHost()
        .overlay {
          if layout.secondShows == .gamePad {
            GamePadTouchArea(onBegin: {
              // a small window: the first tap only enlarges it, so a touch never lands where it can't be seen well
              if small && second.width < size.width * 0.4 { screens.expand(); return false }
              return true
            }, onActivity: { screens.touched() })
          }
        }
        .frame(width: second.width, height: second.height)
        .clipShape(RoundedRectangle(cornerRadius: layout.secondIsWindow ? 8 : 0, style: .continuous))
        .overlay {
          if layout.secondIsWindow {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1)
              .allowsHitTesting(false)
          }
        }
        .shadow(color: .black.opacity(layout.secondIsWindow ? 0.4 : 0), radius: 8)
        .position(x: second.midX, y: second.midY)
        .offset(moving)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(layout.secondShows == .tv ? L("TV picture") : L("GamePad picture"))
    }
  }

  /// The small window's handle (or, when hidden, the button that brings it back), and the shrink button of an
  /// enlarged GamePad window.
  @ViewBuilder private func windowChrome(_ layout: WiiUScreenLayout, size: CGSize, insets: EdgeInsets) -> some View {
    if let second = layout.second, layout.secondIsWindow {
      if screens.expanded {
        Button { screens.collapse() } label: {
          Image(systemName: "arrow.down.right.and.arrow.up.left")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(WiiUTheme.ink)
            .frame(width: 44, height: 44)
            .background(Circle().fill(.ultraThinMaterial).opacity(0.85))
        }
        .accessibilityLabel(L("Make the window small again"))
        .position(x: min(second.maxX + 26, size.width - 26), y: max(second.minY + 22, 22))
      } else {
        let top = [.topLeft, .topCenter, .topRight].contains(screens.prefs.anchor)
        WiiUWindowHandle(model: screens, window: second, size: size, below: top, dragOffset: $windowDrag)
      }
    } else if screens.prefs.windowHidden, layout.shown == .pip || (layout.shown == .gamePad && screens.prefs.tvWindowInGamePad) {
      let restored = WiiUScreenLayout.compute(prefs: { var p = screens.prefs; p.windowHidden = false; return p }(),
                                              size: size, safe: (insets.top, insets.leading, insets.bottom, insets.trailing), isPad: isPad)
      if let w = restored.second {
        WiiUWindowShowButton(model: screens, at: CGPoint(x: w.midX, y: w.midY),
                             screen: restored.secondShows)
      }
    }
  }

  private func showControls(_ layout: WiiUScreenLayout) -> Bool {
    if input.controllerConnected || testControlsHidden { return false }
    if layout.mainShows == .gamePad && screens.prefs.controlsStyle == .hidden { return false }
    return true
  }

  // MARK: Top bar

  private func layoutButtonFrame(_ layout: WiiUScreenLayout) -> CGRect {
    CGRect(x: layout.topBar.minX + 16, y: layout.topBar.minY + 4, width: 44, height: 44)
  }

  private func topBar(_ layout: WiiUScreenLayout, size: CGSize, portrait: Bool) -> some View {
    HStack(spacing: 10) {
      if showLayoutButton {
        WiiULayoutButton(model: screens, shown: layout.shown, isPad: isPad, portrait: portrait)
      }
      // Free play always shows the speed, like GameCube.
      if showSpeed || freePlay.isActive {
        Text(fps > 0 ? String(format: L("%.0f fps"), fps) : L("Loading"))
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(WiiUTheme.ink)
          .padding(.horizontal, 10)
          .frame(height: 28)
          .wiiUSurface(radius: 14)
      }
      Spacer()
      Button { showPause = true } label: {
        Image(systemName: "pause.fill")
          .font(.system(size: 15, weight: .bold))
          .foregroundStyle(WiiUTheme.accent)
          .frame(width: 44, height: 44)
          .wiiUSurface(radius: 22)
      }
      .buttonStyle(WiiUPress())
      .accessibilityLabel(L("Pause menu"))
    }
    .padding(.horizontal, 16)
    .frame(width: layout.topBar.width, height: layout.topBar.height)
    .position(x: layout.topBar.midX, y: layout.topBar.midY)
  }

  @ViewBuilder private func banner(size: CGSize) -> some View {
    if let text = screens.banner {
      Text(text)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(WiiUTheme.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .wiiUSurface(radius: 18)
        .position(x: size.width / 2, y: size.height * 0.42)
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)   // VoiceOver hears it as an announcement
    }
  }

  // MARK: Motion

  private func applyMotion() {
    if screens.prefs.motion && WiiUMotion.shared.isAvailable { WiiUMotion.shared.start() } else { WiiUMotion.shared.stop() }
  }

  private func recenter() {
    WiiUMotion.shared.recenter()
    screens.changed(L("Motion recentered"))
  }

  private func updateMotionOrientation() {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    WiiUMotion.shared.setOrientation(scene?.effectiveGeometry.interfaceOrientation ?? .landscapeRight)
  }

  // MARK: Test hooks

  @State private var testSeconds = 0

  /// Test hooks (not in App Store builds): -wiiuTestPressA <s> taps A every other second for the first s seconds
  /// of play (to get past title screens), -wiiuLogPerf YES logs speed every 10 s, -wiiuTestQuitAfter <s> quits,
  /// -wiiuTouchTest <s> runs the touch-mapping test after s seconds, -wiiuDrawTest <s> draws a line then,
  /// -wiiuLayoutTour <s> goes through the layouts (and the menu) for screenshots.
  private func testHooks() {
    #if !APPSTORE
    let d = UserDefaults.standard
    guard CemuBridge.isRunning(), !CemuBridge.isPaused() else { return }
    testSeconds += 1
    if testSeconds < d.integer(forKey: "wiiuTestPressA"), testSeconds % 2 == 0 {
      input.press(.a, true)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { input.press(.a, false) }
    }
    if d.bool(forKey: "wiiuLogPerf"), testSeconds % 10 == 0 {
      let perf = CemuBridge.perf()
      NSLog("[WiiU] play %d s, %.1f fps, %u draws per frame, free play %@", testSeconds, fps, perf.drawsPerFrame,
            freePlay.isActive ? "on" : "off")
    }
    if d.integer(forKey: "wiiuTouchTest") > 0, testSeconds == d.integer(forKey: "wiiuTouchTest") {
      showTip = false
      WiiUScreenTests.touchMapping(screens: screens, hideControls: { testControlsHidden = $0 })
    }
    if d.integer(forKey: "wiiuDrawTest") > 0, testSeconds == d.integer(forKey: "wiiuDrawTest") {
      showTip = false
      WiiUScreenTests.drawLine()
    }
    if d.integer(forKey: "wiiuLayoutTour") > 0, testSeconds == d.integer(forKey: "wiiuLayoutTour") {
      showTip = false
      WiiUScreenTests.tour(screens: screens, showTip: { v in withAnimation { showTip = v } }, showPause: { v in showPause = v })
    }
    if d.integer(forKey: "wiiuTestQuitAfter") > 0, testSeconds == d.integer(forKey: "wiiuTestQuitAfter") {
      NSLog("[WiiU] test hook: quitting %@", game.name)
      quit()
    }
    #endif
  }

  private func quit() {
    freePlay.end()
    input.stop()
    WiiUMotion.shared.stop()
    model.quit()
  }

  private func errorCard(_ message: String) -> some View {
    VStack(spacing: 14) {
      Text(L("The game couldn't start")).font(.system(size: 20, weight: .semibold)).foregroundStyle(WiiUTheme.ink)
      Text(message).font(.system(size: 15)).foregroundStyle(WiiUTheme.soft).multilineTextAlignment(.center)
      Button(L("Back to Library")) { quit() }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(WiiUTheme.onAccent)
        .padding(.horizontal, 24).frame(height: 46)
        .wiiUSurface(radius: 23, prominent: true)
    }
    .padding(26)
    .frame(maxWidth: 420)
    .wiiUSurface(radius: 24)
  }
}

struct WiiUPauseSheet: View {
  let game: WiiUGame
  @ObservedObject var screens: WiiUScreenModel
  let onResume: () -> Void
  let onRecenter: () -> Void
  let onQuit: () -> Void
  @AppStorage("cafeShowSpeed") private var showSpeed = true

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(game.name).font(.title3.weight(.semibold)).foregroundStyle(WiiUTheme.ink)
        Text(L("The game is paused."))
          .font(.footnote).foregroundStyle(WiiUTheme.dim)
        Button(action: onResume) {
          Label(L("Resume"), systemImage: "play.fill")
            .font(.body.weight(.semibold)).foregroundStyle(WiiUTheme.onAccent)
            .frame(maxWidth: .infinity).frame(minHeight: 50)
            .wiiUSurface(radius: 25, prominent: true)
        }
        .buttonStyle(WiiUPress())
        VStack(alignment: .leading, spacing: 12) {
          Text(L("Screens")).font(.headline)
          WiiUScreenOptions(prefs: $screens.prefs, portrait: WiiUScreenModel.portrait,
                            onPick: { screens.set($0) }, onSwap: { screens.toggleSwap() }, onRecenter: onRecenter)
          Label(WiiUShortcut.text, systemImage: "gamecontroller")
            .font(.footnote).foregroundStyle(WiiUTheme.dim)
        }
        .foregroundStyle(WiiUTheme.ink)
        .padding(16)
        .wiiUSurface(radius: 18)
        Toggle(L("Show speed"), isOn: $showSpeed)
          .foregroundStyle(WiiUTheme.ink)
          .padding(16)
          .wiiUSurface(radius: 18)
        Button(role: .destructive, action: onQuit) {
          Label(L("Quit Game"), systemImage: "xmark")
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity).frame(minHeight: 46)
        }
        Text(L("Save in the game before you quit. Quitting keeps everything the game has saved."))
          .font(.caption).foregroundStyle(WiiUTheme.dim)
      }
      .padding(20)
    }
    .background(WiiUTheme.stage)
    .tint(WiiUTheme.accent)
  }
}

/// Wii U free play: the same FreePlayTimer as GameCube with a 20-minute limit and a 1-minute warning. Counts only
/// while the game runs and isn't paused. At the end the game is paused and muted and the purchase screen appears.
/// Wording rule (Guideline 3.1.1): a free play session that repeats without limit, never a "trial".
@MainActor
final class WiiUFreePlaySession: ObservableObject {
  static let limit: TimeInterval = 20 * 60

  @Published var showUnlock = false
  @Published private(set) var toast: String?

  private var timer = FreePlayTimer(limit: WiiUFreePlaySession.limit)
  private var ticker: Timer?
  private var last = Date()
  private var toastHide: DispatchWorkItem?

  var isActive: Bool { ticker != nil || showUnlock }

  func begin() {
    guard !IridiaUnlock.isUnlocked, ticker == nil else { return }
    timer = FreePlayTimer(limit: Self.limitOverride ?? Self.limit)
    NSLog("[WiiU] free play: session started, %.0f s", timer.limit)
    last = Date()
    post(L("Free play: 20 minutes. Unlock the full version to play as long as you like."))
    ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  func end() {
    ticker?.invalidate()
    ticker = nil
  }

  /// Bought from the purchase screen: stop counting and let the game continue.
  func unlocked() {
    end()
    showUnlock = false   // the play screen resumes the game when the screen closes
  }

  private func tick() {
    let now = Date()
    let elapsed = now.timeIntervalSince(last)
    last = now
    if IridiaUnlock.isUnlocked { unlocked(); return }   // bought elsewhere
    let playing = CemuBridge.isRunning() && !CemuBridge.isPaused()
    switch timer.tick(elapsed: elapsed, isPlaying: playing) {
    case .warning:
      NSLog("[WiiU] free play: 1 minute left")
      post(L("1 minute left in this free play session"))
    case .expired:
      NSLog("[WiiU] free play: session over, purchase screen shown")
      end()
      CemuBridge.setPaused(true)
      showUnlock = true
    case nil:
      break
    }
  }

  private func post(_ text: String) {
    withAnimation { toast = text }
    toastHide?.cancel()
    let hide = DispatchWorkItem { [weak self] in withAnimation { self?.toast = nil } }
    toastHide = hide
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: hide)
  }

  /// Test hook (non-App Store builds): `-iridiaSessionSeconds 30` shortens the session, as on GameCube.
  private static var limitOverride: TimeInterval? {
    #if APPSTORE
    return nil
    #else
    let s = UserDefaults.standard.double(forKey: "iridiaSessionSeconds")
    return s > 0 ? s : nil
    #endif
  }
}
#endif
