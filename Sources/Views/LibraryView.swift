import SwiftUI
import UIKit

struct LibraryView: View {
    // Prozessweite Instanzen (AppSession) statt eigener @StateObjects — die
    // CarPlay-Szene teilt sich Player und Bibliothek mit der UI.
    @ObservedObject private var viewModel: LibraryViewModel
    @ObservedObject private var playerCoordinator: PlayerCoordinator
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    /// Abos beobachten, damit der Podcast-Tab sofort erscheint/verschwindet.
    @ObservedObject private var podcastSubs = PodcastSubscriptions.shared
    @State private var isShowingSearch = false
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
    /// Aktiver Inhaltstyp-Tab. Heute nur Hörbücher; die untere Tab-Leiste
    /// erscheint erst, wenn eine zweite Quelle einen anderen Typ mitbringt.
    @State private var selectedMediaType: MediaType = .audiobooks

    /// Verfügbare Inhaltstypen aus allen aktiven Quellen (dedupliziert,
    /// in fester Reihenfolge). Heute `[.audiobooks]`.
    private var availableMediaTypes: [MediaType] {
        let present = Set(AppSession.shared.allProviders.filter(\.isAvailable).map(\.mediaType))
        return MediaType.allCases.filter { present.contains($0) }
    }

    let provider: any AudioProvider
    let onLogout: () -> Void

