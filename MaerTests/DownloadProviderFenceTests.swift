// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Ein Download bekommt den Anbieter DES TITELS, nie einen benannten.
///
/// Zwei Funde derselben Klasse an einem Tag, in zwei Tabs:
///
/// - `MusicAlbumView` gab beiden Album-Downloads fest den Subsonic-Anbieter
///   mit. Bei einer Jellyfin-Bibliothek war das der falsche Server.
/// - `PodcastComponents` gab zwei Folgen-Downloads fest den RSS-Anbieter mit
///   (Weiter-Karte und Download-Knopf). Eine ABS-Folge traegt eine
///   `abspod:`-Kennung, die RSS-Ablage ist ein exakter Index ueber ihre
///   eigenen Guids, findet sie also nicht — und die Wache dahinter kehrte
///   still zurueck. Der Knopf tat nichts und sagte nichts.
///
/// Beide Male stand die richtige Fassung in DERSELBEN Datei: `PodcastComponents`
/// fragt an einer dritten Stelle laengst `router.provider(item.id)`, und in
/// `MusicAlbumView` fragten fuenfzehn der achtzehn Griffe den eingestellten
/// Anbieter. Es war nie eine Meinung, es war ein Rest.
struct DownloadProviderFenceTests {
    private func codeOf(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Der Bestand ist NULL: kein Download nennt einen Anbieter beim Namen.
    /// Erlaubt ist, was aus dem Titel oder aus der laufenden Sitzung kommt
    /// (`router.provider(id)`, ein hergeleitetes `provider`, der Anbieter des
    /// Koordinators). Verboten ist jeder feste Name.
    @Test("Kein Download nennt einen Anbieter beim Namen", .needsTheSources)
    func noDownloadNamesAProvider() throws {
        let named = ["AppSession.shared.rssProvider", "AppSession.shared.absPodcastProvider",
                     "AppSession.shared.subsonicProvider", "AppSession.shared.jellyfinProvider",
                     "AppSession.shared.musicProvider", "AppSession.shared.localProvider",
                     "SubsonicProvider.shared", "JellyfinProvider.shared",
                     "RSSProvider.shared", "ABSPodcastProvider.shared"]
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let path = SourceTree.relativePath(of: url)
            let flat = try codeOf(path)
            for range in flat.ranges(of: "download(item:") {
                // Das Argument reicht bis zur schliessenden Klammer des
                // Aufrufs; ein Fenster genuegt, weil provider: unmittelbar
                // folgt. LOKAL gefragt, nicht in der Nachbarschaft.
                let to = flat.index(range.upperBound, offsetBy: 160, limitedBy: flat.endIndex) ?? flat.endIndex
                let window = String(flat[range.upperBound..<to])
                guard let arg = window.range(of: "provider:") else { continue }
                let argEnd = window.index(arg.upperBound, offsetBy: 60, limitedBy: window.endIndex) ?? window.endIndex
                let argument = String(window[arg.upperBound..<argEnd])
                for needle in named where argument.contains(needle) {
                    offenders.append("\(path) → \(needle)")
                }
            }
        }
        #expect(offenders.isEmpty, "ein Download bekommt einen benannten Anbieter: \(offenders)")
    }

