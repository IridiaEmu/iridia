// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Settings > About > Acknowledgements. Iridia's licence and source, the projects it is built
// on, the libraries it adds, and Dolphin's full third-party list (bundled from Externals/licenses.md).

import SwiftUI

enum IridiaLinks {
  /// Iridia's public source repository (GPL), if one is published. Optional: the written offer
  /// below covers source distribution on its own.
  static let sourceCode: URL? = URL(string: "https://github.com/IridiaEmu/iridia")

  /// Where to ask for the source under the written offer (a backup to the public repository).
  static let sourceRequestContact = "github.com/IridiaEmu/iridia/issues"
}

struct AcknowledgementsView: View {
  private struct Credit: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let license: String
    let url: String
  }

  private let foundations: [Credit] = [
    Credit(name: "Dolphin", detail: "The GameCube and Wii emulator Iridia's core comes from.", license: "GPL-2.0-or-later", url: "https://dolphin-emu.org"),
    Credit(name: "DolphiniOS", detail: "OatmealDome's iOS port of Dolphin.", license: "GPL-2.0-or-later", url: "https://dolphinios.oatmealdome.me"),
    Credit(name: "iCube", detail: "The DolphiniOS fork Iridia is based on (Provenance project, Joe Mattiello).", license: "GPL-2.0-or-later", url: "https://github.com/Provenance-Emu/iCube"),
    Credit(name: "Cemu", detail: "The Wii U emulator Iridia's experimental Wii U support comes from.", license: "MPL-2.0", url: "https://github.com/cemu-project/Cemu"),
  ]

  private let additions: [Credit] = [
    Credit(name: "PLzmaSDK", detail: "7-Zip archive support (Oleh Kulykov).", license: "MIT", url: "https://github.com/OlehKulykov/PLzmaSDK"),
    Credit(name: "LZMA SDK", detail: "7-Zip compression (Igor Pavlov), used by PLzmaSDK.", license: "Public domain", url: "https://www.7-zip.org/sdk.html"),
    Credit(name: "MoltenVK", detail: "Vulkan on Metal, for the optional Vulkan renderer.", license: "Apache-2.0", url: "https://github.com/KhronosGroup/MoltenVK"),
    Credit(name: "Droid Sans", detail: "The GameCube system fonts Dolphin generates for games (no Nintendo fonts are included).", license: "Apache-2.0", url: "https://fonts.google.com/specimen/Droid+Sans"),
    Credit(name: "Noto Sans CJK", detail: "The Wii U system fonts the Wii U core gives games (no Nintendo fonts are included).", license: "SIL Open Font License 1.1", url: "https://github.com/notofonts/noto-cjk"),
    Credit(name: "Rounded M+", detail: "Rounded display typeface used in some menus.", license: "SIL Open Font License 1.1", url: "https://github.com/google/fonts/tree/main/ofl/roundedmplus1c"),
  ]

  /// "1.0.0 (13)": names the exact build a source request refers to.
  static var versionString: String {
    let info = Bundle.main.infoDictionary
    let v = info?["CFBundleShortVersionString"] as? String ?? "?"
    let b = info?["CFBundleVersion"] as? String ?? "?"
    return "\(v) (\(b))"
  }

  private static func bundled(_ name: String, _ ext: String) -> String {
    guard let url = Bundle.main.url(forResource: name, withExtension: ext),
          let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
    return text
  }

  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text("Iridia").font(.headline)
          Text(L("Iridia is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License, version 2 or (at your option) any later version."))
            .font(.subheadline)
            .foregroundStyle(.secondary)
          if let url = IridiaLinks.sourceCode {
            Link(L("Source code"), destination: url)
          }
        }
        .padding(.vertical, 4)
        NavigationLink(L("GNU General Public License v2")) {
          ScrollView {
            Text(Self.bundled("GPL-2.0", "txt"))
              .font(.system(.footnote, design: .monospaced))
              .textSelection(.enabled)
              .padding()
          }
          .navigationTitle(L("GPL v2"))
        }
      }

      Section(L("Source code offer")) {
        VStack(alignment: .leading, spacing: 8) {
          Text(L("For at least three years from the date you received this version of Iridia, we will give anyone who asks a complete machine-readable copy of its corresponding source code, under the terms of the GNU General Public License version 2 (section 3(b)). It is sent as a download or on a medium customarily used for software interchange, for no more than our cost of providing it."))
            .font(.subheadline)
          if let url = URL(string: "https://" + IridiaLinks.sourceRequestContact) {
            Link(IridiaLinks.sourceRequestContact, destination: url)
              .font(.subheadline.weight(.semibold))
          }
          Text(String(format: L("Version %@"), Self.versionString))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .padding(.vertical, 4)
      }

      Section(L("Built on")) {
        ForEach(foundations) { creditRow($0) }
      }

      Section(L("Libraries Iridia adds")) {
        ForEach(additions) { creditRow($0) }
      }

      Section(L("Dolphin's third-party software")) {
        NavigationLink(L("Libraries included with Dolphin")) {
          ScrollView {
            Text(.init(Self.bundled("DolphinThirdParty", "md")))
              .font(.footnote)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding()
          }
          .navigationTitle(L("Dolphin Libraries"))
        }
      }

      Section(L("Wii U core")) {
        VStack(alignment: .leading, spacing: 8) {
          Text(L("The Wii U core is built from Cemu and is licensed under the Mozilla Public License 2.0. Its source code, with our changes, is part of Iridia's source code."))
            .font(.subheadline)
          if let url = IridiaLinks.sourceCode {
            Link(L("Source code"), destination: url)
          }
        }
        .padding(.vertical, 4)
        NavigationLink(L("Mozilla Public License 2.0")) {
          ScrollView {
            Text(Self.bundled("MPL-2.0", "txt"))
              .font(.system(.footnote, design: .monospaced))
              .textSelection(.enabled)
              .padding()
          }
          .navigationTitle(L("MPL 2.0"))
        }
        NavigationLink(L("Libraries included with the Wii U core")) {
          ScrollView {
            Text(.init(Self.bundled("CemuThirdParty", "md")))
              .font(.footnote)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding()
          }
          .navigationTitle(L("Wii U Core Libraries"))
        }
        NavigationLink(L("Noto Sans CJK font license")) {
          ScrollView {
            Text(Self.bundled("NotoSansCJK-OFL", "txt"))
              .font(.system(.footnote, design: .monospaced))
              .textSelection(.enabled)
              .padding()
          }
          .navigationTitle(L("Noto Sans CJK"))
        }
      }

      Section {
        Text(L("GameCube, Wii and Wii U are trademarks of Nintendo. Iridia is not affiliated with, endorsed or sponsored by Nintendo, the Dolphin Team or the Cemu project. Only play games you own."))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .navigationTitle(L("Acknowledgements"))
  }

  private func creditRow(_ c: Credit) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(c.name).font(.body.weight(.semibold))
        Spacer()
        Text(c.license).font(.caption).foregroundStyle(.secondary)
      }
      Text(c.detail).font(.subheadline).foregroundStyle(.secondary)
      if let url = URL(string: c.url) {
        Link(c.url.replacingOccurrences(of: "https://", with: ""), destination: url).font(.caption)
      }
    }
    .padding(.vertical, 2)
  }
}
