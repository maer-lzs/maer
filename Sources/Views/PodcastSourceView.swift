// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import OSLog
import UniformTypeIdentifiers

/// Subscribe to podcasts (Settings → Areas → Podcasts → Podcast sources): search by name
/// (Apple/PodcastIndex) and subscribe with one tap, or via feed URL; manage
/// subscribed shows. Source-specific management, analogous to `LocalFilesView`.
/// The podcast tab only consumes.
struct PodcastSourceView: View {
    @AppStorage(AppStorageKeys.pinchflatEnabled) private var pinchflatEnabled = true
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared

    /// Create new subscriptions on the ABS server (synced) instead of locally.
    /// Only relevant if the server has a podcast library.
    ///
    /// It was `@State` and therefore forgot itself the moment the page closed:
    /// whoever switched it off had server subscriptions again on the next
    /// visit, silently. The stored value counts from now on; the default stays
    /// `true`, which is what every session did so far.
    @AppStorage(AppStorageKeys.podcastSubscribeToServer) private var subscribeToServer = true
    @State private var subscribeError: String?
    /// Use ABS as a podcast source (default OFF. ABS is primarily an audiobook server).
    @AppStorage(AppStorageKeys.absPodcastsEnabled) private var absPodcastsEnabled = false

    private enum Source: Hashable { case apple, podcastIndex }
    @State private var source: Source = .apple

    @State private var searchText = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var isSearching = false
    @State private var subscribingFeeds: Set<String> = []

    @State private var showAddByURL = false
    @State private var feedURL = ""
    @State private var feedUser = ""
    @State private var feedPassword = ""
    @State private var urlError: String?

    @State private var showOPMLImporter = false
    @State private var opmlShareURL: URL?
    @State private var showAppleImporter = false
    @State private var showAntennaPodImporter = false
    @State private var importMessage: String?
    @State private var isImporting = false
    /// A read foreign library waiting in its preview for Apply.
    @State private var pendingImport: PendingForeignImport?

    @State private var isSyncing = false
    @State private var syncMessage: String?

    /// The premium feed being edited (credentials sheet).

