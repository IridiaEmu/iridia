// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: our on-screen GameCube controller (Packages/GCControls) inside the iCube
// baseline app, replacing iCube's TCGameCubePad. It feeds iCube's existing input
// path (TCManagerInterface), sending only the inputs that changed.
//
// Temporary bridge until our own app shell (Phase 5) and the lock-free core read
// of gcpad_read (Phase 4) replace this path.

#if os(iOS)
import GCControlsCore
import GCControlsUI
import UIKit

final class GCEmuTouchPadView: UIView {
  /// Touchscreen controller port, assigned by the emulation screen.
  var port: Int = 0 {
    didSet {
      guard oldValue != port else { return }
      TCManagerInterface.clearAll(forController: oldValue)
      last = PadState.neutralPacked
      send(current)
    }
  }

  private let pad = TouchControllerView(frame: .zero)
  private let overrideStore = LayoutOverrideStore(directory: LayoutOverrideStore.defaultDirectory())
  private var last = PadState.neutralPacked
  private var current = PadState.neutralPacked
  private var loadedOrientation: SkinOrientation?

  // iCube's GameCube button IDs (TCButtonType).
  private static let buttonIDs: [(GCButtons, Int)] = [
    (.a, TCButtonType.gcButtonA.rawValue), (.b, TCButtonType.gcButtonB.rawValue),
    (.start, TCButtonType.gcButtonStart.rawValue), (.x, TCButtonType.gcButtonX.rawValue),
    (.y, TCButtonType.gcButtonY.rawValue), (.z, TCButtonType.gcButtonZ.rawValue),
    (.dpadUp, TCButtonType.gcButtonUp.rawValue), (.dpadDown, TCButtonType.gcButtonDown.rawValue),
    (.dpadLeft, TCButtonType.gcButtonLeft.rawValue), (.dpadRight, TCButtonType.gcButtonRight.rawValue),
  ]

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isMultipleTouchEnabled = true
    pad.skin = BuiltinSkins.default
    pad.onStateChange = { [weak self] packed in self?.send(packed) }
    pad.onMenu = { NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil) }
    pad.settings.hapticsEnabled = IridiaHaptics.enabled
    addSubview(pad)
    // Follow Settings > Controllers > Vibration, also when it's changed from the pause menu mid-game.
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.pad.settings.hapticsEnabled != IridiaHaptics.enabled else { return }
        self.pad.settings.hapticsEnabled = IridiaHaptics.enabled
      }
    }
  }

  private var defaultsObserver: NSObjectProtocol?

  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let o: SkinOrientation = bounds.width > bounds.height ? .landscape : .portrait
    if loadedOrientation != o {  // only on rotation, never per frame
      loadedOrientation = o
      pad.orientation = o
      pad.overrides = overrideStore.load(skin: pad.skin.identifier, orientation: o)
    }
    // Portrait: controller fills the bottom half. Landscape: overlay on the whole screen.
    pad.frame = o == .portrait
      ? CGRect(x: 0, y: bounds.height * 0.5, width: bounds.width, height: bounds.height * 0.5)
      : bounds
  }

  /// Only touches that land on our controls are ours; everything else reaches the
  /// game view and iCube's gestures underneath.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let p = convert(point, to: pad)
    return pad.point(inside: p, with: event) ? pad.hitTest(p, with: event) : nil
  }

  override func willMove(toSuperview newSuperview: UIView?) {
    super.willMove(toSuperview: newSuperview)
    if newSuperview == nil { release() }
  }

  deinit {
    if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    let p = port
    DispatchQueue.main.async { TCManagerInterface.clearAll(forController: p) }
  }

  private func release() {
    TCManagerInterface.clearAll(forController: port)
    last = PadState.neutralPacked
    current = PadState.neutralPacked
  }

  // MARK: PadState → TCManagerInterface (diffed)

  private func send(_ packed: UInt64) {
    current = packed
    guard packed != last else { return }
    let new = PadState(packed: packed), old = PadState(packed: last)
    last = packed

    if new.buttons != old.buttons {
      for (bit, id) in Self.buttonIDs where new.buttons.contains(bit) != old.buttons.contains(bit) {
        TCManagerInterface.setButtonStateFor(id, controller: port, state: new.buttons.contains(bit))
      }
    }
    if new.stickX != old.stickX || new.stickY != old.stickY {
      sendStick(base: TCButtonType.gcStickMain.rawValue, x: new.stickX, y: new.stickY)
    }
    if new.cStickX != old.cStickX || new.cStickY != old.cStickY {
      sendStick(base: TCButtonType.gcStickC.rawValue, x: new.cStickX, y: new.cStickY)
    }
    sendTrigger(TCButtonType.gcTriggerL.rawValue, new.triggerL, old.triggerL, click: new.buttons.contains(.l), wasClick: old.buttons.contains(.l))
    sendTrigger(TCButtonType.gcTriggerR.rawValue, new.triggerR, old.triggerR, click: new.buttons.contains(.r), wasClick: old.buttons.contains(.r))
  }

  /// iCube/Android ButtonManager convention: base+1…+4 = up, down, left, right, each
  /// carrying the signed axis value in screen space (+y = down), as TCJoystick sends it.
  private func sendStick(base: Int, x: UInt8, y: UInt8) {
    let fx = Float(Int(x) - 128) / 127
    let fy = -Float(Int(y) - 128) / 127  // PadState +y = up → screen +y = down
    let axes = [min(fy, 0), min(fy, 1), min(fx, 0), min(fx, 1)]
    for (i, v) in axes.enumerated() {
      TCManagerInterface.setAxisValueFor(base + i + 1, controller: port, value: max(-1, min(1, v)))
    }
  }

  private func sendTrigger(_ id: Int, _ v: UInt8, _ old: UInt8, click: Bool, wasClick: Bool) {
    if v != old { TCManagerInterface.setAxisValueFor(id, controller: port, value: Float(v) / 255) }
    if click != wasClick { TCManagerInterface.setButtonStateFor(id, controller: port, state: click) }
  }
}
#endif
