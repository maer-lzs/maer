// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Y51: free→premium episode matching — conservative by design (a missed match
/// is cheap, a wrong match moves progress onto the wrong episode).
struct PodcastPremiumMatchTests {
    private func episode(_ guid: String, title: String, audio: String, pubDate: Double = 0) -> PodcastEpisode {
        PodcastEpisode(guid: guid, title: title, audioURL: audio, pubDate: pubDate, duration: 0,
                       description: nil, imageURL: nil)
    }

    @Test("same-show test is normalized but strict; empty titles never match")
    func sameShow() {
        #expect(PodcastPremiumMatch.sameShow(titleA: "Die ZEIT: Verbrechen", titleB: "die zeit verbrechen"))
        #expect(PodcastPremiumMatch.sameShow(titleA: "Café Übermorgen", titleB: "Cafe Übermorgen!"))
        #expect(!PodcastPremiumMatch.sameShow(titleA: "Verbrechen", titleB: "Verbrechen von nebenan"))
        #expect(!PodcastPremiumMatch.sameShow(titleA: "", titleB: ""))
    }

    @Test("primary match: normalized enclosure URL wins regardless of guid/title")
    func enclosurePrimary() {
        let free = [episode("rss:f:1", title: "Folge 1", audio: "https://cdn.host/ep1.mp3?free=1")]
        let premium = [episode("rss:p:9", title: "Ganz anders", audio: "http://CDN.host/ep1.mp3")]
        #expect(PodcastPremiumMatch.episodeMatches(free: free, premium: premium) == ["rss:f:1": "rss:p:9"])
    }

    @Test("ambiguous premium enclosures poison the key — no match")
    func ambiguousEnclosure() {
        let free = [episode("f1", title: "A", audio: "https://h/e.mp3")]
        let premium = [episode("p1", title: "A", audio: "https://h/e.mp3"),
                       episode("p2", title: "B", audio: "https://h/e.mp3")]
        // Enclosure is ambiguous AND the title fallback stays conservative
        // (only p1 shares the title, so the unique-title rule may still apply) —
        // assert the enclosure path did NOT force p2.
        let m = PodcastPremiumMatch.episodeMatches(free: free, premium: premium)
        #expect(m["f1"] != "p2")
    }

    @Test("fallback: unique title on both sides within the 48h window")
    func titleDateFallback() {
        let base: Double = 1_700_000_000_000
        let free = [episode("f1", title: "Der große Fall", audio: "https://free.host/a.mp3", pubDate: base)]
        let premium = [episode("p1", title: "Der große Fall!", audio: "https://prem.host/x/a.mp3?tok=s",
                               pubDate: base + 12 * 3600 * 1000)]
        #expect(PodcastPremiumMatch.episodeMatches(free: free, premium: premium) == ["f1": "p1"])
    }

    @Test("fallback refuses: outside the window or duplicate titles")
    func fallbackConservative() {
        let base: Double = 1_700_000_000_000
        let free = [episode("f1", title: "Folge", audio: "https://free.host/a.mp3", pubDate: base)]
        let farPremium = [episode("p1", title: "Folge", audio: "https://prem.host/b.mp3",
                                  pubDate: base + 72 * 3600 * 1000)]
        #expect(PodcastPremiumMatch.episodeMatches(free: free, premium: farPremium).isEmpty)

        let dupPremium = [episode("p1", title: "Folge", audio: "https://prem.host/b.mp3", pubDate: base),
                          episode("p2", title: "Folge", audio: "https://prem.host/c.mp3", pubDate: base)]
        #expect(PodcastPremiumMatch.episodeMatches(free: free, premium: dupPremium).isEmpty)
    }
}

