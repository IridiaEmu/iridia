// swift-tools-version: 6.2
// SPDX-License-Identifier: GPL-2.0-or-later
//
// IridiaStore: the one-time "Unlock Full Version" purchase (StoreKit 2) and the free 10-minute
// play session timer. Kept out of the app target so purchases, restores and refunds are tested on
// iOS Simulator with StoreKitTest against Iridia.storekit (no App Store Connect account needed),
// hosted by Tools/StoreTestHost because StoreKitTest only runs inside an app.

import PackageDescription

let package = Package(
  name: "IridiaStore",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [.library(name: "IridiaStore", targets: ["IridiaStore"])],
  targets: [
    .target(name: "IridiaStore"),
  ]
)
