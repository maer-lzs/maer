import SwiftUI
import Combine

/// Folgenliste einer Show mit Kopf (Artwork, Titel, Autor, Beschreibung).
struct PodcastShowView: View {
    let show: PodcastShow
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @Environment(\.dismiss) private var dismiss

    @State private var descriptionExpanded = false
    @State private var showDeleteConfirm = false
    // „Ältere Folgen nachladen" (nur ABS-Shows): Feed-Folgen, die noch nicht am
    // Server liegen.
    @State private var available: [FeedEpisode] = []
    @State private var availableLoaded = false
    @State private var loadingAvailable = false
    @State private var downloading: Set<String> = []
    @State private var downloadError: String?
    @State private var loadingHistory = false
    @State private var historyResult: String?
    @State private var showSettings = false
    private var isServerShow: Bool { show.id.hasPrefix("abspod:") }

    /// Aktuelle Show aus dem Store (nicht der beim Öffnen übergebene Snapshot) —
    /// damit nachgeladene Folgen (PodcastIndex/Server) sofort erscheinen.
    private var liveShow: PodcastShow {
        if isServerShow { return absPodcast.shows.first { $0.id == show.id } ?? show }
        return subs.shows.first { $0.id == show.id } ?? show
    }
    /// Sortierrichtung pro Show gemerkt (Default: neueste zuerst).
    @AppStorage private var newestFirst: Bool

    init(show: PodcastShow, playerCoordinator: PlayerCoordinator) {
        self.show = show
        _playerCoordinator = ObservedObject(wrappedValue: playerCoordinator)
        _newestFirst = AppStorage(wrappedValue: true, "podcastSort.\(show.id)")
    }

    /// Folgen dieser Show als LibraryItems, nach Umschalter sortiert — lazy im
    /// Body (nur wenn die Seite wirklich angezeigt wird).
    private var sortedItems: [LibraryItem] {
        AppSession.shared.rssProvider.showItems(for: liveShow).sorted { a, b in
            let da = a.addedAt ?? 0, db = b.addedAt ?? 0
            return newestFirst ? da > db : da < db
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                Divider().padding(.horizontal)
                LazyVStack(spacing: 0) {
                    ForEach(sortedItems) { item in
                        PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
                        Divider().padding(.leading, 88)
                    }
                }
                if isServerShow { availableSection } else { historySection }
            }
            .padding(.top, 8)
            .bottomBarClearance()
        }
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
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
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture { withAnimation { descriptionExpanded.toggle() } }
            }
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

    /// ABS-Show: archivieren (Server bleibt) bzw. endgültig löschen; RSS-Show:
    /// lokal abbestellen.
    @ViewBuilder
    private var manageButton: some View {
        if isServerShow {
            Menu {
                Button {
                    absPodcast.setArchived(show.id, true)
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
                subs.unsubscribe(id: show.id)
                dismiss()
            } label: {
                Label("Unsubscribe", systemImage: "minus.circle")
            }
        }
    }

    /// Feed-Folgen, die noch nicht am Server liegen — server-seitig nachladbar
    /// (für „von Anfang an hören"). Wird erst auf Knopfdruck geladen.
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
                        // Tippen = sofort vom Original-Host streamen (rss:-Item,
                        // Fortschritt lokal+iCloud); Pfeil = am Server sichern.
                        let item = feedEpisodePlayItem(show: liveShow, feed: ep)
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle").font(.title2).foregroundStyle(AppTheme.accent)
                            Text(ep.title).font(.subheadline).lineLimit(2)
                            Spacer(minLength: 8)
                            if downloading.contains(ep.id) {
                                ProgressView()
                            } else {
                                Button {
                                    downloadAvailable(ep)
                                } label: {
                                    Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal).padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Für „Download-on-Play" registrieren, dann streamen.
                            PodcastServerSave.shared.register(rssItemId: item.id, showId: show.id, feed: ep)
                            Task { await playerCoordinator.open(item: item) }
                        }
                        Divider().padding(.leading)
                    }
                }
            }
        }
    }

    /// Server anweisen, die Folge zu laden; danach neu einlesen (der Download
    /// läuft server-seitig asynchron, daher kurz warten).
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

    /// RSS-Shows: volle Folgen-Historie über PodcastIndex nachladen (wenn Key
    /// hinterlegt) — holt auch alte Folgen, die aus dem Live-Feed gefallen sind.
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
