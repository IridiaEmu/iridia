// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

struct WiiPlayButtons: View {
  let gameID: String
  /// The pointer mode's raw value (0 = point the phone).
  let pointerMode: Int

  @State private var choice: PlaysAs

  init(gameID: String, pointerMode: Int) {
    self.gameID = gameID
    self.pointerMode = pointerMode
    _choice = State(initialValue: WiiControls.choice(for: gameID))
  }

  private var usesWiiRemote: Bool { choice != .gameCube && choice != .wiiClassic }

  var body: some View {
    HStack(spacing: 8) {
      if usesWiiRemote && pointerMode == PointerMode.gyro.rawValue {
        round("scope", L("Recenter")) { TCDeviceMotion.requestPointerRecenter() }
      }
      Menu {
        Picker(L("Controls"), selection: Binding(get: { choice }, set: { pick($0) })) {
          ForEach(WiiControls.options, id: \.self) { option in
            Label(option.title, systemImage: WiiControls.symbol(option)).tag(option)
          }
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: WiiControls.symbol(choice))
          Text(WiiControls.shortTitle(choice)).lineLimit(1)
          Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(minWidth: 44, minHeight: 44)
        .background(Capsule().fill(.black.opacity(0.45)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
      }
      .accessibilityLabel(String(format: L("Controls: %@"), choice.title))
      round("pause.fill", L("Pause")) {
        NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: WiiControls.changed)) { _ in
      choice = WiiControls.choice(for: gameID)   // switched in the pause menu
    }
  }

  private func pick(_ option: PlaysAs) {
    guard option != choice else { return }
    choice = option
    WiiControls.remember(option, for: gameID)
    WiiControls.apply(option)
    EmulationToast.post(String(format: L("Controls: %@"), option.title))
  }

  private func round(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .background(Circle().fill(.black.opacity(0.45)))
        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
    }
    .buttonStyle(WiiPress())
    .accessibilityLabel(label)
  }
}
#endif
