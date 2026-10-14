import SwiftUI
import UIKit
import PVHelp

/// A single save-state thumbnail card. Renders identically wherever it is
/// shown (the pause-menu grid in `SaveStateFilmstripView`, the cross-game
/// browser in `SaveStatesBrowserView`) but sizes and styles itself per
/// platform: tvOS gets a larger preview and the system "card" lift-on-focus
/// treatment, iOS stays compact for a scrolling grid.
///
/// tvOS focus note (see `icube-tvos-swiftui-focus`): this view must expose
/// AT MOST one focusable control, because a `List`/grid "row" that contains
/// more than one focusable element collapses to a single focus target and
/// strands the others. The only nested control this view used to add -- a
/// tappable "Incompatible" badge that pushed a help sheet -- is iOS-only for
/// that reason; on tvOS it renders as inert text and the compatibility
/// explanation is reachable from the card's own action menu instead (see
/// `SaveStateFilmstripView`'s confirmation dialog).
struct SaveStateCardView: View {
  let state: SaveStateInfo
  let thumbnail: UIImage?
  /// Explains why a save state is version-incompatible and can't be safely loaded, instead of
  /// leaving the red "Incompatible" badge as an unexplained dead end. iOS only; see the tvOS
  /// focus note above for why tvOS can't have a second tappable control inside this card.
  @State private var showIncompatibleHelp = false

  #if os(tvOS)
  private static let thumbnailSize = CGSize(width: 480, height: 270)
  private static let radius: CGFloat = 12
  private static let placeholderFill = Color.gray.opacity(0.25)
  private static let vignette = Color.black.opacity(0.75)
  private static let continueBadge = Color.green
  private static let slotBadge = Color.blue
  #else
  private static let thumbnailSize = CGSize(width: 300, height: 170)
  // gc-emu: Iridia palette: violet glass instead of iCube's grey/green/blue.
  private static let radius: CGFloat = 16
  private static let placeholderFill = Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.16)
  private static let vignette = Color(red: 0.04, green: 0.02, blue: 0.12).opacity(0.85)
  private static let continueBadge = Color(red: 0.55, green: 0.45, blue: 1.0)
  private static let slotBadge = Color.white.opacity(0.22)
  #endif

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      // Thumbnail or placeholder. `.fit` (not `.fill`) keeps the saved frame's
      // real aspect ratio intact -- GameCube (4:3) and Wii (16:9) thumbnails
      // mixed in the same grid no longer get corner-cropped; the background
      // fill behind it letterboxes evenly so every card stays the same size
      // regardless of the thumbnail's native aspect ratio.
      Group {
        if let thumbnail {
          Image(uiImage: thumbnail)
            .resizable()
            .scaledToFit()
        } else {
          RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
            .fill(Self.placeholderFill)
            .overlay(
              Image(systemName: "photo")
                .font(.system(size: 28, weight: .regular))
                .foregroundColor(.white.opacity(0.7))
            )
        }
      }
      #if os(iOS)
      // gc-emu: fill the grid cell's width (cells grow past 300 pt on wide phones and iPads) at a
      // fixed 16:9 shape; the picture keeps its own ratio, letterboxed on the dark card.
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .aspectRatio(16.0 / 9.0, contentMode: .fit)
      .background(Self.vignette.opacity(0.6))
      #else
      .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
      #endif
      .clipped()
      .background(
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
          .fill(Color.white.opacity(0.04))
      )
      .cornerRadius(Self.radius)

      // Vignette + metadata
      LinearGradient(
        colors: [Color.black.opacity(0.0), Self.vignette],
        startPoint: .center, endPoint: .bottom
      )
      .cornerRadius(Self.radius)

      VStack(alignment: .leading, spacing: 4) {
        Text(state.displayName)
          .font(.headline)
          .foregroundColor(.white)
          .lineLimit(1)

        HStack(spacing: 8) {
          if state.isAuto {
            // The resume save is already titled "Continue"; only badge it when renamed.
            if state.displayName != "Continue", state.displayName != L("Continue") { Badge(text: L("Continue"), color: Self.continueBadge) }
          } else if let slot = state.slot {
            Badge(text: String(format: L("Slot %d"), slot), color: Self.slotBadge)
          }
          if !state.isCompatible {
            #if os(tvOS)
            // No nested Button on tvOS -- see the type-level focus note. The
            // card's own action menu (SaveStateFilmstripView) surfaces the
            // same compatibility explanation.
            Badge(text: L("Incompatible"), color: .red)
            #else
            Button {
              showIncompatibleHelp = true
            } label: {
              Badge(text: L("Incompatible"), color: .red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Incompatible save state. Tap for details."))
            #endif
          }
        }

        HStack(spacing: 8) {
          Text(timestampString)
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.85))
          if let gameTimeString {
            Text("\u{00B7}")
              .foregroundColor(.white.opacity(0.5))
            Label(gameTimeString, systemImage: "clock")
              .font(.subheadline)
              .foregroundColor(.white.opacity(0.85))
              .labelStyle(.titleAndIcon)
          }
        }
      }
      .padding(12)
    }
    #if os(iOS)
    // gc-emu: Iridia glass rim (bright top edge fading down), like the shelf's cases.
    .overlay(
      RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08)], startPoint: .top, endPoint: .bottom),
                      lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    #else
    .overlay(
      RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
    )
    #endif
    #if !os(tvOS)
    .sheet(isPresented: $showIncompatibleHelp) {
      NavigationStack {
        IridiaHelpView(topic: .saveStates)   // gc-emu: built-in help, not iCube's online wiki
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button(L("Close")) { showIncompatibleHelp = false }
            }
          }
      }
    }
    #endif
  }

  private var timestampString: String {
    let date = state.modifiedAt ?? state.createdAt
    guard let date else { return "" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
  }

  /// e.g. "01:24:07" or "12:03" for a state with recorded in-game play time.
  /// Nil (and hidden) for legacy saves with no sidecar, or one written before
  /// this field existed.
  private var gameTimeString: String? {
    SaveStateFormatting.gameTimeString(seconds: state.playTimeSeconds)
  }
}

