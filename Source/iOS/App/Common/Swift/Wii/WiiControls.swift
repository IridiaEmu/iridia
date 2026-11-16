// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: which controller a Wii game is played with (Wii Remote, with a Nunchuk, with a Classic
// Controller, held sideways, or a GameCube controller), remembered for each game. The choice goes
// through the Controllers hub's own "Plays as" change, so touch controls, game controllers and
// the hub always agree.

import Foundation

enum WiiControls {
  /// In the order the switch shows them.
  static let options: [PlaysAs] = [.wiiNunchuk, .wiiRemote, .wiiSideways, .wiiClassic, .gameCube]

  private static let perGameKey = "iridia_wii_controls"          // [game ID: PlaysAs raw value]
  static let newGameKey = "iridia_wii_controls_default"           // PlaysAs raw value

  /// What a game starts with before the player picks anything for it.
  static var defaultForNewGames: PlaysAs {
    get { (UserDefaults.standard.object(forKey: newGameKey) as? Int).flatMap(PlaysAs.init(rawValue:)) ?? .wiiNunchuk }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: newGameKey) }
  }

  static func choice(for gameID: String) -> PlaysAs {
    guard !gameID.isEmpty,
          let raw = (UserDefaults.standard.dictionary(forKey: perGameKey) as? [String: Int])?[gameID],
          let choice = PlaysAs(rawValue: raw) else { return defaultForNewGames }
    return choice
  }

  /// Posted after a game's choice changes (the in-game switch and the pause menu follow each other).
  static let changed = Notification.Name("IridiaWiiControlsChanged")

  static func remember(_ choice: PlaysAs, for gameID: String) {
    guard !gameID.isEmpty else { return }
    var map = UserDefaults.standard.dictionary(forKey: perGameKey) as? [String: Int] ?? [:]
    map[gameID] = choice.rawValue
    UserDefaults.standard.set(map, forKey: perGameKey)
    NotificationCenter.default.post(name: changed, object: nil)
  }

  /// Short name for buttons and the switch.
  static func shortTitle(_ choice: PlaysAs) -> String {
    switch choice {
    case .wiiRemote: return L("Wii Remote")
    case .wiiNunchuk: return L("Nunchuk")
    case .wiiClassic: return L("Classic")
    case .wiiSideways: return L("Sideways")
    case .gameCube: return L("GameCube")
    }
  }

  static func symbol(_ choice: PlaysAs) -> String {
    switch choice {
    case .wiiRemote: return "rectangle.portrait"
    case .wiiNunchuk: return "smallcircle.filled.circle"
    case .wiiClassic: return "gamecontroller"
    case .wiiSideways: return "rectangle"
    case .gameCube: return "cube"
    }
  }

  /// Player 1 plays as `choice` now (in a game, the touch controls change at once). Nothing moves
  /// between GameCube port 1 and Wii Remote 1, so GameCube games keep their controller: the switch
  /// sets Wii Remote 1's extension and sideways setting, and picks which pad the screen shows.
  @MainActor static func apply(_ choice: PlaysAs) {
    let manager = ControllerManager.shared
    if choice == .gameCube {
      manager.overlayMode = .gamecube
    } else {
      if manager.overlayMode == .gamecube { manager.overlayMode = .auto }
      let hub = ControllerHubViewModel(system: .wiiAndGameCube)
      hub.reload()
      // Same kind, so the hub's plan is only the extension and sideways writes.
      if let wii1 = hub.state.players.first(where: { $0.kind == .wiiRemote && $0.port == 1 }) {
        hub.setPlaysAs(wii1, choice)
      }
    }
    NSLog("[Wii] controls: %@", choice.title)
    // The extension and sideways settings alone don't rebuild the touch controls.
    NotificationCenter.default.post(name: Notification.Name("DOLWiiOverlayLayoutChangedNotification"), object: nil)
  }

  /// At the start of a Wii game: what this game was last played with.
  @MainActor static func applyForBoot(gameID: String) {
    apply(choice(for: gameID))
  }
}