    var body: some View {
        List {
            Section {
                AppSwitch(isOn: $absPodcastsEnabled) {
                    Label("Use Audiobookshelf for podcasts", systemImage: "books.vertical")
                }
            } footer: {
                Text("Off = your Audiobookshelf server is used only for audiobooks. Turn on to also manage podcasts on it (subscribe, download, sync).")
            }
            searchSection
            if !results.isEmpty || isSearching {
                resultsSection
            }
            addByURLSection
            pinchflatSection
            importSection
            if absPodcastsEnabled && absPodcast.hasPodcasts { serverSyncSection }
            NavigationLink {
                GPodderSettingsView()
            } label: {
                Label("gpodder Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            NavigationLink {
                PodcastIndexKeyView()
            } label: {
                Label("PodcastIndex Access", systemImage: "key")
            }
            // Subscription list deliberately at the very bottom (after search/add/manage).
            subscriptionsSection
            premiumManagementSection
            archivedSection
        }
        .navigationTitle("Podcasts")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        // Toggling takes effect immediately: ABS probes or clears its state.
        .onChange(of: absPodcastsEnabled) { _, _ in
            Task { await absPodcast.refresh() }
        }
        // What leaves the device, before it leaves: shows, episodes with
        // a state, and the premium feeds held back. Their exclusion is
        // the safe default, "include anyway" the deliberate second step
        // for the own-backup case.
        .confirmationDialog(
            Text("\(opmlShowCount) shows, \(opmlStateCount) episodes with a state"),
            isPresented: $opmlPremiumHintShown, titleVisibility: .visible
        ) {
            if opmlExcludedCount > 0 {
                Button("Export without premium feeds") { performExport(includePremium: false) }
                    .accessibilityIdentifier("opml-export-confirm")
                Button("Include anyway", role: .destructive) { performExport(includePremium: true) }
            } else {
                Button("Export OPML") { performExport(includePremium: false) }
                    .accessibilityIdentifier("opml-export-confirm")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if opmlExcludedCount > 0 {
                Text("\(opmlExcludedCount) premium feeds not exported — they contain personal access links. Their listening states stay out with them.")
            } else {
                Text("Listening states travel with their shows; a plain OPML reader ignores them.")
            }
        }
        .sheet(isPresented: Binding(get: { opmlShareURL != nil },
                                    set: { if !$0 { opmlShareURL = nil } })) {
            if let opmlShareURL {
                // Minimal share host. ShareLink needs a stable view context.
                NavigationStack {
                    VStack(spacing: 16) {
                        Text("Your subscriptions as OPML")
                            .font(.headline)
                        ShareLink(item: opmlShareURL) {
                            Label("Share OPML", systemImage: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityIdentifier("opml-share-link")
                    }
                    .padding()
                    .presentationDetents([.height(180)])
                }
            }
        }
        .modifier(ForeignImportEntries(
            showOPMLPicker: $showOPMLImporter,
            showApplePicker: $showAppleImporter,
            showAntennaPodPicker: $showAntennaPodImporter,
            pending: $pendingImport,
            message: $importMessage,
            onPick: handleImport))
        .alert("Subscribe failed", isPresented: Binding(
            get: { subscribeError != nil },
            set: { if !$0 { subscribeError = nil } }
        )) {
            Button("OK", role: .cancel) { subscribeError = nil }
        } message: {
            if let subscribeError { Text(subscribeError) }
        }
        // A new premium feed matched an existing free subscription. Ask,
        // never replace silently. Decline keeps both (today's behavior).
        .alert("Premium feed detected", isPresented: Binding(
            get: { subs.pendingPremiumReplacement != nil },
            set: { if !$0 { subs.pendingPremiumReplacement = nil } }
        ), presenting: subs.pendingPremiumReplacement) { offer in
            Button("Replace") { subs.replaceFreeWithPremium(offer) }
            Button("Keep Both", role: .cancel) { subs.pendingPremiumReplacement = nil }
        } message: { offer in
            Text("“\(offer.showTitle)” looks like the premium version of an existing subscription. Replace the free feed and carry over listening progress and downloads?")
        }
        // Debounce: wait briefly after typing, then search.
        .task(id: searchText) {
            let term = searchText.trimmingCharacters(in: .whitespaces)
            guard term.count >= 2 else { results = []; return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(term)
        }
    }

    // MARK: - Search

    @ViewBuilder
    private var searchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Podcasts", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = ""; results = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if AppStorageKeys.podcastIndexConfigured {
                Picker("Search source", selection: $source) {
                    Text("Apple").tag(Source.apple)
                    Text("PodcastIndex").tag(Source.podcastIndex)
                }
                .pickerStyle(.segmented)
                .onChange(of: source) { _, _ in
                    let term = searchText.trimmingCharacters(in: .whitespaces)
                    if term.count >= 2 { Task { await runSearch(term) } }
                }
            }
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        Section {
            if isSearching {
                HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
            } else if results.isEmpty {
                Text("No results.").foregroundStyle(.secondary)
            } else {
                ForEach(results) { result in
                    resultRow(result)
                }
            }
        }
    }

    private func resultRow(_ result: PodcastSearchResult) -> some View {
        HStack(spacing: 12) {
            artwork(url: result.artworkURL.flatMap { URL(string: $0) })
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).lineLimit(1)
                if let author = result.author {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            subscribeButton(for: result)
        }
    }

    @ViewBuilder
    private func subscribeButton(for result: PodcastSearchResult) -> some View {
        if isSubscribed(result.feedURL) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if subscribingFeeds.contains(result.feedURL) {
            ProgressView()
        } else {
            Button("Subscribe") {
                subscribingFeeds.insert(result.feedURL)
                Task {
                    _ = await performSubscribe(feedURL: result.feedURL)
                    subscribingFeeds.remove(result.feedURL)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    /// Already subscribed (locally OR on the server). Normalized feed URL.
    private func isSubscribed(_ feedURL: String) -> Bool {
        let n = PodcastSubscriptions.normalizeFeedURL(feedURL)
        return subs.shows.contains { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
            || absPodcast.shows.contains { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
    }

    /// Teil 5 cut: a credentialed subscription on the SAME host as the typed
    /// URL. The "provider account" is derived from existing feeds, no new
    /// persistence. Only offered while the login fields are empty.
    private var providerLoginSource: PodcastShow? {
        let url = feedURL.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty,
              feedUser.trimmingCharacters(in: .whitespaces).isEmpty, feedPassword.isEmpty else { return nil }
        let host = PodcastSubscriptions.feedHost(url)
        guard !host.isEmpty else { return nil }
        return subs.shows.first {
            PodcastSubscriptions.feedHost($0.feedURL) == host
                && PodcastFeedAuth.hasCredentials(feedKey: PodcastSubscriptions.feedKey($0.feedURL))
        }
    }

    /// Create a subscription. On the server (synced) if possible/chosen, else locally.
    private func performSubscribe(feedURL: String) async -> Bool {
        if subscribeToServer, absPodcast.hasPodcasts {
            if let error = await absPodcast.subscribeOnServer(feedURL: feedURL) {
                subscribeError = error
                return false
            }
            return true
        }
        return await subs.subscribe(urlString: feedURL)
    }

    // MARK: - Subscriptions / URL

    /// Archived server shows (subscription ended, history kept on the server).
    @ViewBuilder
    private var archivedSection: some View {
        let archived = absPodcast.archivedShows
        if !archived.isEmpty {
            Section("Archived") {
                ForEach(archived) { show in
                    HStack {
                        Text(show.title).lineLimit(1)
                        Spacer()
                        Button("Reactivate") { absPodcast.setArchived(show.id, false) }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var subscriptionsSection: some View {
        if !subs.shows.isEmpty {
            Section("Subscriptions") {
                ForEach(subs.shows) { show in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(show.title).lineLimit(1)
                        Text("\(show.episodes.count) episodes")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { subs.unsubscribe(id: subs.shows[index].id) }
                }
            }
        }
    }

    // MARK: - Premium management (S22)

    /// THE management surface for premium feeds. Which feeds have a
    /// login, which are the token-URL class, change/delete credentials (until
    /// now only possible at subscribe time). URLs render MASKED (Y52).
    /// The shared always-visible management (provider groups,
    /// manual marking, twin repair). Same view as on the Podcasts pill
    /// (second access point, one truth).
    private var premiumManagementSection: some View {
        PremiumFeedsSection()
    }

    // MARK: - Pinchflat server

    @State private var pinchflatURL: String = PinchflatClient.serverURL?.absoluteString ?? ""
    @State private var pinchflatToken = ""
    @State private var pinchflatUser = ""
    @State private var pinchflatPassword = ""
    @State private var pinchflatStatus: String?
    @State private var pinchflatBusy = false
    @State private var showPinchflat = false

    /// Connect = done. The server's channel list
    /// MIRRORS into its own group; new channels arrive on refresh, hiding is
    /// the opt-out. Visible errors belong to THIS manual gesture;
    /// the app-start pass stays silent.
    /// Hidden channels for the re-admit list (revision-driven.
    /// UserDefaults writes don't invalidate SwiftUI on their own).
    @State private var hiddenRevision = 0
    private var hiddenChannels: [(feedURL: String, title: String)] {
        _ = hiddenRevision
        return PinchflatSync.hiddenEntries()
    }

    private var pinchflatSection: some View {
        Section {
            // This was the ONLY one of the fourteen sources without an
            // on/off switch. Shutting it down meant DELETING it, and
            // afterwards address and token had to be entered again. Now it
            // behaves like all its neighbours: switching off leaves the
            // credentials in place.
            AppSwitch(isOn: $pinchflatEnabled) {
                Label("Use Pinchflat", systemImage: "play.rectangle.on.rectangle")
            }
            .accessibilityIdentifier("pinchflat-toggle")
            DisclosureGroup(isExpanded: $showPinchflat) {
                CredentialField.serverURL("Server URL", text: $pinchflatURL,
                                          id: "pinchflat-url",
                                          service: .pinchflat)
                // Token FIELD + help line. No HTML scraping.
                CredentialField.secret("Route token", text: $pinchflatToken,
                                       id: "pinchflat-token")
                Text("Find the route token in Pinchflat under Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                CredentialField.username("Username (optional)", text: $pinchflatUser,
                                         id: "pinchflat-username")
                CredentialField.secret("Password (optional)", text: $pinchflatPassword,
                                       id: "pinchflat-password")
                if let status = pinchflatStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                // The SAVED state is visible. Never a matter of faith.
                if let host = PinchflatClient.serverURL?.host {
                    Label {
                        Text("Connected to \(host)")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Button {
                    Task { await connectPinchflat() }
                } label: {
                    if pinchflatBusy { ProgressView() } else { Text("Connect") }
                }
                .disabled(pinchflatBusy || pinchflatURL.trimmingCharacters(in: .whitespaces).isEmpty)
                if PinchflatClient.serverURL != nil {
                    Button("Refresh channel list") {
                        Task { await connectPinchflat(reconnect: true) }
                    }
                    .disabled(pinchflatBusy)
                    Button("Disconnect server", role: .destructive) {
                        PinchflatClient.disconnect()
                        pinchflatStatus = nil
                        pinchflatURL = ""
                    }
                }
                // Re-admit hidden channels HERE (the hide gesture
                // lives on the tiles; this is its visible way back). Unhide
                // kicks one mirror pass. Server = source of truth.
                ForEach(hiddenChannels, id: \.feedURL) { entry in
                    Button {
                        PinchflatSync.unhide(feedURL: entry.feedURL)
                        hiddenRevision += 1
                        Task { try? await PinchflatSync.mirror() }
                    } label: {
                        Label {
                            Text("Show \"\(entry.title)\" again")
                        } icon: {
                            Image(systemName: "eye")
                        }
                    }
                }
            } label: {
                Label("Pinchflat Server", systemImage: "play.rectangle.on.rectangle")
            }
        } footer: {
            Text("Mirrors every channel of your Pinchflat server as its own group — manage channels in Pinchflat, Mär serves them. Content plays from your server; provenance is shown as YouTube.")
        }
    }

    private func connectPinchflat(reconnect: Bool = false) async {
        pinchflatBusy = true
        defer { pinchflatBusy = false }
        pinchflatStatus = nil
        if !reconnect {
            // Normalize (scheme-less input is the common case) and show
            // a visible form error on unusable input. The existing
            // configuration stays untouched either way.
            guard let url = PinchflatClient.normalizedServerURL(from: pinchflatURL) else {
                pinchflatStatus = String(localized: "That does not look like a server address.")
                return
            }
            pinchflatURL = url.absoluteString
            PinchflatClient.setServer(url: url,
                                      routeToken: pinchflatToken.trimmingCharacters(in: .whitespaces),
                                      user: pinchflatUser.trimmingCharacters(in: .whitespaces),
                                      password: pinchflatPassword)
            pinchflatToken = ""
            pinchflatPassword = ""
        }
        do {
            let count = try await PinchflatSync.mirror()
            // Only a WORKING address is remembered.
            KnownServers.remember(pinchflatURL, service: .pinchflat)
            pinchflatStatus = String(localized: "Connected — \(count) channels in the group.")
        } catch PinchflatClient.FetchError.unauthorized {
            pinchflatStatus = String(localized: "The server rejected the token or login (401).")
        } catch PinchflatClient.FetchError.badAnswer {
            pinchflatStatus = String(localized: "The server answered, but not with a channel list.")
        } catch {
            // A mesh-only server being away is NORMAL, not an app defect.
            pinchflatStatus = String(localized: "Server not reachable right now — try again in your home network.")
        }
    }

    @ViewBuilder
    private var addByURLSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAddByURL) {
                CredentialField.serverURL("Feed URL", text: $feedURL,
                                          id: "feed-url")
                CredentialField.username("Username (optional)", text: $feedUser,
                                         id: "feed-username")
                CredentialField.secret("Password (optional)", text: $feedPassword,
                                       id: "feed-password")
                // Teil 5 (provider premium, foundation cut): another show of a
                // provider you already have a login for. Reuse it, visibly.
                if let source = providerLoginSource {
                    Label("Will use your \(PodcastSubscriptions.feedHost(source.feedURL)) login (from “\(source.title)”)",
                          systemImage: "person.badge.key")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Add Feed") {
                    let url = feedURL.trimmingCharacters(in: .whitespaces)
                    guard !url.isEmpty else { return }
                    urlError = nil
                    // Store credentials BEFORE fetching (private/premium feeds).
                    // Empty fields + a known provider host → adopt that login.
                    var user = feedUser.trimmingCharacters(in: .whitespaces)
                    var password = feedPassword
                    if user.isEmpty, password.isEmpty,
                       let source = providerLoginSource,
                       let c = PodcastFeedAuth.credentials(feedKey: PodcastSubscriptions.feedKey(source.feedURL)) {
                        user = c.user
                        password = c.password
                    }
                    PodcastFeedAuth.set(feedKey: PodcastSubscriptions.feedKey(url),
                                        user: user,
                                        password: password)
                    Task {
                        let ok = await performSubscribe(feedURL: url)
                        if ok {
                            feedURL = ""; feedUser = ""; feedPassword = ""; showAddByURL = false
                        } else {
                            urlError = String(localized: "Could not load this feed. Check the URL or login.")
                        }
                    }
                }
                .disabled(feedURL.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("podcast-add-feed")
                if let urlError {
                    Text(urlError).font(.caption).foregroundStyle(.red)
                }
            } label: {
                Label("Add by URL", systemImage: "link")
                    .accessibilityIdentifier("podcast-add-by-url")
            }
        } footer: {
            Text("For private or premium feeds that need a login, add the username and password.")
        }
    }

    /// Write the OPML to a temp file and hand it to the share
    /// sheet (a file shares/saves cleanly everywhere; string items don't).
    /// Premium/token feeds stay OUT of the export by
    /// default (a shared OPML would give the access away). Entry point: with
    /// premium feeds present the visible hint dialog takes over. Exporting
    /// continues from there (safe default, or "include anyway" as a
    /// deliberate second step for the own-backup case).
    private func exportOPML() {
        let shows = PodcastSubscriptions.shared.shows.map { (title: $0.title, feedURL: $0.feedURL) }
        let split = OPMLExport.partition(
            shows: shows, isPremium: { PodcastSubscriptions.isPremiumFeed($0) })
        opmlExcludedCount = split.excluded.count
        opmlShowCount = split.safe.count
        opmlStateCount = OPMLExport.states(PodcastSubscriptions.shared.exportableStates(), for: split.safe).count
        opmlPremiumHintShown = true
    }

    private func performExport(includePremium: Bool) {
        let shows = PodcastSubscriptions.shared.shows.map { (title: $0.title, feedURL: $0.feedURL) }
        let split = OPMLExport.partition(shows: shows,
                                         isPremium: { PodcastSubscriptions.isPremiumFeed($0) })
        let written = includePremium ? shows : split.safe
        let doc = OPMLExport.document(shows: written,
                                      states: OPMLExport.states(PodcastSubscriptions.shared.exportableStates(),
                                                                for: written),
                                      generatedAt: Date())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("maer-subscriptions.opml")
        do {
            try doc.write(to: url, atomically: true, encoding: .utf8)
            opmlShareURL = url
        } catch {
            Logger.rss.error("OPML export failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Import

    /// Premium-exclusion dialog state.
    @State private var opmlExcludedCount = 0
    @State private var opmlShowCount = 0
    @State private var opmlStateCount = 0
    @State private var opmlPremiumHintShown = false

    @ViewBuilder
    private var importSection: some View {
        Section {
            Button {
                showOPMLImporter = true
            } label: {
                Label("Import OPML", systemImage: "square.and.arrow.down")
            }
            .disabled(isImporting)
            // The export counterpart. Subscriptions as OPML via
            // the share sheet (pure builder, no network).
            Button {
                exportOPML()
            } label: {
                Label("Export OPML", systemImage: "square.and.arrow.up")
            }
            .disabled(PodcastSubscriptions.shared.shows.isEmpty)
            .accessibilityIdentifier("opml-export")
            Button {
                showAppleImporter = true
            } label: {
                Label("Import from Apple Podcasts", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(isImporting)
            Button {
                showAntennaPodImporter = true
            } label: {
                Label("Import from AntennaPod", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(isImporting)
            if isImporting {
                HStack { ProgressView(); Text("Importing…").foregroundStyle(.secondary) }
            }
        } header: {
            Text("Import")
        } footer: {
            Text("OPML brings in subscriptions from other podcast apps; Overcast's extended OPML also brings positions and played marks. Apple Podcasts import reads an MTLibrary.sqlite copied from a Mac, AntennaPod import its exported database; both restore play progress and played state. Spotify offers no export, so nothing can be imported from it.")
        }
    }

    /// Mirror local RSS subscriptions to the server (ABS canonical). For a
    /// reconciled, cross-device state. Idempotent.
    private var serverSyncSection: some View {
        Section {
            Button {
                isSyncing = true
                Task {
                    let r = await PodcastSubscriptionSync.reconcile(refreshExistingCovers: true)
                    syncMessage = syncSummary(r)
                    isSyncing = false
                }
            } label: {
                Label("Sync subscriptions to server", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isSyncing)
            if isSyncing {
                HStack { ProgressView(); Text("Syncing…").foregroundStyle(.secondary) }
            }
            if let syncMessage {
                Text(syncMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Server Sync")
        } footer: {
            Text("Mirrors your local subscriptions to Audiobookshelf so they sync across devices. Nothing is deleted; archived shows are reactivated. Runs automatically too.")
        }
    }

    private func syncSummary(_ r: PodcastSubscriptionSync.Report) -> String {
        var lines: [String] = []
        if r.pushed > 0 { lines.append(String(localized: "\(r.pushed) subscriptions mirrored to server")) }
        if r.reactivated > 0 { lines.append(String(localized: "\(r.reactivated) reactivated")) }
        if r.alreadySynced > 0 { lines.append(String(localized: "\(r.alreadySynced) already synced")) }
        if !r.failed.isEmpty { lines.append(String(localized: "\(r.failed.count) failed")) }
        if lines.isEmpty { lines.append(String(localized: "Nothing to sync.")) }
        return lines.joined(separator: "\n")
    }

    /// Read the selected file into the common library and open its
    /// preview. Nothing is applied here; the sheet does that on Apply.
    private func handleImport(_ result: Result<[URL], Error>, source: ForeignSource) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            // File is outside the sandbox → request access explicitly.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let library = await PodcastImport.readLibrary(source: source, at: url) {
                pendingImport = PendingForeignImport(source: source, library: library)
            } else {
                // A broken file never imports a silent partial list.
                importMessage = switch source {
                case .opml: String(localized: "Could not read this file as OPML.")
                case .applePodcasts: String(localized: "Could not read this file as an Apple Podcasts database.")
                case .antennaPod: String(localized: "Could not read this file as an AntennaPod database.")
                }
            }
        }
    }

    // MARK: - Logik

    private func runSearch(_ term: String) async {
        isSearching = true
        let directory: PodcastDirectory
        if source == .podcastIndex, AppStorageKeys.podcastIndexConfigured {
            directory = PodcastIndexDirectory(
                key: AppStorageKeys.podcastIndexEffectiveKey,
                secret: AppStorageKeys.podcastIndexEffectiveSecret
            )
        } else if AppStorageKeys.appleCatalogEnabledValue {
            directory = ITunesDirectory()
        } else if AppStorageKeys.podcastIndexConfigured {
            // Apple off: the search runs via PodcastIndex.
            directory = PodcastIndexDirectory(
                key: AppStorageKeys.podcastIndexEffectiveKey,
                secret: AppStorageKeys.podcastIndexEffectiveSecret
            )
        } else {
            // No directory may be asked. An honest empty result, no request.
            results = []
            isSearching = false
            return
        }
        results = (try? await directory.search(term)) ?? []
        isSearching = false
    }

    @ViewBuilder
    private func artwork(url: URL?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if let url {
                CachedAsyncImage(url: url, useThumbnail: true) { image, pixels in
                    CoverFitting(image: image, pixelSize: pixels, backdrop: .neutral)
                } placeholder: {
                    shape.fill(Color.secondary.opacity(0.15))
                }
            } else {
                shape.fill(Color.secondary.opacity(0.15))
                    .overlay(Image(systemName: "mic").foregroundStyle(.secondary))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(shape)
    }
}

/// PodcastIndex access (optional). Key (public, UserDefaults) + secret
/// (credential, in the keychain).
private struct PodcastIndexKeyView: View {
    @AppStorage(AppStorageKeys.podcastIndexKey) private var key = ""
    @State private var secret = AppStorageKeys.podcastIndexSecretValue

    var body: some View {
        Form {
            Section {
                TextField("PodcastIndex API Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Secret", text: $secret)
                    .onChange(of: secret) { _, newValue in
                        AppStorageKeys.setPodcastIndexSecret(newValue)
                    }
            } footer: {
                Text("Optional. Get a free key at podcastindex.org — enables searching the open PodcastIndex catalog in addition to Apple.")
            }
        }
        .navigationTitle("PodcastIndex Access")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
    }
}


/// Change/delete the login of ONE premium feed. The management sheet
/// behind the Premium Feeds section (until now credentials could only be set
/// while subscribing). Token feeds show their class; a login can coexist.
struct PremiumFeedEditor: View {
    let show: PodcastShow
    @Environment(\.dismiss) private var dismiss

    @State private var user = ""
    @State private var password = ""

    private var feedKey: String { PodcastSubscriptions.feedKey(show.feedURL) }

    var body: some View {
        Form {
            Section {
                Text(show.title).font(.headline)
                // Never show the URL unmasked.
                Text(PodcastSubscriptions.maskedFeedURL(show.feedURL))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.disabled)
            }
            if PodcastSubscriptions.isTokenFeedURL(show.feedURL) {
                Section {
                    Label("Access is embedded in the feed URL (token). This feed stays on this device and is never synced to a gpodder server.", systemImage: "key.horizontal")
                        .font(.caption)
                }
            }
            Section("Login") {
                TextField("Username", text: $user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                Button("Save") {
                    PodcastFeedAuth.set(feedKey: feedKey,
                                        user: user.trimmingCharacters(in: .whitespaces),
                                        password: password)
                    dismiss()
                }
                .disabled(user.isEmpty && password.isEmpty)
                if PodcastFeedAuth.hasCredentials(feedKey: feedKey) {
                    Button("Remove Login", role: .destructive) {
                        PodcastFeedAuth.set(feedKey: feedKey, user: "", password: "")
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Premium Feed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            if let c = PodcastFeedAuth.credentials(feedKey: feedKey) {
                user = c.user
                password = c.password
            }
        }
    }
}