    init(provider: any AudioProvider, onLogout: @escaping () -> Void) {
        self.provider = provider
        self.onLogout = onLogout
        _viewModel = ObservedObject(wrappedValue: AppSession.shared.libraryViewModel)
        _playerCoordinator = ObservedObject(wrappedValue: AppSession.shared.playerCoordinator)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                if viewModel.isShowingOfflineCache {
                    offlineBanner
                }

                // Inhalt nach Tab. Heute nur Hörbücher; Podcasts/Musik kommen
                // additiv als weitere Cases mit eigenen Views.
                switch selectedMediaType {
                case .audiobooks:
                    audiobooksContent
                case .podcasts:
                    PodcastsView(playerCoordinator: playerCoordinator)
                default:
                    Spacer()
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
            // Programmatic push aus dem Such-Overlay (Buch-Tap): die Overlay
            // fährt runter und legt die Item-ID auf den Pfad.
            .navigationDestination(for: String.self) { itemId in
                if let entry = viewModel.entries.first(where: { $0.id == itemId }) {
                    BookDetailScreen(entry: entry, coordinator: playerCoordinator, libraryViewModel: viewModel)
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
                        if let vm = playerCoordinator.viewModel, let item = playerCoordinator.activeItem {
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
                        FloatingSearchButton {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                                isShowingSearch = true
                            }
                        }
                    }
                    // Inhaltstyp-Tabs UNTER dem Mini-Player — erst ab zwei
                    // Typen (heute nur Hörbücher → unsichtbar). Der Nutzer
                    // wechselt damit zwischen Hörbüchern/Podcasts/Musik.
                    if availableMediaTypes.count > 1 {
                        MediaTabBar(types: availableMediaTypes, selected: $selectedMediaType)
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
                    let coverURL = provider.coverURL(forItemId: item.id)
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
            // Series data lives here — hand the coordinator a lookup for the
            // auto-play-next-in-series setting.
            playerCoordinator.nextInSeriesProvider = { [weak viewModel] itemId in
                viewModel?.nextInSeries(after: itemId)?.item
            }
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
            // Cold start via quick action / Siri: the request arrived before
            // the library was loaded — execute it now.
            await handlePendingResumeRequest()
            // Falls beim letzten Mal offline Fortschritt liegen geblieben ist
            // (App wurde offline beendet, bevor der Sync durchging): jetzt
            // nachreichen.
            await SyncQueue.shared.flush(apiClient: provider)
            await BookmarkQueue.shared.flush(provider: provider)
            await playerCoordinator.viewModel?.updateSyncStatusFromQueue()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Kehrt die App in den Vordergrund zurück, still die Fortschritts-
            // balken aktualisieren — z. B. wenn zwischenzeitlich auf einem
            // anderen Gerät weitergehört wurde.
            if newPhase == .active {
                Task {
                    await viewModel.refreshProgress()
                    await handlePendingResumeRequest()
                }
            }
            // Home-Screen-Quick-Action fürs zuletzt gehörte Buch anbieten.
            if newPhase == .background {
                updateQuickActions()
            }
        }
        .onOpenURL { url in
            // Home-Screen-Widget: maer://resume → Weiterhören-Pfad (wie
            // Quick Action / Siri).
            guard url.scheme == "maer" else { return }
            ResumeRequest.pending = true
            Task { await handlePendingResumeRequest() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .resumeLastBookRequested)) { _ in
            // Fires when the app was ALREADY running (no scene-phase change).
            Task { await handlePendingResumeRequest() }
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
                    await SyncQueue.shared.flush(apiClient: provider)
                    await BookmarkQueue.shared.flush(provider: provider)
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
        // Such-Overlay als Glas-Sheet über der Bibliothek — UNTER dem vollen
        // Player (dieses .overlay steht früher in der Kette).
        .overlay {
            if isShowingSearch {
                GeometryReader { proxy in
                    SearchOverlay(
                        libraryViewModel: viewModel,
                        provider: provider,
                        topInset: proxy.safeAreaInsets.top,
                        presentHeight: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom,
                        onSelect: { entry in
                            isShowingSearch = false
                            navigationPath.append(entry.id)
                        },
                        onDismiss: { isShowingSearch = false }
                    )
                }
                .transition(.identity)
            }
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

    /// Hörbuch-Tab: Lade-/Fehler-/Leer-Zustände und die eigentliche Liste.
    @ViewBuilder
    private var audiobooksContent: some View {
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

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
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
                                    url: provider.coverURL(forItemId: entry.id),
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
                            .accessibilityElement(children: .combine)
                        }
                        .buttonStyle(.plain)
                        .modifier(BookCellContextMenu(
                            entry: entry,
                            playerCoordinator: playerCoordinator,
                            libraryViewModel: viewModel
                        ))
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
                    BookGridCell(
                        entry: entry,
                        width: gridCellWidth,
                        playerCoordinator: playerCoordinator,
                        libraryViewModel: viewModel
                    )
                    .padding(.top, 10)
                case .series(let name, let entries):
                    NavigationLink {
                        seriesDetail(name: name, entries: entries)
                    } label: {
                        SeriesStackCell(
                            name: name,
                            entries: entries,
                            cellWidth: gridCellWidth,
                            coverURL: { provider.coverURL(forItemId: $0) }
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

    // MARK: Weiterhören von außen (Quick Action / Siri)

    /// Executes a pending "continue listening" request (home-screen quick
    /// action or Siri shortcut): open the last played book and play.
    private func handlePendingResumeRequest() async {
        // Siri "Play <book>": a specific book beats "continue last".
        if let itemId = ResumeRequest.pendingItemId {
            ResumeRequest.pendingItemId = nil
            ResumeRequest.pending = false
            if let entry = viewModel.entries.first(where: { $0.id == itemId }) {
                await playerCoordinator.open(item: entry.item)
            }
            return
        }
        guard ResumeRequest.pending else { return }
        ResumeRequest.pending = false
        // Already active (e.g. paused in the mini player): just play.
        if let vm = playerCoordinator.viewModel {
            await vm.playWithServerCheck()
            return
        }
        guard let lastId = UserDefaults.standard.string(forKey: AppStorageKeys.lastPlayedItemId),
              let entry = viewModel.entries.first(where: { $0.id == lastId }) else { return }
        await playerCoordinator.open(item: entry.item)
    }

    /// Registers the dynamic home-screen quick action with the current
    /// book's title as subtitle (or removes it without a last book).
    private func updateQuickActions() {
        guard let lastId = UserDefaults.standard.string(forKey: AppStorageKeys.lastPlayedItemId),
              let entry = viewModel.entries.first(where: { $0.id == lastId }) else {
            UIApplication.shared.shortcutItems = []
            return
        }
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: ResumeRequest.quickActionType,
                localizedTitle: String(localized: "Continue Listening"),
                localizedSubtitle: entry.item.title,
                icon: UIApplicationShortcutIcon(systemImageName: "play.fill")
            )
        ]
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
        // The menu style tints its label ABOVE the label's own styling —
        // without this the icon renders in the app accent (orange) instead
        // of behaving like the other toolbar buttons.
        .tint(.primary)
    }

    private var settingsLink: some View {
        NavigationLink {
            SettingsView(coordinator: playerCoordinator, libraryViewModel: viewModel, onLogout: onLogout)
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
                // Shared cell (BookGridComponents) — identical in the
                // library and the author/genre browse grids.
                BookGridCell(
                    entry: entry,
                    width: gridCellWidth,
                    playerCoordinator: playerCoordinator,
                    libraryViewModel: viewModel
                )
            }
        }
        .padding(.horizontal)
    }

}
