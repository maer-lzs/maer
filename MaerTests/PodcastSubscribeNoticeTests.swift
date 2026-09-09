// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Produkt-Entscheid 09.09.2026: ein Feed, der als gueltige Sendung ohne
/// Folgen parst, SAGT es beim Abonnieren. Das Abo entsteht trotzdem.
///
/// Die Regel ist pur, weil sie drei Tatsachen abwaegt, von denen keine einer
/// Ansicht gehoert — und weil es DREI Abo-Wege gibt (Einstellungsseite,
/// Karten/Sendungsseite, Katalogseite), die heute schon nicht dasselbe tun.
/// Die Meldung entsteht deshalb in der Ablage und wird an EINER Stelle
/// gezeigt.
struct PodcastSubscribeNoticeTests {
    @Test("Nur das erste eigene Abonnieren eines folgenlosen Feeds sagt etwas")
    func onlyAFirstOwnSubscribeOfAnEmptyFeedSpeaks() {
        #expect(PodcastSubscribeNotice.shouldTell(episodeCount: 0, isUserAction: true,
                                                  isFirstSubscribe: true))
        // Mit Folgen gibt es nichts zu sagen.
        #expect(!PodcastSubscribeNotice.shouldTell(episodeCount: 1, isUserAction: true,
                                                   isFirstSubscribe: true))
        // Aus dem Konto oder von gpodder: niemandes Tipp, also keine Meldung
        // aus dem Nichts.
        #expect(!PodcastSubscribeNotice.shouldTell(episodeCount: 0, isUserAction: false,
                                                   isFirstSubscribe: true))
        // Wieder-Abonnieren VEREINIGT mit dem Zwischenspeicher, ein duenner
        // zweiter Parse verliert also nichts und ist keine Meldung wert.
        #expect(!PodcastSubscribeNotice.shouldTell(episodeCount: 0, isUserAction: true,
                                                   isFirstSubscribe: false))
    }

    /// Die Meldung existiert EINMAL. Wer eine zweite Darstellung baut, muss
    /// diesen Bestand anfassen — genau das war the reviewer's Auflage („bau die Meldung
    /// einmal statt dreimal"), und ein Bestand haelt sie, eine Absicht nicht.
    @Test("Es gibt genau einen Wirt fuer die Meldung")
    func exactlyOneHostShowsIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        var readers: [String: Int] = [:]
        var setters: [String: Int] = [:]
        for case let name as String in walker where name.hasSuffix(".swift") {
            let lines = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            // Die DEKLARATION ist weder Lesen noch Setzen. Mein erster
            // Detektor zaehlte sie als Lesen und machte den Fall rot: eine
            // Zeile, die es gibt, weil es die Sache gibt, ist kein Zugriff.
            let hits = lines.filter {
                $0.contains("emptyFeedNotice") && !$0.contains("var emptyFeedNotice")
            }
            guard !hits.isEmpty else { continue }
            // Die Zuweisung `= …` ist das Setzen, alles andere liest.
            let written = hits.filter { $0.contains("emptyFeedNotice = ") && !$0.contains("== nil") }
            if !written.isEmpty { setters["Sources/" + name] = written.count }
            let read = hits.count - written.count
            if read > 0 { readers["Sources/" + name] = read }
        }
        #expect(Set(readers.keys) == ["Sources/Views/Podcasts/PodcastSubscribeNoticeHost.swift"],
                "die Meldung wird an mehr als einer Stelle gezeigt: \(readers.keys.sorted())")
        // Gesetzt wird sie in der Ablage (dort entsteht sie) und im Wirt
        // zurueckgesetzt, wenn der Mensch sie weggeklickt hat.
        #expect(Set(setters.keys) == ["Sources/Providers/PodcastSubscriptions.swift",
                                      "Sources/Views/Podcasts/PodcastSubscribeNoticeHost.swift"],
                "die Meldung entsteht woanders als in der Ablage: \(setters.keys.sorted())")
    }

    /// Der Satz steht im Katalog, mit deutscher Uebersetzung. Ohne diesen Fall
    /// faellt eine fehlende Uebersetzung erst am Geraet auf, und dort steht
    /// dann Englisch in einer deutschen App.
    @Test("Der Satz ist uebersetzt")
    func theSentenceIsTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = json?["strings"] as? [String: Any]
        let entry = strings?["Subscribed. This feed has no episodes yet."] as? [String: Any]
        let de = ((entry?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"]
            as? [String: Any]
        #expect(de?["state"] as? String == "translated")
        #expect((de?["value"] as? String)?.isEmpty == false)
        // Keine Gedankenstriche im Nutzertext, wie ueberall.
        #expect((de?["value"] as? String)?.contains("—") == false)
    }
}
#endif
