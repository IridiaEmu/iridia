import SwiftUI

#if os(iOS)
#endif

struct TVSoftwarePropertiesView: View, Identifiable {
  let id = UUID()
  let item: TVGameItem
  @Environment(\.dismiss) private var dismiss
  @State private var profilesVersion: Int = 0

  var body: some View {
    #if os(iOS)
    iosBody
    #else
    tvBody
    #endif
  }

  #if os(iOS)
  /// iOS layout, Iridia look: cover and title on the indigo stage, then glass panels for the game's
  /// details and its saved settings. GameCube only (no Wii sensor bar).
  private var iosBody: some View {
    NavigationStack {
      GeometryReader { proxy in
        let isCompact = proxy.size.width < 600
        let coverWidth: CGFloat = isCompact ? 130 : 200
        let fileSizeText = ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file)

        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 18) {
              Image(uiImage: item.coverImage)
                .resizable()
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(width: coverWidth)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                  RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                )
                .shadow(color: IridiaGlass.violet.opacity(0.35), radius: 16, y: 8)

              VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                  .font(.system(size: isCompact ? 22 : 28, weight: .bold))
                  .foregroundStyle(IridiaGlass.ink)
                  .lineLimit(3)
                Text([item.gameID, item.countryName].filter { !$0.isEmpty }.joined(separator: " · "))
                  .font(.system(size: 14, weight: .medium))
                  .foregroundStyle(IridiaGlass.soft)
                Toggle(L("Favorite"), isOn: Binding(get: { item.isFavorite }, set: { item.isFavorite = $0 }))
                  .foregroundStyle(IridiaGlass.ink)
                  .padding(.top, 6)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 10) {
              IridiaSectionLabel(text: L("Details"))
              VStack(spacing: 0) {
                DetailRow(title: L("Game ID"), value: item.gameID)
                DetailRow(title: L("Region"), value: item.countryName)
                DetailRow(title: L("Publisher"), value: item.makerLong)
                DetailRow(title: L("Disc"), value: String(item.discNumber + 1))
                DetailRow(title: L("Revision"), value: String(item.revision))
                DetailRow(title: L("File Size"), value: fileSizeText, isLast: true)
              }
              .iridiaPanel()
            }

