// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The link on maer.fm: its form, reading it back, and the one rule that
/// decides what may be shared and what a link may open.
struct SharedLinkTests {
    static let feed = "https://feeds.example.org/show.xml"
    static let audio = "https://cdn.example.org/ep-214.mp3"
    static let uuid = "9617a958-0601-11e8-ae97-52543be04c81"
    static let open: (String) -> Bool = { _ in false }

    static let episode = SharedLink.Content.episode(
        feedURL: feed, guid: "tag:example.org,2026:214",
        .init(title: "Folge 214: Radio & wir", subtitle: "Medien", audioURL: audio,
              coverURL: "https://cdn.example.org/cover-214.jpg"))
    static let show = SharedLink.Content.show(feedURL: feed, .init(title: "Medien", subtitle: "Ein Verlag"))
    static let station = SharedLink.Content.station(
        uuid: uuid, .init(title: "Deutschlandfunk", audioURL: "https://st01.example.de/dlf.mp3"))
    static let book = SharedLink.Content.book(
        itemId: "lv:1234", .init(title: "Die Verwandlung", subtitle: "Franz Kafka",
                                 audioURL: "https://archive.org/download/x/x_01.mp3"))
    static let jamendoTrack = SharedLink.Content.track(
        itemId: "jam:1848357", .init(title: "Abendlicht", subtitle: "Die Kapelle"))
    static let archiveSong = SharedLink.Content.track(
        itemId: "lva:78_abendlied_georgeblood#2", .init(title: "Abendlied", subtitle: "Ein Orchester",
                                                     audioURL: "https://archive.org/download/x/x_02.mp3"))
    static let all = [episode, show, station, book, jamendoTrack, archiveSong]

    @Test("Jede Art kommt aus ihrem Link unveraendert zurueck")
    func everyKindReadsBack() throws {
        for content in Self.all {
            let url = try #require(SharedLink.url(for: content))
            #expect(SharedLink.read(url) == content)
        }
    }

    @Test("Alles steht hinter dem #, lesbar, in fester Reihenfolge")
    func theFormKeepsEverythingBehindTheHash() throws {
        let url = try #require(SharedLink.url(for: Self.show))
        #expect(url.absoluteString == "https://maer.fm/l/#1?k=s&f=https%3A%2F%2Ffeeds.example.org%2Fshow.xml&t=Medien&s=Ein%20Verlag")
        #expect(url.query == nil)
        #expect(url.path(percentEncoded: true) == "/l/")
    }

    @Test("Zeichen, die die Query trennen, ueberstehen den Rundlauf")
    func separatorsSurviveTheRoundTrip() throws {
        let title = "A&B=C #1 + 2 ? ü 🎧 %20"
        let content = SharedLink.Content.episode(feedURL: Self.feed + "?a=1&b=2", guid: "g&=#",
                                                 .init(title: title, subtitle: nil, audioURL: nil))
        let url = try #require(SharedLink.url(for: content))
        #expect(SharedLink.read(url) == content)
        #expect(SharedLink.read(url)?.facts.title == title)
    }

    @Test("Ein Link einer anderen Form liest sich als nichts")
    func anotherFormReadsAsNothing() throws {
        let good = try #require(SharedLink.url(for: Self.station)).absoluteString
        let fragment = String(good.split(separator: "#", maxSplits: 1)[1])
        let refused = [
            "https://example.org/l#" + fragment,
            "http://maer.fm/l#" + fragment,
            "https://maer.fm/x#" + fragment,
            "https://maer.fm/l//#" + fragment,
            "https://maer.fm/l/x#" + fragment,
            "https://maer.fm/lx#" + fragment,
            "https://maer.fm/L/#" + fragment,
            "https://maer.fm/l/?k=r#" + fragment,
            "https://maer.fm/l?k=r#" + fragment,
            "https://maer.fm/l#2" + fragment.dropFirst(),
            "https://maer.fm/l",
            "https://maer.fm/l#1?k=r&i=\(Self.uuid)&i=\(Self.uuid)",
            "https://maer.fm/l#1?k=e&f=\(Self.feed)",
            "https://maer.fm/l#1?k=s",
            "https://maer.fm/l#1?k=x&i=\(Self.uuid)",
            "https://maer.fm/l#1?k=r&i=%20",
            "https://maer.fm/l#1?k=r&i",
            "https://maer.fm/l#1?k=r&i=\(Self.uuid)&t=" + String(repeating: "a", count: SharedLink.longestFragment),
        ]
        for text in refused {
            let url = try #require(URL(string: text), "\(text)")
            #expect(SharedLink.read(url) == nil, "\(text)")
        }
        // The instrument sees the difference: the same fragment on the right
        // address reads.
        #expect(SharedLink.read(try #require(URL(string: "https://MAER.fm/l#" + fragment))) == Self.station)
        #expect(SharedLink.read(try #require(URL(string: "https://MAER.fm/l/#" + fragment))) == Self.station)
    }

