import SwiftUI

struct SaveStatesBrowserView: View {
  @StateObject private var vm = SaveStatesViewModel()

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        ForEach(vm.grouped, id: \.gameID) { group in
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              #if os(iOS)
              // gc-emu: the game's name, in Iridia colours.
              Text(title(for: group.gameID))
                .font(.title2.weight(.semibold))
                .foregroundStyle(IridiaGlass.ink)
                .lineLimit(1)
              Text("\(group.states.count)")
                .font(.callout)
                .foregroundStyle(IridiaGlass.dim)
              #else
              Text(group.gameID)
                .font(.title2.weight(.semibold))
              Text("\(group.states.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
              #endif
              Spacer()
              NavigationLink("View All") {
                SaveStateFilmstripView(gameID: group.gameID)
              }
            }
            .padding(.horizontal)

            ScrollView(.horizontal) {
              LazyHStack(spacing: 16) {
                ForEach(group.states.prefix(10)) { state in
                  SaveStateCardView(state: state, thumbnail: vm.thumbnails[state.id])
                }
              }
              .padding(.horizontal)
            }
          }
        }
      }
      .padding(.vertical, 16)
    }
    .navigationTitle(L("Save States"))
    .task { await vm.loadAll() }
    #if os(iOS)
    .iridiaScreen()
    #endif
  }

  #if os(iOS)
  private func title(for gameID: String) -> String {
    TVLibraryBridge.currentGames().first(where: { $0.gameID == gameID })?.title ?? gameID
  }
  #endif
}
