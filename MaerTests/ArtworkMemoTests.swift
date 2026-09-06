// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The one directory of remembered picture answers behind the door. The
/// two chains (feed channel picture, radio logo) used to keep their own
/// dictionaries with their own expiry rules; this pins the one rule: a
/// found answer stays until its expiry, a clean "none" counts until its
/// expiry and only under the stamp it was made under, and nothing outside
/// the door names the old keys any more.
struct ArtworkMemoTests {
    private func suite() -> (UserDefaults, String) {
        let name = "artwork-memo-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("gefunden bleibt bis zum Ablauf, ein Nein gilt bis zum Ablauf")
    func foundAndMissingExpire() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        Artwork.Memo.remember("feed|a", value: "https://a.example/cover.jpg", until: 1_000, now: 100, defaults: defaults)
        Artwork.Memo.remember("feed|b", value: nil, until: 500, now: 100, defaults: defaults)
        #expect(Artwork.Memo.remembered("feed|a", now: 200, defaults: defaults) == .found("https://a.example/cover.jpg"))
        #expect(Artwork.Memo.remembered("feed|b", now: 200, defaults: defaults) == .missing)
        #expect(Artwork.Memo.remembered("feed|b", now: 600, defaults: defaults) == nil, "ein abgelaufenes Nein ist offen")
        #expect(Artwork.Memo.remembered("feed|a", now: 2_000, defaults: defaults) == nil)
        #expect(Artwork.Memo.remembered("feed|unknown", now: 200, defaults: defaults) == nil)
    }