            // Game Settings: this title's saved settings (`GameProfiles`), not a Dolphin input profile.
            VStack(alignment: .leading, spacing: 10) {
              IridiaSectionLabel(text: L("Game Settings"))
              VStack(alignment: .leading, spacing: 14) {
                Toggle(L("Widescreen Hack"), isOn: Binding(get: { DOLConfigBridge.gfxWidescreenHack() }, set: { DOLConfigBridge.setGfxWidescreenHack($0) }))
                NavigationLink(destination: ShaderPickerView(selectedPresetPath: Binding(get: { UserDefaults.standard.string(forKey: "shader_preset_path") }, set: { UserDefaults.standard.set($0, forKey: "shader_preset_path")
                  NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
                }))) {
                  HStack {
                    Text(L("Shader Preset"))
                    Spacer()
                    Text(UserDefaults.standard.string(forKey: "shader_preset_path")?.split(separator: "/").last.map(String.init) ?? L("None"))
                      .foregroundStyle(IridiaGlass.soft)
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(IridiaGlass.dim)
                  }
                }
                .buttonStyle(.plain)
                Divider().overlay(Color.white.opacity(0.12))
                Text(L("Save the settings above for this game only. They're applied whenever it starts."))
                  .font(.footnote)
                  .foregroundStyle(IridiaGlass.dim)
                  .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                  Button(L("Save for This Game")) {
                    let snap = GameProfiles.shared.buildProfileFromCurrentSettings()
                    GameProfiles.shared.setProfile(snap, for: item.gameID)
                    GameProfiles.shared.applyProfileIfAvailable(for: item)
                    profilesVersion &+= 1
                  }
                  .buttonStyle(.borderedProminent)
                  if GameProfiles.shared.hasSavedProfile(for: item.gameID) {
                    Button(L("Clear"), role: .destructive) {
                      GameProfiles.shared.clearProfile(for: item.gameID)
                      DOLConfigBridge.setGfxWidescreenHack(false)
                      profilesVersion &+= 1
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Label(L("Saved"), systemImage: "checkmark.circle.fill")
                      .font(.caption.weight(.semibold))
                      .foregroundStyle(IridiaGlass.accent)
                  }
                }
                if let prof = GameProfiles.shared.profile(for: item.gameID) {
                  let diff = GameProfiles.shared.diffCurrentSettings(from: prof)
                  if !diff.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                      Text(L("Changed since saved")).font(.subheadline).foregroundStyle(IridiaGlass.soft)
                      ForEach(Array(diff.enumerated()), id: \.offset) { pair in
                        let row = pair.element
                        HStack {
                          Text(row.0)
                          Spacer()
                          Text(row.1).foregroundStyle(IridiaGlass.dim)
                          Image(systemName: "arrow.right").foregroundStyle(IridiaGlass.dim)
                          Text(row.2).foregroundStyle(IridiaGlass.soft)
                        }
                        .font(.footnote)
                      }
                    }
                  }
                }
              }
              .foregroundStyle(IridiaGlass.ink)
              .iridiaPanel()
              .id(profilesVersion)
            }
          }
          .padding(20)
          .frame(maxWidth: 760)
          .frame(maxWidth: .infinity)
        }
      }
      .iridiaScreen()
      .navigationTitle(L("Game Info"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) { Button(L("Done")) { dismiss() } }
      }
    }
    .preferredColorScheme(.dark)
  }
  #endif

  /// tvOS layout preserved from previous implementation
  private var tvBody: some View {
    // Background composed as a single view and applied via .background to avoid ZStack ordering issues
    let backgroundView = Image(uiImage: item.coverImage)
      .resizable()
      .scaledToFill()
      .blur(radius: 25)
      .opacity(0.8)
      .ignoresSafeArea()
      .allowsHitTesting(false)

    return ScrollView {
      HStack(spacing: 80) {
        // Left: Game cover with shadow (mirroring PauseMenuView)
        VStack(alignment: .leading, spacing: 16) {
          Image(uiImage: item.coverImage)
            .resizable()
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(width: 220, height: 330)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)

          // Optional: small ID under the cover (like Pause)
          VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
              .font(.system(size: 24, weight: .bold))
              .foregroundColor(.white)
              .lineLimit(2)
            Text(item.gameID)
              .font(.system(size: 14, weight: .medium))
              .foregroundColor(.white.opacity(0.7))
          }
        }
        .frame(width: 220)

        // Right: Title + rounded container with property grid
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
              .font(.system(size: 44, weight: .bold))
              .foregroundColor(.white)
              .lineLimit(2)
              .minimumScaleFactor(0.8)
            Text(combinedId)
              .font(.system(size: 16, weight: .medium))
              .foregroundColor(.white.opacity(0.7))
          }

          VStack(alignment: .leading, spacing: 12) {
            // Prepare formatted values
            let fileSizeText = ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)], spacing: 16) {
              // Core identifiers
              PropertyCard(title: L("Internal Name"), value: internalName)
              PropertyCard(title: L("Game ID"), value: item.gameID)

              // Disc/Revision
              PropertyCard(title: L("Disc"), value: String(item.discNumber + 1))
              PropertyCard(title: L("Revision"), value: String(item.revision))

              // Publisher/Manufacturer and Region
              PropertyCard(title: L("Manufacturer"), value: item.makerLong)
              PropertyCard(title: L("Region"), value: item.countryName)

              // IDs
              PropertyCard(title: L("Title ID (Hex)"), value: item.titleIDHex ?? "-")
              PropertyCard(title: L("GameTDB ID"), value: item.gametdbID)

              // Other
              PropertyCard(title: L("Apploader Date"), value: item.apploaderDateString ?? "-")
              PropertyCard(title: L("File Size"), value: fileSizeText)
            }
          }
        }
        .frame(maxWidth: 900, alignment: .leading)
      }
      .padding(.horizontal, 60)
      .padding(.vertical, 50)
    }
    .background(backgroundView)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .topTrailing) {
      Button(L("Close")) { dismiss() }
        .buttonStyle(.borderedProminent)
        .padding(24)
    }
    #if os(tvOS)
    .onExitCommand {
      dismiss()
    }
    #endif
  }

  private var internalName: String {
    let name = item.title
    let disc = item.discNumber
    let rev = item.revision
    if disc > 0 {
      return "\(name) (Disc \(disc + 1), Revision \(rev))"
    } else {
      return "\(name) (Revision \(rev))"
    }
  }

  private var combinedId: String {
    if let titleHex = item.titleIDHex, !titleHex.isEmpty {
      return "\(item.gameID) (\(titleHex))"
    }
    return item.gameID
  }
}

// MARK: - Detail row (iOS, Iridia)

#if os(iOS)
private struct DetailRow: View {
  let title: String
  let value: String
  var isLast = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).foregroundStyle(IridiaGlass.soft)
        Spacer(minLength: 16)
        Text(value.isEmpty ? "–" : value)
          .foregroundStyle(IridiaGlass.ink)
          .multilineTextAlignment(.trailing)
          .textSelection(.enabled)
      }
      .font(.system(size: 15))
      .padding(.vertical, 10)
      if !isLast { Divider().overlay(Color.white.opacity(0.10)) }
    }
  }
}
#endif

// MARK: - Property Card Component

private struct PropertyCard: View {
  let title: String
  let value: String

  var body: some View {
    HStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 14, weight: .medium))
          .foregroundColor(.white.opacity(0.7))
          .textCase(.uppercase)

        Text(value)
          .font(.system(size: 16, weight: .semibold))
          .foregroundColor(.white)
          .multilineTextAlignment(.leading)
          .lineLimit(3)
      }

      Spacer()
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(.white.opacity(0.05))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(.white.opacity(0.1), lineWidth: 1)
        )
    )
    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
  }
}
