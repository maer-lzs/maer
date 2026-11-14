// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A subscribed show whose feed the server refuses
/// permanently says so on the show and offers a new link or a
/// sign-in. „Dauerhaft“ is decided: three refusals in a row and
/// at least one day between the first and the last. Episodes and
/// listening states stay.
@MainActor
struct FeedRefusalTests {
    private let day = FeedRefusal.span

    // MARK: - The rule

    @Test("Permanent only after three refusals AND one day; a success resets, everything else leaves it standing")
    func rule() {
        func run(_ steps: [(FeedRefusal.Answer, Double)]) -> FeedRefusal.Record? {
            steps.reduce(nil) { FeedRefusal.next($0, $1.0, now: $1.1) }
        }
        let r = FeedRefusal.Answer.refused(status: 403)
        // Three on one day: not permanent.
        #expect(!FeedRefusal.isLasting(run([(r, 0), (r, 3600), (r, day - 1)])))
        // Three over a day: permanent.
        #expect(FeedRefusal.isLasting(run([(r, 0), (r, 3600), (r, day)])))
        // Two over two days: not permanent.
        #expect(!FeedRefusal.isLasting(run([(r, 0), (r, 2 * day)])))
        // A success in between starts the series anew.
        #expect(!FeedRefusal.isLasting(run([(r, 0), (r, 3600), (.success, 7200), (r, day)])))
        #expect(run([(r, 0), (.success, 1)]) == nil)
        // A timeout says nothing about the access: the series stays.
        #expect(FeedRefusal.isLasting(run([(r, 0), (.other, 10), (r, 3600), (.other, 20), (r, day)])))
        #expect(run([(.other, 0)]) == nil)
        // The reading of the status goes through the one table of meanings.
        #expect(FeedRefusal.answer(status: 401) == .refused(status: 401))
        #expect(FeedRefusal.answer(status: 403) == .refused(status: 403))
        for other in [404, 410, 429, 500, 503] {
            #expect(FeedRefusal.answer(status: other) == .other, "\(other)")
        }
    }

    @Test("The remedy: a token address without credentials gets a new link, everything else a sign-in")
    func remedy() {
        #expect(ShowAccessRemedy.of(tokenAddress: true, hasCredentials: false) == .newLink)
        #expect(ShowAccessRemedy.of(tokenAddress: true, hasCredentials: true) == .signIn)
        #expect(ShowAccessRemedy.of(tokenAddress: false, hasCredentials: false) == .signIn)
        #expect(ShowAccessRemedy.of(tokenAddress: false, hasCredentials: true) == .signIn)
    }

