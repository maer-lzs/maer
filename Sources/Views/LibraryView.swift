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
    /// Scroll-gesteuertes Zusammenklappen der Bottom-Zone (Apple-Music-artig):
    /// beim Scrollen in der Bibliothek wird sie zu einer kompakten Zeile.
    @Namespace private var barNS
    @ObservedObject private var bottomBar = BottomBarState.shared
    private var barCollapsed: Bool { bottomBar.collapsed }
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
    /// Gemessene Höhe der schwebenden Bottom-Zone (Mini-Player + Tabs) — als
    /// Freiraum unten an alle Scroll-Inhalte gereicht, damit nichts verdeckt
    /// wird. Die Zone liegt als Overlay (reserviert keinen Platz selbst).
    @State private var bottomBarHeight: CGFloat = 0
    /// Einstellungen als modales Sheet (NICHT in den Bibliotheks-Stack gepusht) —
    /// sonst liegt das Mini-Player-Overlay darüber und dessen Medien-Pills lösen
    /// aus den Einstellungen heraus einen Sprung zurück zur Bibliothek aus.
    @State private var showSettings = false
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
            .navigationTitle(selectedMediaType == .audiobooks ? Text("Library") : Text(selectedMediaType.label))
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
        // Bottom-Zone als OVERLAY (reserviert keinen Platz) — den Freiraum
        // liefern die Scroll-Inhalte selbst über `bottomBarClearance()`, was
        // auch gepushte Screens (Detail, Podcast-Show) sauber abdeckt.
        .overlay(alignment: .bottom) {
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
                bottomBarContent
                .animation(.spring(response: 0.5, dampingFraction: 0.88), value: barCollapsed)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
                // Höhe messen → als Freiraum an die Scroll-Inhalte reichen. NUR im
                // aufgeklappten Zustand, damit der Freiraum beim Zusammenklappen
                // nicht schrumpft (das würde eine Scroll-Rückkopplung auslösen).
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { bottomBarHeight = proxy.size.height }
                            .onChange(of: proxy.size.height) { _, h in
                                if !barCollapsed { bottomBarHeight = h }
                            }
                    }
                }
                .task(id: playerCoordinator.activeItem?.id) {
                    let previousId = lastBottomAccentItemId
                    lastBottomAccentItemId = playerCoordinator.activeItem?.id
                    guard let item = playerCoordinator.activeItem else {
                        miniPlayerSwapOffset = 0
                        return
                    }
                    let coverURL = AppSession.shared.coverURL(forItemId: item.id)
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
        // Freiraum-Höhe an ALLE Inhalte (auch gepushte Screens) reichen; auf
        // dem vollen Player 0 (er deckt alles ab).
        .environment(\.bottomBarInset, isShowingFullPlayer ? 0 : bottomBarHeight)
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
            // Prüfen, ob der ABS-Server Podcast-Bibliotheken hat → Podcast-Tab
            // erscheint auch ohne lokale RSS-Abos (1 Request, kein Voll-Laden).
            await AppSession.shared.absPodcastProvider.refreshAvailability()
            // Podcast-Fortschritt über iCloud abgleichen (geräteübergreifend).
            PodcastCloudSync.shared.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Kehrt die App in den Vordergrund zurück, still die Fortschritts-
            // balken aktualisieren — z. B. wenn zwischenzeitlich auf einem
            // anderen Gerät weitergehört wurde.
            if newPhase == .active {
                PodcastCloudSync.shared.reconcile()   // iCloud-Podcast-Stand ziehen
                Task {
                    await viewModel.refreshProgress()
                    await handlePendingResumeRequest()
                }
            }
            // Home-Screen-Quick-Action fürs zuletzt gehörte Buch anbieten.
            if newPhase == .background {
                PodcastCloudSync.shared.reconcile()   // lokalen Stand nach iCloud pushen
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
                        mediaType: selectedMediaType,
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
        // Einstellungen modal — eigener NavigationStack, Bottom-Zone auf 0
        // gesetzt (kein Mini-Player im Sheet → keine Freiraum-Reservierung nötig).
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(coordinator: playerCoordinator, libraryViewModel: viewModel, onLogout: onLogout)
            }
            .environment(\.bottomBarInset, 0)
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

    // MARK: - Bottom-Zone (scroll-gesteuert einklappbar)

    /// Aufgeklappt: Banner · Mini-Player (voll) · [Medien-Pille | Lupe].
    /// Kompakt: eine Zeile [Home-Button · Mini-Player mittig, kleiner · Lupe].
    /// Player und Lupe gleiten per matchedGeometry; die Medien-Pille morpht in
    /// den Home-Button.
    @ViewBuilder
    private var bottomBarContent: some View {
        if barCollapsed {
            // Eine Zeile: Home links, Mini-Player mittig (unverändert, nur ohne
            // AirPlay), Lupe rechts — enger Abstand.
            HStack(spacing: 8) {
                homeButton
                miniPlayer
                searchButton
            }
        } else {
            VStack(spacing: 8) {
                banner
                miniPlayer
                HStack(spacing: 10) {
                    mediaBar
                    Spacer(minLength: 0)
                    searchButton
                }
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let vm = playerCoordinator.viewModel, vm.sourceHint != nil {
            ResumeMessageBanner(viewModel: vm)
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if let vm = playerCoordinator.viewModel, let item = playerCoordinator.activeItem {
            MiniPlayerBar(coordinator: playerCoordinator, viewModel: vm, item: item, compact: barCollapsed) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                    isShowingFullPlayer = true
                }
            }
            .offset(y: miniPlayerSwapOffset)
            .matchedGeometryEffect(id: "player", in: barNS)
        }
    }

    @ViewBuilder
    private var mediaBar: some View {
        if availableMediaTypes.count > 1 {
            MediaTabBar(types: availableMediaTypes, selected: selectedMediaType) { newValue in
                navigationPath = NavigationPath()
                bottomBar.reset()   // Tab-Wechsel klappt die Leiste auf
                withAnimation(.snappy(duration: 0.2)) { selectedMediaType = newValue }
            }
            .matchedGeometryEffect(id: "media", in: barNS)
        }
    }

    /// Kompakter „Home"-Button (aus der Medien-Pille gemorpht) — klappt die
    /// Leiste wieder auf (bis zum nächsten Scroll).
    private var homeButton: some View {
        Button {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
                bottomBar.expand()
            }
        } label: {
            Image(systemName: "house.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(AdaptiveGlassBackground(shape: Circle()))
        .matchedGeometryEffect(id: "media", in: barNS)
    }

    private var searchButton: some View {
        FloatingSearchButton {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { isShowingSearch = true }
        }
        .matchedGeometryEffect(id: "search", in: barNS)
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
                        continueFeaturedSection
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
            // Freiraum als INNEN-Abstand: die ScrollView bleibt vollflächig,
            // Inhalt scrollt weiter hinter dem Glas durch, ruht aber über der
            // Bottom-Zone (kein schwarzer Bereich hinter dem Mini-Player).
            .bottomBarClearance()
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
        .reportsBottomBarScroll()   // Scroll → Bottom-Zone ein-/ausklappen
    }

    // MARK: „Fortsetzen" (große Karten, wie im Podcast-Tab)

    private var continueFeaturedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue").font(.title2).bold().padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(viewModel.continueListening) { entry in
                        BookFeaturedCard(entry: entry,
                                         playerCoordinator: playerCoordinator,
                                         libraryViewModel: viewModel)
                    }
                }
                .padding(.horizontal)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
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
                        // Wertbasiert, damit ein navigationPath-Reset (Medien-Tab)
                        // auch aus dieser Reihe bis zur Wurzel zurückpoppt.
                        NavigationLink(value: entry.id) {
                            VStack(alignment: .leading, spacing: 6) {
                                BookCoverView(
                                    url: AppSession.shared.coverURL(forItemId: entry.id),
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
                            coverURL: { AppSession.shared.coverURL(forItemId: $0) }
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
            if let item = item(forId: itemId) {
                await playerCoordinator.open(item: item)
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
              let item = item(forId: lastId) else { return }
        await playerCoordinator.open(item: item)
    }

    /// Item zu einer ID quellenübergreifend (Hörbuch-Liste ODER Podcast-
    /// Provider) — für Weiterhören/Quick-Action/Siri.
    private func item(forId id: String) -> LibraryItem? {
        viewModel.entries.first(where: { $0.id == id })?.item
            ?? AppSession.shared.libraryItem(forId: id)
    }

    /// Registers the dynamic home-screen quick action with the current
    /// book's title as subtitle (or removes it without a last book).
    private func updateQuickActions() {
        guard let lastId = UserDefaults.standard.string(forKey: AppStorageKeys.lastPlayedItemId),
              let lastItem = item(forId: lastId) else {
            UIApplication.shared.shortcutItems = []
            return
        }
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: ResumeRequest.quickActionType,
                localizedTitle: String(localized: "Continue Listening"),
                localizedSubtitle: lastItem.title,
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
        Button {
            showSettings = true
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
