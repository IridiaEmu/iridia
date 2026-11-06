// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the Wii U tab. Opened from the GameCube shelf's tab bar (or the empty GameCube library); covers it
// until the player taps GameCube in this tab bar. The Wii U library (games as white cases, the centred one
// large), Settings, Help and Unlock Full Version, all reachable without a game.

#if os(iOS) && canImport(IridiaCafeCore)
import IridiaCafeCore
import IridiaStore
import SwiftUI

struct WiiUHomeView: View {
  /// Back to the GameCube library.
  let onGameCube: () -> Void

  @ObservedObject private var model = WiiUModel.shared
  @ObservedObject private var store = IridiaUnlock.store
  @State private var centred: String?
  @State private var sheet: Sheet?
  @State private var showUnlock = false
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  enum Sheet: String, Identifiable { case settings, help; var id: String { rawValue } }

  private var isLandscapePhone: Bool { verticalSizeClass == .compact }
  private var caseScale: CGFloat {
    if isLandscapePhone { return 0.78 }
    return horizontalSizeClass == .regular ? 1.3 : 1
  }

  private var ordered: [WiiUGame] {
    let played = WiiULastPlayed.all()
    return model.games.sorted {
      let a = played[$0.id] ?? .distantPast, b = played[$1.id] ?? .distantPast
      return a != b ? a > b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private var current: WiiUGame? { ordered.first { $0.id == centred } ?? ordered.first }

  var body: some View {
    ZStack {
      WiiUTheme.stage
      if isLandscapePhone {
        VStack(spacing: 0) {
          header
          HStack(spacing: 0) {
            VStack(spacing: 0) {
              Spacer(minLength: 0)
              shelf.frame(height: 300 * caseScale + 30)
              Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
              Spacer(minLength: 0)
              details
              Spacer(minLength: 8)
              tabBar
            }
            .frame(width: 380)
          }
        }
      } else {
        VStack(spacing: 0) {
          header
          caption
          shelf.frame(height: 300 * caseScale + 40)
          details.frame(maxWidth: 560)
          Spacer(minLength: 12)
          tabBar.frame(maxWidth: 560)
        }
      }
    }
    .onAppear {
      model.start()
      model.rescan()
      // Test hooks: -wiiuOpen settings|help|unlock opens that screen; -wiiuAutoplay <part of a name> starts that game.
      if let screen = UserDefaults.standard.string(forKey: "wiiuOpen") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          switch screen {
          case "settings": sheet = .settings
          case "help": sheet = .help
          case "unlock": showUnlock = true
          default: break
          }
        }
      }
    }
    .onChange(of: model.games) { _, games in
      if centred == nil || !games.contains(where: { $0.id == centred }) { centred = ordered.first?.id }
      if let want = UserDefaults.standard.string(forKey: "wiiuAutoplay"), !Self.autoplayed,
         let game = games.first(where: { $0.name.localizedCaseInsensitiveContains(want) }) {
        Self.autoplayed = true
        model.play(game)
      }
    }
    .claimsController()
    .sheet(item: $sheet) { which in
      NavigationStack {
        switch which {
        case .settings: WiiUSettingsView(onUnlock: { sheet = nil; showUnlock = true })
        case .help: WiiUHelpView()
        }
      }
      .claimsController()
    }
    .fullScreenCover(isPresented: $showUnlock) {
      WiiUUnlockView(context: .browsing, onUnlocked: { showUnlock = false }, onDismiss: { showUnlock = false })
        .claimsController()
    }
    .fullScreenCover(item: $model.playing) { game in
      WiiUPlayView(game: game)
    }
  }

  private static var autoplayed = false

  // MARK: Header