/// Y52: token-URL premium class — classification and masking (secrets never
/// shown or logged unmasked).
struct PodcastTokenFeedTests {
    @Test("token classification: known secret param with value; conservative otherwise")
    func classification() {
        #expect(PodcastSubscriptions.isTokenFeedURL("https://h.example/feed?token=abc123"))
        #expect(PodcastSubscriptions.isTokenFeedURL("h.example/feed?auth=x&limit=5"))
        #expect(PodcastSubscriptions.isTokenFeedURL("https://h.example/feed?SECRET=s"))
        #expect(!PodcastSubscriptions.isTokenFeedURL("https://h.example/feed"))
        #expect(!PodcastSubscriptions.isTokenFeedURL("https://h.example/feed?page=2"))
        #expect(!PodcastSubscriptions.isTokenFeedURL("https://h.example/feed?token="))   // empty value
    }

    @Test("masking replaces ONLY secret values, works on raw, normalized and composite strings")
    func masking() {
        #expect(PodcastSubscriptions.maskedFeedURL("https://h.example/feed?token=abc&page=2")
                == "https://h.example/feed?token=••••&page=2")
        #expect(PodcastSubscriptions.maskedFeedURL("h.example/feed?auth=x")
                == "h.example/feed?auth=••••")
        #expect(PodcastSubscriptions.maskedFeedURL("https://h.example/feed") == "https://h.example/feed")
        // Composite report string ("Title — url?token=…") still gets masked.
        #expect(PodcastSubscriptions.maskedFeedURL("Show — https://h.example/f?key=s")
                == "Show — https://h.example/f?key=••••")
    }

    @Test("feedHost: comparable host for the provider-login reuse")
    func feedHost() {
        #expect(PodcastSubscriptions.feedHost("https://www.Provider.example/rss/a?token=x") == "provider.example")
        #expect(PodcastSubscriptions.feedHost("http://provider.example/other") == "provider.example")
        #expect(PodcastSubscriptions.feedHost("provider.example") == "provider.example")
        #expect(PodcastSubscriptions.feedHost("https://other.example/rss") != "provider.example")
    }

    @Test("premium test: token class counts even without stored credentials")
    func premiumIncludesTokenClass() {
        #expect(PodcastSubscriptions.isPremiumFeed("https://h.example/feed?token=abc"))
        #expect(PodcastSubscriptions.isPremiumFeed("https://www.patreon.com/rss/show"))
        #expect(!PodcastSubscriptions.isPremiumFeed("https://h.example/feed"))
    }

    @Test("97b1f7c: twins in the stock — free+premium of the same show pair up")
    func twinDetection() {
        let shows = [
            (id: "f1", title: "Servus. Grüezi. Hallo.", feedURL: "https://feeds.simplecast.com/abc"),
            (id: "p1", title: "Servus. Grüezi. Hallo.", feedURL: "https://premium-feed.zeit.de/x/rss-podcatcher?freebie=TOKEN"),
            (id: "o1", title: "Other Show", feedURL: "https://example.org/feed"),
        ]
        let twins = PodcastPremiumMatch.twins(shows: shows,
                                              isPremium: { PodcastSubscriptions.isTokenFeedURL($0) })
        #expect(twins.count == 1)
        #expect(twins.first?.freeId == "f1")
        #expect(twins.first?.premiumId == "p1")
        // The real ZEIT podcatcher pattern IS detected now (7dba2b1 root):
        // `freebie` joined the secret-parameter set with the OPML fix.
        #expect(PodcastSubscriptions.isTokenFeedURL(
            "https://premium-feed.zeit.de/x/rss-podcatcher?freebie=TOKEN"))
    }

    @Test("92e25d6: manual marking feeds the ONE premium truth")
    func manualMarking() {
        let defaults = UserDefaults(suiteName: "premium-marking-test")!
        defaults.removePersistentDomain(forName: "premium-marking-test")
        let url = "https://example.org/hidden-premium/feed.xml"
        #expect(!PodcastSubscriptions.isManuallyMarkedPremium(url, defaults: defaults))
        PodcastSubscriptions.setManualPremium(true, feedURL: url, defaults: defaults)
        #expect(PodcastSubscriptions.isManuallyMarkedPremium(url, defaults: defaults))
        #expect(PodcastSubscriptions.manualPremiumFeedKeys(defaults: defaults).count == 1)
        PodcastSubscriptions.setManualPremium(false, feedURL: url, defaults: defaults)
        #expect(PodcastSubscriptions.manualPremiumFeedKeys(defaults: defaults).isEmpty)
    }

    @Test("f4f1b46: token-rotation twins collapse at bootstrap — one survivor, progress moved")
    func identityCollapse() {
        func show(_ token: String, episodes: Int, played: Int = 0) -> PodcastShow {
            let url = "https://premium-feed.zeit.de/sgh/rss-podcatcher?freebie=\(token)"
            let key = PodcastSubscriptions.feedKey(url)
            return PodcastShow(id: "feed:\(key)", title: "Servus. Grüezi. Hallo.", author: nil,
                               artworkURL: nil, description: nil, feedURL: url,
                               episodes: (0..<episodes).map { i in
                                   PodcastEpisode(guid: "rss:\(key):ep\(i)", title: "E\(i)",
                                                  audioURL: "https://cdn.zeit.de/ep\(i).mp3",
                                                  pubDate: Double(1000 + i), duration: 60)
                               })
        }
        // Old entry (pre-rotation token, 3 episodes with history) + freshly
        // born full-backlog entry (rotated token, 413 episodes).
        let old = show("OLDTOKEN", episodes: 3)
        let fresh = show("NEWTOKEN", episodes: 413)
        var moves: [(String, String)] = []
        let (result, changed) = PodcastSubscriptions.migrate([old, fresh],
                                                             moveProgress: { moves.append(($0, $1)) })
        #expect(changed)
        #expect(result.count == 1, "the same masked identity must collapse to ONE entry")
        // The fuller entry survives (its URL carries the current token)…
        #expect(result.first?.feedURL.contains("NEWTOKEN") == true)
        // …and the old entry's episodes were re-keyed (progress rides along).
        let survivorKey = PodcastSubscriptions.feedKey(result.first!.feedURL)
        #expect(moves.contains { $0.1.hasPrefix("rss:\(survivorKey):") })
        // Episode union by original guid: 413 (old 3 are a subset).
        #expect(result.first?.episodes.count == 413)
        // Different masked identities never collapse (two providers).
        let other = show("X", episodes: 5)
        var otherShow = other
        otherShow = PodcastShow(id: other.id, title: other.title, author: nil, artworkURL: nil,
                                description: nil,
                                feedURL: "https://other-provider.example/rss?freebie=X",
                                episodes: other.episodes)
        let (two, _) = PodcastSubscriptions.migrate([show("A", episodes: 3), otherShow],
                                                    moveProgress: { _, _ in })
        #expect(two.count == 2)
    }

    @Test("e4b1467: twin offer once per PAIR; suppressed while identity twins exist")
    func twinOfferGuard() {
        let free = (id: "free", title: "Servus. Grüezi. Hallo.", feedURL: "https://feeds.simplecast.com/sgh")
        let p1 = (id: "p1", title: "Servus. Grüezi. Hallo.", feedURL: "https://premium-feed.zeit.de/sgh/rss-podcatcher?freebie=AAA")
        let p2 = (id: "p2", title: "Servus. Grüezi. Hallo.", feedURL: "https://premium-feed.zeit.de/sgh/rss-podcatcher?freebie=BBB")
        // Two premium copies of the SAME masked identity → offer suppressed.
        let guarded = PodcastPremiumMatch.twins(shows: [free, p1, p2],
                                                isPremium: { PodcastSubscriptions.isTokenFeedURL($0) })
        #expect(guarded.isEmpty, "no repair offer while the identity twins are uncollapsed")
        // After the collapse (one premium copy): exactly ONE offer.
        let offers = PodcastPremiumMatch.twins(shows: [free, p1],
                                               isPremium: { PodcastSubscriptions.isTokenFeedURL($0) })
        #expect(offers.count == 1)
        #expect(offers.first?.freeId == "free")
    }
}

