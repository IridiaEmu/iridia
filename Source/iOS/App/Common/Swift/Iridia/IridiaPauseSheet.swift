// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: the pause menu for GameCube and Wii games (Wii U's, WiiUPauseSheet, has the same parts). The paused frame stays visible, dimmed, and a glass
// sheet rises from the bottom (portrait) or sits on the right (landscape): Resume, four big tiles,
// Settings and Save & Exit. "More" hands over to the full tile grid, so nothing is lost.

#if os(iOS)
import SwiftUI
import UIKit

struct IridiaPauseSheet: View {
  let game: TVGameItem
  let actions: PauseMenuActions
  let isLandscape: Bool
  let onShowAll: () -> Void
  let onExit: () -> Void

  @State private var appeared = false
  /// gc-emu: Wii games. What the game is played with; the same choice as the switch on the game screen.
  @State private var wiiChoice: PlaysAs?

  /// Wii games get the Wii tab's grey and white; GameCube games the indigo glass.
  private var isWii: Bool { game.isWiiTitle }
  private var ink: Color { isWii ? WiiTheme.ink : .white }
  private var soft: Color { isWii ? WiiTheme.soft : IridiaGlass.soft }
  private var iconTint: Color { isWii ? WiiTheme.accent : Color(red: 0.79, green: 0.75, blue: 1.0) }

  @ViewBuilder private func surface(_ radius: CGFloat, prominent: Bool = false) -> some View {
    if isWii {
      Color.clear.wiiSurface(radius: radius, prominent: prominent)
    } else {
      Color.clear.glassSurface(radius: radius, prominent: prominent)
    }
  }

  var body: some View {
    ZStack {
      // The game itself shows through (the cover is see-through); this only dims it.
      LinearGradient(colors: [Color(red: 0.03, green: 0.02, blue: 0.10).opacity(0.35), Color(red: 0.03, green: 0.02, blue: 0.10).opacity(0.75)],
                     startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
        .onTapGesture { actions.resume() }
        .accessibilityHidden(true)

      if isLandscape {
        HStack { Spacer(); panel.frame(width: 400).padding(.trailing, 12).padding(.vertical, 10) }
      } else {
        VStack { Spacer(); panel }
          .ignoresSafeArea(edges: .bottom)
      }
    }
    .onAppear {
      withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { appeared = true }
    }
  }

  private var panel: some View {
    VStack(alignment: .leading, spacing: isLandscape ? 12 : 16) {
      if !isLandscape {
        Capsule().fill(isWii ? WiiTheme.dim.opacity(0.5) : .white.opacity(0.3)).frame(width: 40, height: 5).frame(maxWidth: .infinity)
      }
      HStack(spacing: 12) {
        Group {
          if isWii { WiiMark(size: 48) } else { IridiaCube.mark.resizable().scaledToFit() }
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(L("Paused")).font(.system(size: 22, weight: .bold)).foregroundStyle(ink)
          Text(game.title).font(.system(size: 13)).foregroundStyle(soft).lineLimit(1)
        }
        Spacer()
        Button(L("More"), action: onShowAll)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(ink)
          .padding(.horizontal, 14).frame(height: 36)
          .background(surface(18))
          .buttonStyle(SpringPressStyle())
      }

      Button(action: actions.resume) {
        Label(L("Resume"), systemImage: "play.fill")
          .font(.system(size: 19, weight: .bold))
          .foregroundStyle(isWii ? WiiTheme.onAccent : Color(red: 0.07, green: 0.04, blue: 0.20))
          .frame(maxWidth: .infinity, minHeight: isLandscape ? 52 : 60)
          .background(surface(30, prominent: true))
      }
      .buttonStyle(SpringPressStyle())

      LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
        tile(L("Save State"), "square.and.arrow.down") {
          actions.quickSave()
          EmulationToast.post(L("Saved"))
        }
        tile(L("Load State"), "arrow.counterclockwise") { actions.quickLoad() }
        tile(L("Performance"), "gauge.with.dots.needle.67percent") {
          if let perf = actions.openPerformance { perf() } else { actions.openSettings() }
        }
        tile(L("Controls"), "gamecontroller", action: actions.openControllers)
      }

      if game.isWiiTitle { wiiControlsRow }

      HStack(spacing: 12) {
        Button(action: actions.openSettings) {
          Text(L("Settings")).frame(maxWidth: .infinity, minHeight: 50).background(surface(25))
        }
        Button(action: onExit) {
          Text(L("Save & Exit"))
            .foregroundStyle(isWii ? WiiTheme.warning : Color(red: 1.0, green: 0.76, blue: 0.81))
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(surface(25))
        }
      }
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(ink)
      .buttonStyle(SpringPressStyle())
    }
    .padding(.horizontal, 20)
    .padding(.top, 14)
    .padding(.bottom, isLandscape ? 16 : 34)
    .background { if isWii { wiiPanel } else { gameCubePanel } }
    .offset(x: appeared || !isLandscape ? 0 : 440, y: appeared || isLandscape ? 0 : 520)
  }

