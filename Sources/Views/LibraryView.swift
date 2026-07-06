import SwiftUI

/// Reine Marker-Struktur für den Navigationspfad — steht nur dafür, "der
/// große Player wird gepusht", trägt selbst keine Daten (die Session liegt
/// im PlayerCoordinator, nicht im Navigationspfad).
private struct PlayerRoute: Hashable {}

struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    @StateObject private var playerCoordinator: PlayerCoordinator
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var searchText = ""
    @State private var isSearchExpanded = false
    @State private var navigationPath = NavigationPath()
    @State private var isShowingFullPlayer = false
    @Environment(\.scenePhase) private var scenePhase

    /// Auf dem iPhone ist nicht genug Platz für Mini-Leiste UND aufgeklappte
    /// Suche gleichzeitig — dort schließt die Suche die Mini-Leiste temporär
    /// (die Wiedergabe läuft im Hintergrund normal weiter). Auf dem iPad ist
    /// genug Platz, beide bleiben nebeneinander sichtbar.
    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

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
                if viewModel.isShowingOfflineCache {
                    offlineBanner
                }

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
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 8) {
                        if let vm = playerCoordinator.viewModel {
                            ResumeMessageBanner(viewModel: vm)
                        }
                        sortFilterMenu
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Abmelden", action: onLogout)
                        .foregroundStyle(.white)
                }
            }
            .navigationDestination(for: PlayerRoute.self) { _ in
                PlayerScreen(coordinator: playerCoordinator)
                    .onAppear { isShowingFullPlayer = true }
                    .onDisappear { isShowingFullPlayer = false }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Mini-Leiste und Such-Button in EINER Zeile, damit der Such-
            // Button nie nach oben verschoben wird, nur weil die Mini-Leiste
            // erscheint/verschwindet — beide bleiben auf gleicher Höhe.
            // Zentral über dem ganzen NavigationStack, damit beide auf jeder
            // Ebene (Bibliothek UND Buchdetail) sichtbar bleiben. Da diese
            // Zeile strukturell AUSSERHALB des NavigationStack liegt, kann
            // die Mini-Leiste nicht per eigenem NavigationLink navigieren —
            // stattdessen hängt sie sich per Callback in den Navigationspfad
            // des Stacks ein (siehe navigationPath oben). Auf dem vollen
            // Player selbst wird die ganze Zeile ausgeblendet, sonst
            // erscheinen Play/Pause & Co. doppelt.
            if !isShowingFullPlayer {
                HStack(spacing: 10) {
                    // Auf dem iPhone verschwindet die Mini-Leiste, sobald die
                    // Suche aufklappt — nicht genug Platz für beides. Auf dem
                    // iPad bleibt sie bestehen (siehe isPhone).
                    if let vm = playerCoordinator.viewModel, let item = playerCoordinator.activeItem,
                       !(isPhone && isSearchExpanded) {
                        MiniPlayerBar(coordinator: playerCoordinator, viewModel: vm, item: item) {
                            navigationPath.append(PlayerRoute())
                        }
                    } else {
                        Spacer(minLength: 0)
                    }
                    FloatingSearchButton(searchText: $searchText, isExpanded: $isSearchExpanded)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            }
        }
        .task {
            if viewModel.entries.isEmpty {
                await viewModel.loadLibrary()
            }
            // Zuletzt gehörtes Buch still in den Mini-Player holen.
            await playerCoordinator.restoreLastSession(from: viewModel.entries)
            // Falls beim letzten Mal offline Fortschritt liegen geblieben ist
            // (App wurde offline beendet, bevor der Sync durchging): jetzt
            // nachreichen.
            await SyncQueue.shared.flush(apiClient: apiClient)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Kehrt die App in den Vordergrund zurück, still die Fortschritts-
            // balken aktualisieren — z. B. wenn zwischenzeitlich auf einem
            // anderen Gerät weitergehört wurde.
            if newPhase == .active {
                Task { await viewModel.refreshProgress() }
            }
        }
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            // Deckt den Fall ab, dass die App die ganze Zeit offen war,
            // während die Verbindung wiederkam — ohne diesen Trigger würde
            // der "Offline"-Hinweis fälschlich stehen bleiben, obwohl längst
            // wieder Netz da ist.
            if isConnected && viewModel.isShowingOfflineCache {
                Task { await viewModel.loadLibrary() }
            }
            if isConnected {
                Task { await SyncQueue.shared.flush(apiClient: apiClient) }
            }
        }
    }

    // MARK: - Suchleiste

    private var offlineBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("Offline — zuletzt bekannter Stand")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    // MARK: - Inhalt

    @State private var libraryWidth: CGFloat = 0

    /// Kleinste erlaubte Spaltenbreite — bei diesem Wert lag die
    /// Spaltenbreite auch schon vor den ganzen Grid-Anpassungen, er ergibt
    /// auf einem normalen iPhone-Hochformat 3 Spalten.
    private let minColumnWidth: CGFloat = 108
    private let gridSpacing: CGFloat = 16
    private let gridHorizontalPadding: CGFloat = 16

    /// Selbst berechnete Spaltenzahl statt `.adaptive` — das hat sich als
    /// unzuverlässig erwiesen (mal keine Neuberechnung nach einer Rotation,
    /// mal eine Spaltenbreite, die nicht zur tatsächlichen Cover-Größe
    /// passte und dadurch überlappte). Mit einer einzigen verlässlichen
    /// Breitenmessung als Quelle für sowohl Spaltenzahl als auch Zellgröße
    /// gibt es keine Mehrdeutigkeit mehr.
    private var columnCount: Int {
        guard libraryWidth > 0 else { return 3 }
        let available = libraryWidth - gridHorizontalPadding * 2
        let count = Int((available + gridSpacing) / (minColumnWidth + gridSpacing))
        return max(count, 1)
    }

    /// Zellbreite, die exakt zur berechneten Spaltenzahl passt — Grid und
    /// Cover-Größe nutzen immer denselben Wert, können also nie auseinanderlaufen.
    private var gridCellWidth: CGFloat {
        guard libraryWidth > 0 else { return 132 }
        let available = libraryWidth - gridHorizontalPadding * 2
        let totalSpacing = gridSpacing * CGFloat(columnCount - 1)
        return (available - totalSpacing) / CGFloat(columnCount)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if isSearching {
                    searchResultsSection
                } else {
                    if !viewModel.continueListening.isEmpty {
                        horizontalSection(title: "Weiter hören", entries: viewModel.continueListening)
                    }
                    if !viewModel.downloadedEntries.isEmpty {
                        horizontalSection(title: "Heruntergeladen", entries: viewModel.downloadedEntries)
                    }
                    if !viewModel.recentlyAdded.isEmpty {
                        horizontalSection(title: "Kürzlich hinzugefügt", entries: viewModel.recentlyAdded)
                    }
                    allBooksSection
                }
            }
            // Explizit auf volle Breite zwingen — ohne das bestimmt sich die
            // Breite des Stacks nach seinem Inhalt statt nach der tatsächlich
            // verfügbaren Bildschirmbreite, was zu einem zirkulären Bezug mit
            // dem Grid darin führen konnte.
            .frame(maxWidth: .infinity)
            .padding(.vertical)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { libraryWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, newWidth in
                            libraryWidth = newWidth
                        }
                }
            )
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
                                    itemId: entry.id,
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
                        .contextMenu { contextMenu(for: entry) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: Alle Bücher

    private var allBooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alle Bücher")
                .font(.title3).bold()
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
            Button {
                viewModel.sortAscending.toggle()
            } label: {
                Label(
                    viewModel.sortAscending ? "Aufsteigend" : "Absteigend",
                    systemImage: viewModel.sortAscending ? "arrow.up" : "arrow.down"
                )
            }
            Divider()
            Picker("Filter", selection: $viewModel.filterOption) {
                ForEach(FilterOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } label: {
            // Bewusst OHNE eigenen Glas-Hintergrund: In Toolbars gibt iOS 26
            // Buttons automatisch ihr eigenes Liquid-Glass-Aussehen — ein
            // zusätzlicher eigener Hintergrund hier würde sich mit dem
            // System-eigenen verschachteln (zwei Gläser ineinander statt
            // einem, sichtbar als doppelter Kreis/Kapsel-Rahmen).
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.white)
        }
    }

    /// Cover-Grid mit selbst berechneter Spaltenzahl und -breite (siehe
    /// `columnCount`/`gridCellWidth`) statt `.adaptive` — Grid und Cover-Größe
    /// nutzen jetzt garantiert denselben Wert, können also nie mehr
    /// auseinanderlaufen (weder zu schmal mit Überlappung, noch unnötig
    /// wenige Spalten auf einem schmalen iPhone).
    private func bookGrid(_ entries: [LibraryEntry]) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(entries) { entry in
                NavigationLink {
                    BookDetailScreen(entry: entry, coordinator: playerCoordinator, libraryViewModel: viewModel)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        BookCoverView(
                            url: apiClient.coverURL(forItemId: entry.id),
                            progress: entry.progress,
                            itemId: entry.id,
                            size: gridCellWidth
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
                    .frame(width: gridCellWidth, alignment: .leading)
                }
                .buttonStyle(.plain)
                .contextMenu { contextMenu(for: entry) }
            }
        }
        .padding(.horizontal)
    }

    // MARK: Kontextmenü (Haptic Touch)

    @ViewBuilder
    private func contextMenu(for entry: LibraryEntry) -> some View {
        Button {
            Task { await playerCoordinator.open(item: entry.item) }
        } label: {
            Label("Abspielen", systemImage: "play.fill")
        }

        if DownloadManager.shared.isDownloaded(itemId: entry.id) {
            Button(role: .destructive) {
                DownloadManager.shared.deleteDownload(itemId: entry.id)
            } label: {
                Label("Download löschen", systemImage: "trash")
            }
        } else if !DownloadManager.shared.isDownloading(itemId: entry.id) {
            Button {
                Task { await quickDownload(entry: entry) }
            } label: {
                Label("Für offline speichern", systemImage: "arrow.down.circle")
            }
        }

        Button {
            Task { await quickToggleFinished(entry: entry) }
        } label: {
            let isFinished = entry.progress?.isFinished ?? false
            Label(
                isFinished ? "Als ungehört markieren" : "Als gehört markieren",
                systemImage: isFinished ? "checkmark.circle.fill" : "checkmark.circle"
            )
        }
    }

    /// Lädt kurz die Track-Info nach (die Liste selbst hat nur die schlanken
    /// Metadaten) und startet dann den Download — ohne WLAN-Rückfrage, das ist
    /// hier bewusst die schnelle Variante fürs Kontextmenü.
    private func quickDownload(entry: LibraryEntry) async {
        guard let detail = try? await apiClient.fetchItemDetail(itemId: entry.id) else { return }
        await DownloadManager.shared.download(item: detail, apiClient: apiClient)
    }

    /// Wie in BookDetailScreen: immer den vollständigen Datensatz
    /// (currentTime + duration + isFinished) schicken, nie nur das Flag
    /// allein — sonst geht der reale Fortschritt verloren (siehe Sync-Bugfix).
    private func quickToggleFinished(entry: LibraryEntry) async {
        guard let fresh = try? await apiClient.fetchItemDetail(itemId: entry.id) else { return }
        let duration = fresh.media.duration ?? 0
        let currentTime = fresh.userMediaProgress?.currentTime ?? 0
        let newIsFinished = !(entry.progress?.isFinished ?? false)
        try? await apiClient.updateProgress(
            itemId: entry.id,
            currentTime: newIsFinished ? duration : currentTime,
            duration: duration,
            isFinished: newIsFinished
        )
        await viewModel.refreshProgress()
    }

    private func statusText(_ p: BookProgress) -> String {
        if p.isFinished { return "Abgeschlossen" }
        if p.isStarted { return "\(p.percentInt) % gehört" }
        return ""
    }
}
