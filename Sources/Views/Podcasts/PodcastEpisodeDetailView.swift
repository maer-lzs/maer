// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import OSLog

/// Episode page: episode cover + title, linked show, play/resume, download,
/// played toggle and description. Background in the cover gradient like the
/// audiobook detail page.
struct PodcastEpisodeDetailView: View {
    @Environment(\.itemRouter) private var router
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var progress = PodcastProgressStore.shared
    /// Observed so the page follows the Audiobookshelf store: the show of an
    /// ABS episode is read from it (through `PodcastShowSources`) without
    /// observing there.
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    @StateObject private var colorLoader = CoverColorLoader()
    @State private var chapters: [ABSChapter] = []
    /// The shownotes from the detail: a subscribed episode carries none in
    /// memory, they are read when the episode opens.
    @State private var notes: String?
    @State private var showSettings = false
    /// The page stands on top of its stack (appeared, nothing pushed over it).
    @State private var isTopPage = false
    /// Timestamp column ("1:23:45") scales with Dynamic Type.
    @ScaledMetric(relativeTo: .footnote) private var timestampWidth: CGFloat = 52

    private var coverURL: URL? { router.coverURL(item.id) }
    /// Source-aware show, from the one rule every podcast surface asks.
    private var show: PodcastShow? { PodcastShowSources.show(forEpisodeId: item.id) }
    private var state: EpisodePlayState { podcastPlayState(for: item) }
    private var isPlayed: Bool { state == .played }
    private var isInProgress: Bool {
        if case .inProgress = state { return true } else { return false }
    }
    /// Rich episode metadata from the feed (season, type, people, transcript).
    private var podcastEpisode: PodcastEpisode? {
        show?.episodes.first { $0.guid == item.id }
    }

    // MARK: - Reiche Metadaten