  private var panelShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(topLeadingRadius: 32, bottomLeadingRadius: isLandscape ? 32 : 0,
                           bottomTrailingRadius: isLandscape ? 32 : 0, topTrailingRadius: 32, style: .continuous)
  }

  private var wiiPanel: some View {
    WiiTheme.stage
      .clipShape(panelShape)
      .overlay(panelShape.strokeBorder(WiiTheme.rimBottom, lineWidth: 1))
      .shadow(color: WiiTheme.shadow, radius: 30, y: -10)
  }

  private var gameCubePanel: some View {
      UnevenRoundedRectangle(topLeadingRadius: 32, bottomLeadingRadius: isLandscape ? 32 : 0,
                             bottomTrailingRadius: isLandscape ? 32 : 0, topTrailingRadius: 32, style: .continuous)
        .fill(LinearGradient(stops: [.init(color: Color(red: 0.47, green: 0.39, blue: 0.90).opacity(0.45), location: 0),
                                     .init(color: Color(red: 0.19, green: 0.14, blue: 0.47).opacity(0.85), location: 0.2),
                                     .init(color: Color(red: 0.055, green: 0.035, blue: 0.16).opacity(0.97), location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .background(.ultraThinMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 32, bottomLeadingRadius: isLandscape ? 32 : 0,
                                                                   bottomTrailingRadius: isLandscape ? 32 : 0, topTrailingRadius: 32, style: .continuous))
        .overlay(alignment: .top) {
          UnevenRoundedRectangle(topLeadingRadius: 32, bottomLeadingRadius: isLandscape ? 32 : 0,
                                 bottomTrailingRadius: isLandscape ? 32 : 0, topTrailingRadius: 32, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.05)], startPoint: .top, endPoint: .center), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.55), radius: 30, y: -10)
  }

  /// gc-emu: Wii games switch between Wii Remote, Nunchuk, sideways, Classic and GameCube here too.
  private var wiiControlsRow: some View {
    let choice = wiiChoice ?? WiiControls.choice(for: game.gameID)
    return Menu {
      Picker(L("Controls"), selection: Binding(get: { choice }, set: { option in
        wiiChoice = option
        WiiControls.remember(option, for: game.gameID)
        WiiControls.apply(option)
      })) {
        ForEach(WiiControls.options, id: \.self) { option in
          Label(option.title, systemImage: WiiControls.symbol(option)).tag(option)
        }
      }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: WiiControls.symbol(choice))
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(iconTint)
        VStack(alignment: .leading, spacing: 1) {
          Text(L("Wii controls")).font(.system(size: 12, weight: .medium)).foregroundStyle(soft)
          Text(choice.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
        }
        Spacer()
        Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(soft)
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 54)
      .background(surface(22))
    }
    .accessibilityLabel(String(format: L("Controls: %@"), choice.title))
  }

  private func tile(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(alignment: .leading) {
        Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(iconTint)
        Spacer(minLength: 6)
        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
      }
      .frame(maxWidth: .infinity, minHeight: isLandscape ? 64 : 88, alignment: .leading)
      .padding(14)
      .background(surface(22))
    }
    .buttonStyle(SpringPressStyle())
  }
}
#endif