/// 6446a04: the in-feed "do not list publicly" signal — channel level only,
/// both namespaces, case-tolerant; a platform-bounded block says nothing.
struct PodcastFeedBlockTests {
    @Test("itunes:block yes on channel level counts, case and whitespace tolerant")
    func itunesBlock() {
        #expect(PodcastFeedBlock.isBlocked(
            feedHead: "<rss><channel><title>X</title><itunes:block>Yes</itunes:block>"))
        #expect(PodcastFeedBlock.isBlocked(
            feedHead: "<channel><itunes:block>\n  yes\n</itunes:block>"))
        #expect(!PodcastFeedBlock.isBlocked(
            feedHead: "<channel><itunes:block>no</itunes:block>"))
        #expect(!PodcastFeedBlock.isBlocked(feedHead: "<channel><title>plain feed</title>"))
    }

    @Test("an EPISODE-level block means something else and never counts")
    func episodeBlockIgnored() {
        let feed = """
        <rss><channel><title>Public show</title>
        <item><title>Folge</title><itunes:block>yes</itunes:block></item>
        """
        #expect(!PodcastFeedBlock.isBlocked(feedHead: feed))
    }

    @Test("podcast:block: unbounded yes counts, a platform slug does not")
    func podcastBlock() {
        #expect(PodcastFeedBlock.isBlocked(
            feedHead: "<channel><podcast:block value=\"yes\"/>"))
        #expect(PodcastFeedBlock.isBlocked(
            feedHead: "<channel><podcast:block>yes</podcast:block>"))
        // Bounded to one directory ⇒ says nothing about the feed being private.
        #expect(!PodcastFeedBlock.isBlocked(
            feedHead: "<channel><podcast:block value=\"yes\" platform=\"amazon\"/>"))
        #expect(!PodcastFeedBlock.isBlocked(
            feedHead: "<channel><podcast:block value=\"no\"/>"))
    }

    @Test("the premium test reads the recorded signal; membership hosts stay data")
    func premiumTestUsesSignal() {
        let defaults = UserDefaults(suiteName: "feed-block-test")!
        defaults.removePersistentDomain(forName: "feed-block-test")
        let feed = "https://feeds.example.com/private/abc123/feed.xml"
        #expect(!PodcastSubscriptions.isFeedBlocked(feed, defaults: defaults))
        PodcastSubscriptions.noteFeedBlocked(feed, defaults: defaults)
        #expect(PodcastSubscriptions.isFeedBlocked(feed, defaults: defaults))
        // The path-token class the query-param heuristic cannot see.
        #expect(!PodcastSubscriptions.isTokenFeedURL(feed))
        // Membership hosters are recognised by host alone.
        #expect(PodcastSubscriptions.isPremiumFeed("https://steadyhq.com/feed/x"))
        #expect(PodcastSubscriptions.isPremiumFeed("https://api.supportingcast.fm/feed/1"))
        #expect(PodcastSubscriptions.isPremiumFeed("https://supercast.com/f/9"))
        defaults.removePersistentDomain(forName: "feed-block-test")
    }
}

