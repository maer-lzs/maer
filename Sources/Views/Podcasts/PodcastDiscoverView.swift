import SwiftUI

/// "Discover": trending podcasts via PodcastIndex (if a key is set), otherwise
/// iTunes top charts. Tapping "+" subscribes directly (on the server if ABS
/// podcasts are active; otherwise locally + gpodder reconcile).
struct PodcastDiscoverView: View {
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @State private var results: [PodcastSearchResult] = []
    @State private var loading = true
    @State private var loadError: String?

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 16)]
    /// D4/B3: more tile text lines at accessibility sizes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
            } else if let loadError {
                ContentUnavailableView(
                    "Couldn't load Discover",
                    systemImage: "wifi.exclamationmark",
                    description: Text(loadError)
                )
                .padding(.top, 40)
            } else if results.isEmpty {
                // No match or no PodcastIndex key stored → a clear empty state
                // instead of an empty grid.
                ContentUnavailableView(
                    "Nothing to show",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search, or add a PodcastIndex API key in Settings for richer discovery.")
                )
                .padding(.top, 40)
            } else {
                CoverGrid(columns: columns) {
                    ForEach(results) { tile($0) }
                }
                .padding()
                .bottomBarClearance()
            }
        }
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func tile(_ r: PodcastSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                podcastArtwork(url: r.artworkURL.flatMap { URL(string: $0) }, size: 108, corner: 12)
                PodcastSubscribeBadge(feedURL: r.feedURL).padding(6)
            }
            Text(r.title).font(.caption)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                .frame(width: 108, alignment: .leading)
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        do {
            if AppStorageKeys.podcastIndexConfigured {
                results = try await PodcastIndexDirectory(
                    key: AppStorageKeys.podcastIndexKeyValue,
                    secret: AppStorageKeys.podcastIndexSecretValue
                ).trending()
            } else {
                results = try await ITunesDirectory().topPodcasts()
            }
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }
}
