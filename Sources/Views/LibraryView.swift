import SwiftUI

struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    @StateObject private var playerCoordinator: PlayerCoordinator
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var searchText = ""
    @State private var isSearchExpanded = false
    @State private var navigationPath = NavigationPath()
    @State private var isShowingFullPlayer = false
    @State private var showDeleteAllDownloads = false
    /// Vertikaler Zieh-Versatz des vollen Players beim Nach-unten-Entlassen
    /// (0 im Ruhezustand).
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    /// Cover accent of the ACTIVE book — shared with every glass element in
    /// the bottom bar (mini player, search button, pill) via environment.
    @StateObject private var bottomColorLoader = CoverColorLoader()
    /// Book-switch swap animation of the mini player (pushed below the
    /// screen while the new accent loads, then springs back up).
    @State private var miniPlayerSwapOffset: CGFloat = 0
    @State private var lastBottomAccentItemId: String?

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
                        ProgressView("Loading library…")
                        Spacer()
                    } else if let error = viewModel.errorMessage, viewModel.entries.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Text(error).multilineTextAlignment(.center)
                            Button("Try Again") {
                                Task { await viewModel.loadLibrary() }
                            }
                        }
                        .padding()
                        Spacer()
                    } else if viewModel.entries.isEmpty {
                        // Verbunden, aber der Server hat (noch) keine Bücher.
                        Spacer()
                        ContentUnavailableView {
                            Label("No Audiobooks", systemImage: "books.vertical")
                        } description: {
                            Text(viewModel.isShowingOfflineCache
                                ? String(localized: "Offline — no books are downloaded.")
                                : String(localized: "Your library is empty. Add audiobooks via the Audiobookshelf web interface."))
                        } actions: {
                            Button("Refresh") {
                                Task { await viewModel.loadLibrary() }
                            }
                        }
                        Spacer()
                    } else {
                        content
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                // Our own adaptive glass instead of the system's toolbar
                // glass — the system one must be FULLY suppressed (shared
                // background hidden AND plain button style below), otherwise
                // both glasses stack: a dark doubled circle with a tinted
                // outline ring.
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .navigationBarLeading) {
                        sortFilterMenu
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .navigationBarTrailing) {
                        settingsLink
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigationBarLeading) {
                        sortFilterMenu
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        settingsLink
                    }
                }
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
                VStack(spacing: 8) {
                    // Quell-/Sync-Hinweis-Pille direkt ÜBER der Mini-Leiste, als
                    // Teil der Bottom-Playback-Zone (nur sichtbar, wenn gesetzt —
                    // reserviert sonst keinen Platz).
                    if let vm = playerCoordinator.viewModel, vm.sourceHint != nil {
                        ResumeMessageBanner(viewModel: vm)
                    }
                    HStack(spacing: 10) {
                        // Auf dem iPhone verschwindet die Mini-Leiste, sobald die
                        // Suche aufklappt — nicht genug Platz für beides. Auf dem
                        // iPad bleibt sie bestehen (siehe isPhone).
                        if let vm = playerCoordinator.viewModel, let item = playerCoordinator.activeItem,
                           !(isPhone && isSearchExpanded) {
                            MiniPlayerBar(coordinator: playerCoordinator, viewModel: vm, item: item) {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                                    isShowingFullPlayer = true
                                }
                            }
                            // Book-switch swap: pushed below the screen edge
                            // while cover/title/accent change, springs back up
                            // (driven by the .task(id:) below).
                            .offset(y: miniPlayerSwapOffset)
                        } else {
                            Spacer(minLength: 0)
                        }
                        FloatingSearchButton(searchText: $searchText, isExpanded: $isSearchExpanded)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
                .task(id: playerCoordinator.activeItem?.id) {
                    let previousId = lastBottomAccentItemId
                    lastBottomAccentItemId = playerCoordinator.activeItem?.id
                    guard let item = playerCoordinator.activeItem else {
                        miniPlayerSwapOffset = 0
                        return
                    }
                    let coverURL = apiClient.coverURL(forItemId: item.id)
                    // Real book SWITCH (not first appearance): dip the mini
                    // player below the screen, swap content + accent while it
                    // is hidden, then spring it back up — masks the async
                    // accent load that used to pop the glass color hard.
                    guard let previousId, previousId != item.id else {
                        // First appearance (row insertion animates already):
                        // no dip, but clear any offset a cancelled swap left.
                        miniPlayerSwapOffset = 0
                        await bottomColorLoader.load(from: coverURL)
                        return
                    }
                    withAnimation(.easeIn(duration: 0.25)) {
                        miniPlayerSwapOffset = 160
                    }
                    await bottomColorLoader.load(from: coverURL)
                    // Hold below the edge for a beat even when the cover is
                    // cached (accent load would be instant → visible twitch).
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    // Rapid double switch: a newer task owns the offset now —
                    // springing up here would interrupt ITS dip mid-swap.
                    guard !Task.isCancelled else { return }
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                        miniPlayerSwapOffset = 0
                    }
                }
            }
        }
        // Hoisted OUTSIDE the bottom row so the toolbar buttons (sort,
        // settings) inherit the same cover accent as the glass elements in
        // the bottom row. The detail page overrides it with its own loader.
        .environment(\.glassAccent, playerCoordinator.activeItem != nil ? bottomColorLoader.accent : nil)
        .task {
            // Cover-Wartung (TTL, Größenlimit, verwaiste persistente Cover).
            ImageCache.shared.performMaintenance(
                activeDownloadIds: DownloadManager.shared.downloadedItemIds
            )
            // Download-Wartung: falsche Datei-Endungen aller Bücher reparieren.
            DownloadManager.shared.performMaintenance()
            // Einmalig: unlesbare Alt-Dateien entfernen (Auto-Heilung ersetzt sie).
            DownloadManager.shared.performDeepValidation()
            if viewModel.entries.isEmpty {
                await viewModel.loadLibrary()
            }
            // Zuletzt gehörtes Buch still in den Mini-Player holen.
            await playerCoordinator.restoreLastSession(from: viewModel.entries)
            // Falls beim letzten Mal offline Fortschritt liegen geblieben ist
            // (App wurde offline beendet, bevor der Sync durchging): jetzt
            // nachreichen.
            await SyncQueue.shared.flush(apiClient: apiClient)
            await playerCoordinator.viewModel?.updateSyncStatusFromQueue()
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
                Task {
                    await SyncQueue.shared.flush(apiClient: apiClient)
                    await playerCoordinator.viewModel?.updateSyncStatusFromQueue()
                }
            } else {
                // Verbindung weg, während evtl. gerade abgespielt wird: den
                // Sync-Status sofort sichtbar auf "offline" setzen, ohne etwas
                // in die Queue zu legen.
                playerCoordinator.viewModel?.markConnectionLostWhilePlaying()
            }
        }
        .alert("Delete all downloads?", isPresented: $showDeleteAllDownloads) {
            Button("Delete", role: .destructive) {
                DownloadManager.shared.deleteAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All downloaded audiobooks will be removed from this device. Listening progress is kept.")
        }
        // Logout (manuell oder automatisch bei 401): Wiedergabe sauber beenden —
        // finaler Sync-Versuch landet bei totem Token in der Queue und wird nach
        // dem nächsten Login nachgereicht; Lockscreen-Anzeige wird geräumt.
        .onDisappear {
            playerCoordinator.viewModel?.stop()
        }
        // Voller Player als Overlay ÜBER der Bibliothek (statt Push).
        .overlay {
            if isShowingFullPlayer {
                // Insets hier lesen (normaler Safe-Area-Kontext) und explizit
                // durchreichen — das Overlay selbst ignoriert Safe Areas am Root.
                GeometryReader { proxy in
                    FullPlayerOverlay(
                        coordinator: playerCoordinator,
                        topInset: proxy.safeAreaInsets.top,
                        bottomInset: proxy.safeAreaInsets.bottom,
                        presentHeight: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
                    ) {
                        // Sheet ist hier schon unten — nur Mini-Leiste weich einblenden.
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                            isShowingFullPlayer = false
                        }
                    }
                }
                // Kein .move-Transition: Ein-/Ausfahren läuft über den Offset im
                // Overlay (unterbrechbar, kann nicht mehr hängen bleiben).
                .transition(.identity)
            }
        }
    }

    // MARK: - Suchleiste

    private var offlineBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("Offline — last known state")
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
                        horizontalSection(title: String(localized: "Continue Listening"), entries: viewModel.continueListening)
                    }
                    if !viewModel.downloadedEntries.isEmpty {
                        horizontalSection(
                            title: String(localized: "Downloaded"),
                            entries: viewModel.downloadedEntries,
                            subtitle: ByteCountFormatter.string(
                                fromByteCount: downloadManager.totalDownloadsSize, countStyle: .file
                            ),
                            menu: {
                                Button(role: .destructive) {
                                    showDeleteAllDownloads = true
                                } label: {
                                    Label("Delete All Downloads", systemImage: "trash")
                                }
                            }
                        )
                    }
                    if !viewModel.recentlyAdded.isEmpty {
                        horizontalSection(title: String(localized: "Recently Added"), entries: viewModel.recentlyAdded)
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
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.entries }
        // Diakritika-/case-insensitiv über Titel, Autor, Erzähler und Serie.
        return viewModel.entries.filter { entry in
            let meta = entry.item.media?.metadata
            let fields = [
                entry.item.title,
                meta?.authorName,
                meta?.narratorName,
                meta?.seriesName
            ]
            return fields.contains { field in
                field?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if filteredEntries.isEmpty {
                Text("No results.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else {
                bookGrid(filteredEntries)
            }
        }
    }

    // MARK: Horizontale Sektion

    private func horizontalSection(
        title: String,
        entries: [LibraryEntry],
        subtitle: String? = nil,
        @ViewBuilder menu: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.title3).bold()
                if let subtitle {
                    // Belegter Speicher; Kontext-Menü übers Ellipsis-Icon.
                    Menu {
                        menu()
                    } label: {
                        HStack(spacing: 4) {
                            Text(subtitle)
                            Image(systemName: "ellipsis.circle")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }
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
                                    Text(p.remainingText(bookDuration: entry.item.media?.duration) ?? p.fraction.formatted(.percent.precision(.fractionLength(0))))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            contextMenu(for: entry)
                        } preview: {
                            contextPreview(for: entry)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: Alle Bücher

    private var allBooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All Books")
                .font(.title3).bold()
                .padding(.horizontal)
            if viewModel.sortOption == .serie {
                seriesGrid
            } else {
                bookGrid(viewModel.sortedFilteredEntries)
            }
        }
    }

    /// Grid bei Serien-Sortierung: Serien als Stapel, Einzelbücher normal.
    private var seriesGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(viewModel.seriesGroupedEntries) { gridEntry in
                switch gridEntry {
                case .single(let entry):
                    // Gleicher Top-Abstand wie der Fächer-Headroom der Stapel-
                    // Kacheln — sonst sitzen Cover/Texte in gemischten Zeilen
                    // auf unterschiedlichen Höhen.
                    bookCell(entry).padding(.top, 10)
                case .series(let name, let entries):
                    NavigationLink {
                        seriesDetail(name: name, entries: entries)
                    } label: {
                        SeriesStackCell(
                            name: name,
                            entries: entries,
                            cellWidth: gridCellWidth,
                            coverURL: { apiClient.coverURL(forItemId: $0) }
                        )
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
    }

    /// Detailansicht einer Serie: alle Bände in Reihenfolge.
    private func seriesDetail(name: String, entries: [LibraryEntry]) -> some View {
        ScrollView {
            bookGrid(entries)
                .padding(.top, 12)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sortFilterMenu: some View {
        Menu {
            Picker("Sort By", selection: $viewModel.sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            Button {
                viewModel.sortAscending.toggle()
            } label: {
                Label(
                    viewModel.sortAscending ? String(localized: "Ascending") : String(localized: "Descending"),
                    systemImage: viewModel.sortAscending ? "arrow.up" : "arrow.down"
                )
            }
            Divider()
            Picker("Filter", selection: $viewModel.filterOption) {
                ForEach(FilterOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            toolbarGlassIcon("line.3.horizontal.decrease")
        }
        // Opt out of the toolbar's automatic glass button style — our
        // AdaptiveGlassBackground is the ONLY glass on this button.
        .buttonStyle(.plain)
    }

    private var settingsLink: some View {
        NavigationLink {
            SettingsView(coordinator: playerCoordinator, onLogout: onLogout)
        } label: {
            toolbarGlassIcon("gearshape")
        }
        .buttonStyle(.plain)
    }

    /// Toolbar icon on our OWN adaptive glass circle, treated EXACTLY like
    /// every other glass element (mini player, search button): shared cover
    /// accent in light mode, dark glass in dark mode.
    ///
    /// Toolbar content runs in its OWN environment that does not reliably
    /// carry our values (color scheme reported dark in light mode → black
    /// glass with white icon; `\.glassAccent` absent; menu labels tinted
    /// with the app accent → orange symbol). Everything the glass and icon
    /// need is therefore pinned/passed EXPLICITLY here.
    private func toolbarGlassIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .foregroundStyle(.primary)
            .frame(width: 40, height: 40)
            .modifier(AdaptiveGlassBackground(
                shape: Circle(),
                lightAccent: playerCoordinator.activeItem != nil ? bottomColorLoader.accent : nil
            ))
            .environment(\.colorScheme, systemColorScheme)
            // Menu renders its label via tint (ignoring foregroundStyle).
            .tint(.primary)
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
                bookCell(entry)
            }
        }
        .padding(.horizontal)
    }

    private func bookCell(_ entry: LibraryEntry) -> some View {
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
                    Text(statusText(p, duration: entry.item.media?.duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: gridCellWidth, alignment: .leading)
            // Top-align within the grid row: LazyVGrid sizes each row to its
            // tallest cell and CENTERS shorter ones — covers of cells with
            // less text would sit visibly lower than their neighbours.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenu(for: entry)
        } preview: {
            contextPreview(for: entry)
        }
    }

    // MARK: Kontextmenü (Haptic Touch)

    /// Lifted force-press preview on our adaptive glass instead of the plain
    /// system platter, so it matches the rest of the chrome. Deliberately
    /// NEUTRAL glass: the shared accent belongs to the PLAYING book, not the
    /// pressed one.
    private func contextPreview(for entry: LibraryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BookCoverView(
                url: apiClient.coverURL(forItemId: entry.id),
                progress: entry.progress,
                itemId: entry.id,
                size: 240
            )
            Text(entry.item.title)
                .font(.headline)
                .lineLimit(2)
            if let author = entry.item.author {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let p = entry.progress {
                Text(statusText(p, duration: entry.item.media?.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 240)
        .padding(20)
        .modifier(AdaptiveGlassBackground(shape: RoundedRectangle(cornerRadius: 28, style: .continuous)))
        .environment(\.glassAccent, nil)
        // Room for the glass shadow — the preview is snapshotted at its bounds.
        .padding(12)
    }

    @ViewBuilder
    private func contextMenu(for entry: LibraryEntry) -> some View {
        Button {
            Task { await playerCoordinator.open(item: entry.item) }
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        if DownloadManager.shared.isDownloaded(itemId: entry.id) {
            Button(role: .destructive) {
                DownloadManager.shared.deleteDownload(itemId: entry.id)
            } label: {
                Label("Delete Download", systemImage: "trash")
            }
        } else {
            // Mirror the detail page's download controls: a running or
            // paused download used to leave the menu without ANY download
            // entry — pause/resume/cancel now work from the library too.
            switch DownloadManager.shared.phase[entry.id] {
            case .downloading:
                Button {
                    DownloadManager.shared.pauseDownload(itemId: entry.id)
                } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
                Button(role: .destructive) {
                    DownloadManager.shared.cancelDownload(itemId: entry.id)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            case .paused:
                Button {
                    DownloadManager.shared.resumeDownload(itemId: entry.id)
                } label: {
                    Label("Resume", systemImage: "play.circle")
                }
                Button(role: .destructive) {
                    DownloadManager.shared.cancelDownload(itemId: entry.id)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            case .failed, nil:
                Button {
                    Task { await quickDownload(entry: entry) }
                } label: {
                    Label("Save for Offline", systemImage: "arrow.down.circle")
                }
            }
        }

        Button {
            Task { await quickToggleFinished(entry: entry) }
        } label: {
            let isFinished = entry.progress?.isFinished ?? false
            Label(
                isFinished ? String(localized: "Mark as Unfinished") : String(localized: "Mark as Finished"),
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
        let newIsFinished = !(entry.progress?.isFinished ?? false)
        let duration: Double
        let currentTime: Double
        if let fresh = try? await apiClient.fetchItemDetail(itemId: entry.id) {
            duration = fresh.media.duration ?? 0
            currentTime = fresh.userMediaProgress?.currentTime ?? 0
        } else {
            // Offline/Fehler: lokal bekannte Werte statt stillem Abbruch.
            duration = entry.item.media?.duration ?? 0
            currentTime = (entry.progress?.fraction ?? 0) * duration
        }
        do {
            try await apiClient.updateProgress(
                itemId: entry.id,
                currentTime: newIsFinished ? duration : currentTime,
                duration: duration,
                isFinished: newIsFinished
            )
        } catch {
            // Statusentscheidung nicht verlieren: queuen, Flush reicht nach.
            SyncQueue.shared.enqueue(
                itemId: entry.id,
                currentTime: newIsFinished ? duration : currentTime,
                duration: duration,
                isFinished: newIsFinished
            )
        }
        await viewModel.refreshProgress()
    }

    private func statusText(_ p: BookProgress, duration: Double?) -> String {
        if p.isFinished { return String(localized: "Completed") }
        if p.isStarted {
            if let t = p.remainingText(bookDuration: duration) { return t }
            return String(localized: "\(p.fraction.formatted(.percent.precision(.fractionLength(0)))) listened")
        }
        return ""
    }
}
