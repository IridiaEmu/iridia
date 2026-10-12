// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Iridia's pause menu (direction A). The paused frame stays visible, dimmed, and a glass
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

  @State private var backdropImage: UIImage?

  /// The frame captured as this menu opened (SaveStateService.capturePausePreview). The capture lands a
  /// moment after the menu appears, so only a file written in the last few seconds counts (an older one
  /// is from a previous game) and it's read again shortly after appearing.
  private func loadBackdrop() {
    let url = SaveStateService.pausePreviewURL
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 5,
          let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return }
    backdropImage = img
  }

  var body: some View {
    ZStack {
      Color(red: 0.03, green: 0.02, blue: 0.10).ignoresSafeArea()
      if let backdropImage {
        Image(uiImage: backdropImage)
          .resizable().scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isLandscape ? .center : .top)
          .padding(.top, isLandscape ? 0 : 60)
          .opacity(0.45)
          .ignoresSafeArea()
          .transition(.opacity)
      }
      LinearGradient(colors: [Color(red: 0.03, green: 0.02, blue: 0.10).opacity(0.25), Color(red: 0.03, green: 0.02, blue: 0.10).opacity(0.85)],
                     startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
        .onTapGesture { IridiaSound.close.play(); actions.resume() }
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
      IridiaSound.open.play()
      loadBackdrop()
      // The PNG is written on the next presented frame and encoded off-thread: look a few times.
      for delay in [0.3, 0.7, 1.2, 1.8] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if backdropImage == nil { withAnimation { loadBackdrop() } } }
      }
    }
  }

  private var panel: some View {
    VStack(alignment: .leading, spacing: isLandscape ? 12 : 16) {
      if !isLandscape {
        Capsule().fill(.white.opacity(0.3)).frame(width: 40, height: 5).frame(maxWidth: .infinity)
      }
      HStack(spacing: 12) {
        IridiaCube.mark.resizable().scaledToFit().frame(width: 52, height: 52).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(L("Paused")).font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
          Text(game.title).font(.system(size: 13)).foregroundStyle(IridiaGlass.soft).lineLimit(1)
        }
        Spacer()
        Button(L("More"), action: onShowAll)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 14).frame(height: 36)
          .glassSurface(radius: 18)
          .buttonStyle(SpringPressStyle())
      }

      Button(action: { IridiaSound.close.play(); actions.resume() }) {
        Label(L("Resume"), systemImage: "play.fill")
          .font(.system(size: 19, weight: .bold))
          .foregroundStyle(Color(red: 0.07, green: 0.04, blue: 0.20))
          .frame(maxWidth: .infinity, minHeight: isLandscape ? 52 : 60)
          .glassSurface(radius: 30, prominent: true)
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

      HStack(spacing: 12) {
        Button(action: actions.openSettings) {
          Text(L("Settings")).frame(maxWidth: .infinity, minHeight: 50).glassSurface(radius: 25)
        }
        Button(action: onExit) {
          Text(L("Save & Exit"))
            .foregroundStyle(Color(red: 1.0, green: 0.76, blue: 0.81))
            .frame(maxWidth: .infinity, minHeight: 50)
            .glassSurface(radius: 25)
        }
      }
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(.white)
      .buttonStyle(SpringPressStyle())
    }
    .padding(.horizontal, 20)
    .padding(.top, 14)
    .padding(.bottom, isLandscape ? 16 : 34)
    .background {
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
    .offset(x: appeared || !isLandscape ? 0 : 440, y: appeared || isLandscape ? 0 : 520)
  }

  private func tile(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(alignment: .leading) {
        Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(Color(red: 0.79, green: 0.75, blue: 1.0))
        Spacer(minLength: 6)
        Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
      }
      .frame(maxWidth: .infinity, minHeight: isLandscape ? 64 : 88, alignment: .leading)
      .padding(14)
      .glassSurface(radius: 22)
    }
    .buttonStyle(SpringPressStyle())
  }
}
#endif
