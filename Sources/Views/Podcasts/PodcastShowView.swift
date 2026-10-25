// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine

/// THE show page. One surface for both states, because the difference between
/// a subscribed and a merely browsed show is the STATE, not the surface.
///
/// A browsed show got its own smaller page once, and the two drifted: the
/// small one cut the episode list at 25 and did not know every spelling of the
/// show image, while this one could do both. What one surface learns, the
/// other one did not.
///
/// The subscribed state is unchanged by construction: it takes the same show
/// value, reads the same store, keeps the same controls. The browsed state
/// sits beside it and takes its episodes from the freshly parsed feed. What
/// the two really differ in lives in `PodcastShowCapabilities`, resolved ONCE
/// here and handed down, so a control cannot forget to ask.
struct PodcastShowView: View {
    /// The show as it was passed in. Present for a subscribed show and for the
    /// server's own shows; nil while a browsed feed is still loading.
    private let seedShow: PodcastShow?
    /// The address the page stands for. It survives subscribing, so the page
    /// switches state under the same navigation entry.
    private let feedURL: String

    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared
    /// Cell-cost sweep: the episode ROWS carry no observers anymore. The PAGE
    /// observes coarsely instead (ONE subscription set per page, not five per
    /// row): the recompute scope covers progress/download changes (played
    /// flips, finished downloads). The offline dim needs no subscription here
    /// any more, because the rows read the online answer as a value and the
    /// value invalidates exactly them.
    @ObservedObject private var recomputeScope = PodcastsRecomputeScope.shared
    @Environment(\.dismiss) private var dismiss

    @State private var descriptionExpanded = false
    @State private var showDeleteConfirm = false
    @State private var showUnsubscribeConfirm = false
    // "Load older episodes" (ABS shows only): feed episodes not yet on the server.
    @State private var available: [FeedEpisode] = []
    @State private var availableLoaded = false
    @State private var loadingAvailable = false
    @State private var downloading: Set<String> = []
    @State private var downloadError: String?
    /// The sentence of a delete the server did not take; the page stays.
    @State private var deleteError: String?
    @State private var loadingHistory = false
    @State private var historyResult: String?
    @State private var showSettings = false
    /// The freshly parsed feed of a show nobody subscribed to. It lives for
    /// the visit; leaving the page discards it.
    @State private var fetchedShow: PodcastShow?
    @State private var fetchFailed = false
    /// Sort and filter. Loaded through the ONE rule that decides whether they
    /// were ever written down, so a browsed show starts from the default.
    @State private var preferences = PodcastShowPreferences.default
    /// The new-link prompt and the sign-in sheet of a refused feed.
    @State private var newLinkText = ""
    @State private var askingNewLink = false
    @State private var newLinkFailed = false
    @State private var freeTwinFailed = false
    /// Counts the page's reads; see `readPreferences`.
    @State private var readCount = 0
    @State private var signInShow: PodcastShow?
    /// The sign-in's moment when the sheet opened; see `asksAgainAfterSignIn`.
    @State private var signInMomentBefore: Double?

    init(show: PodcastShow, playerCoordinator: PlayerCoordinator) {
        self.seedShow = show
        self.feedURL = show.feedURL
        _playerCoordinator = ObservedObject(wrappedValue: playerCoordinator)
    }

    /// A show reached without a subscription. The feed is parsed on appear;
    /// until then the catalog entry that the tile was built from carries the
    /// header, so the page is never blank.
    init(feedURL: String, playerCoordinator: PlayerCoordinator) {
        self.seedShow = nil
        self.feedURL = feedURL
        _playerCoordinator = ObservedObject(wrappedValue: playerCoordinator)
    }

    // MARK: - State of this page

    private var normalizedFeed: String { PodcastSubscriptions.normalizeFeedURL(feedURL) }

    /// The show as the SUBSCRIPTION stores know it. Looked up per render, so
    /// subscribing on this page switches the state without a new push.
    ///
    /// A show handed in BY VALUE ends the search: it came from a store, and
    /// the stores load asynchronously. Without that last step a page opened
    /// during a cold start would find empty stores, read itself as browsed and
    /// offer subscribing to a show that is already subscribed.
    private var storedShow: PodcastShow? {
        if let id = seedShow?.id, ItemNamespace.isABSPodcast(id) {
            return absPodcast.shows.first { $0.id == id } ?? seedShow
        }
        if let found = subs.shows.first(where: {
            PodcastSubscriptions.normalizeFeedURL($0.feedURL) == normalizedFeed
        }) { return found }
        if let found = absPodcast.shows.first(where: {
            PodcastSubscriptions.normalizeFeedURL($0.feedURL) == normalizedFeed
        }) { return found }
        return seedShow
    }

