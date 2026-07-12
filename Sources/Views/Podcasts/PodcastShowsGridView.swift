import SwiftUI
import Combine

/// Vollständiges Sendungs-Grid (erreichbar über „See All" in der Shows-Reihe).
struct PodcastShowsGridView: View {
    let shows: [PodcastShow]
    @ObservedObject var playerCoordinator: PlayerCoordinator
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(shows) { show in
                    NavigationLink {
                        PodcastShowView(show: show, playerCoordinator: playerCoordinator)
                    } label: {
                        ShowTile(show: show)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .bottomBarClearance()
        }
        .navigationTitle("Shows")
        .navigationBarTitleDisplayMode(.inline)
    }
}
