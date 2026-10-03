// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// „Ist das geladen?" sind ZWEI Fragen mit einem Namen:
///
/// - `isDownloaded` heisst Download und beantwortet OFFLINE-VERFUEGBARKEIT.
///   Eine importierte lokale Datei ist offline verfuegbar und wurde nie
///   geladen (`LocalProvider` kann `.alwaysLocal`).
/// - `isDeletableDownload` beantwortet, ob WIR etwas geholt haben, dessen
///   Loeschen Platz freigibt.
///
/// Sieben Loesch-Tore fragten die erste und meinten die zweite. Bei einem
/// importierten lokalen Hoerbuch stand damit „Download loeschen" im Menue,
/// der Tipp entfernte ein `Downloads/`-Verzeichnis, das es nie gab, der
/// Eintrag blieb, der Knopf blieb, und gesagt wurde nichts.
@MainActor
struct DeletableDownloadTests {
    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// Der Fall am VERHALTEN, ohne Attrappe: eine `local:`-Kennung fuehrt
    /// ueber `AppSession.provider(for:)` zum `LocalProvider`, und der traegt
    /// `.alwaysLocal`. Nichts davon ist gestellt.
    @Test("Eine lokale Datei ist offline verfuegbar, aber kein loeschbarer Download")
    func localFileIsAvailableButNotADownload() {
        let id = "local:probe-nicht-geladen"
        #expect(DownloadManager.shared.isDownloaded(itemId: id),
                "eine lokale Datei muss offline verfuegbar sein")
        #expect(!DownloadManager.shared.isDeletableDownload(itemId: id),
                "eine lokale Datei wurde nie geladen, ihr Loeschen gibt nichts frei")
    }

    /// Die Gegenprobe, damit der Fall oben nicht gruen ist, weil die zweite
    /// Frage immer falsch antwortet: eine Kennung ohne lokale Quelle ist
    /// weder verfuegbar noch loeschbar, und beide sagen dasselbe.
    @Test("Ohne lokale Quelle sagen beide Fragen dasselbe")
    func withoutALocalSourceBothAgree() {
        let id = "sub:song:gibt-es-nicht"
        #expect(!DownloadManager.shared.isDownloaded(itemId: id))
        #expect(!DownloadManager.shared.isDeletableDownload(itemId: id))
    }

    /// Jede Stelle, die einen Download loescht, nennt ihr Tor. Der Bestand
    /// steht je Datei MIT Grund, damit eine neue Loesch-Stelle die Frage
    /// beantworten muss, statt die naechstliegende zu nehmen.
    @Test("Jede Loesch-Stelle nennt, was sie vorher fragt")
    func everyDeleteSiteNamesItsGate() throws {
        let expected: [String: (count: Int, reason: String)] = [
            "Sources/Views/BookGridComponents.swift":
                (1, "Kontextmenue der Buchkachel, Tor isDeletableDownload. HIER war der Fund: "
                    + "ein importiertes lokales Hoerbuch bekam den Loeschen-Eintrag"),
            "Sources/Views/BookDetailScreen.swift":
                (1, "Papierkorb der Detailseite, Tor isDeletableDownload. Zweite erreichbare "
                    + "Stelle desselben Fundes"),
            "Sources/Views/Music/MusicAlbumView.swift":
                (2, "Titelmenue, Tor isDeletableDownload; der Album-Knopf loescht seit F9 "
                    + "beim Tippen nicht mehr. Heute unerreichbar (keine lokale Quelle bedient Musik), "
                    + "umgestellt weil der Name die Klasse ist. Dazu die VoiceOver-Handlung "
                    + "des fertigen Leisten-Symbols, im Zweig desselben Tors (F9-Form)"),
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
                (4, "die Fassungen fuer einen und fuer viele, deleteDownload ueber deleteDownloads, "
                    + "und deleteAllDownloads, das ueber downloadedItemIds laeuft und damit per Bau "
                    + "nur echte Downloads trifft"),
        ]
        var found: [String: Int] = [:]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        for case let name as String in walker where name.hasSuffix(".swift") {
            let count = try sourceText("Sources/" + name)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .filter { $0.contains("deleteDownload(itemId:") || $0.contains("deleteDownloads(") }
                .count
            if count > 0 { found["Sources/" + name] = count }
        }
        #expect(found == expected.mapValues(\.count),
                "neue, verschwundene oder verschobene Loesch-Stelle")
    }

    /// Und die Umkehrung des Fundes: kein Loesch-Tor fragt mehr die
    /// Verfuegbarkeit. Gezaehlt wird die ZEILE des Tors direkt vor einem
    /// destruktiven Knopf, nicht die Datei — eine Datei darf beide Fragen
    /// stellen, sie stehen nur an verschiedenen Stellen.
    @Test("Kein Loesch-Tor fragt mehr die Verfuegbarkeit")
    func noDeleteGateAsksAvailability() throws {
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        for case let name as String in walker where name.hasSuffix(".swift") {
            let lines = try sourceText("Sources/" + name)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            for (index, line) in lines.enumerated()
            where line.contains("isDownloaded(itemId:") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                // „destruktiv" ist die Marke, die den Loesch-Weg eindeutig
                // macht: der Knopf traegt sie, eine Anzeige nie. Zwei Zeilen,
                // weil zwischen Tor und Marke nur die Klammer steht.
                let window = lines[index..<min(index + 3, lines.count)].joined(separator: " ")
                if window.contains("role: .destructive") { offenders.append("Sources/\(name):\(index + 1)") }
            }
        }
        #expect(offenders.isEmpty,
                "Loesch-Tor fragt die Verfuegbarkeit statt isDeletableDownload: \(offenders)")
    }
}
#endif
