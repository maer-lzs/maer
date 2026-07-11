import CarPlay
import UIKit

/// CarPlay-Szene: drei Tabs (Weiter hören / Heruntergeladen / Bibliothek) als
/// Listen, Auswahl startet die Wiedergabe über den GEMEINSAMEN
/// PlayerCoordinator (AppSession) und zeigt den Now-Playing-Screen — dessen
/// Inhalt/Buttons kommen automatisch aus MPNowPlayingInfoCenter/RemoteCommands,
/// die für den Lockscreen längst verdrahtet sind.
///
/// Funktioniert auch beim KALTSTART im Auto (Telefon in der Tasche): die
/// Bibliothek lädt hier selbst (fällt offline auf den Disk-Cache zurück).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        Task { await self.setupTemplates() }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    private func setupTemplates() async {
        let session = AppSession.shared
        if session.libraryViewModel.entries.isEmpty {
            await session.libraryViewModel.loadLibrary()
        }

        let continueTab = await listTemplate(
            title: String(localized: "Continue Listening"),
            systemImage: "play.circle",
            entries: session.libraryViewModel.continueListening
        )
        let downloadedTab = await listTemplate(
            title: String(localized: "Downloaded"),
            systemImage: "arrow.down.circle",
            entries: session.libraryViewModel.downloadedEntries
        )
        let libraryTab = await listTemplate(
            title: String(localized: "Library"),
            systemImage: "books.vertical",
            entries: session.libraryViewModel.sortedFilteredEntries
        )

        let tabBar = CPTabBarTemplate(templates: [continueTab, downloadedTab, libraryTab])
        interfaceController?.setRootTemplate(tabBar, animated: true, completion: nil)
    }

    /// Baut eine Buchliste; Cover kommen aus der Thumbnail-Stufe des
    /// ImageCache (bereits klein dekodiert — fürs Auto genau richtig).
    private func listTemplate(title: String, systemImage: String, entries: [LibraryEntry]) async -> CPListTemplate {
        // CarPlay-Listen sind hart limitiert; mehr als das zeigt das System
        // ohnehin nicht an, und jede Zeile kostet einen Thumbnail-Decode.
        let limited = entries.prefix(Int(CPListTemplate.maximumItemCount))
        var items: [CPListItem] = []
        for entry in limited {
            let coverURL = AppSession.shared.apiClient.coverURL(forItemId: entry.id)
            var image: UIImage?
            if let coverURL {
                image = await ImageCache.shared.thumbnail(for: coverURL)
            }
            let item = CPListItem(
                text: entry.item.title,
                detailText: entry.item.author,
                image: image
            )
            item.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    await AppSession.shared.playerCoordinator.open(item: entry.item)
                    self?.showNowPlaying()
                    completion()
                }
            }
            items.append(item)
        }
        let template = CPListTemplate(title: title, sections: [CPListSection(items: items)])
        template.tabImage = UIImage(systemName: systemImage)
        template.emptyViewTitleVariants = [String(localized: "No books here yet.")]
        return template
    }

    private func showNowPlaying() {
        guard let interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        // Nicht doppelt pushen, wenn Now Playing schon oben liegt.
        if interfaceController.topTemplate != nowPlaying {
            interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }
}
