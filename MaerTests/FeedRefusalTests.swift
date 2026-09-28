// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Eine abonnierte Sendung, deren Feed der Server dauerhaft
/// ablehnt, sagt es an der Sendung und bietet einen neuen Link oder eine
/// Anmeldung an. „Dauerhaft“ ist entschieden: drei Ablehnungen in Folge und
/// mindestens ein Tag zwischen der ersten und der letzten. Folgen und
/// Hoerstaende bleiben.
@MainActor
struct FeedRefusalTests {
    private let day = FeedRefusal.span

    // MARK: - Die Regel

    @Test("Dauerhaft erst nach drei Ablehnungen UND einem Tag; ein Erfolg setzt zurueck, alles andere laesst stehen")
    func rule() {
        func run(_ steps: [(FeedRefusal.Answer, Double)]) -> FeedRefusal.Record? {
            steps.reduce(nil) { FeedRefusal.next($0, $1.0, now: $1.1) }
        }
        let r = FeedRefusal.Answer.refused(status: 403)
        // Drei an einem Tag: nicht dauerhaft.
        #expect(!FeedRefusal.isLasting(run([(r, 0), (r, 3600), (r, day - 1)])))
        // Drei ueber einen Tag: dauerhaft.
        #expect(FeedRefusal.isLasting(run([(r, 0), (r, 3600), (r, day)])))
        // Zwei ueber zwei Tage: nicht dauerhaft.
        #expect(!FeedRefusal.isLasting(run([(r, 0), (r, 2 * day)])))
        // Ein Erfolg dazwischen beginnt die Reihe neu.
        #expect(!FeedRefusal.isLasting(run([(r, 0), (r, 3600), (.success, 7200), (r, day)])))
        #expect(run([(r, 0), (.success, 1)]) == nil)
        // Ein Zeitueberlauf sagt nichts ueber den Zugang: die Reihe bleibt.
        #expect(FeedRefusal.isLasting(run([(r, 0), (.other, 10), (r, 3600), (.other, 20), (r, day)])))
        #expect(run([(.other, 0)]) == nil)
        // Die Lesung des Status geht ueber die eine Tafel der Bedeutungen.
        #expect(FeedRefusal.answer(status: 401) == .refused(status: 401))
        #expect(FeedRefusal.answer(status: 403) == .refused(status: 403))
        for other in [404, 410, 429, 500, 503] {
            #expect(FeedRefusal.answer(status: other) == .other, "\(other)")
        }
    }

    @Test("Das Mittel: Token-Adresse ohne Zugangsdaten bekommt einen neuen Link, alles andere eine Anmeldung")
    func remedy() {
        #expect(ShowAccessRemedy.of(tokenAddress: true, hasCredentials: false) == .newLink)
        #expect(ShowAccessRemedy.of(tokenAddress: true, hasCredentials: true) == .signIn)
        #expect(ShowAccessRemedy.of(tokenAddress: false, hasCredentials: false) == .signIn)
        #expect(ShowAccessRemedy.of(tokenAddress: false, hasCredentials: true) == .signIn)
    }

    // MARK: - Der Speicher