    /// „Detail holen, dann laden" ist EINE Handlung, und sie hat einen Ort.
    /// Sechs Flaechen schrieben die drei Schritte von Hand, und sie waren sich
    /// nicht einig: zwei fragten den Koordinator nach einem Anbieter, der fuer
    /// die Bibliothek antwortet und nicht fuer den Titel, und ALLE SECHS
    /// verschluckten einen fehlgeschlagenen Abruf mit `try?` und einem
    /// `return` — der Knopf tat nichts und sagte nichts, waehrend die
    /// automatische Schleife nebenan den Fehler faengt und meldet.
    ///
    /// Wer den Lader jetzt noch direkt ruft, HAELT das Detail bereits: er
    /// handelt auf eine Entscheidung hin, die schon gefallen ist.
    @Test("Wer aus einer Kennung laedt, nimmt die eine Handlung", .needsTheSources)
    func startingFromAnIdUsesTheOneAction() throws {
        let holdsTheDetail: [String: String] = [
            "Sources/ViewModels/PlayerViewModel.swift":
                "Selbstheilung und Spur-Reparatur: das Item liegt vor, es wird nichts geholt",
            "Sources/Views/BookDetailScreen.swift":
                "die Seite hat ihr Detail geladen und reicht den Anbieter weiter, DER es geladen hat",
            "Sources/Views/Music/MusicAlbumView.swift":
                "zweimal: die Album-Seite haelt ihr Detail, der Anbieter kommt aus der Kennung",
            "Sources/Views/Podcasts/PodcastHelpers.swift":
                "die Auto-Download-Schleife: eine Massenhandlung mit eigener Fehlermeldung je Folge",
        ]
        // `DownloadManager` steht NICHT in der Liste: sein eigener Ruf in
        // `startDownload` hat keinen Empfaenger („download(item:" ohne Punkt)
        // und faellt dem Sucher deshalb gar nicht auf. Das ist richtig so, und
        // es hier hinzuschreiben ist billiger, als den Sucher ungenauer zu
        // machen.
        var callers: Set<String> = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let path = SourceTree.relativePath(of: url)
            let code = try codeOf(path)
            // Die Fassung selbst ist kein Rufer.
            let calls = code.replacingOccurrences(of: "func download(item:", with: "func download(DECL:")
            if calls.contains(".download(item:") { callers.insert(path) }
        }
        #expect(callers == Set(holdsTheDetail.keys),
                "jemand laedt aus einer Kennung, ohne die eine Handlung zu nehmen: \(callers.symmetricDifference(Set(holdsTheDetail.keys)).sorted())")
    }

    /// Und die Haelfte, die dem Menschen gehoert: ein fehlgeschlagener Abruf
    /// wird GEMELDET. Die Rot-Probe deckte auf, dass mein erster Zaun das gar
    /// nicht prueft — ich haette den `catch` leeren koennen und alles waere
    /// gruen geblieben, also haette der Zaun genau den Fehler durchgelassen,
    /// gegen den die Handlung gebaut ist.
    @Test("Die eine Handlung meldet einen fehlgeschlagenen Abruf", .needsTheSources)
    func theOneActionReportsAFailedFetch() throws {
        let code = try codeOf("Sources/Networking/DownloadManager.swift")
        guard let action = code.range(of: "func startDownload(itemId: String, kind: DownloadKind) async") else {
            Issue.record("die Handlung wurde umbenannt"); return
        }
        let to = code.index(action.lowerBound, offsetBy: 700, limitedBy: code.endIndex) ?? code.endIndex
        let body = String(code[action.lowerBound..<to])
        #expect(body.contains("} catch {"), "der Abruf faengt nichts mehr")
        #expect(body.contains("phase[itemId] = .failed("),
                "ein fehlgeschlagener Abruf sagt nichts mehr: der Knopf taete wieder nichts")
        #expect(body.contains("Logger."), "der Fehlschlag hinterlaesst keine Spur im Geraete-Log")
    }

    /// Gegenprobe, damit der Bestand oben nicht deshalb leer ist, weil es
    /// keine Downloads mehr gibt: es sind weiterhin die dreizehn Aufrufe, und
    /// die Tuer, die den Anbieter aus der Kennung holt, existiert.
    @Test("Es gibt die Download-Stellen noch, und die Tuer auch", .needsTheSources)
    func theCallSitesAndTheDoorStillExist() throws {
        var sites = 0
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            sites += try codeOf(SourceTree.relativePath(of: url)).ranges(of: "download(item:").count
        }
        // Waren dreizehn, bevor „Detail holen, dann laden" eine Handlung
        // wurde; sechs davon sind in `startDownload` zusammengefallen. Die
        // Zahl steht hier als Boden gegen das Verschwinden, nicht als Ziel.
        #expect(sites >= 8, "die Download-Aufrufe sind verschwunden, der Bestand oben prueft nichts")
        #expect(try codeOf("Sources/Views/ItemRouterEnvironment.swift").contains("var provider:"),
                "der Router beantwortet die Anbieter-Frage nicht mehr")
    }
}
#endif