/// 6bae86b: the reduced provider-token scope — the probe DISPROVED the
/// "one token for the whole provider" assumption (ZEIT hands out a token per
/// SHOW), so nothing anbieterweit was built. What has to hold instead: a
/// per-show podcatcher URL added by hand runs through the EXISTING chain.
/// Verified on the ZEIT URL *structure*; the real token values never appear
/// here (nor anywhere outside the device).
struct ProviderTokenChainTests {
    /// Same shape as the real thing, placeholder value.
    private let zeitPremium =
        "https://zeit.de/podcasts/servus-gruezi-hallo/rss-podcatcher?freebie=PLACEHOLDER"
    private let zeitFree = "https://feeds.simplecast.com/servus-gruezi-hallo"

    @Test("a per-show podcatcher URL is recognised and protected without any new mechanism")
    func recognisedAndProtected() {
        #expect(PodcastSubscriptions.isTokenFeedURL(zeitPremium))
        #expect(PodcastSubscriptions.isPremiumFeed(zeitPremium))
        #expect(!PodcastSubscriptions.isPremiumFeed(zeitFree))
        // The token value never shows up unmasked.
        #expect(!PodcastSubscriptions.maskedFeedURL(zeitPremium).contains("PLACEHOLDER"))
        // OPML export leaves it out (the same guard gpodder sync uses).
        let split = OPMLExport.partition(
            shows: [(title: "Servus", feedURL: zeitPremium),
                    (title: "Servus frei", feedURL: zeitFree)],
            isPremium: { PodcastSubscriptions.isPremiumFeed($0) })
        #expect(split.excluded.map(\.feedURL) == [zeitPremium])
        #expect(split.safe.map(\.feedURL) == [zeitFree])
    }