    private var mode: PodcastShowMode { storedShow != nil ? .subscribed : .browsed }
    private var caps: PodcastShowCapabilities { .of(mode) }

    /// The show the page draws. The stored one wins, because it is the one
    /// truth for what we own; otherwise the parsed feed, otherwise the seed.
    private var liveShow: PodcastShow? { storedShow ?? fetchedShow ?? seedShow }

    /// Catalog entry the tile was built from, for the header while the feed
    /// loads. Best effort: the pool may have rotated since.
    private var catalogSeed: PodcastSearchResult? {
        PodcastRecommendationsStore.shared.results.first {
            PodcastSubscriptions.normalizeFeedURL($0.feedURL) == normalizedFeed
        }
    }

    private var isServerShow: Bool { liveShow.map { ItemNamespace.isABSPodcast($0.id) } == true }
    private var title: String { liveShow?.title ?? catalogSeed?.title ?? "" }

    // MARK: - Episodes

    /// Episodes of this show as LibraryItems, sorted by the toggle. Lazy in the
    /// body (only when the page is actually shown). The mapping is the pure
    /// one every podcast surface uses; the show carries its episodes, so no
    /// source has to be asked.
    private var sortedItems: [LibraryItem] {
        guard let show = liveShow else { return [] }
        let newestFirst = preferences.newestFirst
        let items = show.episodes.map { podcastLibraryItem(show: show, episode: $0) }
        let chronological = items.sorted { a, b in
            let da = a.addedAt ?? 0, db = b.addedAt ?? 0
            return newestFirst ? da > db : da < db
        }
        // Container feeds (the radio-play pools) interleave many
        // works. The parts of one work become a contiguous block, ascending
        // inside, positioned where the block's first part already stood.
        // Below the density threshold nothing moves at all.
        return PodcastWorkOrder.ordered(chronological, newestFirst: newestFirst) { $0.title }
    }

    /// What the list shows. The filter's edge is "counts as played"
    /// (`ProgressMark`, the one decision), never "has progress": a half-heard
    /// episode stays. The RUNNING episode stays too, even once it counts as
    /// played. A list that pulls the playing row away from under the finger
    /// answers a question nobody asked.
    private var visibleItems: [LibraryItem] {
        guard preferences.unplayedOnly else { return sortedItems }
        return sortedItems.filter { item in
            if item.id == playerCoordinator.activeItem?.id { return true }
            return PodcastProgressStore.shared.state(for: item) != .played
        }
    }

    /// Bulk mark every episode of this show as played/unplayed. One iCloud
    /// reconcile at the end instead of one per episode (each full reconcile
    /// scans ALL UserDefaults keys). The import marks the tombstones clear
    /// are written once at the end, not per episode.
    private func markAllEpisodes(played: Bool) {
        ForeignMarks.clearingTogether {
            for item in sortedItems {
                podcastSetPlayed(item, played, syncCloud: false)
            }
        }
        PodcastCloudSync.shared.reconcile()
    }