  private var header: some View {
    HStack(spacing: 10) {
      WiiUMark(size: 38)
      Text(L("Wii U (Experimental)"))
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(WiiUTheme.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .layoutPriority(1)
      Spacer(minLength: 4)
      if !IridiaUnlock.isUnlocked {
        Button { showUnlock = true } label: {
          Text(L("Unlock"))
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(WiiUTheme.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .wiiUSurface(radius: 20, prominent: true)
        }
        .buttonStyle(WiiUPress())
        .fixedSize()
        .accessibilityLabel(L("Unlock Full Version"))
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 8)
  }

  private var caption: some View {
    HStack {
      Text(String(format: model.games.count == 1 ? L("Your Wii U shelf · %d game") : L("Your Wii U shelf · %d games"),
                  model.games.count).uppercased())
        .font(.system(size: 13, weight: .medium))
        .tracking(1.5)
        .foregroundStyle(WiiUTheme.dim)
      Spacer()
      if WiiUModel.canRunGames {
        Button { model.rescan() } label: {
          Image(systemName: "arrow.clockwise")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(WiiUTheme.accent)
            .frame(width: 34, height: 34)
            .wiiUSurface(radius: 17)
        }
        .buttonStyle(WiiUPress())
        .accessibilityLabel(L("Look for games again"))
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 10)
  }

  // MARK: Shelf

  @ViewBuilder private var shelf: some View {
    if model.games.isEmpty {
      emptyShelf
    } else {
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 18) {
          ForEach(ordered) { item in
            WiiUGameCase(item: item, isCentred: item.id == current?.id)
              .scaleEffect(caseScale)
              .frame(width: 214 * caseScale, height: 300 * caseScale)
              .scrollTransition(.interactive, axis: .horizontal) { view, phase in
                view
                  .rotation3DEffect(.degrees(phase.value * -38), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                  .scaleEffect(1 - abs(phase.value) * 0.22)
                  .opacity(1 - abs(phase.value) * 0.35)
              }
              .onTapGesture {
                if item.id == current?.id { model.play(item) }
                else { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { centred = item.id } }
              }
          }
        }
        .scrollTargetLayout()
        .padding(.horizontal, 60)
      }
      .scrollTargetBehavior(.viewAligned)
      .scrollPosition(id: $centred, anchor: .center)
    }
  }

  private var emptyShelf: some View {
    VStack(spacing: 14) {
      Image(systemName: WiiUModel.canRunGames ? "folder.badge.plus" : "memorychip")
        .font(.system(size: 40, weight: .regular))
        .foregroundStyle(WiiUTheme.accent)
      Text(emptyTitle)
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(WiiUTheme.ink)
        .multilineTextAlignment(.center)
      Text(emptyMessage)
        .font(.system(size: 15))
        .multilineTextAlignment(.center)
        .foregroundStyle(WiiUTheme.soft)
        .padding(.horizontal, 30)
      if case .failed(let message) = model.phase {
        Text(message)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(WiiUTheme.warning)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 30)
      }
      if WiiUModel.canRunGames {
        Button { sheet = .help } label: {
          Label(L("How to Add Games"), systemImage: "questionmark.circle")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(WiiUTheme.accent)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .wiiUSurface(radius: 22)
        }
        .buttonStyle(WiiUPress())
      }
    }
    .frame(maxWidth: 520)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var emptyTitle: String {
    if !WiiUModel.canRunGames { return L("This device can't run Wii U games") }
    switch model.phase {
    case .idle, .starting: return L("Getting ready")
    default: return model.scanning ? L("Looking for games") : L("No Wii U games yet")
    }
  }

  private var emptyMessage: String {
    if !WiiUModel.canRunGames {
      return L("Wii U games need a device with 8 GB of memory, such as iPhone 15 Pro or later, or an iPad with an M1 chip or later.")
    }
    return String(format: L("Open the Files app, go to %@, and copy your own game there with its keys.txt."), WiiUModel.filesPath)
  }

  // MARK: Details

  @ViewBuilder private var details: some View {
    if let item = current {
      VStack(spacing: 12) {
        Text(item.name)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(WiiUTheme.ink)
          .lineLimit(2)
          .multilineTextAlignment(.center)
        Text(lastPlayedText(item))
          .font(.system(size: 14))
          .foregroundStyle(WiiUTheme.dim)
        Button { model.play(item) } label: {
          Label(L("Play"), systemImage: "play.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(WiiUTheme.onAccent)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .wiiUSurface(radius: 27, prominent: true)
        }
        .buttonStyle(WiiUPress())
        .padding(.horizontal, 24)
      }
      .padding(.top, 6)
    }
  }

  private func lastPlayedText(_ item: WiiUGame) -> String {
    guard let date = WiiULastPlayed.all()[item.id] else { return L("Not played yet") }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return String(format: L("Played %@"), f.localizedString(for: date, relativeTo: Date()))
  }

  // MARK: Tab bar

  private var tabBar: some View {
    HStack(spacing: 4) {
      tab("cube", L("GameCube"), selected: false, action: onGameCube)
      tab("square.stack", L("Wii U"), selected: true) {}
      tab("gearshape", L("Settings"), selected: false) { sheet = .settings }
      tab("questionmark.circle", L("Help"), selected: false) { sheet = .help }
    }
    .padding(6)
    .wiiUSurface(radius: 30)
    .padding(.horizontal, 20)
    .padding(.bottom, 10)
  }

  private func tab(_ symbol: String, _ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 3) {
        Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
        Text(title).font(.system(size: 11, weight: .medium))
      }
      .foregroundStyle(selected ? WiiUTheme.onAccent : WiiUTheme.soft)
      .frame(maxWidth: .infinity)
      .frame(height: 52)
      .background {
        if selected { Capsule().fill(WiiUTheme.accent) }
      }
    }
    .buttonStyle(WiiUPress())
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

/// A game on the Wii U shelf: a white case with the title on its face and a blue spine.
struct WiiUGameCase: View {
  let item: WiiUGame
  let isCentred: Bool

  var body: some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(LinearGradient(colors: [WiiUTheme.surfaceTop, WiiUTheme.surfaceBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WiiUTheme.stageTop))
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(LinearGradient(colors: [WiiUTheme.accentTop, WiiUTheme.deep], startPoint: .top, endPoint: .bottom))
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 8) {
        Spacer()
        Text(item.name)
          .font(.system(size: 20, weight: .bold))
          .foregroundStyle(WiiUTheme.ink)
          .lineLimit(4)
        Text(item.title.format.uppercased())
          .font(.system(size: 11, weight: .semibold))
          .tracking(1.2)
          .foregroundStyle(WiiUTheme.dim)
      }
      .padding(.leading, 34)
      .padding(.trailing, 18)
      .padding(.bottom, 24)
    }
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(LinearGradient(colors: [WiiUTheme.rimTop, WiiUTheme.rimBottom], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
    )
    .shadow(color: WiiUTheme.accent.opacity(isCentred ? 0.32 : 0.10), radius: isCentred ? 20 : 8, y: 10)
  }
}
#endif
