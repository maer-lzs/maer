// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Drei Bezahlfeeds folgten auf einem neuen Geraet nicht (403).
/// Ein gewechselter Token reiste als alte Aussage weiter, nach der Mär-Sync-
/// Anmeldung versuchte niemand es neu, und die Liste bot fuer eine reine
/// Token-Adresse „Anmelden“ an.
struct FeedAccessRefusedTests {
    private func show(_ token: String, episodes: Int) -> PodcastShow {
        let url = "https://premium-feed.zeit.de/sgh/rss-podcatcher?freebie=\(token)"
        let key = PodcastIdentity.feedKey(url)
        return PodcastShow(id: "feed:\(key)", title: "Servus. Grüezi. Hallo.", author: nil,
                           artworkURL: nil, description: nil, feedURL: url,
                           episodes: (0..<episodes).map { i in
                               PodcastEpisode(guid: "rss:\(key):ep\(i)", title: "E\(i)",
                                              audioURL: "https://cdn.zeit.de/ep\(i).mp3",
                                              pubDate: Double(1000 + i), duration: 60)
                           })
    }

    @Test("Ein Token-Wechsel nennt die alte und die neue Adresse, damit die alte nicht weiterreist")
    func aRetiredTwinIsNamed() {
        var retired: [(String, String)] = []
        let (result, _) = PodcastIdentity.migrate([show("OLDTOKEN", episodes: 3), show("NEWTOKEN", episodes: 40)],
                                                       moveProgress: { _, _ in },
                                                       retired: { retired.append(($0, $1)) })
        #expect(result.count == 1)
        #expect(retired.count == 1)
        #expect(retired.first?.0.contains("OLDTOKEN") == true, "the loser is the old token")
        #expect(retired.first?.1.contains("NEWTOKEN") == true, "the survivor carries the current token")
        // The other order: the fuller entry comes first.
        var again: [(String, String)] = []
        _ = PodcastIdentity.migrate([show("NEWTOKEN", episodes: 40), show("OLDTOKEN", episodes: 3)],
                                         moveProgress: { _, _ in }, retired: { again.append(($0, $1)) })
        #expect(again.first?.0.contains("OLDTOKEN") == true && again.first?.1.contains("NEWTOKEN") == true)
        // No twin, nothing retired.
        var none = 0
        _ = PodcastIdentity.migrate([show("ONLY", episodes: 3)], moveProgress: { _, _ in }, retired: { _, _ in none += 1 })
        #expect(none == 0)
    }

    @Test("Der Laden sagt dem Konto: alte Adresse abbestellt, neue abonniert", .needsTheSources)
    func theLoadTellsTheAccount() throws {
        let source = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/PodcastSubscriptions.swift"), encoding: .utf8))
        let body = try #require(functionBody(of: "private func migrated(_ decoded: [PodcastShow]) -> [PodcastShow] {", in: source))
        let collapsed = body.components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(collapsed.contains("Self.stateSubscription(twin.loser,subscribed:false)"))
        #expect(collapsed.contains("Self.stateSubscription(twin.survivor,subscribed:true)"))
    }

    @Test("Ein 401/403 an einer Token-Adresse ohne Zugangsdaten heisst Zugang abgelehnt, nie braucht eine Anmeldung")
    func theReading() {
        typealias R = FeedAdoptionPending.Reason
        #expect(R.from(meaning: StatusMeaning.from(status: 403), tokenAddress: true, hasCredentials: false) == .accessRefused)
        #expect(R.from(meaning: StatusMeaning.from(status: 401), tokenAddress: true, hasCredentials: false) == .accessRefused)
        #expect(R.from(meaning: StatusMeaning.from(status: 403), tokenAddress: true, hasCredentials: true) == .signIn, "a login exists: sign in")
        #expect(R.from(meaning: StatusMeaning.from(status: 403), tokenAddress: false, hasCredentials: false) == .signIn)
        #expect(R.from(meaning: StatusMeaning.from(status: 404), tokenAddress: true, hasCredentials: false) == .notFound)
        #expect(R.from(meaning: StatusMeaning.from(status: 500), tokenAddress: true, hasCredentials: false) == .server)
        let phrase = FeedAdoptionPending.phrase(.accessRefused, status: 403)
        #expect(phrase != FeedAdoptionPending.phrase(.signIn, status: 403))
        #expect(PodcastFeedAddress.isTokenFeedURL("https://premium-feed.zeit.de/sgh/rss-podcatcher?freebie=abc"),
                "the ZEIT class is a token address, or the case measures nothing")
    }

    @Test("Wenn Zugang eintrifft, bekommt genau jeder abgelehnte Feed einen neuen Versuch")
    func whoIsRetried() {
        typealias E = FeedAdoptionPending.Entry
        let pending: [String: E] = [
            "a": E(feedURL: "https://x/a", reason: .signIn),
            "b": E(feedURL: "https://x/b?freebie=t", reason: .accessRefused),
            "c": E(feedURL: "https://x/c", reason: .notFound),
            "d": E(feedURL: "https://x/d", reason: .dismissed),
            "e": E(feedURL: "https://x/e", reason: .timeout),
        ]
        #expect(FeedAdoptionPending.retryOnNewAccess(pending) == ["a", "b"])
    }

    @Test("Mär-Sync-Anmeldung und eintreffende Feed-Zugaenge melden es, die Abos versuchen es neu", .needsTheSources)
    func theTriggersAreWired() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
                .components(separatedBy: .whitespacesAndNewlines).joined()
        }
        let signIn = try source("Sources/Networking/MaerSyncSignIn.swift")
        #expect(signIn.contains("post(name:FeedAdoptionPending.accessArrived"))
        let feedAuth = try source("Sources/Networking/FeedAuthSync.swift")
        #expect(feedAuth.contains("post(name:FeedAdoptionPending.accessArrived"))
        let subs = try source("Sources/Providers/PodcastSubscriptions.swift")
        #expect(subs.contains("forName:FeedAdoptionPending.accessArrived"))
        #expect(subs.contains("forkeyinkeys{retryAdoption(feedKey:key)}"))
    }

    @Test("Die Messzeile traegt nie den Token, und derselbe Feed hat auf beiden Geraeten denselben Schluessel")
    func theMeasuringLine() {
        let upper = "https://premium-feed.zeit.de/sgh/rss-podcatcher?freebie=AbC123SecretToken"
        let lower = "https://premium-feed.zeit.de/sgh/rss-podcatcher?freebie=abc123secrettoken"
        let a = PodcastIdentity.addressLine(upper)
        let b = PodcastIdentity.addressLine(lower)
        #expect(!a.contains("AbC123SecretToken") && !a.lowercased().contains("secret") && !a.contains("freebie"))
        #expect(a.contains("capitals=true") && b.contains("capitals=false"))
        func part(_ line: String, _ name: String) -> Substring? {
            line.split(separator: " ").first { $0.hasPrefix(name + "=") }
        }
        #expect(part(a, "key") == part(b, "key"), "the same feed key on both devices")
        #expect(part(a, "addr") != part(b, "addr"), "a different address shows as a different hash")
    }
}
#endif
