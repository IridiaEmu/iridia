// SPDX-License-Identifier: GPL-2.0-or-later
// Controls Lab: test harness for Packages/GCControls (touch skin, smart mapping).
import ProjectDescription

let project = Project(
  name: "ControlsLab",
  packages: [.local(path: "../../Packages/GCControls")],
  settings: .settings(base: [
    "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
    "SWIFT_VERSION": "6.0",
    "DEVELOPMENT_TEAM": "$(GCEMU_TEAM)",
    "CODE_SIGN_STYLE": "Automatic",
  ]),
  targets: [
    .target(
      name: "ControlsLab",
      destinations: [.iPhone, .iPad],
      product: .app,
      bundleId: "$(GCEMU_BUNDLE_PREFIX).controlslab",
      deploymentTargets: .iOS("26.0"),
      infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "Controls Lab",
        "UILaunchScreen": [:],
        "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        "GCSupportsControllerUserInteraction": true,
        "GCSupportedGameControllers": [["ProfileName": "ExtendedGamepad"]],
        "UTImportedTypeDeclarations": [[
          "UTTypeIdentifier": "app.gcemu.controller-skin",
          "UTTypeDescription": "Controller Skin",
          "UTTypeConformsTo": ["public.json"],
          "UTTypeTagSpecification": ["public.filename-extension": ["gcskin"]],
        ]],
      ]),
      sources: ["Sources/**"],
      dependencies: [.package(product: "GCControlsUI"), .package(product: "GCControlsCore")]
    )
  ]
)