    @Test("ein Nein gilt nur unter seinem Stempel, ein Ja unter jedem")
    func negativesCarryTheirStamp() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        Artwork.Memo.remember("radio|no", value: nil, until: nil, under: "64-48", now: 100, defaults: defaults)
        Artwork.Memo.remember("radio|yes", value: "commons:A.svg", until: nil, under: "64-48", now: 100, defaults: defaults)
        #expect(Artwork.Memo.remembered("radio|no", under: "64-48", now: 200, defaults: defaults) == .missing)
        #expect(Artwork.Memo.remembered("radio|no", under: "96-48", now: 200, defaults: defaults) == nil, "andere Schwellen, das Nein wird neu gefragt")
        #expect(Artwork.Memo.remembered("radio|yes", under: "96-48", now: 200, defaults: defaults) == .found("commons:A.svg"))
        // A never-expiring entry counts at any moment.
        #expect(Artwork.Memo.remembered("radio|yes", now: 1e12, defaults: defaults) == .found("commons:A.svg"))
    }

    @Test("Namensraeume: answers und entries liefern ohne Praefix, nur den eigenen Raum")
    func namespacesStayApart() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        Artwork.Memo.remember("feed|f", value: "https://f.example/c.jpg", until: nil, now: 100, defaults: defaults)
        Artwork.Memo.remember("radio|r", value: nil, until: 150, now: 100, defaults: defaults)
        Artwork.Memo.remember("radio|s", value: "https://s.example/i.png", until: nil, now: 100, defaults: defaults)
        let answers = Artwork.Memo.answers(prefix: "radio|", now: 120, defaults: defaults)
        #expect(answers == ["r": .missing, "s": .found("https://s.example/i.png")])
        #expect(Artwork.Memo.answers(prefix: "radio|", now: 200, defaults: defaults) == ["s": .found("https://s.example/i.png")])
        #expect(Artwork.Memo.entries(prefix: "feed|", defaults: defaults).keys.sorted() == ["f"])
        #expect(Artwork.Memo.entries(prefix: "radio|", defaults: defaults)["r"]?.resolvedAt == 100)
    }

    @Test("vergessen oeffnet die Frage; schreiben fegt Abgelaufenes")
    func forgetAndPrune() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        Artwork.Memo.remember("radio|old", value: nil, until: 150, now: 100, defaults: defaults)
        Artwork.Memo.remember("radio|keep", value: "x", until: nil, now: 100, defaults: defaults)
        let forgotten = Artwork.Memo.forget("radio|keep", defaults: defaults)
        #expect(forgotten)
        let again = Artwork.Memo.forget("radio|keep", defaults: defaults)
        #expect(!again)
        // A write after the expiry drops the stale negative with it.
        Artwork.Memo.remember("radio|new", value: "y", until: nil, now: 200, defaults: defaults)
        #expect(Artwork.Memo.entries(prefix: "radio|", defaults: defaults).keys.sorted() == ["new"])
    }

    @Test("adopt faltet einmal ein und ueberschreibt nichts Neueres")
    func adoptOnce() {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        Artwork.Memo.remember("feed|a", value: "new", until: nil, now: 300, defaults: defaults)
        let adopted = Artwork.Memo.adopt([
            "feed|a": .init(value: "old", resolvedAt: 100, until: nil, under: nil),
            "feed|b": .init(value: nil, resolvedAt: 100, until: 900, under: nil),
        ], defaults: defaults)
        #expect(adopted == 1)
        #expect(Artwork.Memo.remembered("feed|a", now: 400, defaults: defaults) == .found("new"))
        #expect(Artwork.Memo.remembered("feed|b", now: 400, defaults: defaults) == .missing)
        #expect(Artwork.Memo.adopt([:], defaults: defaults) == 0)
    }

    /// The old feed dictionary carried `url` and `resolvedAt` under the
    /// key `feedArtworkResults.v2`, positives good for 30 days, negatives
    /// for 7. The fold keeps exactly those spans and removes the key.
    @Test("die alte Feed-Liste zieht mit ihren Fristen um, der Schluessel geht")
    func feedLegacyAdoption() throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        struct Old: Codable { var url: String?; var resolvedAt: Double }
        let old: [String: Old] = ["https://f.example/feed.xml": Old(url: "https://f.example/c.jpg", resolvedAt: 1_000),
                                  "https://g.example/feed.xml": Old(url: nil, resolvedAt: 1_000)]
        defaults.set(try JSONEncoder().encode(old), forKey: "feedArtworkResults.v2")
        defaults.set(Data(), forKey: "feedArtworkResults")
        #expect(FeedArtworkService.adoptLegacy(defaults: defaults) == 2)
        #expect(defaults.data(forKey: "feedArtworkResults.v2") == nil)
        #expect(defaults.data(forKey: "feedArtworkResults") == nil)
        let day = 24.0 * 3600
        #expect(Artwork.Memo.remembered("feed|https://f.example/feed.xml", now: 1_000 + 29 * day, defaults: defaults) == .found("https://f.example/c.jpg"))
        #expect(Artwork.Memo.remembered("feed|https://f.example/feed.xml", now: 1_000 + 31 * day, defaults: defaults) == nil)
        #expect(Artwork.Memo.remembered("feed|https://g.example/feed.xml", now: 1_000 + 6 * day, defaults: defaults) == .missing)
        #expect(Artwork.Memo.remembered("feed|https://g.example/feed.xml", now: 1_000 + 8 * day, defaults: defaults) == nil)
        // Nothing to adopt the second time.
        #expect(FeedArtworkService.adoptLegacy(defaults: defaults) == 0)
    }

    /// The old radio dictionary carried `url`, `resolvedAt`, `commonsFile`
    /// and `gate` under `radioLogoChainResults`: a Commons file becomes
    /// `commons:<file>` and never expires, a touch icon keeps its address,
    /// a negative keeps its gate stamp and its 14 days.
    @Test("die alte Logo-Liste zieht mit Datei, Adresse und Tor um")
    func radioLegacyAdoption() throws {
        let (defaults, name) = suite()
        defer { defaults.removePersistentDomain(forName: name) }
        struct Old: Codable { var url: String?; var resolvedAt: Double; var commonsFile: String?; var gate: String? }
        let old: [String: Old] = [
            "radio:rb:commons": Old(url: nil, resolvedAt: 1_000, commonsFile: "NDR Info Logo.svg", gate: nil),
            "radio:rb:touch": Old(url: "https://t.example/touch.png", resolvedAt: 1_000, commonsFile: nil, gate: nil),
            "radio:rb:no": Old(url: nil, resolvedAt: 1_000, commonsFile: nil, gate: RadioLogoService.gateSignature),
        ]
        defaults.set(try JSONEncoder().encode(old), forKey: "radioLogoChainResults")
        #expect(RadioLogoService.adoptLegacy(defaults: defaults) == 3)
        #expect(defaults.data(forKey: "radioLogoChainResults") == nil)
        let day = 24.0 * 3600
        let stamp = RadioLogoService.gateSignature
        #expect(Artwork.Memo.remembered("radio|radio:rb:commons", under: stamp, now: 1_000 + 400 * day, defaults: defaults) == .found("commons:NDR Info Logo.svg"))
        #expect(Artwork.Memo.remembered("radio|radio:rb:touch", under: stamp, now: 1_000 + 400 * day, defaults: defaults) == .found("https://t.example/touch.png"))
        #expect(Artwork.Memo.remembered("radio|radio:rb:no", under: stamp, now: 1_000 + 13 * day, defaults: defaults) == .missing)
        #expect(Artwork.Memo.remembered("radio|radio:rb:no", under: stamp, now: 1_000 + 15 * day, defaults: defaults) == nil)
        // The diagnosis reads the stored form back with its age and today's address.
        let urls = RadioLogoService.storedURLs(defaults: defaults)
        #expect(urls["radio:rb:commons"]?.query?.contains("width=\(RadioLogoService.commonsWidth)") == true)
        #expect(urls["radio:rb:touch"]?.absoluteString == "https://t.example/touch.png")
        #expect(urls["radio:rb:no"] == nil)
        let outcomes = RadioLogoService.storedOutcomes(defaults: defaults)
        #expect(outcomes["radio:rb:no"]?.hasLogo == false)
        #expect(outcomes["radio:rb:commons"]?.resolvedAt == 1_000)
        #expect(RadioLogoService.adoptLegacy(defaults: defaults) == 0)
    }

    @Test("ausserhalb der Tuer nennt niemand die alten Schluessel oder das Verzeichnis")
    func oldKeysAreGone() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let name = file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            let namesLegacy = text.contains("\"feedArtworkResults") || text.contains("\"radioLogoChainResults\"")
            let namesDirectory = text.contains("\"artworkMemo\"")
            // The two chains name their old key once, for the fold; the door names its own.
            let allowed = ["FeedArtworkService.swift", "RadioLogoService.swift"].contains(name)
            if namesLegacy, !allowed { offenders.append("\(name) names a legacy key") }
            if namesDirectory, name != "Artwork+Memo.swift" { offenders.append("\(name) names the directory key") }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
#endif
