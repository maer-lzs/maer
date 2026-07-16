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
    @State private var subscribing: Set<String> = []

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
                subscribeControl(r).padding(6)
            }
            Text(r.title).font(.caption)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                .frame(width: 108, alignment: .leading)
        }
    }

    @ViewBuilder
    private func subscribeControl(_ r: PodcastSearchResult) -> some View {
        if isSubscribed(r.feedURL) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, .green)
                .background(Circle().fill(.black.opacity(0.25)))
        } else if subscribing.contains(r.feedURL) {
            ProgressView().controlSize(.small)
                .padding(4).background(Circle().fill(.black.opacity(0.35)))
        } else {
            Button {
                subscribing.insert(r.feedURL)
                Task {
                    await subscribe(r.feedURL)
                    subscribing.remove(r.feedURL)
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, AppTheme.accent)
            }
            .buttonStyle(.plain)
        }
    }

    /// Already subscribed (locally OR on the server) — normalized feed URL.
    private func isSubscribed(_ feedURL: String) -> Bool {
        let n = PodcastSubscriptions.normalizeFeedURL(feedURL)
        return subs.shows.contains { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
            || absPodcast.shows.contains { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
    }

    private func subscribe(_ feedURL: String) async {
        if AppStorageKeys.absPodcastsEnabledValue, absPodcast.hasPodcasts {
            _ = await absPodcast.subscribeOnServer(feedURL: feedURL)
        } else {
            _ = await subs.subscribe(urlString: feedURL)
            await GPodderSync.shared.reconcile()   // push the new subscription to the server
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
