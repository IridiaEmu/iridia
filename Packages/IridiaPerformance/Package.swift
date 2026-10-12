// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-2.0-or-later
//
// IridiaPerformance: device tiers, performance presets, power modes, the thermal governor and
// the speed-hack catalog. Pure Swift (no UIKit), so the policy is unit-tested on macOS and the
// app shell only supplies the device model, thermal state and a way to write emulator settings.

import PackageDescription

let package = Package(
  name: "IridiaPerformance",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [.library(name: "IridiaPerformance", targets: ["IridiaPerformance"])],
  targets: [
    .target(name: "IridiaPerformance"),
    .testTarget(name: "IridiaPerformanceTests", dependencies: ["IridiaPerformance"]),
  ]
)
