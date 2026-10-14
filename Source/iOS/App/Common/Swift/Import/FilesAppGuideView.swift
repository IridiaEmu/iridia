// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// gc-emu: names as the Files app shows them. Files lists the app's folder under its home-screen
/// name (CFBundleDisplayName), so it's read at runtime and every instruction stays right after a
/// rename.
enum FilesAppNames {
  static var appFolder: String {
    let info = Bundle.main.infoDictionary
    return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? "Iridia"
  }

  static var gamesFolder: String { UserFolderUtil.gamesFolderName }

  /// "Files → On My iPhone → <App> → Games" (says iPad on iPad).
  static var gamesPath: String {
    let device = UIDevice.current.userInterfaceIdiom == .pad ? L("On My iPad") : L("On My iPhone")
    return "Files → \(device) → \(appFolder) → \(gamesFolder)"
  }
}

#if os(iOS)
/// gc-emu: step-by-step guide for adding a game with the Files app. Offered from the shelf's "+"
/// menu, and as the fallback when Apple's import picker gets stuck on "Loading" (its Recents tab
/// depends on iOS's search index).
struct FilesAppGuideView: View {
  @Environment(\.dismiss) private var dismiss

  private var steps: [(icon: String, text: String)] {
    let device = UIDevice.current.userInterfaceIdiom == .pad ? L("On My iPad") : L("On My iPhone")
    return [
      ("folder", L("Open the Files app.")),
      ("magnifyingglass", L("Go to where your game file is (for example Downloads or iCloud Drive).")),
      ("hand.tap", L("Press and hold the game file.")),
      ("folder.badge.plus", L("Tap Move.")),
      ("iphone", String(format: L("Tap %1$@, then the %2$@ folder, then the %3$@ folder."),
                        device, FilesAppNames.appFolder, FilesAppNames.gamesFolder)),
      ("checkmark.circle", String(format: L("Tap Move, then come back to %@. The game shows up in your library."),
                                  FilesAppNames.appFolder)),
    ]
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          Text(String(format: L("Move a game into %@'s Games folder with Apple's Files app. It's the easiest way to add big games, or several at once."), FilesAppNames.appFolder))
            .font(.system(size: 16))
            .foregroundStyle(IridiaGlass.soft)
            .fixedSize(horizontal: false, vertical: true)

          VStack(alignment: .leading, spacing: 10) {
            IridiaSectionLabel(text: L("Steps"))
            VStack(alignment: .leading, spacing: 0) {
              ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 14) {
                  Text("\(index + 1)")
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color(red: 0.07, green: 0.04, blue: 0.20))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(LinearGradient(colors: [Color(red: 0.84, green: 0.80, blue: 1.0), IridiaGlass.violet],
                                                              startPoint: .top, endPoint: .bottom)))
                  VStack(alignment: .leading, spacing: 4) {
                    Text(step.text)
                      .font(.system(size: 16))
                      .foregroundStyle(IridiaGlass.ink)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                  Spacer(minLength: 8)
                  Image(systemName: step.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(IridiaGlass.accent)
                    .frame(width: 26)
                }
                .padding(.vertical, 12)
                if index < steps.count - 1 { Divider().overlay(Color.white.opacity(0.10)) }
              }
            }
            .iridiaPanel()
          }

          VStack(alignment: .leading, spacing: 10) {
            IridiaSectionLabel(text: L("Where games go"))
            VStack(alignment: .leading, spacing: 8) {
              Text(FilesAppNames.gamesPath)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(IridiaGlass.ink)
              Text(L("ISO, RVZ, GCM and CISO files work. ZIP and 7Z files are unpacked for you, which can take a minute or two for a big game."))
                .font(.footnote)
                .foregroundStyle(IridiaGlass.dim)
                .fixedSize(horizontal: false, vertical: true)
            }
            .iridiaPanel()
          }

          Button {
            if let url = URL(string: "shareddocuments://" + Self.gamesFolderURLPath) {
              UIApplication.shared.open(url)
            }
          } label: {
            Label(L("Open the Files App"), systemImage: "arrow.up.forward.app")
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(Color(red: 0.07, green: 0.04, blue: 0.20))
              .frame(maxWidth: .infinity)
              .frame(height: 52)
              .glassSurface(radius: 26, prominent: true)
          }
          .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
      }
      .iridiaScreen()
      .navigationTitle(L("Add Games with Files"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L("Done")) { dismiss() }
        }
      }
    }
    .preferredColorScheme(.dark)
  }

  /// Opens Files directly in this app's Games folder.
  private static var gamesFolderURLPath: String {
    URL(fileURLWithPath: UserFolderUtil.getSoftwareFolder(), isDirectory: true).path
      .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
  }
}
#endif
