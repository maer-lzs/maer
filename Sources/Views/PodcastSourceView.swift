import SwiftUI
import UniformTypeIdentifiers

/// Subscribe to podcasts (Settings → Sources → Podcasts): search by name
/// (Apple/PodcastIndex) and subscribe with one tap, or via feed URL; manage
/// subscribed shows. Source-specific management, analogous to `LocalFilesView`
/// — the podcast tab only consumes.
struct PodcastSourceView: View {
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared

    /// Create new subscriptions on the ABS server (synced) instead of locally —
    /// only relevant if the server has a podcast library.
    @State private var subscribeToServer = true
    @State private var subscribeError: String?
    /// Automatically save a feed-only episode on the server after ~30 s of play.
    @AppStorage("podcastAutoSaveOnPlay") private var autoSaveOnPlay = true
    /// Use ABS as a podcast source (default OFF — ABS is primarily an audiobook server).
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
    @State private var showAppleImporter = false
    @State private var importMessage: String?
    @State private var isImporting = false

    @State private var isSyncing = false
    @State private var syncMessage: String?

    var body: some View {
        List {
            Section {
                Toggle(isOn: $absPodcastsEnabled) {
                    Label("Use Audiobookshelf for podcasts", systemImage: "books.vertical")
                }
            } footer: {
                Text("Off = your Audiobookshelf server is used only for audiobooks. Turn on to also manage podcasts on it (subscribe, download, sync).")
            }
            if absPodcastsEnabled && absPodcast.hasPodcasts {
                Section {
                    Toggle(isOn: $subscribeToServer) {
                        Label("Subscribe on server", systemImage: "cloud")
                    }
                    Toggle(isOn: $autoSaveOnPlay) {
                        Label("Auto-save to server on play", systemImage: "arrow.down.circle")
                    }
                } footer: {
                    Text("New subscriptions are created on your Audiobookshelf server and sync across devices. Off = local only, this device. Auto-save stores a streamed feed episode on the server after ~30 s so its progress syncs there too.")
                }
            }
            Section {
                NavigationLink {
                    PodcastDiscoverView()
                } label: {
                    Label("Discover", systemImage: "sparkles.rectangle.stack")
                }
            }
            searchSection
            if !results.isEmpty || isSearching {
                resultsSection
            }
            addByURLSection
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
            archivedSection
        }
        .navigationTitle("Podcasts")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        // Toggling takes effect immediately: ABS probes or clears its state.
        .onChange(of: absPodcastsEnabled) { _, _ in
            Task { await absPodcast.refresh() }
        }
        .fileImporter(
            isPresented: $showOPMLImporter,
            allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml],
            allowsMultipleSelection: false
        ) { handleImport($0, apple: false) }
        .fileImporter(
            isPresented: $showAppleImporter,
            allowedContentTypes: [UTType(filenameExtension: "sqlite") ?? .database, .database, .data],
            allowsMultipleSelection: false
        ) { handleImport($0, apple: true) }
        .alert("Import", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("OK", role: .cancel) { importMessage = nil }
        } message: {
            if let importMessage { Text(importMessage) }
        }
        .alert("Subscribe failed", isPresented: Binding(
            get: { subscribeError != nil },
            set: { if !$0 { subscribeError = nil } }
        )) {
            Button("OK", role: .cancel) { subscribeError = nil }
        } message: {
            if let subscribeError { Text(subscribeError) }
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

    /// Already subscribed (locally OR on the server) — normalized feed URL.
    private func isSubscribed(_ feedURL: String) -> Bool {
        let n = PodcastSubscriptions.normalizeFeedURL(feedURL)
        return subs.shows.contains { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
            || absPodcast.shows.contains { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
    }

    /// Create a subscription — on the server (synced) if possible/chosen, else locally.
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

    @ViewBuilder
    private var addByURLSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAddByURL) {
                TextField("Feed URL", text: $feedURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Username (optional)", text: $feedUser)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password (optional)", text: $feedPassword)
                Button("Add Feed") {
                    let url = feedURL.trimmingCharacters(in: .whitespaces)
                    guard !url.isEmpty else { return }
                    urlError = nil
                    // Store credentials BEFORE fetching (private/premium feeds).
                    PodcastFeedAuth.set(feedKey: PodcastSubscriptions.feedKey(url),
                                        user: feedUser.trimmingCharacters(in: .whitespaces),
                                        password: feedPassword)
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
                if let urlError {
                    Text(urlError).font(.caption).foregroundStyle(.red)
                }
            } label: {
                Label("Add by URL", systemImage: "link")
            }
        } footer: {
            Text("For private or premium feeds that need a login, add the username and password.")
        }
    }

    // MARK: - Import

    @ViewBuilder
    private var importSection: some View {
        Section {
            Button {
                showOPMLImporter = true
            } label: {
                Label("Import OPML", systemImage: "square.and.arrow.down")
            }
            .disabled(isImporting)
            Button {
                showAppleImporter = true
            } label: {
                Label("Import from Apple Podcasts", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(isImporting)
            if isImporting {
                HStack { ProgressView(); Text("Importing…").foregroundStyle(.secondary) }
            }
        } header: {
            Text("Import")
        } footer: {
            Text("OPML brings in subscriptions from other podcast apps. Apple Podcasts import reads an MTLibrary.sqlite copied from a Mac and also restores play progress and played state.")
        }
    }

    /// Mirror local RSS subscriptions to the server (ABS canonical) — for a
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

    /// Read and import the selected file (OPML or Apple SQLite).
    private func handleImport(_ result: Result<[URL], Error>, apple: Bool) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            // File is outside the sandbox → request access explicitly.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            if apple {
                if let r = await subs.importAppleLibrary(at: url) {
                    importMessage = summary(r)
                } else {
                    importMessage = String(localized: "Could not read this file as an Apple Podcasts database.")
                }
            } else {
                guard let data = try? Data(contentsOf: url) else {
                    importMessage = String(localized: "Could not read this file.")
                    return
                }
                importMessage = summary(await subs.importOPML(data))
            }
        }
    }

    private func summary(_ r: PodcastSubscriptions.ImportResult) -> String {
        var lines = [String(localized: "\(r.subscribed) subscriptions imported")]
        if r.progressApplied > 0 {
            lines.append(String(localized: "\(r.progressApplied) episodes with progress"))
        }
        if r.failed > 0 {
            lines.append(String(localized: "\(r.failed) feeds could not be loaded"))
        }
        // S21: paid/exclusive subscriptions have no public feed — say so instead
        // of dropping them silently.
        if r.paidSkipped > 0 {
            lines.append(String(localized: "\(r.paidSkipped) paid subscriptions can't be imported — use the provider's subscriber feed"))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Logik

    private func runSearch(_ term: String) async {
        isSearching = true
        let directory: PodcastDirectory
        if source == .podcastIndex, AppStorageKeys.podcastIndexConfigured {
            directory = PodcastIndexDirectory(
                key: AppStorageKeys.podcastIndexKeyValue,
                secret: AppStorageKeys.podcastIndexSecretValue
            )
        } else {
            directory = ITunesDirectory()
        }
        results = (try? await directory.search(term)) ?? []
        isSearching = false
    }

    @ViewBuilder
    private func artwork(url: URL?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Group {
            if let url {
                CachedAsyncImage(url: url, useThumbnail: true) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
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

/// PodcastIndex access (optional) — key (public, UserDefaults) + secret
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
