// SPDX-License-Identifier: GPL-2.0-or-later
//
// The Wii U shelf: white cases with a blue spine, the centred game's details below. The header and tab bar
// belong to IridiaHomeView.

#if os(iOS) && canImport(IridiaCafeCore)
import IridiaCafeCore
import IridiaStore
import SwiftUI

struct WiiUHomeView: View {
  @ObservedObject private var router = HomeRouter.shared
  @ObservedObject private var model = WiiUModel.shared
  @ObservedObject private var store = IridiaUnlock.store
  @State private var centred: String?
  @State private var sheet: Sheet?
  @State private var gameSettings: WiiUGame?
  @State private var pendingDelete: WiiUGame?
  @State private var showUnlock = false
  @State private var controllerScope = UUID()
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  enum Sheet: String, Identifiable { case settings, help, filesGuide, controllers; var id: String { rawValue } }

  private var isLandscapePhone: Bool { verticalSizeClass == .compact }
  /// The screen's size, for `u`.
  @State private var screen = CGSize.zero
  /// iPad: the iPhone layout drawn larger to fill the screen (ShelfScale). 1 on iPhone.
  private var u: CGFloat { isLandscapePhone ? 1 : ShelfScale.value(screen, regular: horizontalSizeClass == .regular) }
  /// Cases grow with the rest on iPad, shrink in iPhone landscape.
  private var caseScale: CGFloat { isLandscapePhone ? 0.78 : u }

  private var ordered: [WiiUGame] {
    let played = WiiULastPlayed.all()
    return model.games.sorted {
      let a = WiiULastPlayed.date($0.id, in: played) ?? .distantPast, b = WiiULastPlayed.date($1.id, in: played) ?? .distantPast
      return a != b ? a > b : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private var current: WiiUGame? { ordered.first { $0.id == centred } ?? ordered.first }

  var body: some View {
    ZStack {
      if isLandscapePhone {
        VStack(spacing: 0) {
          Color.clear.frame(height: HomeMetrics.headerHeight(u))
          HStack(spacing: 0) {
            VStack(spacing: 0) {
              Spacer(minLength: 0)
              shelfOrEmpty.frame(height: 300 * caseScale + 30)
              Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
              Spacer(minLength: 0)
              details
              Spacer(minLength: 8)
              Color.clear.frame(height: HomeMetrics.tabBarHeight(u))
            }
            .frame(width: HomeMetrics.landscapeColumn)
          }
        }
      } else {
        VStack(spacing: 0) {
          Color.clear.frame(height: HomeMetrics.headerHeight(u))
          shelfCaption
          shelfOrEmpty
            .frame(height: 300 * caseScale + 40)
          details
            .frame(maxWidth: 480 * u)
          Spacer(minLength: 12)
          Color.clear.frame(height: HomeMetrics.tabBarHeight(u))
        }
      }
      if model.importing { importingOverlay }
    }
    .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
    .onAppear {
      model.start()
      model.rescan()
      // Test hooks (not in App Store builds): -wiiuOpen settings|help|unlock|filesguide|import opens that screen;
      // -wiiuAutoplay <name part>[,<name part>...] starts those games one after another (the next one when the
      // previous ends).
      #if !APPSTORE
      // -wiiuNoJitCheck YES logs the result of the "Check for JIT" self-check at launch.
      if UserDefaults.standard.bool(forKey: "wiiuNoJitCheck") {
        NSLog("[WiiU] test hook: no-JIT self-check: %@", CemuBridge.noJitSelfCheck())
      }
      if let screen = UserDefaults.standard.string(forKey: "wiiuOpen") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          switch screen {
          case "settings": sheet = .settings
          case "help": sheet = .help
          case "controllers": sheet = .controllers
          case "filesguide": sheet = .filesGuide
          case "import": model.chooseGameFiles()
          case "unlock": showUnlock = true
          default: break
          }
        }
      }
      #endif
    }
    .onChange(of: model.games) { _, games in
      if centred == nil || !games.contains(where: { $0.id == centred }) { centred = ordered.first?.id }
      autoplayNext()
    }
    .onChange(of: model.playing) { _, playing in
      router.homeCovered = playing != nil
      if playing == nil {
        router.lift()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { autoplayNext() }
      }
    }
    .onChange(of: router.system) { _, system in
      if system == .wiiU { model.rescan() }
    }
    .controllerScope(controllerScope, active: router.system == .wiiU)
    .onHomeAction(.wiiU, perform: handle)
    .sheet(item: $sheet) { which in
      switch which {
      case .settings:
        NavigationStack { WiiUSettingsView(onUnlock: { sheet = nil; showUnlock = true }, onControllers: { sheet = .controllers }) }.environment(\.menuLook, .wiiU).claimsController()
      case .help:
        NavigationStack { WiiUHelpView() }.environment(\.menuLook, .wiiU).claimsController()
      case .filesGuide:
        NavigationStack { WiiUFilesGuideView() }.environment(\.menuLook, .wiiU).claimsController()
      case .controllers:
        NavigationStack { WiiUControllersView().menuClose { sheet = nil } }.environment(\.menuLook, .wiiU).claimsController()
      }
    }
    .fullScreenCover(isPresented: $showUnlock) {
      WiiUUnlockView(context: .browsing, onUnlocked: { showUnlock = false }, onDismiss: { showUnlock = false })
        .claimsController()
    }
    .iridiaAlert(item: $model.ticketMissing, look: .wiiU, title: { _ in L("Can't Open This Game") },
                 message: { WiiUModel.noTicketNote([$0.name]) })
    .sheet(item: $model.keyNeeded) { game in
      NavigationStack { WiiUDiscKeyView(game: game) }
        .environment(\.menuLook, .wiiU)
        .claimsController()
    }
    .sheet(item: $gameSettings) { game in
      NavigationStack { WiiUGameSettingsView(game: game) }
        .environment(\.menuLook, .wiiU)
        .claimsController()
    }
    .iridiaAlert(item: $pendingDelete, look: .wiiU, title: { _ in L("Delete Game?") }, message: { game in
      model.addOns(of: game).isEmpty
        ? String(format: L("Delete %@? You can't undo this."), game.name)
        : String(format: L("Delete %@ and its update and extra content? You can't undo this."), game.name)
    }, buttons: { game in
      [IridiaAlertButton(L("Delete"), .destructive) { delete(game) }, .cancel()]
    })
    .fullScreenCover(item: $model.playing) { game in
      WiiUPlayView(game: game)
    }
  }

