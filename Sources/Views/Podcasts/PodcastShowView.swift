import SwiftUI
import Combine

/// Episode list of a show with header (artwork, title, author, description).
struct PodcastShowView: View {
    let show: PodcastShow
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @Environment(\.dismiss) private var dismiss

    @State private var descriptionExpanded = false
    @State private var showDeleteConfirm = false
    // "Load older episodes" (ABS shows only): feed episodes not yet on the server.
    @State private var available: [FeedEpisode] = []
    @State private var availableLoaded = false
    @State private var loadingAvailable = false
    @State private var downloading: Set<String> = []
    @State private var downloadError: String?
    @State private var loadingHistory = false
    @State private var historyResult: String?
    @State private var showSettings = false
    private var isServerShow: Bool { show.id.hasPrefix("abspod:") }

    /// Current show from the store (not the snapshot passed on open) — so
    /// loaded-in episodes (PodcastIndex/server) appear immediately.
    private var liveShow: PodcastShow {
        if isServerShow { return absPodcast.shows.first { $0.id == show.id } ?? show }
        return subs.shows.first { $0.id == show.id } ?? show
    }
    /// Sort direction remembered per show (default: newest first).
    @AppStorage private var newestFirst: Bool

    init(show: PodcastShow, playerCoordinator: PlayerCoordinator) {
        self.show = show
        _playerCoordinator = ObservedObject(wrappedValue: playerCoordinator)
        _newestFirst = AppStorage(wrappedValue: true, "podcastSort.\(show.id)")
    }

    /// Episodes of this show as LibraryItems, sorted by the toggle — lazy in the
    /// body (only when the page is actually shown).
    private var sortedItems: [LibraryItem] {
        AppSession.shared.rssProvider.showItems(for: liveShow).sorted { a, b in
            let da = a.addedAt ?? 0, db = b.addedAt ?? 0
            return newestFirst ? da > db : da < db
        }
    }

    /// Bulk mark every episode of this show as played/unplayed. One iCloud
    /// reconcile at the end instead of one per episode (each full reconcile
    /// scans ALL UserDefaults keys).
    private func markAllEpisodes(played: Bool) {
        for item in sortedItems {
            podcastSetPlayed(item, played, syncCloud: false)
        }
        PodcastCloudSync.shared.reconcile()
    }

