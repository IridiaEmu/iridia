// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// gc-emu: names as the Files app shows them. Files lists the app's folder under its home-screen
/// name (CFBundleDisplayName), so it's read at runtime and every instruction stays right after a
/// rename.
enum FilesAppNames {
  static var appFolder: String {
    let info = Bundle.main.infoDictionary
    return (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? "iCube"
  }

  static var gamesFolder: String { UserFolderUtil.gamesFolderName }

  /// "Files → On My iPhone → <App> → Games" (says iPad on iPad).
  static var gamesPath: String {
    let device = UIDevice.current.userInterfaceIdiom == .pad ? L("On My iPad") : L("On My iPhone")
    return "Files → \(device) → \(appFolder) → \(gamesFolder)"
  }
}

#if os(iOS)
/// gc-emu: step-by-step guide for adding a game with the Files app. It's the fallback for when
/// Apple's import picker gets stuck on "Loading" (its Recents tab depends on iOS's search index).
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
      List {
        Section {
          Text(L("If the import screen keeps showing \"Loading\", you can add games with the Files app instead."))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Section(L("Steps")) {
          ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text("\(index + 1)")
                .font(.headline.monospacedDigit())
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
              Label(step.text, systemImage: step.icon)
            }
            .padding(.vertical, 2)
          }
        }
        Section {
          Text(L("ISO, RVZ, GCM and CISO files work. ZIP and 7Z archives are unpacked automatically; a big one can take a minute or two."))
            .font(.footnote)
            .foregroundStyle(.secondary)
          Button {
            if let url = URL(string: "shareddocuments://" + Self.gamesFolderURLPath) {
              UIApplication.shared.open(url)
            }
          } label: {
            Label(L("Open the Files App"), systemImage: "arrow.up.forward.app")
          }
        }
      }
      .navigationTitle(L("Add Games with Files"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(L("Done")) { dismiss() }
        }
      }
    }
  }

  /// Opens Files directly in this app's Games folder.
  private static var gamesFolderURLPath: String {
    URL(fileURLWithPath: UserFolderUtil.getSoftwareFolder(), isDirectory: true).path
      .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
  }
}
#endif
