// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// „Ist das geladen?" is TWO questions under one name:
///
/// - `isDownloaded` is called download and answers OFFLINE AVAILABILITY.
///   An imported local file is available offline and was never
///   downloaded (`LocalProvider` can `.alwaysLocal`).
/// - `isDeletableDownload` answers whether WE fetched something whose
///   deletion frees space.
///
/// Seven delete gates asked the first and meant the second. For an
/// imported local audiobook, „Download loeschen" thus appeared in the menu,
/// the tap removed a `Downloads/` directory that never existed, the
/// entry stayed, the button stayed, and nothing was said.
@MainActor
struct DeletableDownloadTests {
    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The case on BEHAVIOR, without a stand-in: a `local:` id leads
    /// through `AppSession.provider(for:)` to the `LocalProvider`, and that carries
    /// `.alwaysLocal`. None of it is staged.
    @Test("A local file is available offline, but not a deletable download")
    func localFileIsAvailableButNotADownload() {
        let id = "local:probe-nicht-geladen"
        #expect(DownloadManager.shared.isDownloaded(itemId: id),
                "eine lokale Datei muss offline verfuegbar sein")
        #expect(!DownloadManager.shared.isDeletableDownload(itemId: id),
                "eine lokale Datei wurde nie geladen, ihr Loeschen gibt nichts frei")
    }

    /// The counter-check, so the case above is not green because the second
    /// question always answers false: an id without a local source is
    /// neither available nor deletable, and both say the same.
    @Test("Without a local source both questions say the same")
    func withoutALocalSourceBothAgree() {
        let id = "sub:song:gibt-es-nicht"
        #expect(!DownloadManager.shared.isDownloaded(itemId: id))
        #expect(!DownloadManager.shared.isDeletableDownload(itemId: id))
    }

    /// Every place that deletes a download names its gate. The inventory
    /// lists each file WITH a reason, so a new delete place has to
    /// answer the question instead of taking the nearest one.
    @Test("Every delete place names what it asks first", .needsTheSources)
    func everyDeleteSiteNamesItsGate() throws {
        let expected: [String: (count: Int, reason: String)] = [
            "Sources/Views/BookGridComponents.swift":
                (1, "Kontextmenue der Buchkachel, Tor isDeletableDownload. HIER war der Fund: "
                    + "ein importiertes lokales Hoerbuch bekam den Loeschen-Eintrag"),
            "Sources/Views/BookDetailScreen.swift":
                (1, "Papierkorb der Detailseite, Tor isDeletableDownload. Zweite erreichbare "
                    + "Stelle desselben Fundes"),
            "Sources/Views/Music/MusicAlbumView.swift":
                (1, "Download-Eintraege im Menue der Seite, am Cover und an jeder Titelzeile, "
                    + "Tor isDeletableDownload. Heute unerreichbar (keine lokale Quelle bedient Musik), "
                    + "umgestellt weil der Name die Klasse ist"),
            "Sources/Views/Music/MusicView.swift":
                (1, "Titelmenue, Tor isDeletableDownload, ebenfalls heute unerreichbar"),
            "Sources/Views/Podcasts/PodcastComponents.swift":
                (1, "Folgenzeile, Tor isDeletableDownload, heute unerreichbar"),
            "Sources/Views/Podcasts/PodcastHelpers.swift":
                (3, "Folgenmenue mit Tor isDeletableDownload, der Auto-Download-Fegelauf und das "
                    + "Raeumen ueber der Anzahl, die beide NICHT von einem Knopf kommen: ihre Listen "
                    + "stammen aus PodcastAutoDownloadRules.expired und .hold, also entscheidet die "
                    + "Regel und kein Tor, und beide fassen nur eigene Downloads an"),
            "Sources/Views/SettingsView.swift":
                (1, "Loeschen je Sorte in den Einstellungen. Fragt gar kein Tor, sondern zaehlt "
                    + "downloadedItemIds selbst auf, also die richtige Menge: lokale Dateien "
                    + "stehen dort nie drin"),
            "Sources/Networking/DownloadManager.swift":
                (5, "die Fassungen fuer einen und fuer viele, deleteDownload ueber deleteDownloads, "
                    + "und deleteAllDownloads, das ueber downloadedItemIds laeuft und damit per Bau "
                    + "nur echte Downloads trifft; dazu clearOldRemnants, das nur Ordner ohne Marke "
                    + "trifft und vorher remnantClears fragt (Marken gelesen, nichts laeuft, sieben Tage)"),
        ]
        var found: [String: Int] = [:]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.lastPathComponent.hasSuffix(".swift") {
            let path = SourceTree.relativePath(of: url)
            let count = try sourceText(path)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .filter { $0.contains("deleteDownload(itemId:") || $0.contains("deleteDownloads(") }
                .count
            if count > 0 { found[path] = count }
        }
        #expect(found == expected.mapValues(\.count),
                "neue, verschwundene oder verschobene Loesch-Stelle")
    }

    /// And the reverse of the finding: no delete gate asks for
    /// availability any more. What is counted is the gate's LINE directly before a
    /// destructive button, not the file. A file may ask both questions,
    /// they just stand in different places.
    @Test("No delete gate asks for availability any more", .needsTheSources)
    func noDeleteGateAsksAvailability() throws {
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.lastPathComponent.hasSuffix(".swift") {
            let path = SourceTree.relativePath(of: url)
            let lines = try sourceText(path)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            for (index, line) in lines.enumerated()
            where line.contains("isDownloaded(itemId:") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                // „destruktiv" is the mark that makes the delete path unambiguous:
                // the button carries it, a display never. Two lines,
                // because only the bracket stands between gate and mark.
                let window = lines[index..<min(index + 3, lines.count)].joined(separator: " ")
                if window.contains("role: .destructive") { offenders.append("\(path):\(index + 1)") }
            }
        }
        #expect(offenders.isEmpty,
                "Loesch-Tor fragt die Verfuegbarkeit statt isDeletableDownload: \(offenders)")
    }
}
#endif
