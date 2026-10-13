// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Settings > About > Acknowledgements. Iridia's licence and source, the projects it is built
// on, the libraries it adds, and Dolphin's full third-party list (bundled from Externals/licenses.md).

import SwiftUI

enum IridiaLinks {
  /// Iridia's public source repository (GPL), if one is published. Optional: the written offer
  /// below covers source distribution on its own.
  static let sourceCode: URL? = URL(string: "https://github.com/zaptrem4/iridia")

  /// Where to ask for the source under the written offer (a backup to the public repository).
  static let sourceRequestContact = "github.com/zaptrem4/iridia/issues"
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
  ]

  private let additions: [Credit] = [
    Credit(name: "PLzmaSDK", detail: "7-Zip archive support (Oleh Kulykov).", license: "MIT", url: "https://github.com/OlehKulykov/PLzmaSDK"),
    Credit(name: "LZMA SDK", detail: "7-Zip compression (Igor Pavlov), used by PLzmaSDK.", license: "Public domain", url: "https://www.7-zip.org/sdk.html"),
    Credit(name: "MoltenVK", detail: "Vulkan on Metal, for the optional Vulkan renderer.", license: "Apache-2.0", url: "https://github.com/KhronosGroup/MoltenVK"),
    Credit(name: "Droid Sans", detail: "The GameCube system fonts Dolphin generates for games (no Nintendo fonts are included).", license: "Apache-2.0", url: "https://fonts.google.com/specimen/Droid+Sans"),
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
          Text(String(format: L("Write to %@ and include this version: %@."), IridiaLinks.sourceRequestContact, Self.versionString))
            .font(.subheadline.weight(.semibold))
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

      Section {
        Text(L("GameCube and Wii are trademarks of Nintendo. Iridia is not affiliated with, endorsed or sponsored by Nintendo or the Dolphin Team. Only play games you own."))
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