    @Test("Ein Link liest sich mit und ohne Schraegstrich, geschrieben wird er mit")
    func bothFormsOfThePathRead() throws {
        for content in Self.all {
            let written = try #require(SharedLink.url(for: content))
            #expect(written.absoluteString.hasPrefix("https://maer.fm/l/#1?"), "\(written)")
            let fragment = try #require(written.fragment(percentEncoded: true))
            let withSlash = try #require(URL(string: "https://maer.fm/l/#" + fragment))
            let withoutSlash = try #require(URL(string: "https://maer.fm/l#" + fragment))
            #expect(SharedLink.read(withSlash) == content, "with the slash: \(content)")
            #expect(SharedLink.read(withoutSlash) == content, "without the slash: \(content)")
        }
    }

    @Test("Was teilbar ist, je Art")
    func whatMayBeShared() {
        for content in Self.all {
            #expect(SharedLink.offers(content, staysHome: Self.open), "\(content)")
        }
    }

    @Test("Ein Feed, der zu Hause bleibt, ist nie teilbar, Folge wie Sendung")
    func aFeedThatStaysHomeIsNeverShared() {
        let home: (String) -> Bool = { $0 == Self.feed }
        #expect(!SharedLink.offers(Self.episode, staysHome: home))
        #expect(!SharedLink.offers(Self.show, staysHome: home))
        // The real question of the export: a token, a user before the host.
        for feed in ["https://feeds.example.org/show.xml?token=abc", "https://user:pw@feeds.example.org/show.xml"] {
            #expect(PodcastSubscriptions.staysHome(feed, ownHosts: []))
            #expect(!SharedLink.offers(.show(feedURL: feed, .init()), staysHome: { PodcastSubscriptions.staysHome($0, ownHosts: []) }))
        }
        // An own server's host stays home with nothing in the address.
        #expect(!SharedLink.offers(.show(feedURL: "https://pod.home.example/feed", .init()),
                                   staysHome: { PodcastSubscriptions.staysHome($0, ownHosts: ["pod.home.example"]) }))
    }

    @Test("Eine Adresse mit Zugang oder fremdem Schema oeffnet nichts, je Art")
    func anAddressWithAccessOpensNothing() throws {
        let tainted = ["https://cdn.example.org/a.mp3?token=s3cr3t", "https://u:p@cdn.example.org/a.mp3",
                       "javascript:alert(1)", "file:///etc/hosts", "cdn.example.org/a.mp3"]
        for content in Self.all {
            for audio in tainted {
                var facts = content.facts
                facts.audioURL = audio
                let changed = content.with(facts)
                // Written by hand and read back, as a link from outside arrives.
                let url = try #require(SharedLink.url(for: changed))
                let read = try #require(SharedLink.read(url))
                #expect(!SharedLink.offers(read, staysHome: Self.open), "\(audio) in \(content)")
            }
        }
        #expect(!SharedLink.offers(.episode(feedURL: "ftp://feeds.example.org/x", guid: "g", .init()), staysHome: Self.open))
    }

    @Test("Ein Cover mit Zugang oder fremdem Schema im Link oeffnet nichts, je Art")
    func aCoverWithAccessOpensNothing() throws {
        let tainted = ["https://cdn.example.org/c.jpg?token=s3cr3t", "https://u:p@cdn.example.org/c.jpg",
                       "javascript:alert(1)", "file:///etc/hosts"]
        for content in Self.all {
            #expect(SharedLink.offers(content, staysHome: Self.open), "the precondition: \(content) is shared")
            for cover in tainted {
                var facts = content.facts
                facts.coverURL = cover
                // Written by hand and read back, as a link from outside arrives.
                let url = try #require(SharedLink.url(for: content.with(facts)))
                let read = try #require(SharedLink.read(url))
                #expect(read.facts.coverURL == cover, "the precondition: the link carries the cover")
                #expect(!SharedLink.offers(read, staysHome: Self.open), "\(cover) in \(content)")
            }
        }
    }

    @Test("Das Cover der Seite kommt nur als oeffentliche https-Adresse in den Link, sonst ohne Cover")
    func onlyAPublicHttpsCoverEntersTheLink() throws {
        let cover = "https://cdn.example.org/show.jpg"
        for content in Self.all {
            #expect(SharedLink.withCover(content, cover: cover)?.facts.coverURL == cover, "\(content)")
            #expect(SharedLink.withCover(content, cover: cover)?.with(content.facts) == content,
                    "the cover changes more than the cover")
            for other in [nil, "http://cdn.example.org/show.jpg", "https://cdn.example.org/show.jpg?token=s3cr3t",
                          "https://u:p@cdn.example.org/show.jpg", "file:///var/cover.jpg", ""] {
                let shared = try #require(SharedLink.withCover(content, cover: other))
                #expect(shared.facts.coverURL == nil, "\(String(describing: other)) entered the link")
                #expect(SharedLink.offers(shared, staysHome: Self.open), "a cover left out keeps \(content) from sharing")
            }
        }
        #expect(SharedLink.withCover(nil, cover: cover) == nil)
        let url = try #require(SharedLink.shareURL(SharedLink.withCover(Self.show, cover: cover), staysHome: Self.open))
        #expect(url.absoluteString.hasSuffix("&c=https%3A%2F%2Fcdn.example.org%2Fshow.jpg"), "\(url)")
    }

    @Test("Ein Sender nur mit uuid, ein Buch nur aus einem Buchkatalog")
    func stationsAndBooksByTheirIdentity() {
        #expect(!SharedLink.offers(.station(uuid: "manual:1234", .init()), staysHome: Self.open))
        for id in ["jam:42", "lva:collection#3", "local:/x.m4b", "abc123", "sub:album:9", "lv:", "rss:k:g"] {
            #expect(!SharedLink.offers(.book(itemId: id, .init()), staysHome: Self.open), "\(id)")
        }
        for id in ["lv:1234", "lva:dieverwandlung_1001_librivox", "gut:5200"] {
            #expect(SharedLink.offers(.book(itemId: id, .init()), staysHome: Self.open), "\(id)")
        }
    }

    @Test("Ein Musiktitel nur aus Jamendo oder als Lied einer archive.org-Veroeffentlichung, Jamendo nie mit Strom")
    func tracksByTheirIdentity() {
        for id in ["jam:1848357", "lva:78_abendlied_georgeblood#0", "lva:netlabel-release#12"] {
            #expect(SharedLink.offers(.track(itemId: id, .init()), staysHome: Self.open), "\(id)")
        }
        for id in ["jam:", "jam:12a", "jam:-1", "jam:１２", "lva:release", "lva:#3", "lva:release#a", "lva:a#b#3",
                   "lv:1234#2", "gut:5200#1", "sub:album:9#1", "local:/x.mp3", "1848357"] {
            #expect(!SharedLink.offers(.track(itemId: id, .init()), staysHome: Self.open), "\(id)")
        }
        // A Jamendo stream address never travels; an archive.org song plays
        // from its public address.
        #expect(!SharedLink.offers(.track(itemId: "jam:1848357", .init(audioURL: "https://prod-1.storage.jamendo.com/?trackid=1848357")),
                                   staysHome: Self.open))
        #expect(SharedLink.offers(Self.archiveSong, staysHome: Self.open))
        // The precondition: the same ids are not books.
        #expect(!SharedLink.offers(.book(itemId: "jam:1848357", .init()), staysHome: Self.open))
        #expect(!SharedLink.offers(.book(itemId: "lva:78_abendlied_georgeblood#2", .init()), staysHome: Self.open))
    }

    @Test("Ein Musiktitel aus der App: Jamendo ohne Strom, archive.org mit, jeder andere Titel nicht")
    func musicTracksBecomeLinks() {
        #expect(SharedLink.content(trackId: "jam:1848357", title: "Abendlicht", artist: "Die Kapelle",
                                   audioURL: "https://prod-1.storage.jamendo.com/?trackid=1848357")
                == Self.jamendoTrack)
        #expect(SharedLink.content(trackId: "lva:78_abendlied_georgeblood#2", title: "Abendlied", artist: "Ein Orchester",
                                   audioURL: "https://archive.org/download/x/x_02.mp3")
                == Self.archiveSong)
        for id in ["sub:song:1", "lva:78_abendlied_georgeblood", "lv:1234", "local:/x.mp3"] {
            #expect(SharedLink.content(trackId: id, title: "T", artist: nil, audioURL: nil) == nil, "\(id)")
        }
    }

    @Test("Aus den Dingen der App: nur Feed, Radio Browser und Buchkatalog")
    func onlyPublicThingsBecomeLinks() {
        let rss = PodcastEpisode(guid: "rss:k1:tag:example.org,2026:214", title: "Folge 214",
                                 audioURL: Self.audio, pubDate: 1, duration: 60)
        #expect(SharedLink.content(episode: rss, feedURL: Self.feed, showTitle: "Medien")
                == .episode(feedURL: Self.feed, guid: "tag:example.org,2026:214",
                            .init(title: "Folge 214", subtitle: "Medien", audioURL: Self.audio)))
        let server = PodcastEpisode(guid: "abspod:s:e1", title: "S", audioURL: "/api/items/s/file", pubDate: 1, duration: 60)
        #expect(SharedLink.content(episode: server, feedURL: Self.feed, showTitle: nil) == nil)

        let feedShow = PodcastShow(id: "feed:k1", title: "Medien", author: "Verlag", artworkURL: nil,
                                   description: nil, feedURL: Self.feed, episodes: [])
        #expect(SharedLink.content(show: feedShow) == .show(feedURL: Self.feed, .init(title: "Medien", subtitle: "Verlag")))
        let serverShow = PodcastShow(id: "abspod:server-1", title: "S", author: nil, artworkURL: nil,
                                     description: nil, feedURL: Self.feed, episodes: [])
        #expect(SharedLink.content(show: serverShow) == nil)

        let rb = RadioStation(id: "radio:rb:\(Self.uuid)", name: "DLF", streamURL: "https://s/dlf")
        #expect(SharedLink.content(station: rb) == .station(uuid: Self.uuid, .init(title: "DLF", audioURL: "https://s/dlf")))
        let manual = RadioStation(id: "radio:manual:\(Self.uuid)", name: "Heim", streamURL: "http://192.168.1.2/stream")
        #expect(SharedLink.content(station: manual) == nil)

        #expect(SharedLink.content(bookId: "jam:42", title: "Lied", author: nil, audioURL: nil) == nil)
        #expect(SharedLink.content(bookId: "gut:5200", title: "B", author: "A", audioURL: nil)
                == .book(itemId: "gut:5200", .init(title: "B", subtitle: "A")))
    }

    @Test("Die Kennungen der App aus einem Link")
    func theAppIdsOfALink() {
        #expect(SharedLink.stationId(uuid: Self.uuid) == "radio:rb:\(Self.uuid)")
        let id = SharedLink.episodeId(feedURL: Self.feed, guid: "tag:example.org,2026:214")
        #expect(ItemNamespace.isRSS(id))
        #expect(PodcastIdentity.originalGuid(id) == "tag:example.org,2026:214")
        #expect(id == "rss:\(PodcastIdentity.feedKey(Self.feed)):tag:example.org,2026:214")
    }

    @Test("Der Link einer Seite: keiner ohne Inhalt, keiner fuer etwas, das zu Hause bleibt, sonst der Link der Regel")
    func thePageLinkFollowsTheRule() throws {
        #expect(SharedLink.shareURL(nil, staysHome: Self.open) == nil)
        #expect(SharedLink.shareURL(Self.show, staysHome: { _ in true }) == nil)
        #expect(SharedLink.shareURL(Self.show, staysHome: Self.open) == SharedLink.url(for: Self.show))
    }

    /// The seam: the link is written in one place, a page shares through
    /// the one button, and the system's share link stands only where it is
    /// known to stand.
    @Test("Zaun: der Link entsteht nur in SharedLink, geteilt wird ueber den einen Knopf auf den fuenf Seiten", .needsTheSources)
    func theLinkHasOneHome() throws {
        var writesTheLink: Set<String> = []
        var systemShareLink: Set<String> = []
        var usesTheButton: Set<String> = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            let name = file.lastPathComponent
            if code.contains("maer.fm/l") || code.contains("\"/l\"") || code.contains("\"/l/\"") || code.contains("/l#")
                || code.contains("/l/#") { writesTheLink.insert(name) }
            if code.contains("ShareLink(") { systemShareLink.insert(name) }
            if code.contains("SharedLinkButton(") { usesTheButton.insert(name) }
        }
        #expect(writesTheLink == ["SharedLink.swift"], "the link is written elsewhere: \(writesTheLink.sorted())")
        #expect(systemShareLink == ["SharedLinkButton.swift", "PodcastSourceView.swift", "MetricRecordsView.swift"],
                "a share link stands past the one button: \(systemShareLink.sorted())")
        #expect(usesTheButton == ["PodcastEpisodeDetailView.swift", "PodcastShowView.swift",
                                  "RadioStationDetailView.swift", "BookDetailScreen.swift", "CatalogSourcePage.swift"],
                "the pages that share: \(usesTheButton.sorted())")
        // The catalog page shares a music track by its id alone; the stream
        // address of a Jamendo track never reaches the link from there.
        let catalog = SourceTree.root.appendingPathComponent("Sources/Views/CatalogSourcePage.swift")
        let catalogCode = SyncContractFenceTests.stripped(try String(contentsOf: catalog, encoding: .utf8))
        #expect(catalogCode.contains("SharedLink.content(trackId: itemId, title: title, artist: metadata.authorName, audioURL: nil)"),
                "the catalog page builds its link otherwise")
    }
}
#endif