    @Test("the free subscription of the same show gets the existing replace offer")
    func twinOfferAgainstFreeShow() {
        let offers = PodcastPremiumMatch.twins(
            shows: [(id: "free", title: "Servus. Grüezi. Hallo.", feedURL: zeitFree),
                    (id: "premium", title: "Servus. Grüezi. Hallo.", feedURL: zeitPremium)],
            isPremium: { PodcastSubscriptions.isPremiumFeed($0) })
        #expect(offers.count == 1)
        #expect(offers.first?.freeId == "free")
        #expect(offers.first?.premiumId == "premium")
    }

    @Test("c493143: no 'one feed = one token' assumption is wired in")
    func formOpen() {
        // TWO shows of the same provider with DIFFERENT tokens stay two
        // independent premium feeds — the measured ZEIT form.
        let other = "https://zeit.de/podcasts/wie-war-das-noch-mal/rss-podcatcher?freebie=OTHER"
        #expect(PodcastSubscriptions.isPremiumFeed(other))
        #expect(PodcastSubscriptions.feedKey(other) != PodcastSubscriptions.feedKey(zeitPremium))
        // …and the OPPOSITE form (Patreon: one membership token, several
        // shows) is not excluded either: the SAME token in two feed URLs
        // yields two feeds, no collision, no merge.
        let patreonA = "https://www.patreon.com/rss/creator?auth=SAMETOKEN&show=a"
        let patreonB = "https://www.patreon.com/rss/creator?auth=SAMETOKEN&show=b"
        #expect(PodcastSubscriptions.isPremiumFeed(patreonA))
        #expect(PodcastSubscriptions.isPremiumFeed(patreonB))
        #expect(PodcastSubscriptions.feedKey(patreonA) != PodcastSubscriptions.feedKey(patreonB))
        // Neither form is a twin of the other (different shows, no offer).
        let offers = PodcastPremiumMatch.twins(
            shows: [(id: "a", title: "Show A", feedURL: patreonA),
                    (id: "b", title: "Show B", feedURL: patreonB)],
            isPremium: { PodcastSubscriptions.isPremiumFeed($0) })
        #expect(offers.isEmpty)
    }

    @Test("T2-Zaun: gespiegelter Feed traegt NIE Premium — auch mit Host-Credentials")
    func mirroredFeedIsNeverPremium() {
        let feedURL = "https://tube.example/sources/abc/feed.xml"
        let key = PodcastSubscriptions.feedKey(feedURL)
        // Host credentials from the server setup — exactly the class the
        // premium heuristic used to trip over (Befund T).
        PodcastFeedAuth.set(feedKey: key, user: "the implementer", password: "pw")
        defer { PodcastFeedAuth.remove(feedKey: key) }
        let defaults = UserDefaults(suiteName: "t2-zaun-\(UUID().uuidString)")!
        // Without membership the credentials DO mark premium (heuristic works)…
        #expect(PodcastSubscriptions.isPremiumFeed(feedURL, defaults: defaults))
        // …with origin-membership the ONE truth answers false — so the tile
        // lock, the premium row and the premium page all drop it (T3: the
        // double appearance dies with the same truth).
        defaults.set([key], forKey: AppStorageKeys.pinchflatMirroredFeedKeys)
        #expect(!PodcastSubscriptions.isPremiumFeed(feedURL, defaults: defaults))
    }

