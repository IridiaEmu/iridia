// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-2.0-or-later
//
// GCControls: on-screen touch controller, physical-controller mapping, and the
// lock-free pad state the emulation thread reads. Independent of any app shell.

import PackageDescription

let package = Package(
  name: "GCControls",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "GCControlsCore", targets: ["GCControlsCore"]),
    .library(name: "GCControlsUI", targets: ["GCControlsUI"]),
  ],
  targets: [
    // Pure Swift: no UIKit, testable on macOS. Hot-path code lives here.
    .target(
      name: "GCControlsCore",
      swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
    ),
    .target(
      name: "GCControlsUI",
      dependencies: ["GCControlsCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(name: "GCControlsCoreTests", dependencies: ["GCControlsCore"]),
  ]
)
