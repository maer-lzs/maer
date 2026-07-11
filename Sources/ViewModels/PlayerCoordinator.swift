import Foundation
import Combine

/// Hält die aktuell laufende Wiedergabe-Session, unabhängig davon, ob der
/// volle Player-Screen gerade sichtbar ist oder nicht. Das ist die
/// Voraussetzung für die Mini-Player-Leiste: früher wurde der Player beim
/// Verlassen des Screens gestoppt, jetzt läuft er weiter, bis der Nutzer ihn
/// explizit schließt oder ein anderes Buch öffnet.
@MainActor
final class PlayerCoordinator: ObservableObject {
    @Published private(set) var viewModel: PlayerViewModel?
    @Published private(set) var activeItem: LibraryItem?
    @Published private(set) var isLoading = false
    @Published var loadError: String?

    let provider: any AudioProvider

    /// Set by the library screen (owner of the series data): returns the
    /// next unfinished book of the same series. Basis for the auto-play-
    /// next setting when a book finishes.
    var nextInSeriesProvider: ((String) -> LibraryItem?)?

    /// Merkt sich die zuletzt gehörte Item-ID über App-Neustarts hinweg, damit
    /// das Buch beim nächsten Start direkt im Mini-Player griffbereit ist.
    private let lastItemKey = AppStorageKeys.lastPlayedItemId

    init(provider: any AudioProvider) {
        self.provider = provider
    }

    /// Öffnet ein Buch. Ist es bereits aktiv, passiert nichts außer ggf. dem
    /// Fortsetzen der Wiedergabe. Ist ein anderes Buch aktiv, wird dessen
    /// Session sauber beendet (inkl. finalem Sync), bevor das neue geladen
    /// wird.
    /// - Parameter autoplay: true bei bewusstem Öffnen durch den Nutzer (startet
    ///   die Wiedergabe direkt nach dem Laden), false beim stillen
    ///   Wiederherstellen nach App-Start (bleibt pausiert).
    func open(item: LibraryItem, autoplay: Bool = true) async {
        if activeItem?.id == item.id, viewModel != nil {
            if autoplay { await viewModel?.playWithServerCheck() }
            return
        }

        viewModel?.stop()
        viewModel = nil
        activeItem = item
        loadError = nil
        isLoading = true
        defer { isLoading = false }

        // Quelle des Items bestimmen (Server vs. lokale Dateien) — der
        // injizierte `provider` ist die Standardquelle, lokale Items werden
        // umgeleitet.
        let itemProvider = AppSession.shared.provider(for: item.id)
        do {
            let detail = try await itemProvider.fetchItemDetail(itemId: item.id)
            let newViewModel = PlayerViewModel(provider: itemProvider)
            await newViewModel.load(item: detail)
            attachBookEndHandler(to: newViewModel)
            viewModel = newViewModel
            UserDefaults.standard.set(item.id, forKey: lastItemKey)
            if autoplay {
                await newViewModel.playWithServerCheck()
            }
        } catch {
            // Server nicht erreichbar (z. B. offline unterwegs) — falls das
            // Buch heruntergeladen ist, mit den beim Download mitgespeicherten
            // Buchdetails weitermachen, statt komplett zu scheitern. Ohne das
            // bräuchte selbst ein längst heruntergeladenes Buch noch eine
            // funktionierende Serververbindung nur zum Öffnen.
            if let cached = DownloadManager.shared.loadCachedDetail(forItemId: item.id) {
                let newViewModel = PlayerViewModel(provider: itemProvider)
                await newViewModel.load(item: cached, isOfflineFallback: true)
                attachBookEndHandler(to: newViewModel)
                viewModel = newViewModel
                UserDefaults.standard.set(item.id, forKey: lastItemKey)
                if autoplay {
                    await newViewModel.playWithServerCheck()
                }
            } else {
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                activeItem = nil
            }
        }
    }

    /// Auto-play next in series (settings toggle, default OFF): when a book
    /// plays to its end, open the next unfinished book of the same series.
    private func attachBookEndHandler(to viewModel: PlayerViewModel) {
        viewModel.onBookFinished = { [weak self] finishedItemId in
            guard let self,
                  UserDefaults.standard.bool(forKey: AppStorageKeys.autoPlayNextInSeries),
                  let next = self.nextInSeriesProvider?(finishedItemId) else { return }
            Task { await self.open(item: next) }
        }
    }

    /// Stellt beim App-Start die zuletzt gehörte Session wieder her — pausiert,
    /// damit nichts von selbst losspielt. Das Buch erscheint direkt im
    /// Mini-Player. Wird aus der Bibliothek aufgerufen, sobald die Liste da ist
    /// (damit wir das passende LibraryItem haben).
    func restoreLastSession(from entries: [LibraryEntry]) async {
        guard viewModel == nil, activeItem == nil else { return }
        guard let lastId = UserDefaults.standard.string(forKey: lastItemKey) else { return }
        // Zuletzt Gehörtes kann aus JEDER Quelle stammen — Podcast-Episoden
        // stehen NICHT in der Hörbuch-Liste, sondern nur beim RSS-Provider.
        guard let item = entries.first(where: { $0.id == lastId })?.item
            ?? AppSession.shared.libraryItem(forId: lastId) else { return }
        await open(item: item, autoplay: false)
    }

    /// Beendet die Wiedergabe komplett (Mini-Leiste verschwindet).
    func close() {
        viewModel?.stop()
        viewModel = nil
        activeItem = nil
        loadError = nil
        UserDefaults.standard.removeObject(forKey: lastItemKey)
    }
}
