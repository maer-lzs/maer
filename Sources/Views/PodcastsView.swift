import SwiftUI

/// Podcast-Tab im Inbox-Stil (Overcast/Castro): oben eine große horizontale
/// Cover-Reihe der abonnierten Shows (Blickfang), darunter die dominante
/// „Neueste Folgen"-Liste. Episoden sind normale `LibraryItem`s und laufen
/// über den bestehenden Player/Coordinator.
struct PodcastsView: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var subs = PodcastSubscriptions.shared
    private var rss: RSSProvider { AppSession.shared.rssProvider }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                showsShelf
                latestEpisodes
            }
            .padding(.top, 8)
            .bottomBarClearance()
        }
        .refreshable { await subs.refreshAll() }
    }

    // MARK: - Shows (große Cover-Reihe)

    @ViewBuilder
    private var showsShelf: some View {
        let shows = rss.showsWithEpisodes()
        if !shows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Shows").font(.title3).bold().padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(shows, id: \.show.id) { entry in
                            NavigationLink {
                                PodcastShowView(
                                    show: entry.show,
                                    items: entry.items,
                                    playerCoordinator: playerCoordinator
                                )
                            } label: {
                                ShowTile(show: entry.show)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Neueste Folgen (Inbox)

    @ViewBuilder
    private var latestEpisodes: some View {
        let episodes = rss.latestEpisodeItems()
        VStack(alignment: .leading, spacing: 8) {
            Text("Latest Episodes").font(.title3).bold().padding(.horizontal)
            if episodes.isEmpty {
                Text("No episodes yet.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 8)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(episodes) { item in
                        PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
                        Divider().padding(.leading, 88)
                    }
                }
            }
        }
    }
}

/// Große Show-Kachel für die obere Reihe — bewusst größer als alle anderen
/// Cover in der App (Blickfang).
private struct ShowTile: View {
    let show: PodcastShow
    private let size: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            podcastArtwork(url: show.artworkURL.flatMap { URL(string: $0) }, size: size, corner: 14)
            Text(show.title)
                .font(.caption)
                .lineLimit(2)
                .frame(width: size, alignment: .leading)
        }
    }
}

/// Folgenliste einer Show mit Kopf (Artwork, Titel, Autor, Beschreibung).
struct PodcastShowView: View {
    let show: PodcastShow
    let items: [LibraryItem]
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @Environment(\.dismiss) private var dismiss

    @State private var descriptionExpanded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                Divider().padding(.horizontal)
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator)
                        Divider().padding(.leading, 88)
                    }
                }
            }
            .padding(.top, 8)
            .bottomBarClearance()
        }
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
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
            Button(role: .destructive) {
                subs.unsubscribe(id: show.id)
                dismiss()
            } label: {
                Label("Unsubscribe", systemImage: "minus.circle")
            }
            .font(.subheadline)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
    }
}

/// Reiche Episoden-Zeile: Cover, Show + Titel, Datum/Restzeit, Fortschritt,
/// Play- und Download-Button. Tap spielt ab.
struct PodcastEpisodeRow: View {
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var downloads = DownloadManager.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            podcastArtwork(url: AppSession.shared.coverURL(forItemId: item.id), size: 64, corner: 8)

            VStack(alignment: .leading, spacing: 3) {
                if let show = item.media?.metadata?.authorName {
                    Text(show.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)

                if let progress = episodeProgress {
                    // Angespielt: dünner Balken + Restzeit.
                    ProgressView(value: progress.fraction)
                        .tint(AppTheme.accent)
                        .padding(.trailing, 40)
                        .padding(.top, 2)
                }

                HStack(spacing: 8) {
                    Text(metaText).font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    downloadButton
                    playButton
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { Task { await playerCoordinator.open(item: item) } }
    }

    // MARK: Teile

    private var playButton: some View {
        Button {
            Task { await playerCoordinator.open(item: item) }
        } label: {
            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(AppTheme.accent)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var downloadButton: some View {
        if downloads.isDownloaded(itemId: item.id) {
            Image(systemName: "checkmark.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        } else if case .downloading(let f) = downloads.phase[item.id] {
            ProgressView(value: f).progressViewStyle(.circular).scaleEffect(0.7)
        } else {
            Button {
                Task {
                    guard let detail = try? await AppSession.shared.rssProvider.fetchItemDetail(itemId: item.id) else { return }
                    await DownloadManager.shared.download(item: detail, provider: AppSession.shared.rssProvider)
                }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Daten

    /// Lokaler Fortschritt der Episode (kein Server) — direkt aus localPosition.
    private var episodeProgress: (fraction: Double, remaining: Double)? {
        guard let duration = item.media?.duration, duration > 0,
              let stored = UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(item.id)) as? [Double],
              stored.count == 2 else { return nil }
        let time = stored[0]
        guard time > 1, time < duration - 1 else { return nil }
        return (min(max(time / duration, 0), 1), duration - time)
    }

    /// „vor 2 Tagen · 45 Min" bzw. „vor 2 Tagen · 12 Min übrig".
    private var metaText: String {
        var parts: [String] = []
        if let added = item.addedAt, added > 0 {
            parts.append(Date(timeIntervalSince1970: added / 1000)
                .formatted(.relative(presentation: .named)))
        }
        if let progress = episodeProgress {
            parts.append(String(localized: "\(Int(progress.remaining / 60)) min left"))
        } else if let duration = item.media?.duration, duration > 0 {
            parts.append(String(localized: "\(Int(duration / 60)) min"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Podcast-Cover (Remote-URL) mit Fallback-Mikrofon.
@ViewBuilder
private func podcastArtwork(url: URL?, size: CGFloat, corner: CGFloat) -> some View {
    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
    Group {
        if let url {
            CachedAsyncImage(url: url, useThumbnail: size <= 200) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                shape.fill(Color.secondary.opacity(0.15))
            }
        } else {
            shape.fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: "mic").font(.title3).foregroundStyle(.secondary))
        }
    }
    .frame(width: size, height: size)
    .clipShape(shape)
}
