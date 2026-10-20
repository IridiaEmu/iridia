// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore
import PVWebServer
import PVHelp
#if os(iOS)
import SafariServices
import AudioToolbox
#endif
#if canImport(GameController)
import GameController
#endif
#if os(iOS)
#endif
import Foundation

private enum AboutLogoAnimationStyle {
  case centerPulse
  case orbitRight
}

struct AboutView: View {
  @Environment(\.openURL) private var openURL
  @State private var animationStyle: AboutLogoAnimationStyle = .centerPulse
  @State private var logoScale: CGFloat = 1.0
  @State private var orbitAngle: Double = 0.0
  @State private var sparkleOpacity: Double = 0.3
  @State private var showBugEmailCopied = false

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        // Top spacer to mimic storyboard padding
        Color.clear.frame(height: 0)
        // Animated iCube logo with sparkle effects
        ZStack {
          // Subtle sparkles around the logo
          ForEach(0..<6, id: \.self) { index in
            Image(systemName: "sparkle")
              .font(.system(size: 12))
              .foregroundColor(.blue.opacity(0.6))
              .offset(
                x: cos(Double(index) * .pi / 3) * 80,
                y: sin(Double(index) * .pi / 3) * 80
              )
              .opacity(sparkleOpacity)
              .animation(.easeInOut(duration: 2.0).delay(Double(index) * 0.2).repeatForever(autoreverses: true), value: sparkleOpacity)
          }

          // Main logo — center pulse or right-biased orbit, chosen at random.
          IridiaCubeView()
            .frame(width: 140, height: 140)
            .scaleEffect(logoScale)
            .offset(
              x: animationStyle == .orbitRight ? 8 + 14 * cos(orbitAngle) : 0,
              y: animationStyle == .orbitRight ? 6 * sin(orbitAngle) : 0
            )
            .tint(Color("DolphinTint"))
        }
        .frame(height: 160)
        .onAppear {
          startAboutAnimation()
        }

        Text("Iridia")
          .font(.system(size: 28, weight: .semibold))
          .foregroundColor(Color(red: 0.86, green: 0.83, blue: 1.0))

        // App version / build + Dolphin core version.
        VStack(spacing: 2) {
          Text(verbatim: "\(L("Version")) \(VersionManager.shared().appVersion.userFacing)")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text(verbatim: "\(L("Core")) \(VersionManager.shared().coreVersion)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Text("© 2003-2015+ Dolphin Team.\n© 2025+ iCube Project.")
          .multilineTextAlignment(.center)

        Text("SwiftUI version by Joe Mattiello")
          .multilineTextAlignment(.center)

        Button("github.com/JoeMatt") {
          if let url = URL(string: "https://github.com/JoeMatt") {
            openURL(url)
          }
        }

        Button("joemattiello.dev") {
          if let url = URL(string: "https://joemattiello.dev") {
            openURL(url)
          }
        }

        Text("Iridia is an unofficial port of Dolphin to iOS, based on iCube. Neither Iridia nor the iCube Project is affiliated with Dolphin Team or Nintendo.")
          .multilineTextAlignment(.center)

        // Fork lineage with tappable source links.
        VStack(spacing: 8) {
          Text(L("Iridia is based on iCube, a fork of OatmealDome's DolphiniOS, built on the Dolphin emulator."))
            .multilineTextAlignment(.center)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          VStack(spacing: 6) {
            Button("dolphinios.oatmealdome.me") {
              if let url = URL(string: "https://dolphinios.oatmealdome.me") { openURL(url) }
            }
            Button("dolphin-emu.org") {
              if let url = URL(string: "https://dolphin-emu.org") { openURL(url) }
            }
            Button("icube-emu.com") {
              if let url = URL(string: "https://icube-emu.com") { openURL(url) }
            }
          }
          .font(.callout)
        }
        .padding(.vertical, 4)

        Text("\"GameCube\" and \"Wii\" are trademarks of Nintendo. Iridia is not affiliated with Nintendo in any way.")
          .multilineTextAlignment(.center)

        Text("This software should not be used to play games you do not legally own.")
          .multilineTextAlignment(.center)

        // gc-emu: the source link lives only inside Acknowledgements (kept low-key on purpose).
        NavigationLink(destination: AcknowledgementsView().padBackNavigation()) {
          Label(L("Acknowledgements"), systemImage: "heart.text.square")
        }

        NavigationLink(destination: DolphinBlogView().padBackNavigation()) { Label(L("Dolphin Blog"), systemImage: "newspaper") }
        NavigationLink(destination: IridiaHelpView().padBackNavigation()) { Label(L("Help"), systemImage: "questionmark.circle") }
        Button { reportBug() } label: { Label(L("Report a Bug"), systemImage: "envelope") }
        SettingsResetAllButton(role: .destructive) { Label(L("Reset All Settings"), systemImage: "arrow.counterclockwise") }

        Color.clear.frame(height: 0)
      }
      .padding(.horizontal, 20)
      .frame(maxWidth: .infinity)
    }
    .navigationTitle(L("About Iridia"))
    .alert(L("Email Address Copied"), isPresented: $showBugEmailCopied) {
      Button(L("OK"), role: .cancel) {}
    } message: {
      Text(String(format: L("Send your bug report to %@."), BugReport.email))
    }
  }

  private func reportBug() {
    BugReport.compose { showBugEmailCopied = true }
  }

  private func startAboutAnimation() {
    animationStyle = Bool.random() ? .centerPulse : .orbitRight
    sparkleOpacity = 0.8
    switch animationStyle {
    case .centerPulse:
      logoScale = 0.94
      withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
        logoScale = 1.08
      }
    case .orbitRight:
      logoScale = 1.02
      orbitAngle = 0
      withAnimation(.linear(duration: 6.0).repeatForever(autoreverses: false)) {
        orbitAngle = 2 * .pi
      }
    }
  }
}

/// gc-emu: where bug reports go (About, the top of Settings, the one-time notice).
enum BugReport {
  static let email = "iridiadev@gmail.com"
  /// Shown once, the first time the app opens.
  static let noticeSeenKey = "bug_report_notice_seen_v1"

  /// A new email to `email` with the version and device filled in.
  static var mailURL: URL? {
    var system = utsname()
    uname(&system)
    let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    let body = "\n\n\n" + [
      "\(L("Version")) \(VersionManager.shared().appVersion.userFacing)",
      "\(L("Core")) \(VersionManager.shared().coreVersion)",
      "\(model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
    ].joined(separator: "\n")
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = email
    components.queryItems = [
      URLQueryItem(name: "subject", value: L("Iridia bug report")),
      URLQueryItem(name: "body", value: body),
    ]
    return components.url
  }

  /// Opens the email. Without a mail app to take it, copies the address and calls `onCopied`.
  static func compose(onCopied: @escaping () -> Void) {
    guard let url = mailURL else { return }
    UIApplication.shared.open(url) { opened in
      guard !opened else { return }
      #if os(iOS)
      UIPasteboard.general.string = email
      #endif
      onCopied()
    }
  }
}
