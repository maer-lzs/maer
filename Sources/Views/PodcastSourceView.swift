import SwiftUI
import UniformTypeIdentifiers

/// Podcasts abonnieren (Einstellungen → Quellen → Podcasts): nach Namen
/// suchen (Apple/PodcastIndex) und mit einem Tap abonnieren, alternativ per
/// Feed-URL; abonnierte Shows verwalten. Quellenspezifische Verwaltung,
/// analog `LocalFilesView` — der Podcast-Tab konsumiert nur.
struct PodcastSourceView: View {
    @ObservedObject private var subs = PodcastSubscriptions.shared
    @ObservedObject private var absPodcast = ABSPodcastProvider.shared

    /// Neue Abos auf dem ABS-Server anlegen (synchronisiert) statt lokal — nur
    /// relevant, wenn der Server eine Podcast-Bibliothek hat.
    @State private var subscribeToServer = true
    @State private var subscribeError: String?
    /// Feed-only-Folge beim Abspielen nach ~30 s automatisch am Server sichern.
    @AppStorage("podcastAutoSaveOnPlay") private var autoSaveOnPlay = true

    private enum Source: Hashable { case apple, podcastIndex }
    @State private var source: Source = .apple

    @State private var searchText = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var isSearching = false
    @State private var subscribingFeeds: Set<String> = []

    @State private var showAddByURL = false
    @State private var feedURL = ""
    @State private var urlError: String?

    @State private var showOPMLImporter = false
    @State private var showAppleImporter = false
    @State private var importMessage: String?
    @State private var isImporting = false

    var body: some View {
        List {
            if absPodcast.hasPodcasts {
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
            searchSection
            if !results.isEmpty || isSearching {
                resultsSection
            }
            subscriptionsSection
            archivedSection
            addByURLSection
            importSection
            NavigationLink {
                PodcastIndexKeyView()
            } label: {
                Label("PodcastIndex Access", systemImage: "key")
            }
        }
        .navigationTitle("Podcasts")
        .navigationBarTitleDisplayMode(.inline)
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
        // Debounce: nach Tippen kurz warten, dann suchen.
        .task(id: searchText) {
            let term = searchText.trimmingCharacters(in: .whitespaces)
            guard term.count >= 2 else { results = []; return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await runSearch(term)
        }
    }

    // MARK: - Suche

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

    /// Bereits abonniert (lokal ODER am Server) — normalisierte Feed-URL.
    private func isSubscribed(_ feedURL: String) -> Bool {
        let n = PodcastSubscriptions.normalizeFeedURL(feedURL)
        return subs.shows.contains { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
            || absPodcast.shows.contains { PodcastSubscriptions.normalizeFeedURL($0.feedURL) == n }
    }

    /// Abo anlegen — am Server (synchronisiert), wenn möglich/gewählt, sonst lokal.
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

    // MARK: - Abos / URL

    /// Archivierte Server-Shows (Abo beendet, Historie am Server erhalten).
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
                Button("Add Feed") {
                    let url = feedURL.trimmingCharacters(in: .whitespaces)
                    guard !url.isEmpty else { return }
                    urlError = nil
                    Task {
                        let ok = await performSubscribe(feedURL: url)
                        if ok { feedURL = ""; showAddByURL = false }
                        else { urlError = String(localized: "Could not load this feed. Check the URL.") }
                    }
                }
                .disabled(feedURL.trimmingCharacters(in: .whitespaces).isEmpty)
                if let urlError {
                    Text(urlError).font(.caption).foregroundStyle(.red)
                }
            } label: {
                Label("Add by URL", systemImage: "link")
            }
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

    /// Ausgewählte Datei einlesen und importieren (OPML oder Apple-SQLite).
    private func handleImport(_ result: Result<[URL], Error>, apple: Bool) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            // Datei liegt außerhalb der Sandbox → Zugriff explizit anfordern.
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

/// PodcastIndex-Zugang (optional) — Key (öffentlich, UserDefaults) + Secret
/// (Credential, im Keychain).
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
    }
}
