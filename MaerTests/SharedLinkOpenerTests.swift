// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// What a link opens in the app: each kind its content, and a link that
/// names a private feed or an address with access nothing, without asking.
@MainActor
struct SharedLinkOpenerTests {
    static let feed = "https://feeds.example.org/show.xml"
    static let uuid = "9617a958-0601-11e8-ae97-52543be04c81"

    /// The seams, with a record of what was asked.
    final class Ways {
        var known: Set<String> = []
        var browsed: [String] = []
        var loadsOnBrowse: Set<String> = []
        var feedHolds: [String: String] = [:]
        var books: Set<String> = []
        var stayHome: Set<String> = []
        var stations: [String: RadioStation] = [:]
        var stationsAsked: [String] = []

        func opener() -> SharedLinkOpener {
            SharedLinkOpener(
                staysHome: { [self] in stayHome.contains($0) },
                knows: { [self] in known.contains($0) },
                browse: { [self] feed in
                    browsed.append(feed)
                    if let id = feedHolds[feed] { known.insert(id) }
                    return loadsOnBrowse.contains(feed)
                },
                resolveCatalog: { [self] in books.contains($0) },
                resolveStation: { [self] uuid in
                    stationsAsked.append(uuid)
                    return stations[uuid].map { .found($0) } ?? .unknown
                })
        }
    }

    private func link(_ content: SharedLink.Content) throws -> URL {
        try #require(SharedLink.url(for: content))
    }

    @Test("Episode: a known one opens, one from a foreign feed opens after reading, a vanished one opens its show")
    func anEpisodeOpensItselfOrItsShow() async throws {
        let content = SharedLink.Content.episode(feedURL: Self.feed, guid: "g-214", .init(title: "T"))
        let id = SharedLink.episodeId(feedURL: Self.feed, guid: "g-214")

        let known = Ways()
        known.known = [id]
        #expect(await known.opener().outcome(for: try link(content)) == .episode(itemId: id))
        #expect(known.browsed.isEmpty, "a known episode read its feed")

        let browsed = Ways()
        browsed.loadsOnBrowse = [Self.feed]
        browsed.feedHolds = [Self.feed: id]
        #expect(await browsed.opener().outcome(for: try link(content)) == .episode(itemId: id))
        #expect(browsed.browsed == [Self.feed])

        let gone = Ways()
        gone.loadsOnBrowse = [Self.feed]
        #expect(await gone.opener().outcome(for: try link(content)) == .show(feedURL: Self.feed))

        let unreadable = Ways()
        #expect(await unreadable.opener().outcome(for: try link(content)) == .show(feedURL: Self.feed))
    }

