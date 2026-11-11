// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the Wii U tab. Opened from the GameCube shelf's tab bar (or the empty GameCube library); covers it
// until the player taps GameCube in this tab bar. The same layout as the GameCube shelf (IridiaShelfView):
// header with Unlock and an add menu ("Choose a Game File" or the Files app guide), the shelf with the
// centred game large, the selected game with Play, and the tab bar. The Wii U tab keeps its own white and
// blue look (WiiUTheme): games are white cases with a blue spine. Settings, Help and Unlock Full Version are
// all reachable without a game.

#if os(iOS) && canImport(IridiaCafeCore)
import IridiaCafeCore
import IridiaStore
import SwiftUI

struct WiiUHomeView: View {
  /// Set while a Downloads folder is chosen (DownloadsFolder); here so the + menu updates.
  @AppStorage("downloadsFolderName") private var downloadsName: String?
  /// Back to the GameCube library.
  let onGameCube: () -> Void

  @ObservedObject private var model = WiiUModel.shared
  @ObservedObject private var store = IridiaUnlock.store
  @State private var centred: String?
  @State private var sheet: Sheet?
  @State private var gameSettings: WiiUGame?
  @State private var pendingDelete: WiiUGame?
  @State private var showUnlock = false
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  enum Sheet: String, Identifiable { case settings, help, filesGuide; var id: String { rawValue } }

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
      WiiUTheme.stage
      if isLandscapePhone {
        // iPhone landscape: header across the top, the shelf on the left, the selected game and actions on the right.
        VStack(spacing: 0) {
          header
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
              tabBar
            }
            .frame(width: 380)
          }
        }
      } else {
        VStack(spacing: 0) {
          header
          shelfCaption
          shelfOrEmpty
            .frame(height: 300 * caseScale + 40)
          details
            .frame(maxWidth: 480 * u)
          Spacer(minLength: 12)
          tabBar
            .frame(maxWidth: 480 * u)
        }
      }
      if model.importing { importingOverlay }
    }
    .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
    .onAppear {
      model.start()
      model.rescan()
      // Look in the player's Downloads folder (if they turned that on) once the shelf has settled.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { WiiUDownloads.check(model: model) }
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
      if playing == nil { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { autoplayNext() } }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
      WiiUDownloads.check(model: model)
    }
    .claimsController()
    .sheet(item: $sheet) { which in
      switch which {
      case .settings:
        NavigationStack { WiiUSettingsView(onUnlock: { sheet = nil; showUnlock = true }) }.claimsController()
      case .help:
        NavigationStack { WiiUHelpView() }.claimsController()
      case .filesGuide:
        NavigationStack { WiiUFilesGuideView() }.claimsController()
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
        .claimsController()
    }
    .sheet(item: $gameSettings) { game in
      NavigationStack { WiiUGameSettingsView(game: game) }
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

  /// "Check Downloads for Games" until a folder is chosen, then "Check Downloads Now".
  @ViewBuilder private var downloadsMenuItem: some View {
    if downloadsName != nil {
      Button { WiiUDownloads.check(model: model, manual: true) } label: {
        Label(String(format: L("Check %@ Now"), WiiUDownloads.folderName), systemImage: "arrow.down.circle")
      }
    } else {
      Button { WiiUDownloads.chooseFolder(model: model) } label: {
        Label(L("Check Downloads for Games"), systemImage: "arrow.down.circle")
      }
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

  // MARK: Header

  private var header: some View {
    HStack(spacing: 8 * u) {
      WiiUMark(size: 38 * u)
        .accessibilityHidden(true)
      Text(L("Wii U (Experimental)"))
        .font(.system(size: 22 * u, weight: .semibold))
        .foregroundStyle(WiiUTheme.ink)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .layoutPriority(1)
      Spacer()
      if !IridiaUnlock.isUnlocked {
        Button { showUnlock = true } label: {
          Text(L("Unlock"))
            .font(.system(size: 14 * u, weight: .bold))
            .foregroundStyle(WiiUTheme.onAccent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14 * u)
            .frame(height: 36 * u)
            .wiiUSurface(radius: 18 * u, prominent: true)
        }
        .buttonStyle(SpringPressStyle())
        .accessibilityLabel(L("Unlock Full Version"))
      }
      if WiiUModel.canRunGames {
        // The same two ways in as the GameCube shelf: pick a file now, or the Files app guide.
        Menu {
          Button { model.chooseGameFiles() } label: { Label(L("Choose a Game File"), systemImage: "doc.badge.plus") }
          Button { sheet = .filesGuide } label: { Label(L("Add with the Files App"), systemImage: "folder") }
          downloadsMenuItem
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 17 * u, weight: .semibold))
            .foregroundStyle(WiiUTheme.accent)
            .frame(width: 44 * u, height: 44 * u)
            .wiiUSurface(radius: 22 * u)
        }
        .accessibilityLabel(L("Add a game"))
      }
    }
    .padding(.horizontal, 20 * u)
    .padding(.top, 8 * u)
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
        downloadsMenuItem
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
              if item.id == current?.id { model.play(item) }
              else { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { centred = item.id } }
            }
            .contextMenu {
              Button { model.play(item) } label: { Label(L("Play"), systemImage: "play.fill") }
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
          Button { model.play(item) } label: {
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

  // MARK: Tab bar

  private var tabBar: some View {
    HStack(spacing: 6 * u) {
      tab(L("GameCube"), symbol: "cube", selected: false, action: onGameCube)
      tab(L("Wii U"), symbol: "square.stack", selected: true) {}
      tab(L("Settings"), symbol: "gearshape", selected: false) { sheet = .settings }
      tab(L("Help"), symbol: "questionmark.circle", selected: false) { sheet = .help }
    }
    .padding(8 * u)
    .wiiUSurface(radius: 35 * u)
    .padding(.horizontal, 20 * u)
    .padding(.bottom, 8 * u)
  }

  private func tab(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 3 * u) {
        Image(systemName: symbol).font(.system(size: 19 * u, weight: .semibold))
        Text(title).font(.system(size: 11 * u, weight: .semibold))
      }
      .foregroundStyle(selected ? WiiUTheme.onAccent : WiiUTheme.soft)
      .frame(maxWidth: .infinity, minHeight: 54 * u)
      .background {
        if selected { Capsule().fill(WiiUTheme.accent) }
      }
    }
    .buttonStyle(SpringPressStyle())
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
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.name)
    .accessibilityAddTraits(.isButton)
  }
}
#endif