  private static var autoplayQueue: [String]? = nil

  private func autoplayNext() {
    #if !APPSTORE
    if Self.autoplayQueue == nil {
      Self.autoplayQueue = (UserDefaults.standard.string(forKey: "wiiuAutoplay") ?? "")
        .split(separator: ",").map(String.init)
    }
    guard model.playing == nil, let want = Self.autoplayQueue?.first,
          let game = model.games.first(where: { $0.name.localizedCaseInsensitiveContains(want) }) else { return }
    Self.autoplayQueue?.removeFirst()
    NSLog("[WiiU] test hook: starting %@", game.name)
    model.play(game)
    #endif
  }

  private func play(_ game: WiiUGame) {
    router.launch { model.play(game) }
  }

  private func handle(_ action: HomeAction) {
    switch action {
    case .chooseFile: model.chooseGameFiles()
    case .filesGuide: sheet = .filesGuide
    case .checkDownloads: WiiUDownloads.check(model: model, manual: true)
    case .chooseDownloads: WiiUDownloads.chooseFolder(model: model)
    case .stopDownloads: DownloadsFolder.stop()
    case .settings: sheet = .settings
    case .help: sheet = .help
    case .controllers: sheet = .controllers
    case .unlock: showUnlock = true
    case .saves: break
    }
  }

  /// Deletes the game's file or folder from the Wii U folder. Only ever something inside that folder.
  /// Its update and extra content go too: without the game they're no use.
  private func delete(_ game: WiiUGame) {
    let folder = model.gamesDir.standardizedFileURL.path
    let addOns = model.addOns(of: game)
    for url in [URL(fileURLWithPath: game.id)] + addOns {
      let path = url.standardizedFileURL.path
      guard path.hasPrefix(folder + "/") else { continue }
      try? FileManager.default.removeItem(atPath: path)
    }
    model.rescan()
  }

