import SwiftUI

/// Podcasts abonnieren (Einstellungen → Quellen → Podcasts): nach Namen
/// suchen (Apple/PodcastIndex) und mit einem Tap abonnieren, alternativ per
/// Feed-URL; abonnierte Shows verwalten. Quellenspezifische Verwaltung,
/// analog `LocalFilesView` — der Podcast-Tab konsumiert nur.
struct PodcastSourceView: View {
    @ObservedObject private var subs = PodcastSubscriptions.shared

    private enum Source: Hashable { case apple, podcastIndex }
    @State private var source: Source = .apple

    @State private var searchText = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var isSearching = false
    @State private var subscribingFeeds: Set<String> = []

    @State private var showAddByURL = false
    @State private var feedURL = ""
    @State private var urlError: String?

    var body: some View {
        List {
            searchSection
            if !results.isEmpty || isSearching {
                resultsSection
            }
            subscriptionsSection
            addByURLSection
            NavigationLink {
                PodcastIndexKeyView()
            } label: {
                Label("PodcastIndex Access", systemImage: "key")
            }
        }
        .navigationTitle("Podcasts")
        .navigationBarTitleDisplayMode(.inline)
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
        if subs.shows.contains(where: { $0.feedURL == result.feedURL }) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if subscribingFeeds.contains(result.feedURL) {
            ProgressView()
        } else {
            Button("Subscribe") {
                subscribingFeeds.insert(result.feedURL)
                Task {
                    _ = await subs.subscribe(urlString: result.feedURL)
                    subscribingFeeds.remove(result.feedURL)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Abos / URL

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
                        let ok = await subs.subscribe(urlString: url)
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

    // MARK: - Logik

    private func runSearch(_ term: String) async {
        isSearching = true
        let directory: PodcastDirectory
        if source == .podcastIndex, AppStorageKeys.podcastIndexConfigured {
            directory = PodcastIndexDirectory(
                key: UserDefaults.standard.string(forKey: AppStorageKeys.podcastIndexKey) ?? "",
                secret: UserDefaults.standard.string(forKey: AppStorageKeys.podcastIndexSecret) ?? ""
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

/// PodcastIndex-Zugang (optional) — Key + Secret eintragen.
private struct PodcastIndexKeyView: View {
    @AppStorage(AppStorageKeys.podcastIndexKey) private var key = ""
    @AppStorage(AppStorageKeys.podcastIndexSecret) private var secret = ""

    var body: some View {
        Form {
            Section {
                TextField("PodcastIndex API Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Secret", text: $secret)
            } footer: {
                Text("Optional. Get a free key at podcastindex.org — enables searching the open PodcastIndex catalog in addition to Apple.")
            }
        }
        .navigationTitle("PodcastIndex Access")
        .navigationBarTitleDisplayMode(.inline)
    }
}