    @Test("Show, station and audiobook open what they name")
    func showStationAndBookOpenWhatTheyName() async throws {
        let ways = Ways()
        ways.books = ["lv:1234"]
        let catalog = RadioStation(id: "radio:rb:\(Self.uuid)", name: "DLF", streamURL: "https://s.example/dlf")
        ways.stations = [Self.uuid: catalog]
        let opener = ways.opener()
        #expect(await opener.outcome(for: try link(.show(feedURL: Self.feed, .init(title: "S")))) == .show(feedURL: Self.feed))
        let station = await opener.outcome(for: try link(.station(uuid: Self.uuid, .init(title: "DLF", audioURL: "https://s.example/dlf"))))
        #expect(station == .station(catalog))
        #expect(await opener.outcome(for: try link(.book(itemId: "lv:1234", .init(title: "B")))) == .book(itemId: "lv:1234"))
        #expect(await opener.outcome(for: try link(.book(itemId: "lv:9999", .init(title: "B")))) == .refused(reason: "bookUnknown"))
        #expect(await opener.outcome(for: try link(.station(uuid: Self.uuid, .init(title: "DLF")))) == .station(catalog),
                "a station link without a stream opens the catalog's station")
        let unknown = Ways()
        #expect(await unknown.opener().outcome(for: try link(.station(uuid: Self.uuid, .init(title: "DLF", audioURL: "https://s.example/dlf"))))
                == .refused(reason: "stationUnknown"))
    }

    @Test("A music title opens when the catalog finds it: Jamendo and a song from archive.org; an unknown one does not")
    func aMusicTrackOpensWhenTheCatalogFindsIt() async throws {
        let ways = Ways()
        ways.books = ["jam:1848357", "lva:release_x#2"]
        let opener = ways.opener()
        #expect(await opener.outcome(for: try link(.track(itemId: "jam:1848357", .init(title: "T"))))
                == .track(itemId: "jam:1848357"))
        #expect(await opener.outcome(for: try link(.track(itemId: "lva:release_x#2", .init(title: "T"))))
                == .track(itemId: "lva:release_x#2"))
        #expect(await opener.outcome(for: try link(.track(itemId: "jam:42", .init(title: "T"))))
                == .refused(reason: "trackUnknown"))
    }

    @Test("A music title opens its page by the catalog's rule, a song its release; a refusal opens none")
    func aMusicTrackOpensItsPage() {
        guard case .catalogAlbum(let jamendo) = SharedLinkOpener.target(of: .track(itemId: "jam:1848357")) else {
            Issue.record("a Jamendo track does not open its catalog page"); return
        }
        #expect(jamendo == "jam:1848357")
        guard case .catalogAlbum(let release) = SharedLinkOpener.target(of: .track(itemId: "lva:release_x#2")) else {
            Issue.record("a song does not open its release"); return
        }
        #expect(release == "lva:release_x")
        guard case .catalogBook(let book) = SharedLinkOpener.target(of: .book(itemId: "lv:1234")) else {
            Issue.record("a book does not open its page"); return
        }
        #expect(book == "lv:1234")
        #expect(SharedLinkOpener.target(of: .refused(reason: "form")) == nil)
    }

    @Test("Fence: a link shows and starts no playback", .needsTheSources)
    func aLinkNeverStartsPlayback() throws {
        let file = SourceTree.root.appendingPathComponent("Sources/ViewModels/SharedLinkOpener.swift")
        let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
        #expect(code.contains("PlayerSourceRouter.shared.open(target)"), "the precondition: the opener navigates")
        let playing = ["playerCoordinator", "PlayerCoordinator", "PlayerViewModel", ".play(", "playItem", "startPlayback"]
            .filter { code.contains($0) }
        #expect(playing.isEmpty, "the opener starts playback: \(playing)")
    }

    @Test("A hand-built link with a feed that stays at home, or an address with access, opens nothing, per kind, without asking")
    func aLinkAroundSomethingPrivateOpensNothing() async throws {
        let tainted = "https://cdn.example.org/a.mp3?token=s3cr3t"
        let contents: [SharedLink.Content] = [
            .episode(feedURL: Self.feed, guid: "g", .init(audioURL: tainted)),
            .show(feedURL: Self.feed + "?auth=x", .init()),
            .station(uuid: Self.uuid, .init(title: "Heim", audioURL: tainted)),
            .book(itemId: "lv:1234", .init(audioURL: tainted)),
        ]
        for content in contents {
            let ways = Ways()
            ways.known = [SharedLink.episodeId(feedURL: Self.feed, guid: "g")]
            ways.books = ["lv:1234"]
            #expect(await ways.opener().outcome(for: try link(content)) == .refused(reason: "notShared"), "\(content)")
            #expect(ways.browsed.isEmpty, "a refused link read a feed: \(content)")
        }
        let home = Ways()
        home.stayHome = [Self.feed]
        home.known = [SharedLink.episodeId(feedURL: Self.feed, guid: "g")]
        #expect(await home.opener().outcome(for: try link(.episode(feedURL: Self.feed, guid: "g", .init()))) == .refused(reason: "notShared"))
        #expect(await home.opener().outcome(for: try link(.show(feedURL: Self.feed, .init()))) == .refused(reason: "notShared"))
        #expect(home.browsed.isEmpty)
        // Another form on the right host opens nothing either.
        let other = try #require(URL(string: "https://maer.fm/l#2?k=s&f=x"))
        #expect(await Ways().opener().outcome(for: other) == .refused(reason: "form"))
    }
}
#endif