    // MARK: - The store

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
        PodcastShow(id: PodcastIdentity.feedKey(url.absoluteString), title: "Verbrechen",
                    author: nil, artworkURL: nil, description: nil,
                    feedURL: url.absoluteString,
                    episodes: episodes.map {
                        PodcastEpisode(guid: "rss:\(guidStem)-\($0)", title: "Folge \($0)",
                                       audioURL: "https://media.example/verbrechen-\($0).mp3",
                                       pubDate: Double($0 + 1) * 1000, duration: 3000)
                    })
    }

    @Test("The refresh passes the status through: refused three times over a day makes the show permanently refused, episodes stay, a success lifts it")
    func refreshCountsRefusals() async throws {
        let h = try harness("refresh")
        defer { h.close() }
        try #require(AppStorageKeys.rssActive, "das RSS-Tor ist zu, der Fall misst nichts")
        let feed = try #require(URL(string: "https://paid.example/\(UUID().uuidString.prefix(8))/feed?token=abc"))
        let key = PodcastIdentity.feedKey(feed.absoluteString)
        var now = 1_000_000.0
        h.subs.clock = { now }
        await h.subs.ensureLoaded()
        h.subs._testFeedFetcher = { url in .show(Self.show(url, guidStem: "a", episodes: 0..<5)) }
        try #require(await h.subs.subscribe(urlString: feed.absoluteString, notesCloud: false))
        let show = try #require(h.subs.shows.first)

        h.subs._testFeedFetcher = { _ in .status(403) }
        await h.subs.refreshAll()
        now += 12 * 3600
        // A timeout in between does not count and does not reset.
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

    @Test("New link: listening states go along over the episode bridge, the old address goes, the refusal too")
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
        // Make it permanently refused.
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

    @Test("If an episode keeps its guid, its listening state stays: no move onto itself")
    func sameGuidKeepsItsStand() async throws {
        let h = try harness("sameguid")
        defer { h.close() }
        let run = UUID().uuidString.prefix(8)
        let old = try #require(URL(string: "https://paid.example/\(run)/feed?token=alt"))
        let new = try #require(URL(string: "https://paid.example/\(run)/feed?token=neu"))
        await h.subs.ensureLoaded()
        // The same guids under both addresses, like a provider that only
        // rotates the token.
        h.subs._testFeedFetcher = { url in .show(Self.show(url, guidStem: "gleich", episodes: 0..<4)) }
        try #require(await h.subs.subscribe(urlString: old.absoluteString, notesCloud: false))
        let oldShow = try #require(h.subs.shows.first)
        ListeningStore.store("rss:gleich-1", entry: [600, 1_700_000_000_000, 3000], in: h.defaults)

        #expect(await h.subs.replaceShowLink(showId: oldShow.id, newURL: new.absoluteString, notesCloud: false))

        #expect(ListeningStore.backup("rss:gleich-1", in: h.defaults)?.first == 600)
    }

    // MARK: - Wiring

    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("The show displays the notice, the tiles the glyph, both places say „Neuen Link eintragen“", .needsTheSources)
    func wiring() throws {
        let seite = try sourceText("Sources/Views/Podcasts/PodcastShowView.swift")
        #expect(seite.contains("ShowAccessRefusedBanner("))
        #expect(seite.contains("subs.isAccessRefused(show)"))
        #expect(seite.contains("subs.replaceShowLink(showId:"))
        #expect(seite.contains("subs.recheckAccess(showId:"))
        let kacheln = try sourceText("Sources/Views/Podcasts/PodcastComponents.swift")
        #expect(kacheln.components(separatedBy: "StandardCoverMarks(lock: lock").count == 3,
                "beide Kacheln tragen das Zeichen")
        let liste = try sourceText("Sources/Views/PodcastsView.swift")
        #expect(liste.components(separatedBy: "lock: subs.lock(feedURL:").count == 7,
                "alle sechs Kachel-Rufer reichen das Schloss aus der einen Frage hinein")
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
        #expect(auffrischen.contains("status=\\(status) merged=\\(merged)"), "die Logzeile nennt den Status und die Vereinigung")
        #expect(auffrischen.components(separatedBy: "Self.mergedRefresh(").count - 1 == 1,
                "die Vereinigung wird fuer die Logzeile ein zweites Mal gerechnet")
    }

    // MARK: - The sign-in sheet asks only after a change

    @Test("A sheet that closes without a new sign-in does not ask; saved or removed asks once")
    func signInSheetAsksOnlyAfterAChange() {
        #expect(!FeedRefusal.asksAgainAfterSignIn(momentBefore: nil, momentAfter: nil), "no sign-in, swiped away")
        #expect(!FeedRefusal.asksAgainAfterSignIn(momentBefore: 5, momentAfter: 5), "a sign-in, swiped away unchanged")
        #expect(FeedRefusal.asksAgainAfterSignIn(momentBefore: nil, momentAfter: 7), "a first sign-in saved")
        #expect(FeedRefusal.asksAgainAfterSignIn(momentBefore: 5, momentAfter: 9), "a sign-in saved again")
        #expect(FeedRefusal.asksAgainAfterSignIn(momentBefore: 5, momentAfter: nil), "a sign-in removed")
    }

    @Test("The moment of a sign-in moves only on a write that landed")
    func theSignInMomentMovesOnlyOnALandedWrite() throws {
        let suite = "feedauth-moment-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let feed = "feed-\(UUID().uuidString)"
        #expect(PodcastFeedAuth.moment(feedKey: feed, defaults: defaults) == nil)
        PodcastFeedAuth.set(feedKey: feed, user: "u", password: "p", now: Date(timeIntervalSince1970: 100),
                            defaults: defaults, writing: { _, _, _ in false })
        #expect(PodcastFeedAuth.moment(feedKey: feed, defaults: defaults) == nil, "a failed write moved the moment")
        PodcastFeedAuth.set(feedKey: feed, user: "u", password: "p", now: Date(timeIntervalSince1970: 100),
                            defaults: defaults, writing: { _, _, _ in true })
        #expect(PodcastFeedAuth.moment(feedKey: feed, defaults: defaults) == 100_000)
    }

    @Test("The show's sheet asks the rule before it asks again", .needsTheSources)
    func theSheetAsksTheRuleBeforeItAsksTheFeed() throws {
        let seite = try sourceText("Sources/Views/Podcasts/PodcastShowView.swift")
        let sheet = try #require(seite.range(of: ".sheet(item: $signInShow, onDismiss: {"))
        let rest = seite[sheet.upperBound...]
        let rule = try #require(rest.range(of: "FeedRefusal.asksAgainAfterSignIn("), "the sheet does not ask the rule")
        let recheck = try #require(rest.range(of: "subs.recheckAccess(showId:"))
        #expect(rule.lowerBound < recheck.lowerBound, "the sheet asks the feed before the rule")
        #expect(seite.components(separatedBy: "subs.recheckAccess(showId:").count == 2, "one recheck on the page")
    }

    // MARK: - Register, entry by entry

    @Test("The register reads entry by entry and writes unreadable entries back unchanged")
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
