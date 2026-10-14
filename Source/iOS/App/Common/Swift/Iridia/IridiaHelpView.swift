// SPDX-License-Identifier: GPL-2.0-or-later
//
// gc-emu: Iridia's own help, built in (no downloads): adding games, controls, saves, and the free
// 10-minute play sessions. Replaces iCube's online wiki pages.

#if os(iOS)
import SwiftUI

struct IridiaHelpView: View {
  enum Topic: String { case all, saveStates }

  var topic: Topic = .all
  @State private var showFilesGuide = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        if topic == .saveStates {
          saveStates
        } else {
          section(L("Adding games"), [
            L("Iridia doesn't come with any games. Use your own game files."),
            L("Tap + at the top of your library, then Choose a Game File. Or move files into Iridia's Games folder with the Files app."),
            L("ISO, RVZ, GCM and CISO files work. ZIP and 7Z files are unpacked for you."),
          ])
          Button { showFilesGuide = true } label: {
            Label(L("How to Add Games with Files"), systemImage: "folder")
          }
          .buttonStyle(.bordered)

          section(L("Controls"), [
            L("The on-screen controller has every GameCube button. Drag the sticks for analog movement."),
            L("Tap ☰ at the bottom of the controller to pause. From there you can save, load, change settings or quit."),
            L("To move or resize buttons, go to Settings > Controllers > Edit Layout."),
            L("To use a game controller, pair it in the iPhone or iPad Settings app under Bluetooth. The on-screen controller hides while it's connected."),
          ])

          section(L("Saving"), [
            L("Most games save to a memory card from their own menus, just like on a GameCube."),
            L("Save states save the game at any moment. Find them in the pause menu."),
            L("When you leave a game, Iridia saves your spot. Tap Continue to pick up there, or Title Screen to start fresh."),
          ])
          saveStates

          section(L("Free play sessions"), [
            L("Iridia is free to play in 10-minute sessions, and you can start as many as you like. You'll get a warning a minute before a session ends."),
            L("When a session ends, your progress is saved. A one-time purchase removes the time limit."),
            L("Already bought it? Tap Unlock at the top of your library, then Restore Purchases."),
          ])
        }
      }
      .padding(20)
      .frame(maxWidth: 680)
      .frame(maxWidth: .infinity)
    }
    .iridiaScreen()
    .navigationTitle(topic == .saveStates ? L("Save States") : L("Help"))
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showFilesGuide) { FilesAppGuideView() }
  }

  private var saveStates: some View {
    section(L("Save states and updates"), [
      L("A save state made with a different version of Iridia might not load. If one says it's incompatible, load your memory card save from the game's own menu instead."),
      L("Memory card saves always carry over between versions."),
    ])
  }

  private func section(_ title: String, _ lines: [String]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      IridiaSectionLabel(text: title)
      VStack(alignment: .leading, spacing: 12) {
        ForEach(lines, id: \.self) { line in
          Text(line)
            .font(.system(size: 16))
            .foregroundStyle(IridiaGlass.ink)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .iridiaPanel()
    }
  }
}
#endif
