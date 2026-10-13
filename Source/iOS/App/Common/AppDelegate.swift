// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    // Before anything logs: a JIT debugger's undrained stdio pipe must not block main (ICUBE-AC).
    DebuggerStdio.makeStdioNonBlocking()
    // gc-emu: move the old Documents layout into the hidden user folder + Documents/Games before
    // anything reads Dolphin's folders.
    UserFolderUtil.migrateLegacyLayoutIfNeeded()
    #if os(iOS)
    IridiaPresets.noteLaunch()  // gc-emu: before the core writes its config
    IridiaUnlock.start()        // gc-emu: StoreKit 2 listener + entitlement
    ControlOptions.apply()      // gc-emu: camera-stick inversion into the core
    #endif
    // gc-emu: games reopen where you left off (an automatic save state) instead of at the title screen.
    UserDefaults.standard.register(defaults: [SaveStateService.resumeDefaultsKey: true,
                                              "thermal_auto_enable": true])  // gc-emu: Keep Cool on by default
    MotionSettings.registerDefaults()
    DSUSettings.registerDefaults()

    // gc-emu: no telemetry (iCube's Sentry crash/performance reporting removed).

    // Settings-sync backbone: one global Config-changed hook (debounced auto-save of menu changes so
    // settings persist between runs, + a coalesced refresh notification so open settings UI re-reads
    // live Config after resets/external changes).
    DOLConfigBridge.startConfigAutoSyncBridge()

    // Single app-lifetime listener that resolves the resume/boot-into-state decision for
    // every emulation boot (see SaveStateService.resumeOrBootIntoPendingState()). Installed
    // once, here, instead of per-`EmulationScreen`-appearance so a navigation transition can
    // never leave two observers racing to consume the one-shot "Start Fresh" flag.
    SaveStateService.installDidStartObserver()
    PauseArbiter.shared.installObservers()

    #if os(iOS)
    GCEmuBenchmark.armIfRequested()  // gc-emu: scripted benchmark mode (-gcemuBench <seconds>)
    #endif
    return ServiceManager.shared.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func applicationWillTerminate(_ application: UIApplication) {
    ServiceManager.shared.applicationWillTerminate()
  }

  func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
    ServiceManager.shared.applicationDidReceiveMemoryWarning()
  }

  func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    ServiceManager.shared.open(url: url, options: options)
  }

  func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    // For tvOS, override any storyboard-based scene configuration and provide a programmatic scene.
    // This prevents crashes due to missing storyboards and enables a SwiftUI-based root.
    if AppConsts.useSwiftUI {
      let role = connectingSceneSession.role
      let config = UISceneConfiguration(name: "Default Configuration", sessionRole: role)
      if role == .windowExternalDisplayNonInteractive {
        config.delegateClass = ExternalDisplaySceneDelegate.self
      } else {
        config.delegateClass = MainDisplaySceneDelegate.self
      }
      config.storyboard = nil
      return config
    } else {
      return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
  }

  func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
    //
  }
}
