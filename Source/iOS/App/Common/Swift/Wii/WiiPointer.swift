// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// The Wii pointer's settings in Wii Settings: its speed and whether Iridia draws where it points.
enum WiiPointer {
  private static let showKey = "wii_show_pointer"
  static let speedRange: ClosedRange<Double> = 0.5...2.0

  /// Draw a dot where the Wii Remote points (off by default: most games draw their own pointer).
  static var showPointer: Bool {
    get { UserDefaults.standard.bool(forKey: showKey) }
    set { UserDefaults.standard.set(newValue, forKey: showKey) }
  }

  /// How far the pointer moves for a drag or a turn of the phone. Each aiming mode keeps its own value;
  /// Follow your finger has none (the pointer is under the finger).
  static func speed(for mode: PointerMode) -> Double {
    switch mode {
    case .gyro: return MotionSettings.gyroPointerSensitivity()
    case .touchDrag: return Double(TouchOverlayIRGeometry.clampDragGain(MotionSettings.irPointerGain()))
    case .touchFollow: return 1
    }
  }

  static func setSpeed(_ value: Double, for mode: PointerMode) {
    let speed = min(max(value, speedRange.lowerBound), speedRange.upperBound)
    switch mode {
    case .gyro: MotionSettings.setGyroPointerSensitivity(speed)
    case .touchDrag: MotionSettings.setIRPointerGain(speed)
    case .touchFollow: return
    }
    NotificationCenter.default.post(name: Notification.Name("DOLMotionSettingsChanged"), object: nil)
  }
}

/// A dot over the game picture where the Wii Remote points, from the pointer position the touch and
/// motion aiming write (-1...1 across the picture, down and right positive).
struct WiiPointerDot: View {
  let deviceId: Int

  var body: some View {
    GeometryReader { geo in
      TimelineView(.animation) { _ in
        if let point = point(relativeTo: geo.frame(in: .global)) {
          Circle()
            .fill(.white.opacity(0.9))
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(.black.opacity(0.55), lineWidth: 2))
            .shadow(color: .black.opacity(0.4), radius: 3)
            .position(point)
        }
      }
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func point(relativeTo frame: CGRect) -> CGPoint? {
    guard let main = EmulationCoordinator.shared().mainDisplayView(), main.window != nil else { return nil }
    let video = TVEmulationBridge.currentVideoContentRect()
    let picture = main.convert(video == .zero ? main.bounds : video, to: nil)
    let rect = TouchOverlayIRGeometry.letterboxedGameRect(in: picture, aspectRatio: CGFloat(TVEmulationBridge.currentDrawAspectRatio()))
    guard rect.width > 1, rect.height > 1 else { return nil }
    let x = CGFloat(TCManagerInterface.axisValue(for: TCButtonType.wiiInfraredLeft.rawValue, controller: deviceId))
    let y = CGFloat(TCManagerInterface.axisValue(for: TCButtonType.wiiInfraredUp.rawValue, controller: deviceId))
    return CGPoint(x: rect.midX + x * rect.width / 2 - frame.minX, y: rect.midY + y * rect.height / 2 - frame.minY)
  }
}
#endif
