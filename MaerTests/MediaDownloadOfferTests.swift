// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// „Darf hier ueberhaupt geladen werden?" hatte keinen Platz, und der ganze
/// Baum fragte stattdessen „liegt es schon hier?". Das liest sich im Normalfall
/// gleich und in genau den Faellen anders, auf die es ankommt.
///
/// Der Ausloeser war eine Regression von mir: das Loesch-Tor lernte zu fragen,
/// ob WIR etwas geholt haben, und damit bot ein importiertes lokales Hoerbuch
/// nicht mehr „Download loeschen" an (richtig) sondern „Save for Offline"
/// (falsch, und mit dem Bibliotheks-Anbieter fuer eine Datei, die er nicht
/// kennt). Ein totes Angebot gegen ein sinnloses getauscht.
struct MediaDownloadOfferTests {
    @Test("Nur eine Quelle, die laden KANN, bekommt das Angebot")
    func onlyADownloadableSourceIsOffered() {
        #expect(MediaDownloadOffer.isPossible([.downloadable]))
        #expect(MediaDownloadOffer.isPossible([.progressSync, .downloadable, .bookmarks]))
        // Importierte lokale Dateien: liegen da, koennen nicht geladen werden.
        #expect(!MediaDownloadOffer.isPossible([.alwaysLocal]))
        // Freie Kataloge und Radio tragen gar keine.
        #expect(!MediaDownloadOffer.isPossible([]))
        #expect(!MediaDownloadOffer.isPossible([.remoteSearch]))
    }

    /// Die Anbieter selbst, damit die Wahrheitstafel oben nicht an
    /// erfundenen Mengen haengt: was der Baum wirklich fuehrt.
    @MainActor
    @Test("Die echten Anbieter antworten wie erwartet")
    func therealProvidersAnswerAsExpected() {
        #expect(!MediaDownloadOffer.isPossible(LocalProvider.shared.capabilities),
                "eine importierte Datei darf kein Download-Angebot bekommen")
        #expect(!MediaDownloadOffer.isPossible(FreeCatalogProvider.shared.capabilities))
        #expect(!MediaDownloadOffer.isPossible(RadioProvider.shared.capabilities))
        #expect(MediaDownloadOffer.isPossible(RSSProvider.shared.capabilities))
        #expect(MediaDownloadOffer.isPossible(SubsonicProvider.shared.capabilities))
        #expect(MediaDownloadOffer.isPossible(JellyfinProvider.shared.capabilities))
    }

    /// Der Bestand: jede Stelle, die einen Download ANBIETET, fragt vorher.
    /// Gezaehlt wird der Aufruf, der den Download startet; wer einen anbietet,
    /// ohne die Frage im selben Zweig zu stellen, faellt auf.
    @Test("Kein Download-Angebot ohne die Frage, ob es geht")
    func noOfferWithoutTheQuestion() throws {
        // Diese vier starten einen Download, OHNE ihn anzubieten: sie handeln
        // auf eine Entscheidung hin, die schon gefallen ist.
        let actsWithoutOffering: [String: String] = [
            "Sources/ViewModels/PlayerViewModel.swift":
                "Selbstheilung: fragt `.downloadable` selbst, direkt daneben, und bietet nichts an",
            "Sources/Views/BookDetailScreen.swift":
                "der Knopf steht im Download-Abschnitt der Detailseite und wird ueber "
                + "`reallyStartDownload` gerufen; das Angebot entscheidet der Abschnitt",
            "Sources/Views/BookFeaturedCard.swift":
                "CardDownloadBadge zeigt die Ecke; sie fragt isDownloaded, und fuer eine "
                + "lokale Datei ist das richtig (liegt offline vor), also kein Angebot",
            "Sources/Views/Podcasts/PodcastComponents.swift":
                "dieselbe Karten-Ecke, plus die zwei Zweige, die die Frage stellen",
        ]
        var offersWithoutAsking: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        for case let name as String in walker where name.hasSuffix(".swift") {
            let relative = "Sources/" + name
            let code = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            guard code.contains(".download(item:") else { continue }
            if code.contains("MediaDownloadOffer.isPossible") { continue }
            if actsWithoutOffering[relative] != nil { continue }
            offersWithoutAsking.append(relative)
        }
        #expect(offersWithoutAsking.isEmpty,
                "startet einen Download, ohne zu fragen, ob die Quelle das kann: \(offersWithoutAsking)")
    }
}
#endif
