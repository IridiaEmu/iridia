// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the device's motion sensors as the Wii U GamePad's gyro and accelerometer. Core Motion at 100 Hz on its
// own queue, turned into the GamePad's axes for the way the device is held, and sent straight to the core
// (which runs Cemu's sensor fusion). Off: Core Motion isn't started at all.

#if os(iOS) && canImport(IridiaCafeCore)
import CoreMotion
import IridiaCafeCore
import UIKit

final class WiiUMotion {
  static let shared = WiiUMotion()

  private let manager = CMMotionManager()
  private let queue: OperationQueue = {
    let q = OperationQueue()
    q.name = "Wii U motion"
    q.maxConcurrentOperationCount = 1
    q.qualityOfService = .userInteractive
    return q
  }()
  private var lastTimestamp: TimeInterval = 0
  /// The interface orientation, set from the main thread (read on the motion queue).
  private let orientationLock = NSLock()
  private var _orientation: UIInterfaceOrientation = .landscapeRight

  var isAvailable: Bool { manager.isDeviceMotionAvailable }
  var isRunning: Bool { manager.isDeviceMotionActive }

  func setOrientation(_ o: UIInterfaceOrientation) {
    orientationLock.lock(); _orientation = o; orientationLock.unlock()
  }

  func start() {
    guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
    lastTimestamp = 0
    manager.deviceMotionUpdateInterval = 1.0 / 100.0
    manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, _ in
      guard let self, let motion else { return }
      let dt = self.lastTimestamp == 0 ? 0.01 : min(motion.timestamp - self.lastTimestamp, 0.1)
      self.lastTimestamp = motion.timestamp
      self.orientationLock.lock(); let o = self._orientation; self.orientationLock.unlock()
      let r = motion.rotationRate
      // gravity direction plus the user's own movement, in g
      let a = (x: motion.gravity.x + motion.userAcceleration.x, y: motion.gravity.y + motion.userAcceleration.y,
               z: motion.gravity.z + motion.userAcceleration.z)
      let g = Self.toGamePad((r.x, r.y, r.z), o), acc = Self.toGamePad(a, o)
      CemuBridge.addMotionSampleDt(Float(dt), gyroX: Float(g.x), gyroY: Float(g.y), gyroZ: Float(g.z),
                                   accX: Float(acc.x), accY: Float(acc.y), accZ: Float(acc.z))
    }
  }

  func stop() {
    if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    CemuBridge.resetMotionOff(true)
  }

  func recenter() { CemuBridge.resetMotionOff(false) }

  /// Device axes (x right and y up in portrait, z out of the screen) -> the GamePad's axes as the core expects
  /// them: x to the right of the picture, y into the screen, z up along the picture.
  static func toGamePad(_ v: (x: Double, y: Double, z: Double), _ o: UIInterfaceOrientation) -> (x: Double, y: Double, z: Double) {
    let right: (Double, Double), up: (Double, Double)   // picture right and up, as device (x, y)
    switch o {
    case .landscapeRight: right = (0, -1); up = (1, 0)    // the device's top is on the left
    case .landscapeLeft: right = (0, 1); up = (-1, 0)     // the device's top is on the right
    case .portraitUpsideDown: right = (-1, 0); up = (0, -1)
    default: right = (1, 0); up = (0, 1)
    }
    return (x: v.x * right.0 + v.y * right.1, y: -v.z, z: v.x * up.0 + v.y * up.1)
  }
}
#endif