    var body: some View {
        // `List` (instead of ScrollView) → swipe actions on the episode rows.
        List {
            header
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                // Force-touch the show header to bulk-update the played state.
                .contextMenu {
                    Button {
                        markAllEpisodes(played: true)
                    } label: {
                        Label("Mark All as Played", systemImage: "checkmark.circle")
                    }
                    Button {
                        markAllEpisodes(played: false)
                    } label: {
                        Label("Mark All as Unplayed", systemImage: "circle")
                    }
                }
            ForEach(sortedItems) { item in
                PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.visible)
            }
            Group { if isServerShow { availableSection } else { historySection } }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .bottomBarClearance()
        .reportsBottomBarScroll()
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Y63 (parity): the per-show settings slider inboard, the global
            // app settings cog OUTERMOST (declared last) so it stays visible on
            // this pushed page like on the music album page.
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                SettingsToolbarButton()
            }
        }
        .sheet(isPresented: $showSettings) {
            PodcastShowSettingsSheet(showId: show.id, newestFirst: $newestFirst)
        }
        .alert("Download failed", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("OK", role: .cancel) { downloadError = nil }
        } message: {
            if let downloadError { Text(downloadError) }
        }
    }

    /// Reiche Show-Metadaten (Kategorien, Folgenzahl, Sprache, Website/Funding).
    @ViewBuilder
    private var showMetaSection: some View {
        let s = liveShow
        VStack(spacing: 8) {
            if let cats = s.categories, !cats.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(cats, id: \.self) { c in
                            Text(c)
                                .font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Text("\(s.episodes.count) episodes").font(.caption).foregroundStyle(.secondary)
                if let lang = s.language, !lang.isEmpty {
                    Text(lang.uppercased()).font(.caption).foregroundStyle(.secondary)
                }
                if s.explicit == true {
                    Text("E").font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            if s.link != nil || s.funding?.isEmpty == false {
                HStack(spacing: 18) {
                    if let l = s.link, let url = URL(string: l) {
                        Link(destination: url) { Label("Website", systemImage: "safari") }
                    }
                    if let f = s.funding?.first, let url = URL(string: f.url) {
                        Link(destination: url) {
                            Label(f.label ?? String(localized: "Support"), systemImage: "heart")
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            podcastArtwork(url: show.artworkURL.flatMap { URL(string: $0) }, size: 150, corner: 16)
            VStack(spacing: 4) {
                Text(show.title).font(.headline).multilineTextAlignment(.center)
                if let author = show.author {
                    Text(author).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let description = show.description, !description.isEmpty {
                Text(podcastPlainText(description))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { withAnimation { descriptionExpanded.toggle() } }
            }
            showMetaSection
            manageButton
                .font(.subheadline)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .confirmationDialog("Delete on server?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete on server", role: .destructive) {
                Task { _ = await absPodcast.deleteShowOnServer(showId: show.id); dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the podcast and its listening history from the server for everyone.")
        }
    }

    /// ABS show: archive (server stays) or delete permanently; RSS show:
    /// unsubscribe locally.
    @ViewBuilder
    private var manageButton: some View {
        if isServerShow {
            Menu {
                Button {
                    podcastUnsubscribe(show)   // archive ABS + remove possible RSS duplicate
                    dismiss()
                } label: {
                    Label("End subscription (archive)", systemImage: "archivebox")
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete on server", systemImage: "trash")
                }
            } label: {
                Label("Manage subscription", systemImage: "ellipsis.circle")
            }
        } else {
            Button(role: .destructive) {
                podcastUnsubscribe(show)   // from both sources (RSS + possibly ABS)
                dismiss()
            } label: {
                Label("Unsubscribe", systemImage: "minus.circle")
            }
        }
    }

    /// Feed episodes not yet on the server — downloadable server-side (for
    /// "listen from the start"). Loaded only on button press.
    @ViewBuilder
    private var availableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.horizontal)
            if !availableLoaded {
                Button {
                    Task {
                        loadingAvailable = true
                        available = await absPodcast.availableEpisodes(for: show)
                        availableLoaded = true
                        loadingAvailable = false
                    }
                } label: {
                    Label(loadingAvailable ? String(localized: "Loading…") : String(localized: "Load older episodes"),
                          systemImage: "tray.and.arrow.down")
                }
                .disabled(loadingAvailable)
                .padding(.horizontal)
            } else if available.isEmpty {
                Text("All feed episodes are on the server.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            } else {
                Text("Available episodes").font(.title3).bold().padding(.horizontal)
                LazyVStack(spacing: 0) {
                    ForEach(available) { ep in
                        // Tap = stream immediately from the original host (rss:
                        // item, progress local+iCloud); arrow = save on the server.
                        let item = feedEpisodePlayItem(show: liveShow, feed: ep)
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle").font(.title2).foregroundStyle(.secondary)
                            Text(ep.title).font(.subheadline).lineLimit(2)
                            Spacer(minLength: 8)
                            if downloading.contains(ep.id) {
                                ProgressView()
                            } else {
                                Button {
                                    downloadAvailable(ep)
                                } label: {
                                    Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(.secondary)
                                        // D8/B7: 44pt hit area.
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal).padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Register for "download-on-play", then stream.
                            PodcastServerSave.shared.register(rssItemId: item.id, showId: show.id, feed: ep)
                            Task { await playerCoordinator.open(item: item) }
                        }
                        Divider().padding(.leading)
                    }
                }
            }
        }
    }

    /// Tell the server to load the episode; then re-read (the download runs
    /// server-side asynchronously, so wait briefly).
    private func downloadAvailable(_ ep: FeedEpisode) {
        downloading.insert(ep.id)
        Task {
            if let error = await absPodcast.downloadEpisode(showId: show.id, episode: ep) {
                downloadError = error
                downloading.remove(ep.id)
                return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await absPodcast.refresh()
            available.removeAll { $0.id == ep.id }
            downloading.remove(ep.id)
        }
    }

    /// RSS shows: load the full episode history via PodcastIndex (if a key is
    /// set) — also fetches old episodes that fell out of the live feed.
    @ViewBuilder
    private var historySection: some View {
        if AppStorageKeys.podcastIndexConfigured {
            VStack(alignment: .leading, spacing: 8) {
                Divider().padding(.horizontal)
                Button {
                    Task {
                        loadingHistory = true
                        let n = await subs.loadFullHistory(showId: show.id)
                        historyResult = n > 0
                            ? String(localized: "\(n) episodes added")
                            : String(localized: "No additional episodes found.")
                        loadingHistory = false
                    }
                } label: {
                    Label(loadingHistory ? String(localized: "Loading…") : String(localized: "Load full history"),
                          systemImage: "clock.arrow.circlepath")
                }
                .disabled(loadingHistory)
                .padding(.horizontal)
                if let historyResult {
                    Text(historyResult).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
        }
    }
}
