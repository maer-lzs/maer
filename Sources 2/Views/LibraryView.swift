import SwiftUI

/// Reine Marker-Struktur für den Navigationspfad — steht nur dafür, "der
/// große Player wird gepusht", trägt selbst keine Daten (die Session liegt
/// im PlayerCoordinator, nicht im Navigationspfad).
private struct PlayerRoute: Hashable {}

struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    @StateObject private var playerCoordinator: PlayerCoordinator
    @State private var searchText = ""
    @State private var navigationPath = NavigationPath()
    @State private var isShowingFullPlayer = false
    @Environment(\.scenePhase) private var scenePhase

    let apiClient: APIClient
    let onLogout: () -> Void

    init(apiClient: APIClient, onLogout: @escaping () -> Void) {
        self.apiClient = apiClient
        self.onLogout = onLogout
        _viewModel = StateObject(wrappedValue: LibraryViewModel(apiClient: apiClient))
        _playerCoordinator = StateObject(wrappedValue: PlayerCoordinator(apiClient: apiClient))
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                // Suchleiste fest oben, immer sichtbar.
                searchBar

                Group {
                    if viewModel.isLoading && viewModel.entries.isEmpty {
                        Spacer()
                        ProgressView("Bibliothek wird geladen…")
                        Spacer()
                    } else if let error = viewModel.errorMessage, viewModel.entries.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Text(error).multilineTextAlignment(.center)
                            Button("Erneut versuchen") {
                                Task { await viewModel.loadLibrary() }
                            }
                        }
                        .padding()
                        Spacer()
                    } else {
                        content
                    }
                }
            }
            .navigationTitle("Bibliothek")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Abmelden", action: onLogout)
                }
            }
            .navigationDestination(for: PlayerRoute.self) { _ in
                PlayerScreen(coordinator: playerCoordinator)
                    .onAppear { isShowingFullPlayer = true }
                    .onDisappear { isShowingFullPlayer = false }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Zentral über dem ganzen NavigationStack: der Mini-Player erscheint
            // dadurch auf jeder Ebene (Bibliothek UND Buchdetail), ohne ihn
            // mehrfach einbauen zu müssen. Da er strukturell AUSSERHALB des
            // NavigationStack liegt, kann er nicht per eigenem NavigationLink
            // navigieren — stattdessen hängt er sich per Callback in den
            // Navigationspfad des Stacks ein (siehe navigationPath oben).
            // Auf dem vollen Player selbst wird er ausgeblendet, sonst
            // erscheinen Play/Pause & Co. doppelt.
            if !isShowingFullPlayer {
                MiniPlayerBar(coordinator: playerCoordinator) {
                    navigationPath.append(PlayerRoute())
                }
            }
        }
        .task {
            if viewModel.entries.isEmpty {
                await viewModel.loadLibrary()
            }
            // Zuletzt gehörtes Buch still in den Mini-Player holen.
            await playerCoordinator.restoreLastSession(from: viewModel.entries)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Kehrt die App in den Vordergrund zurück, still die Fortschritts-
            // balken aktualisieren — z. B. wenn zwischenzeitlich auf einem
            // anderen Gerät weitergehört wurde.
            if newPhase == .active {
                Task { await viewModel.refreshProgress() }
            }
        }
    }

    // MARK: - Suchleiste

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Titel oder Autor", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Inhalt

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if isSearching {
                    searchResultsSection
                } else {
                    if !viewModel.continueListening.isEmpty {
                        horizontalSection(title: "Weiter hören", entries: viewModel.continueListening)
                    }
                    if !viewModel.recentlyAdded.isEmpty {
                        horizontalSection(title: "Kürzlich hinzugefügt", entries: viewModel.recentlyAdded)
                    }
                    allBooksSection
                }
            }
            .padding(.vertical)
        }
        .refreshable { await viewModel.loadLibrary() }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredEntries: [LibraryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return viewModel.entries }
        return viewModel.entries.filter { entry in
            entry.item.title.lowercased().contains(query)
                || (entry.item.author?.lowercased().contains(query) ?? false)
        }
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if filteredEntries.isEmpty {
                Text("Keine Treffer.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                bookGrid(filteredEntries)
            }
        }
    }

    // MARK: Horizontale Sektion

    private func horizontalSection(title: String, entries: [LibraryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3).bold()
                .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(entries) { entry in
                        NavigationLink {
                            BookDetailScreen(entry: entry, coordinator: playerCoordinator, libraryViewModel: viewModel)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                BookCoverView(
                                    url: apiClient.coverURL(forItemId: entry.id),
                                    progress: entry.progress,
                                    size: 132
                                )
                                Text(entry.item.title)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .frame(width: 132, alignment: .leading)
                                if let p = entry.progress, p.isStarted {
                                    Text("\(p.percentInt) %")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: Alle Bücher

    private var allBooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Alle Bücher")
                    .font(.title3).bold()
                Spacer()
                sortFilterMenu
            }
            .padding(.horizontal)
            bookGrid(viewModel.sortedFilteredEntries)
        }
    }

    private var sortFilterMenu: some View {
        Menu {
            Picker("Sortieren", selection: $viewModel.sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            Divider()
            Picker("Filter", selection: $viewModel.filterOption) {
                ForEach(FilterOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.title3)
        }
    }

    /// Adaptives Cover-Grid. Die Spaltenzahl richtet sich automatisch nach der
    /// verfügbaren Breite: auf dem iPhone wenige, auf dem iPad (v. a. quer)
    /// deutlich mehr Spalten — ganz ohne Geräteabfrage.
    private func bookGrid(_ entries: [LibraryEntry]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: 16)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(entries) { entry in
                NavigationLink {
                    BookDetailScreen(entry: entry, coordinator: playerCoordinator, libraryViewModel: viewModel)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        BookCoverView(
                            url: apiClient.coverURL(forItemId: entry.id),
                            progress: entry.progress,
                            size: 132
                        )
                        Text(entry.item.title)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let author = entry.item.author {
                            Text(author)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let p = entry.progress {
                            Text(statusText(p))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 132)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private func statusText(_ p: BookProgress) -> String {
        if p.isFinished { return "Abgeschlossen" }
        if p.isStarted { return "\(p.percentInt) % gehört" }
        return ""
    }
}
