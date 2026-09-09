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
    @Test("Kein Download nennt einen Anbieter beim Namen")
    func noDownloadNamesAProvider() throws {
        let named = ["AppSession.shared.rssProvider", "AppSession.shared.absPodcastProvider",
                     "AppSession.shared.subsonicProvider", "AppSession.shared.jellyfinProvider",
                     "AppSession.shared.musicProvider", "AppSession.shared.localProvider",
                     "SubsonicProvider.shared", "JellyfinProvider.shared",
                     "RSSProvider.shared", "ABSPodcastProvider.shared"]
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        for case let name as String in walker where name.hasSuffix(".swift") {
            let flat = try codeOf("Sources/" + name)
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
                    offenders.append("Sources/\(name) → \(needle)")
                }
            }
        }
        #expect(offenders.isEmpty, "ein Download bekommt einen benannten Anbieter: \(offenders)")
    }

    /// Gegenprobe, damit der Bestand oben nicht deshalb leer ist, weil es
    /// keine Downloads mehr gibt: es sind weiterhin die dreizehn Aufrufe, und
    /// die Tuer, die den Anbieter aus der Kennung holt, existiert.
    @Test("Es gibt die Download-Stellen noch, und die Tuer auch")
    func theCallSitesAndTheDoorStillExist() throws {
        var sites = 0
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        for case let name as String in walker where name.hasSuffix(".swift") {
            sites += try codeOf("Sources/" + name).ranges(of: "download(item:").count
        }
        // Dreizehn Rufer plus die Fassung selbst.
        #expect(sites >= 13, "die Download-Aufrufe sind verschwunden, der Bestand oben prueft nichts")
        #expect(try codeOf("Sources/Views/ItemRouterEnvironment.swift").contains("var provider:"),
                "der Router beantwortet die Anbieter-Frage nicht mehr")
    }
}
#endif