    @ViewBuilder
    private func badges(_ ep: PodcastEpisode) -> some View {
        let explicit = PodcastExplicit.marks(
            episode: ep.explicit, show: PodcastSubscriptions.shared.episode(guid: item.id)?.show.explicit)
        let parts: [String] = [seasonEpisodeText(ep), typeText(ep), explicit ? PodcastExplicit.letter : nil]
            .compactMap { $0 }
        if !parts.isEmpty {
            HStack(spacing: 6) {
                ForEach(parts, id: \.self) { p in
                    Text(p)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.white.opacity(0.18), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private func seasonEpisodeText(_ ep: PodcastEpisode) -> String? {
        var parts: [String] = []
        if let s = ep.season { parts.append("S\(s)") }
        if let n = ep.episodeNumber { parts.append("E\(n)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func typeText(_ ep: PodcastEpisode) -> String? {
        switch ep.episodeType {
        case "trailer": return String(localized: "Trailer")
        case "bonus": return String(localized: "Bonus")
        default: return nil
        }
    }

    @ViewBuilder
    private var episodeLinks: some View {
        if let ep = podcastEpisode, ep.transcriptURL != nil || ep.link != nil {
            // Among the head's controls, as on the show.
            DetailLinkRow {
                if let t = ep.transcriptURL, let url = URL(string: t) {
                    Link(destination: url) { Label("Transcript", systemImage: "doc.text") }
                }
                if let l = ep.link, let url = URL(string: l) {
                    Link(destination: url) { Label("Website", systemImage: "safari") }
                }
            }
            .tint(.white)
        }
    }

    @ViewBuilder
    private var metadataSection: some View {
        if let ep = podcastEpisode, ep.persons?.isEmpty == false {
            VStack(alignment: .leading, spacing: 10) {
                if let persons = ep.persons, !persons.isEmpty {
                    Text("People").font(.headline).foregroundStyle(.white)
                    ForEach(persons, id: \.self) { p in
                        HStack(spacing: 6) {
                            Text(p.name).foregroundStyle(.white)
                            if let role = p.role, !role.isEmpty {
                                Text(role).font(.caption).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .font(.subheadline)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: colorLoader.topAccent, location: 0.0),
                    .init(color: colorLoader.topAccent.opacity(0.6), location: 0.35),
                    .init(color: .black.opacity(0.85), location: 0.8)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // In a wide window the head stands beside notes and chapters,
            // divided at the fold (`DetailScrollColumns`).
            DetailScrollColumns(spacing: 18) {
                    DetailHeader(title: item.title, titleStyle: AnyShapeStyle(.white)) { side in
                        podcastArtwork(url: coverURL, size: side ?? 220, corner: DetailCoverCard.cornerRadius)
                            .coverCard()
                            .opacity(isPlayed ? 0.6 : 1)
                            // Download and delete live here, on the cover's
                            // long press: the episode's own menu.
                            .podcastEpisodeMenu(item: item, playerCoordinator: playerCoordinator)
                    } lines: {
                        showLink
                        Text(metaText)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                        if let ep = podcastEpisode { badges(ep) }
                    } actions: {
                        // Text-only episodes show the notes without play/
                        // download/played affordances (nothing to hear).
                        VStack(spacing: 12) {
                            if !isTextOnly {
                                HStack(spacing: 14) {
                                    playButton
                                    PodcastDownloadButton(item: item)
                                    markPlayedButton
                                }
                            }
                            episodeLinks
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 40)
            } content: {
                VStack(spacing: 18) {
                    metadataSection
                    chaptersSection

                    if let description = notes ?? item.media?.metadata?.description, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Description").font(.headline).foregroundStyle(.white)
                            Text(podcastPlainText(description))
                                .font(.body)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 20)
            }
            // The page stands on the cover gradient fading to black, so it is
            // dark in either system mode: the main button's glass and label
            // read light on it, as on the book page.
            .environment(\.colorScheme, .dark)
            // While it is the top page, the side column takes the same
            // brightness (`sideColumnScheme`).
            .sideColumnScheme(isTopPage ? .dark : nil)
            .onAppear { isTopPage = true }
            .onDisappear { isTopPage = false }
        }
        .untitledDetailPage()
        // The show's settings from its episode too. The show comes
        // only from a store, so there is one whenever there are settings.
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if show != nil {
                    PodcastShowSettingsButton { showSettings = true }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            Group {
                if let show { PodcastShowSettingsEntry(show: show) }
            }
            .followsAppearanceChoice()
        }
        .task(id: coverURL) { await colorLoader.load(from: coverURL) }
        // Load chapters lazily (RSS: JSON file, ABS: from the episode object).
        .task(id: item.id) {
            do {
                let detail = try await router.provider(item.id).fetchItemDetail(itemId: item.id)
                chapters = detail.media.chapters ?? []
                notes = detail.media.metadata?.description
            } catch {
                // The page stands without chapters and with the notes the
                // entry carries; the line says why. A page left is no failure.
                if Task.isCancelled { return }
                chapters = []
                notes = nil
                Logger.rss.notice("EPISODE detail failed reason=\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Chapter list (Podcasting 2.0 / ABS). Tapping plays from that point.
    @ViewBuilder
    private var chaptersSection: some View {
        if !chapters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chapters").font(.headline).foregroundStyle(.white)
                ForEach(chapters) { chapter in
                    Button {
                        Task {
                            await playerCoordinator.open(item: item)
                            await playerCoordinator.viewModel?.seek(to: chapter.start)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Text(chapterTimestamp(chapter.start))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: timestampWidth, alignment: .leading)
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            Image(systemName: "play.circle")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(.white.opacity(0.12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
    }

    /// Seconds → "m:ss" or "h:mm:ss".
    private func chapterTimestamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    @ViewBuilder
    private var showLink: some View {
        if let show {
            NavigationLink(value: PodcastRoute.show(feedURL: show.feedURL)) {
                HStack(spacing: 8) {
                    podcastArtwork(url: show.artworkURL.flatMap { URL(string: $0) }, size: 24, corner: 5)
                    Text(show.title).font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
        }
    }

    /// A text-only episode has nothing to play. The page shows the
    /// notes without the play affordance.
    private var isTextOnly: Bool {
        !PodcastSubscriptions.shared.isPlayableEpisode(itemId: item.id)
    }

    private var playButton: some View {
        DetailMainButton(title: isInProgress ? String(localized: "Resume") : String(localized: "Play"),
                         systemImage: "play.fill") {
            Task {
                if podcastRestartsOnPlay(item) {
                    // Replay a finished episode from the beginning + mark unplayed.
                    podcastSetPlayed(item, false)
                    await playerCoordinator.open(item: item, restart: true)
                } else {
                    await playerCoordinator.open(item: item)
                }
            }
        }
    }

    private var markPlayedButton: some View {
        // The icon is the toggle, so it shows what a tap does: within the
        // tail it offers "played", like every other toggle.
        let gesture = podcastMarkGesture(item)
        return Button {
            podcastSetPlayed(item, gesture.marksPlayed)
            // Marking played behaves like a natural end. If this episode
            // is the active session, playback stops and auto-continue advances
            // (parity with the audiobook detail page).
            // `podcastSetPlayed` draws that consequence itself now, in one
            // place for every surface.
        } label: {
            Image(systemName: gesture.marksPlayed ? "checkmark.circle" : "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(gesture.marksPlayed ? Text("Mark as Played") : Text("Mark as Unplayed"))
    }

    private var metaText: String {
        var parts: [String] = []
        let date = relativeDateText(item)
        if !date.isEmpty { parts.append(date) }
        switch state {
        case .played:
            parts.append(String(localized: "Played"))
        case .inProgress(_, let remaining):
            parts.append(DurationText.remaining(seconds: remaining))
        case .unplayed:
            if let duration = item.media?.duration, duration > 0 { parts.append(durationText(item)) }
        }
        return parts.joined(separator: " · ")
    }
}
