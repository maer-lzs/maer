import SwiftUI

/// Gemeinsame Bausteine für Buch-Grids: Zelle, Haptic-Touch-Menü und die
/// Autoren-/Genre-Browsing-Screens. Aus `LibraryView` extrahiert, damit die
/// Browse-Grids exakt dieselbe Optik und dasselbe Menü bekommen.

/// Statuszeile unter dem Cover ("Abgeschlossen" / "noch x Std." / "x % gehört").
@MainActor
func bookStatusText(_ p: BookProgress, duration: Double?) -> String {
    if p.isFinished { return String(localized: "Completed") }
    if p.isStarted {
        if let t = p.remainingText(bookDuration: duration) { return t }
        return String(localized: "\(p.fraction.formatted(.percent.precision(.fractionLength(0)))) listened")
    }
    return ""
}

// MARK: - Kontextmenü (Haptic Touch)

/// Menüeinträge: Abspielen, Download-Steuerung passend zur Phase, Gehört-Status.
struct BookContextMenuItems: View {
    let entry: LibraryEntry
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    var body: some View {
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
            // entry — pause/resume/cancel work from the library too.
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
                    Task { await quickDownload() }
                } label: {
                    Label("Save for Offline", systemImage: "arrow.down.circle")
                }
            }
        }

        Button {
            Task { await quickToggleFinished() }
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
    private func quickDownload() async {
        guard let detail = try? await playerCoordinator.apiClient.fetchItemDetail(itemId: entry.id) else { return }
        await DownloadManager.shared.download(item: detail, apiClient: playerCoordinator.apiClient)
    }

    /// Wie in BookDetailScreen: immer den vollständigen Datensatz
    /// (currentTime + duration + isFinished) schicken, nie nur das Flag
    /// allein — sonst geht der reale Fortschritt verloren (siehe Sync-Bugfix).
    private func quickToggleFinished() async {
        let apiClient = playerCoordinator.apiClient
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
        await libraryViewModel.refreshProgress()
    }
}

/// Lifted force-press preview on our adaptive glass instead of the plain
/// system platter, so it matches the rest of the chrome. Deliberately
/// NEUTRAL glass: the shared accent belongs to the PLAYING book, not the
/// pressed one.
struct BookContextPreview: View {
    let entry: LibraryEntry
    let apiClient: APIClient

    var body: some View {
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
                Text(bookStatusText(p, duration: entry.item.media?.duration))
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
}

/// Hängt Menü + Glas-Preview an eine beliebige Buchzelle.
struct BookCellContextMenu: ViewModifier {
    let entry: LibraryEntry
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    func body(content: Content) -> some View {
        content.contextMenu {
            BookContextMenuItems(
                entry: entry,
                playerCoordinator: playerCoordinator,
                libraryViewModel: libraryViewModel
            )
        } preview: {
            BookContextPreview(entry: entry, apiClient: playerCoordinator.apiClient)
        }
    }
}

// MARK: - Grid-Zelle

/// Eine Buchzelle (Cover + Titel + Autor + Status) inkl. Navigation zur
/// Detailseite und Haptic-Touch-Menü — identisch in Bibliothek und Browse.
struct BookGridCell: View {
    let entry: LibraryEntry
    let width: CGFloat
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    var body: some View {
        NavigationLink {
            BookDetailScreen(entry: entry, coordinator: playerCoordinator, libraryViewModel: libraryViewModel)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                BookCoverView(
                    url: playerCoordinator.apiClient.coverURL(forItemId: entry.id),
                    progress: entry.progress,
                    itemId: entry.id,
                    size: width
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
                    Text(bookStatusText(p, duration: entry.item.media?.duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: width, alignment: .leading)
            // Top-align within the grid row: LazyVGrid sizes each row to its
            // tallest cell and CENTERS shorter ones — covers of cells with
            // less text would sit visibly lower than their neighbours.
            .frame(maxHeight: .infinity, alignment: .top)
            // VoiceOver: one stop per book (title, author, status together)
            // instead of stepping through cover, texts, and badges separately.
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .modifier(BookCellContextMenu(
            entry: entry,
            playerCoordinator: playerCoordinator,
            libraryViewModel: libraryViewModel
        ))
    }
}

// MARK: - Browse-Grid

/// Cover-Grid einer Gruppe — misst seine Breite selbst und nutzt dieselbe
/// Spalten-Mathematik wie die Bibliothek (siehe LibraryView-Kommentar).
struct BrowseBooksScreen: View {
    let title: String
    let entries: [LibraryEntry]
    let playerCoordinator: PlayerCoordinator
    let libraryViewModel: LibraryViewModel

    @State private var measuredWidth: CGFloat = 0

    private let minColumnWidth: CGFloat = 108
    private let gridSpacing: CGFloat = 16
    private let horizontalPadding: CGFloat = 16

    private var columnCount: Int {
        guard measuredWidth > 0 else { return 3 }
        let available = measuredWidth - horizontalPadding * 2
        return max(Int((available + gridSpacing) / (minColumnWidth + gridSpacing)), 1)
    }

    private var cellWidth: CGFloat {
        guard measuredWidth > 0 else { return 132 }
        let available = measuredWidth - horizontalPadding * 2
        let totalSpacing = gridSpacing * CGFloat(columnCount - 1)
        return (available - totalSpacing) / CGFloat(columnCount)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount),
                alignment: .leading,
                spacing: 20
            ) {
                ForEach(entries) { entry in
                    BookGridCell(
                        entry: entry,
                        width: cellWidth,
                        playerCoordinator: playerCoordinator,
                        libraryViewModel: libraryViewModel
                    )
                }
            }
            .padding(.horizontal)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { measuredWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newWidth in
                        measuredWidth = newWidth
                    }
            }
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