    private func harness(_ name: String) throws -> (subs: PodcastSubscriptions, defaults: UserDefaults, close: () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "refusal-\(name)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let closeTheGate = PodcastPublishCountTests.openTheRSSGate()
        let subs = PodcastSubscriptions(
            fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
            database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
            defaults: defaults, isTheApp: false)
        return (subs, defaults, {
            closeTheGate()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    static func show(_ url: URL, guidStem: String, episodes: Range<Int>) -> PodcastShow {
        PodcastShow(id: PodcastSubscriptions.feedKey(url.absoluteString), title: "Verbrechen",
                    author: nil, artworkURL: nil, description: nil,
                    feedURL: url.absoluteString,
                    episodes: episodes.map {
                        PodcastEpisode(guid: "rss:\(guidStem)-\($0)", title: "Folge \($0)",
                                       audioURL: "https://media.example/verbrechen-\($0).mp3",
                                       pubDate: Double($0 + 1) * 1000, duration: 3000)
                    })
    }

    @Test("Das Auffrischen reicht den Status durch: dreimal abgelehnt ueber einen Tag macht die Sendung dauerhaft abgelehnt, Folgen bleiben, ein Erfolg hebt es auf")
    func refreshCountsRefusals() async throws {
        let h = try harness("refresh")
        defer { h.close() }
        try #require(AppStorageKeys.rssActive, "das RSS-Tor ist zu, der Fall misst nichts")
        let feed = try #require(URL(string: "https://paid.example/\(UUID().uuidString.prefix(8))/feed?token=abc"))
        let key = PodcastSubscriptions.feedKey(feed.absoluteString)
        var now = 1_000_000.0
        h.subs.clock = { now }
        await h.subs.ensureLoaded()
        h.subs._testFeedFetcher = { url in .show(Self.show(url, guidStem: "a", episodes: 0..<5)) }
        try #require(await h.subs.subscribe(urlString: feed.absoluteString, notesCloud: false))
        let show = try #require(h.subs.shows.first)

        h.subs._testFeedFetcher = { _ in .status(403) }
        await h.subs.refreshAll()
        now += 12 * 3600
        // Ein Zeitueberlauf dazwischen zaehlt nicht und setzt nicht zurueck.
        h.subs._testFeedFetcher = { _ in .failed(.timeout) }
        await h.subs.refreshAll()
        h.subs._testFeedFetcher = { _ in .status(403) }
        await h.subs.refreshAll()
        #expect(!h.subs.isAccessRefused(show), "zwei Ablehnungen sind noch nichts")
        now += 12 * 3600
        await h.subs.refreshAll()
        #expect(h.subs.isAccessRefused(show), "drei ueber einen Tag: dauerhaft")
        #expect(h.subs.refusedFeedKeys == [key])
        #expect(h.subs.refusalCount(show) == 3)
        #expect(h.subs.shows.first?.episodes.count == 5, "die Folgen bleiben")
        #expect(FeedRefusal.all(defaults: h.defaults)[key]?.status == 403)

        h.subs._testFeedFetcher = { url in .show(Self.show(url, guidStem: "a", episodes: 0..<6)) }
        await h.subs.refreshAll()
        #expect(!h.subs.isAccessRefused(show))
        #expect(h.defaults.object(forKey: AppStorageKeys.podcastFeedRefusals) == nil,
                "ein Erfolg raeumt den Eintrag, der Schluessel bleibt nicht leer stehen")
    }

    @Test("Neuer Link: Hoerstaende gehen ueber die Folgen-Bruecke mit, die alte Adresse geht, die Ablehnung auch")
    func newLinkCarriesOver() async throws {
        let h = try harness("newlink")
        defer { h.close() }
        let run = UUID().uuidString.prefix(8)
        let old = try #require(URL(string: "https://paid.example/\(run)/feed?token=alt"))
        let new = try #require(URL(string: "https://paid.example/\(run)/feed?token=neu"))
        var now = 1_000_000.0
        h.subs.clock = { now }
        await h.subs.ensureLoaded()
        h.subs._testFeedFetcher = { url in
            .show(Self.show(url, guidStem: url.absoluteString.hasSuffix("neu") ? "neu" : "alt", episodes: 0..<4))
        }
        try #require(await h.subs.subscribe(urlString: old.absoluteString, notesCloud: false))
        let oldShow = try #require(h.subs.shows.first)
        ListeningStore.store("rss:alt-2", entry: [900, 1_700_000_000_000, 3000], in: h.defaults)
        // Dauerhaft abgelehnt machen.
        h.subs._testFeedFetcher = { _ in .status(403) }
        for _ in 0..<3 { await h.subs.refreshAll(); now += day / 2 }
        try #require(h.subs.isAccessRefused(oldShow))

        h.subs._testFeedFetcher = { url in
            .show(Self.show(url, guidStem: url.absoluteString.hasSuffix("neu") ? "neu" : "alt", episodes: 0..<4))
        }
        let ok = await h.subs.replaceShowLink(showId: oldShow.id, newURL: new.absoluteString, notesCloud: false)

        #expect(ok)
        #expect(h.subs.shows.map(\.feedURL) == [new.absoluteString], "nur noch die neue Adresse")
        #expect(ListeningStore.backup("rss:neu-2", in: h.defaults)?.first == 900, "der Hoerstand ging mit")
        #expect(ListeningStore.backup("rss:alt-2", in: h.defaults) == nil)
        #expect(h.subs.refusedFeedKeys.isEmpty)
        #expect(FeedRefusal.all(defaults: h.defaults).isEmpty)
    }

    @Test("Behaelt eine Folge ihre guid, bleibt ihr Hoerstand stehen: kein Umzug auf sich selbst")
    func sameGuidKeepsItsStand() async throws {
        let h = try harness("sameguid")
        defer { h.close() }
        let run = UUID().uuidString.prefix(8)
        let old = try #require(URL(string: "https://paid.example/\(run)/feed?token=alt"))
        let new = try #require(URL(string: "https://paid.example/\(run)/feed?token=neu"))
        await h.subs.ensureLoaded()
        // Dieselben guids unter beiden Adressen, wie ein Anbieter, der nur
        // den Token dreht.
        h.subs._testFeedFetcher = { url in .show(Self.show(url, guidStem: "gleich", episodes: 0..<4)) }
        try #require(await h.subs.subscribe(urlString: old.absoluteString, notesCloud: false))
        let oldShow = try #require(h.subs.shows.first)
        ListeningStore.store("rss:gleich-1", entry: [600, 1_700_000_000_000, 3000], in: h.defaults)

        #expect(await h.subs.replaceShowLink(showId: oldShow.id, newURL: new.absoluteString, notesCloud: false))

        #expect(ListeningStore.backup("rss:gleich-1", in: h.defaults)?.first == 600)
    }

    // MARK: - Verdrahtung

    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("Die Sendung zeigt den Hinweis, die Kacheln das Zeichen, beide Orte sagen Neuen Link eintragen")
    func wiring() throws {
        let seite = try sourceText("Sources/Views/Podcasts/PodcastShowView.swift")
        #expect(seite.contains("ShowAccessRefusedBanner("))
        #expect(seite.contains("subs.isAccessRefused(show)"))
        #expect(seite.contains("subs.replaceShowLink(showId:"))
        #expect(seite.contains("subs.recheckAccess(showId:"))
        let kacheln = try sourceText("Sources/Views/Podcasts/PodcastComponents.swift")
        #expect(kacheln.components(separatedBy: ".premiumLock(PodcastSubscriptions.isPremiumFeed(").count == 3
                && kacheln.components(separatedBy: "refused: refused)").count == 3,
                "beide Kacheln tragen das Zeichen")
        let liste = try sourceText("Sources/Views/PodcastsView.swift")
        #expect(liste.components(separatedBy: "refused: subs.isAccessRefused(").count == 7,
                "alle sechs Kachel-Rufer reichen den Zustand hinein")
        #expect(liste.contains(".alert(\"Enter new link\""), "die Abfrage der Liste")
        #expect(liste.contains("NotFollowedRow("))
        #expect(try sourceText("Sources/Views/Podcasts/NotFollowedRow.swift").contains("Button(\"Enter new link\""),
                "der Knopf der Zeile")
        #expect(try sourceText("Sources/Views/Podcasts/NotFollowedRow.swift").contains("if dynamicTypeSize.isAccessibilitySize {"),
                "bei grosser Schrift stehen die Knoepfe unter dem Text")
        #expect(!liste.contains("\"New link\""))
        #expect(seite.contains("\"Enter new link\""))
        let auffrischen = try sourceText("Sources/Providers/PodcastSubscriptions.swift")
        #expect(auffrischen.contains("if let outcome { noteRefusal(show, outcome) }"))
        #expect(auffrischen.contains("status=\\(status ?? 0) merged="), "die Logzeile nennt den Status")
    }

    // MARK: - Register, Eintrag fuer Eintrag

    @Test("Das Register liest Eintrag fuer Eintrag und schreibt unlesbare Eintraege unveraendert zurueck")
    func registerReadsEntryByEntry() throws {
        let suite = "known-lenient-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = """
        [{"url":"https://abs.example","service":"audiobookshelf","lastSuccessAt":1},
         {"url":"https://neu.example","service":"dienstVonMorgen","lastSuccessAt":2}]
        """
        defaults.set(Data(stored.utf8), forKey: KnownServers.storeKey)
        #expect(KnownServers.all(defaults: defaults).map(\.url) == ["https://abs.example"],
                "ein unbekannter Dienst kostet seinen Eintrag, nicht die Liste")
        KnownServers.remember("https://music.example", service: .subsonic, now: 3, defaults: defaults)
        #expect(Set(KnownServers.all(defaults: defaults).map(\.url)) == ["https://abs.example", "https://music.example"])
        let raw = String(decoding: defaults.data(forKey: KnownServers.storeKey) ?? Data(), as: UTF8.self)
        #expect(raw.contains("dienstVonMorgen"), "der unlesbare Eintrag bleibt fuer den Build, der ihn kennt")
    }
}
#endif