  /// The same height and place as the GameCube shelf's caption, so the two tabs line up when they cross-fade;
  /// the refresh button floats at the end of the line without making it taller.
  private var shelfCaption: some View {
    Text(String(format: model.games.count == 1 ? L("Your Wii U shelf · %d game") : L("Your Wii U shelf · %d games"),
                model.games.count).uppercased())
      .font(.system(size: 13 * u, weight: .medium))
      .tracking(1.5 * u)
      .foregroundStyle(WiiUTheme.dim)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .trailing) {
        if WiiUModel.canRunGames {
          Button { model.rescan() } label: {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 13 * u, weight: .semibold))
              .foregroundStyle(WiiUTheme.accent)
              .frame(width: 30 * u, height: 30 * u)
              .wiiUSurface(radius: 15 * u)
          }
          .buttonStyle(SpringPressStyle())
          .accessibilityLabel(L("Look for games again"))
        }
      }
      .padding(.horizontal, 20 * u)
      .padding(.top, 14 * u)
  }

  // MARK: Shelf (3D carousel)

  @ViewBuilder private var shelfOrEmpty: some View {
    if ordered.isEmpty { emptySlot } else { shelf }
  }

  /// No games yet: one empty glass case in the middle of the shelf. Tapping it adds a game.
  @ViewBuilder private var emptySlot: some View {
    if WiiUModel.canRunGames {
      Menu {
        Button { model.chooseGameFiles() } label: { Label(L("Choose a Game File"), systemImage: "doc.badge.plus") }
        Button { sheet = .filesGuide } label: { Label(L("Add with the Files App"), systemImage: "folder") }
      } label: {
        emptyCase(symbol: "plus", text: L("Add a game"))
      }
      .accessibilityLabel(L("Add a game"))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      emptyCase(symbol: "memorychip", text: L("Wii U"))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func emptyCase(symbol: String, text: String) -> some View {
    VStack(spacing: 12 * u) {
      Image(systemName: symbol)
        .font(.system(size: 34 * u, weight: .semibold))
      Text(text)
        .font(.system(size: 15 * u, weight: .semibold))
    }
    .foregroundStyle(WiiUTheme.accent)
    .frame(width: 214 * caseScale, height: 300 * caseScale)
    .background(
      RoundedRectangle(cornerRadius: 22 * u, style: .continuous)
        .strokeBorder(WiiUTheme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
    )
    .wiiUSurface(radius: 22 * u)
  }

  private var shelf: some View {
    GeometryReader { geo in
    ScrollViewReader { proxy in
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: 18 * u) {
        ForEach(ordered) { item in
          WiiUGameCase(item: item, isCentred: item.id == current?.id)
            .frame(width: 214, height: 300)
            .scaleEffect(caseScale)
            .frame(width: 214 * caseScale, height: 300 * caseScale)
            .scrollTransition(.interactive, axis: .horizontal) { view, phase in
              view
                .rotation3DEffect(.degrees(phase.value * -38), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .scaleEffect(1 - abs(phase.value) * 0.22)
                .opacity(1 - abs(phase.value) * 0.35)
            }
            .onTapGesture {
              if item.id == current?.id { play(item) }
              else { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { centred = item.id } }
            }
            .contextMenu {
              Button { play(item) } label: { Label(L("Play"), systemImage: "play.fill") }
              Button { gameSettings = item } label: { Label(L("Game settings"), systemImage: "slider.horizontal.3") }
              Button(role: .destructive) { pendingDelete = item } label: { Label(L("Delete"), systemImage: "trash") }
            }
        }
      }
      .scrollTargetLayout()
      .padding(.vertical, 12 * u)
    }
    .scrollTargetBehavior(.viewAligned)
    .scrollPosition(id: $centred, anchor: .center)
    // Half the leftover width on each side, so the first and last case can sit in the centre too.
    .safeAreaPadding(.horizontal, max(16, (geo.size.width - 214 * caseScale) / 2))
    // Re-centre after a rotation (the scroll offset doesn't follow the new width).
    .onChange(of: geo.size) { _, _ in
      guard let id = current?.id else { return }
      DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }
    .sensoryFeedback(.selection, trigger: centred) { _, _ in IridiaHaptics.enabled }
    }
    }
    .frame(height: 300 * caseScale + 24)
  }

  // MARK: Details + actions

  private var details: some View {
    VStack(spacing: 6 * u) {
      if let item = current {
        Text(item.name)
          .font(.system(size: 26 * u, weight: .bold))
          .foregroundStyle(WiiUTheme.ink)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .minimumScaleFactor(0.7)
        Text(lastPlayedText(item))
          .font(.system(size: 14 * u))
          .foregroundStyle(WiiUTheme.soft)
        HStack(spacing: 12 * u) {
          Button { play(item) } label: {
            Label(L("Play"), systemImage: "play.fill")
              .font(.system(size: 18 * u, weight: .bold))
              .foregroundStyle(WiiUTheme.onAccent)
              .frame(maxWidth: .infinity, minHeight: 58 * u)
              .wiiUSurface(radius: 29 * u, prominent: true)
          }
          .buttonStyle(SpringPressStyle())
          Button { gameSettings = item } label: {
            Image(systemName: "slider.horizontal.3")
              .font(.system(size: 18 * u, weight: .semibold))
              .foregroundStyle(WiiUTheme.accent)
              .frame(width: 58 * u, height: 58 * u)
              .wiiUSurface(radius: 29 * u)
          }
          .buttonStyle(SpringPressStyle())
          .accessibilityLabel(String(format: L("Game settings for %@"), item.name))
        }
        .padding(.horizontal, 20 * u)
        .padding(.top, 14 * u)
      } else {
        Text(emptyTitle)
          .font(.system(size: 26 * u, weight: .bold))
          .foregroundStyle(WiiUTheme.ink)
          .multilineTextAlignment(.center)
        Text(emptyMessage)
          .font(.system(size: 14 * u))
          .foregroundStyle(WiiUTheme.soft)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24 * u)
        if case .failed(let message) = model.phase {
          Text(message)
            .font(.system(size: 14 * u, weight: .medium))
            .foregroundStyle(WiiUTheme.warning)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24 * u)
        }
        if WiiUModel.canRunGames {
          HStack(spacing: 12 * u) {
            Button { model.chooseGameFiles() } label: {
              Label(L("Choose a Game File"), systemImage: "doc.badge.plus")
                .font(.system(size: 16 * u, weight: .bold))
                .foregroundStyle(WiiUTheme.onAccent)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 58 * u)
                .wiiUSurface(radius: 29 * u, prominent: true)
            }
            .buttonStyle(SpringPressStyle())
            Button { sheet = .filesGuide } label: {
              Text(L("Files App"))
                .font(.system(size: 15 * u, weight: .semibold))
                .foregroundStyle(WiiUTheme.accent)
                .frame(width: 134 * u, height: 58 * u)
                .wiiUSurface(radius: 29 * u)
            }
            .buttonStyle(SpringPressStyle())
          }
          .padding(.horizontal, 20 * u)
          .padding(.top, 14 * u)
        }
      }
    }
    .padding(.top, 8 * u)
    .animation(.spring(response: 0.35, dampingFraction: 0.85), value: current?.id)
  }

  private var emptyTitle: String {
    if !WiiUModel.canRunGames { return L("This device can't run Wii U games") }
    switch model.phase {
    case .idle, .starting: return L("Getting ready")
    default: return model.scanning ? L("Looking for games") : L("Your Wii U shelf is empty")
    }
  }

  private var emptyMessage: String {
    if !WiiUModel.canRunGames {
      return L("Wii U games need a device with 8 GB of memory, such as iPhone 15 Pro or later, or an iPad with an M1 chip or later.")
    }
    return L("Add a Wii U game to start playing.")
  }

  private func lastPlayedText(_ item: WiiUGame) -> String {
    if item.needsKey { return L("Needs the key for your disc") }
    if item.missingTicket { return L("Missing its title.tik file") }
    guard let date = WiiULastPlayed.date(item.id, in: WiiULastPlayed.all()) else { return L("Not played yet") }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .full
    return String(format: L("Last played %@"), f.localizedString(for: date, relativeTo: Date()))
  }

  /// Shown while picked games are copied in (a big disc image can take a few minutes).
  private var importingOverlay: some View {
    ZStack {
      Color.black.opacity(0.25).ignoresSafeArea()
      VStack(spacing: 14 * u) {
        ProgressView().controlSize(.large).tint(WiiUTheme.accent)
        Text(L("Adding games…"))
          .font(.system(size: 16 * u, weight: .semibold))
          .foregroundStyle(WiiUTheme.ink)
        Text(L("Big games can take a few minutes. Keep Iridia open."))
          .font(.system(size: 13 * u))
          .foregroundStyle(WiiUTheme.soft)
          .multilineTextAlignment(.center)
      }
      .padding(24 * u)
      .wiiUSurface(radius: 24 * u)
      .padding(40 * u)
    }
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
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.name)
    .accessibilityAddTraits(.isButton)
  }
}
#endif
