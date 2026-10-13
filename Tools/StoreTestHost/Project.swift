// SPDX-License-Identifier: GPL-2.0-or-later
// Test host for Packages/IridiaStore: StoreKitTest (SKTestSession) only works inside an app.
//   cd Tools/StoreTestHost && tuist generate --no-open
//   xcodebuild test -workspace StoreTestHost.xcworkspace -scheme StoreTestHost -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
import ProjectDescription

let project = Project(
  name: "StoreTestHost",
  packages: [.local(path: "../../Packages/IridiaStore")],
  targets: [
    .target(name: "StoreTestHost", destinations: .iOS, product: .app,
            bundleId: "dev.iridia.storetesthost", deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: ["UILaunchScreen": [:]]),
            sources: ["Host/**"],
            dependencies: [.package(product: "IridiaStore")]),
    .target(name: "StoreTestHostTests", destinations: .iOS, product: .unitTests,
            bundleId: "dev.iridia.storetesthost.tests", deploymentTargets: .iOS("26.0"),
            sources: ["Tests/**/*.swift"], resources: ["../../Source/iOS/App/Common/Store/Iridia.storekit"],
            dependencies: [.target(name: "StoreTestHost"), .package(product: "IridiaStore")]),
  ],
  schemes: [
    .scheme(name: "StoreTestHost", buildAction: .buildAction(targets: ["StoreTestHost"]),
            testAction: .targets(["StoreTestHostTests"]),
            runAction: .runAction(options: .options(storeKitConfigurationPath: "../../Source/iOS/App/Common/Store/Iridia.storekit"))),
  ]
)