/// Pure, testable formatting helpers shared by the save-state UI. Split out of
/// `SaveStateCardView` (a `View`, whose private computed properties are not
/// reachable from `@testable import` unit tests) so the slot-card duration
/// formatting has direct test coverage -- see `SaveStateFormattingTests`.
enum SaveStateFormatting {
  /// e.g. "01:24:07" for >= 1 hour, "12:03" under an hour. `DateComponentsFormatter`'s
  /// `.positional` style with `.pad` zero-pads every component, including the
  /// leading one (verified empirically, not just from docs) -- so this is
  /// "01:24:07", not "1:24:07". Nil for a missing, negative, or non-finite
  /// value (legacy saves have no recorded play time).
  static func gameTimeString(seconds: Double?) -> String? {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
    formatter.zeroFormattingBehavior = .pad
    formatter.unitsStyle = .positional
    return formatter.string(from: seconds)
  }
}

private struct Badge: View {
  let text: String
  var color: Color = .blue
  var body: some View {
    Text(text)
      .font(.caption2.weight(.semibold))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.75), in: Capsule())
      .foregroundColor(.white)
  }
}

struct SaveStateCardView_Previews: PreviewProvider {
  static var previews: some View {
    let sample = SaveStateInfo(
      gameID: "GALE01",
      displayName: "Quick Slot 1",
      slot: 1,
      createdAt: Date().addingTimeInterval(-3600),
      modifiedAt: Date(),
      sizeBytes: 1024,
      versionHash: nil,
      isCompatible: true,
      path: URL(fileURLWithPath: "/tmp/dummy"),
      thumbnailURL: nil,
      isAuto: false,
      playTimeSeconds: 5427
    )
    SaveStateCardView(state: sample, thumbnail: nil)
      .preferredColorScheme(.dark)
      .padding()
      .background(Color.black)
  }
}