    @Test("78c5298-Zaun: origin ueberlebt den Refresh-Merge — auch wenn fresh die Base wird")
    func originSurvivesRefreshMerge() {
        func show(_ id: String, episodes: Int, origin: String? = nil) -> PodcastShow {
            var s = PodcastShow(id: id, title: "T", author: nil, artworkURL: nil,
                                description: nil, feedURL: "https://x/\(id)",
                                episodes: (0..<episodes).map {
                                    PodcastEpisode(guid: "\(id)-\($0)", title: "E\($0)",
                                                   audioURL: "https://x/\($0).mp3",
                                                   pubDate: Double($0), duration: 60,
                                                   description: nil, imageURL: nil,
                                                   chaptersURL: nil)
                                })
            s.origin = origin
            return s
        }
        let stored = show("a", episodes: 2, origin: "pinchflat:tube.example")
        // The normal first-refresh case: the fresh parse has MORE episodes,
        // becomes base — and used to drop the store-owned origin silently.
        let freshBigger = show("a", episodes: 5)
        #expect(PodcastSubscriptions.merge(stored, freshBigger).origin == "pinchflat:tube.example")
        // The other direction stays correct too.
        let freshSmaller = show("a", episodes: 1)
        #expect(PodcastSubscriptions.merge(stored, freshSmaller).origin == "pinchflat:tube.example")
        // An ordinary subscription never grows an origin out of nowhere.
        #expect(PodcastSubscriptions.merge(show("b", episodes: 2), show("b", episodes: 5)).origin == nil)
    }

    @Test("U4-Zaun: Artwork-Fehlschlag persistiert KEIN Negativ — naechster Aufruf versucht neu")
    func artworkFailureIsNotAbsence() async {
        let service = FeedArtworkService()
        let feed = "https://tube.example/sources/u4/feed.xml"
        let head = "<rss><channel><itunes:image href=\"https://tube.example/cover.jpg\"/></channel></rss>"
        // First call: the endpoint answers 401 (server connected before the
        // artwork switch) — a FAILURE, not "feed states no image".
        let poisoned = await service.artworkURL(feedURL: feed, fetch: { request in
            (Data("denied".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 401,
                             httpVersion: nil, headerFields: nil))
        })
        #expect(poisoned == nil)
        // Second call must TRY AGAIN (no cached/persisted negative) and win.
        let healed = await service.artworkURL(feedURL: feed, fetch: { request in
            (Data(head.utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil))
        })
        #expect(healed?.absoluteString == "https://tube.example/cover.jpg")
        // A successfully read head WITHOUT an image is the honest negative.
        let empty = await service.artworkURL(feedURL: "https://tube.example/none/feed.xml", fetch: { request in
            (Data("<rss></rss>".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil))
        })
        #expect(empty == nil)
    }

    @Test("S1: Schema-lose Pinchflat-Adressen normalisieren auf denselben Host")
    func pinchflatAddressNormalization() {
        let hosts = ["tube.x.y", "https://tube.x.y", "  tube.x.y  ", "http://tube.x.y"]
            .map { PinchflatClient.normalizedServerURL(from: $0)?.host }
        #expect(hosts == ["tube.x.y", "tube.x.y", "tube.x.y", "tube.x.y"])
        // Unusable input answers nil — the caller shows a form error and the
        // existing configuration stays (S2: no delete branch on save).
        #expect(PinchflatClient.normalizedServerURL(from: "   ") == nil)
        #expect(PinchflatClient.normalizedServerURL(from: "https://") == nil)
    }
}
#endif
