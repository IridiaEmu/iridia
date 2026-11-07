// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the Wii U game screen. A Metal layer the core draws into, touch controls on top (hidden once a game
// controller is used), the speed readout, the pause menu, and the free play session.

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

/// The TV picture. Starts the game once the view has its real size.
struct WiiUMetalHost: UIViewRepresentable {
  let game: WiiUGame
  let onLaunched: () -> Void
  @Binding var error: String?

  func makeUIView(context: Context) -> WiiUMetalView {
    let view = WiiUMetalView()
    view.backgroundColor = .black
    var launched = false
    view.onLayout = { size in
      guard size.width > 0, size.height > 0 else { return }
      if !launched {
        launched = true
        DispatchQueue.main.async {
          WiiUSettings.applyToEngine()
          CemuBridge.setGamePadOnMainScreen(UserDefaults.standard.string(forKey: "cafeGamePadScreen") == GamePadScreen.main.rawValue)
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

/// The GamePad's own screen in a second view (setting "GamePad screen: Small window"). Starts drawing once the game
/// is running.
struct GamePadHost: UIViewRepresentable {
  func makeUIView(context: Context) -> WiiUMetalView {
    let view = WiiUMetalView()
    view.backgroundColor = .black
    var attached = false
    func attach(_ size: CGSize) {
      guard !attached, view.window != nil else { return }
      guard CemuBridge.isRunning() else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { attach(view.bounds.size) }
        return
      }
      attached = true
      _ = CemuBridge.setGamePadLayer(view.metalLayer, width: Int32(size.width), height: Int32(size.height))
    }
    view.onLayout = { size in
      guard size.width > 0, size.height > 0 else { return }
      if attached {
        CemuBridge.resizeGamePadWidth(Int32(size.width), height: Int32(size.height))
      } else {
        attach(size)
      }
    }
    return view
  }

  func updateUIView(_ uiView: WiiUMetalView, context: Context) {}
}

/// Sends touches on the GamePad picture to the game's GamePad touch screen. The picture is drawn aspect-fit
/// (854 x 480) and centered in this area, like the core draws it.
struct GamePadTouchArea: View {
  var body: some View {
    GeometryReader { geo in
      Color.clear
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
          .onChanged { value in
            let size = geo.size
            let scale = min(size.width / 854, size.height / 480)
            let w = 854 * scale, h = 480 * scale
            let x = (value.location.x - (size.width - w) / 2) / w
            let y = (value.location.y - (size.height - h) / 2) / h
            if x >= 0, x <= 1, y >= 0, y <= 1 {
              CemuBridge.setTouchDown(true, x: Float(x), y: Float(y))
            } else {
              CemuBridge.setTouchDown(false, x: 0, y: 0)
            }
          }
          .onEnded { _ in CemuBridge.setTouchDown(false, x: 0, y: 0) })
    }
  }
}

struct WiiUPlayView: View {
  let game: WiiUGame
  @ObservedObject private var model = WiiUModel.shared
  @StateObject private var input = PadInput.shared
  @StateObject private var freePlay = WiiUFreePlaySession()
  @State private var error: String?
  @State private var showPause = false
  @State private var fps: Float = 0
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("cafeShowSpeed") private var showSpeed = true
  @AppStorage("cafeTouchOpacity") private var touchOpacity = 0.55
  @AppStorage("cafeGamePadScreen") private var gamePadScreen = GamePadScreen.off.rawValue

  private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  /// The game is held while the pause menu, the purchase screen or another app is in front.
  private var shouldPause: Bool { showPause || freePlay.showUnlock || scenePhase != .active }

  var body: some View {
    GeometryReader { geo in
      let portrait = geo.size.height > geo.size.width
      ZStack {
        Color.black.ignoresSafeArea()
        // Portrait: the picture at full width at the top (16:9), controls in the space below. Landscape: full screen.
        VStack(spacing: 0) {
          WiiUMetalHost(game: game, onLaunched: { freePlay.begin() }, error: $error)
            .overlay { if gamePadScreen == GamePadScreen.main.rawValue { GamePadTouchArea() } }
            .frame(height: portrait ? geo.size.width * 9 / 16 : nil)
            .padding(.top, portrait ? geo.safeAreaInsets.top : 0)
          if portrait { Spacer(minLength: 0) }
        }
        .ignoresSafeArea()
        if gamePadScreen == GamePadScreen.window.rawValue {
          // GamePad screen in a small window: below the picture in portrait, top center in landscape
          let w = portrait ? geo.size.width * 0.5 : geo.size.width * 0.3
          GamePadHost()
            .overlay { GamePadTouchArea() }
            .frame(width: w, height: w * 480 / 854)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .position(x: geo.size.width / 2, y: portrait ? geo.size.width * 9 / 16 + w * 240 / 854 + 12 : w * 240 / 854 + 8)
        }
        if !input.controllerConnected {
          WiiUTouchControls(input: input, portrait: portrait, pictureBottom: geo.size.width * 9 / 16)
            .opacity(touchOpacity)
        }
        topBar
        if let toast = freePlay.toast {
          VStack {
            Spacer()
            Text(toast)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(WiiUTheme.ink)
              .multilineTextAlignment(.center)
              .padding(.horizontal, 16)
              .padding(.vertical, 10)
              .wiiUSurface(radius: 18)
              .padding(.horizontal, 24)
              .padding(.bottom, portrait ? 24 : 70)
          }
          .transition(.opacity)
          .allowsHitTesting(false)
        }
        if let error { errorCard(error) }
      }
    }
    .statusBarHidden()
    .persistentSystemOverlays(.hidden)
    .claimsController()
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
      input.start()
    }
    .onDisappear {
      UIApplication.shared.isIdleTimerDisabled = false
      input.stop()
      freePlay.end()
    }
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
      WiiUPauseSheet(game: game, onResume: { showPause = false }, onQuit: { showPause = false; quit() })
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

  @State private var testSeconds = 0

  /// Test hooks (not in App Store builds): -wiiuTestPressA <s> taps A every other second for the first s seconds
  /// of play (to get past title screens), -wiiuLogPerf YES logs speed every 10 s, -wiiuTestQuitAfter <s> quits.
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
    if d.integer(forKey: "wiiuTestQuitAfter") > 0, testSeconds == d.integer(forKey: "wiiuTestQuitAfter") {
      NSLog("[WiiU] test hook: quitting %@", game.name)
      quit()
    }
    #endif
  }

  private func quit() {
    freePlay.end()
    input.stop()
    model.quit()
  }

  private var topBar: some View {
    VStack {
      HStack(spacing: 10) {
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
            .frame(width: 40, height: 40)
            .wiiUSurface(radius: 20)
        }
        .buttonStyle(WiiUPress())
        .accessibilityLabel(L("Pause menu"))
      }
      .padding(.horizontal, 16)
      .padding(.top, 6)
      Spacer()
    }
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
  let onResume: () -> Void
  let onQuit: () -> Void
  @AppStorage("cafeShowSpeed") private var showSpeed = true
  @AppStorage("cafeTouchOpacity") private var touchOpacity = 0.55

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(game.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(WiiUTheme.ink)
      Text(L("The game is paused."))
        .font(.system(size: 13)).foregroundStyle(WiiUTheme.dim)
      Button(action: onResume) {
        Label(L("Resume"), systemImage: "play.fill")
          .font(.system(size: 17, weight: .semibold)).foregroundStyle(WiiUTheme.onAccent)
          .frame(maxWidth: .infinity).frame(height: 50)
          .wiiUSurface(radius: 25, prominent: true)
      }
      .buttonStyle(WiiUPress())
      VStack(alignment: .leading, spacing: 12) {
        Toggle(L("Show speed"), isOn: $showSpeed)
        VStack(alignment: .leading) {
          Text(L("Touch controls")).font(.system(size: 14)).foregroundStyle(WiiUTheme.soft)
          Slider(value: $touchOpacity, in: 0.15...1)
        }
      }
      .foregroundStyle(WiiUTheme.ink)
      .padding(16)
      .wiiUSurface(radius: 18)
      Button(role: .destructive, action: onQuit) {
        Label(L("Quit Game"), systemImage: "xmark")
          .font(.system(size: 16, weight: .semibold))
          .frame(maxWidth: .infinity).frame(height: 46)
      }
      Text(L("Save in the game before you quit. Quitting keeps everything the game has saved."))
        .font(.system(size: 12)).foregroundStyle(WiiUTheme.dim)
      Spacer(minLength: 0)
    }
    .padding(20)
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