    var body: some View {
        // `List` (instead of ScrollView) → swipe actions on the episode rows.
        // In a wide window the header stands beside the list, divided at
        // the fold (`DetailListColumns`).
        DetailListColumns {
            header
                // The header row holds a cover, links and the subscription
                // button. Without a borderless style a List row hands a tap
                // anywhere in the row to EVERY control in it: a tap on the
                // cover opened the website and unsubscribed at once.
                .buttonStyle(.borderless)
                // Force-touch the show header to bulk-update the played state.
                .contextMenu {
                    if caps.marksAllEpisodes {
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
                }
        } rows: {
            // The server keeps refusing this feed. Below the header,
            // above the episodes, which stay.
            if mode == .subscribed, let show = storedShow, subs.isAccessRefused(show) {
                let _ = readCount
                ShowAccessRefusedBanner(
                    refusals: subs.refusalCount(show),
                    isPremium: PodcastSubscriptions.isPremiumFeed(show.feedURL),
                    remedy: ShowAccessRemedy.of(
                        tokenAddress: PodcastFeedAddress.isTokenFeedURL(show.feedURL),
                        hasCredentials: PodcastFeedAuth.hasCredentials(
                            feedKey: PodcastSubscriptions.feedKey(show.feedURL))),
                    onNewLink: { newLinkText = ""; askingNewLink = true },
                    onSignIn: {
                        signInMomentBefore = PodcastFeedAuth.moment(feedKey: PodcastSubscriptions.feedKey(show.feedURL))
                        signInShow = show
                    },
                    freeTwin: subs.freeTwinOffer(show),
                    onSwitch: {
                        Task {
                            // The page stands for the paid address; the show
                            // lives on under the free one in the list.
                            if await subs.switchToFreeTwin(showId: show.id) { dismiss() } else { freeTwinFailed = true }
                        }
                    },
                    onDecline: { subs.declineFreeTwin(show) })
                    .buttonStyle(.borderless)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            // An empty cut says WHY it is empty. The filter is on
            // and everything is heard; one tap shows all again.
            if preferences.unplayedOnly && visibleItems.isEmpty && !sortedItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("All \(sortedItems.count) episodes are played.")
                        .font(.subheadline)
                    Button("Show all episodes") { setUnplayedOnly(false) }
                        .font(.subheadline)
                }
                .listRowSeparator(.hidden)
            }
            ForEach(visibleItems) { item in
                // The row eyebrow repeating the show title is
                // noise. The show page hands its title in, the pure rule
                // decides (parity: other surfaces list MANY shows and keep it).
                PodcastEpisodeRow(item: item, playerCoordinator: playerCoordinator,
                                  showTitle: title, showsDownload: caps.downloads)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.visible)
            }
            loadingOrFailureRow
                .listRowSeparator(.hidden)
            if caps.fetchesMoreEpisodes {
                Group { if isServerShow { availableSection } else { historySection } }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
        }
        .untitledDetailPage()
        .toolbar {
            // The per-show settings slider inboard, the global settings cog
            // not: a pushed page carries its OWN actions and no app settings cog.
            // The toolbar holds three elements on a phone, and a destination
            // needed once a day must not crowd out the tools needed
            // constantly; the cog lives on every tab root instead.
            ToolbarItemGroup(placement: .topBarTrailing) {
                if caps.showsSettingsSheet {
                    PodcastShowSettingsButton { showSettings = true }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            Group {
                if let show = liveShow {
                    PodcastShowSettingsSheet(show: show,
                                             newestFirst: preferenceBinding(\.newestFirst),
                                             unplayedOnly: preferenceBinding(\.unplayedOnly))
                }
            }
            .followsAppearanceChoice()
        }
        // The same prompt as in the list of feeds not followed yet: one
        // action, one wording.
        .alert("Enter new link", isPresented: $askingNewLink) {
            TextField("Feed link", text: $newLinkText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Follow") {
                guard let show = storedShow else { return }
                let link = newLinkText.trimmingCharacters(in: .whitespaces)
                Task {
                    if await subs.replaceShowLink(showId: show.id, newURL: link) {
                        // The page stands for the old address; the show
                        // lives on under the new one in the list.
                        if subs.shows.first(where: { $0.id == show.id }) == nil { dismiss() }
                    } else {
                        newLinkFailed = true
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paste the new link from your subscription. Your episodes and listening positions go with it.")
        }
        .alert("The new link could not be followed", isPresented: $newLinkFailed) {
            Button("OK", role: .cancel) {}
        }
        .alert("The free feed could not be followed", isPresented: $freeTwinFailed) {
            Button("OK", role: .cancel) {}
        }
        .sheet(item: $signInShow, onDismiss: {
            guard let show = storedShow,
                  FeedRefusal.asksAgainAfterSignIn(
                    momentBefore: signInMomentBefore,
                    momentAfter: PodcastFeedAuth.moment(feedKey: PodcastSubscriptions.feedKey(show.feedURL)))
            else { return }
            Task { await subs.recheckAccess(showId: show.id) }
        }) { show in
            NavigationStack { PremiumFeedEditor(show: show) }
                // A settings page outside the settings sheet keeps the rows'
                // title edge at an accessibility size, as there.
                .labelStyle(RowLabelStyle())
                .followsAppearanceChoice()
        }
        .alert("Download failed", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("OK", role: .cancel) { downloadError = nil }
        } message: {
            if let downloadError { Text(downloadError) }
        }
        .sentenceAlert($deleteError)
        .task { await loadIfBrowsed() }
        .task(id: preferencesSlot) { readPreferences() }
        // Another device changed this show's sort or filter: read it again.
        // Only a read; the page writes on a gesture alone.
        .onReceive(NotificationCenter.default.publisher(for: .userChoicesAdopted)) { note in
            guard PodcastShowPreferences.adoptionTouches(PodcastShowPreferences.adoptedKeys(note.userInfo),
                                                         showId: preferencesId) else { return }
            readPreferences()
        }
    }

    /// The one read of sort and filter, on opening, on a change of id or
    /// state, and when another device changed them. The count makes the
    /// notice read the free twin again too, which lives in the store.
    private func readPreferences() {
        preferences = PodcastShowPreferences.load(showId: preferencesId, mode: mode)
        readCount += 1
    }

    // MARK: - Preferences

    /// The ONE id the sort and the filter of this show are read AND written
    /// under. They used to be read under the seed's id and written under the
    /// live show's, so a page opened by its feed address read a key nobody
    /// wrote and the choice fell back.
    private var preferencesId: String { liveShow?.id ?? feedURL }

    /// When the id or the state changes, the choice is read again: a page
    /// that appears during a cold start reads as browsed until the stores
    /// have loaded, and a choice read once at that moment stayed the default.
    private var preferencesSlot: String { "\(preferencesId)|\(mode)" }

    /// Every change runs through the ONE store rule. In the browsed state it
    /// writes nothing, so looking at a show leaves no key behind under an id
    /// no subscription owns.
    private func preferenceBinding(_ path: WritableKeyPath<PodcastShowPreferences, Bool>) -> Binding<Bool> {
        PodcastShowPreferences.binding(path, of: $preferences, showId: preferencesId, mode: mode)
    }

    private func setUnplayedOnly(_ value: Bool) {
        preferences.unplayedOnly = value
        preferences.store(\.unplayedOnly, showId: preferencesId, mode: mode)
    }

    // MARK: - Loading a browsed feed

    /// The full history, the same answer for both kinds of show. A followed
    /// show merges it into the store. A browsed one holds it on the page for
    /// the visit and remembers the episodes so they play, like its feed.
    private func loadHistory(_ show: PodcastShow) async -> Int? {
        guard mode == .browsed else { return await subs.loadFullHistory(showId: show.id) }
        guard let history = await PodcastSubscriptions.browsedHistory(of: show) else { return nil }
        fetchedShow = history.show
        BrowsedEpisodes.shared.remember(show: history.show)
        return history.added
    }

    /// Parses the feed of a show nobody subscribed to and remembers its
    /// episodes for the visit, so they resolve when one of them is played.
    /// A subscribed show never runs this: its store already answers.
    private func loadIfBrowsed() async {
        guard mode == .browsed, fetchedShow == nil else { return }
        guard let url = PodcastFeedAddress.requestURL(feedURL) else { fetchFailed = true; return }
        guard let parsed = await PodcastSubscriptions.fetchAndParse(feedURL: url) else {
            fetchFailed = true
            return
        }
        fetchedShow = parsed
        BrowsedEpisodes.shared.remember(show: parsed)
    }

    @ViewBuilder
    private var loadingOrFailureRow: some View {
        if mode == .browsed, fetchedShow == nil {
            if fetchFailed {
                ContentUnavailableView("The feed could not be loaded.",
                                       systemImage: "wifi.exclamationmark")
                    .padding(.top, 24)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
    }

    /// Rich show metadata: the episode count, language and explicit mark
    /// under the title; the categories with the facts; website and funding
    /// with the controls.
    @ViewBuilder
    private var showCountLine: some View {
        if let s = liveShow {
            HStack(spacing: 12) {
                Text("\(s.episodes.count) episodes").font(.caption).foregroundStyle(.secondary)
                if let lang = s.language, !lang.isEmpty {
                    Text(lang.uppercased()).font(.caption).foregroundStyle(.secondary)
                }
                if PodcastExplicit.marks(show: s.explicit) {
                    ExplicitMark()
                }
            }
        }
    }

    @ViewBuilder
    private var showCategories: some View {
        if let cats = liveShow?.categories, !cats.isEmpty {
            ScrollView(.horizontal) {
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
    }

    @ViewBuilder
    private var showLinks: some View {
        if let s = liveShow, s.link != nil || s.funding?.isEmpty == false {
            HStack(spacing: 18) {
                if let l = s.link, let url = URL(string: l) {
                    Link(destination: url) { Label("Website", systemImage: "safari") }
                        .accessibilityIdentifier("show-website")
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

    private var header: some View {
        DetailHeader(title: title) { side in
            podcastArtwork(
                url: (liveShow?.artworkURL ?? catalogSeed?.artworkURL).flatMap { URL(string: $0) },
                size: side ?? 150, corner: 16)
                .accessibilityIdentifier("show-cover")
        } lines: {
            if let author = liveShow?.author ?? catalogSeed?.author, !author.isEmpty {
                Text(author).font(.subheadline).foregroundStyle(.secondary)
            }
            // Provenance on the show page (origin-carried).
            if liveShow?.origin != nil { OriginCapsule() }
            showCountLine
        } facts: {
            VStack(alignment: .leading, spacing: 8) {
                if let description = liveShow?.description, !description.isEmpty {
                    Text(podcastPlainText(description))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(descriptionExpanded ? nil : 3)
                        .multilineTextAlignment(.leading)
                        .onTapGesture { withAnimation { descriptionExpanded.toggle() } }
                }
                showCategories
            }
        } actions: {
            VStack(spacing: 12) {
                showLinks
                subscriptionControl
                    .font(.subheadline)
            }
        }
        .padding(.horizontal)
        .confirmationDialog("Delete on server?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete on server", role: .destructive) {
                Task {
                    if let id = liveShow?.id, let error = await absPodcast.deleteShowOnServer(showId: id) {
                        deleteError = ErrorSentence.of(error)
                        return
                    }
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the podcast and its listening history from the server for everyone.")
        }
    }

    /// Managing an existing subscription, or the way into one. The state
    /// decides which of the two exists; there is no disabled third form.
    @ViewBuilder
    private var subscriptionControl: some View {
        if caps.managesSubscription, let show = storedShow {
            manageButton(show)
        } else {
            PodcastSubscribeButton(feedURL: feedURL)
        }
    }

    /// ABS show: archive (server stays) or delete permanently; RSS show:
    /// unsubscribe locally.
    @ViewBuilder
    private func manageButton(_ show: PodcastShow) -> some View {
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
            // Destructive, so it asks first, like "Delete on server" does.
            Button(role: .destructive) {
                showUnsubscribeConfirm = true
            } label: {
                Label("Unsubscribe", systemImage: "minus.circle")
            }
            .accessibilityIdentifier("show-unsubscribe")
            .confirmationDialog("Unsubscribe?", isPresented: $showUnsubscribeConfirm, titleVisibility: .visible) {
                Button("Unsubscribe", role: .destructive) {
                    podcastUnsubscribe(show)   // from both sources (RSS + possibly ABS)
                    dismiss()
                }
                .accessibilityIdentifier("show-unsubscribe-confirm")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The show leaves your subscriptions. Listening states stay on this device.")
            }
        }
    }

    /// Feed episodes not yet on the server. Downloadable server-side (for
    /// "listen from the start"). Loaded only on button press.
    @ViewBuilder
    private var availableSection: some View {
        if let show = liveShow {
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
                    RowHeading.plain("Available episodes")
                    LazyVStack(spacing: 0) {
                        ForEach(available) { ep in
                            // Tap = stream immediately from the original host (rss:
                            // item, progress local+iCloud); arrow = save on the server.
                            let item = feedEpisodePlayItem(show: show, feed: ep)
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle").font(.title2).foregroundStyle(.secondary)
                                Text(ep.title).font(.subheadline).lineLimit(2)
                                Spacer(minLength: 8)
                                if downloading.contains(ep.id) {
                                    ProgressView()
                                } else {
                                    Button {
                                        downloadAvailable(ep, showId: show.id)
                                    } label: {
                                        Image(systemName: "arrow.down.circle").font(.title3).foregroundStyle(.secondary)
                                            // 44pt hit area.
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
    }

    /// Tell the server to load the episode; then re-read (the download runs
    /// server-side asynchronously, so wait briefly).
    private func downloadAvailable(_ ep: FeedEpisode, showId: String) {
        downloading.insert(ep.id)
        Task {
            if let error = await absPodcast.downloadEpisode(showId: showId, episode: ep) {
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

    /// RSS shows: load the full episode history via PodcastIndex. Also
    /// fetches old episodes that fell out of the live feed. The button stands
    /// under the same condition the load asks: with the directory off in the
    /// sources a tap answered "no additional episodes" without asking anyone.
    @ViewBuilder
    private var historySection: some View {
        if AppStorageKeys.podcastIndexActive, let show = liveShow {
            VStack(alignment: .leading, spacing: 8) {
                Divider().padding(.horizontal)
                Button {
                    Task {
                        loadingHistory = true
                        switch await loadHistory(show) {
                        case .some(let n) where n > 0:
                            historyResult = String(localized: "\(n) episodes added")
                        case .some:
                            historyResult = String(localized: "No additional episodes found.")
                        case .none:
                            historyResult = String(localized: "The full history could not be loaded.")
                        }
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
