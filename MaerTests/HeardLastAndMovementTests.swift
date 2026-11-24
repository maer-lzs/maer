// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Two ends of a title. A title heard to its end leaves the standby (the
/// mini player offers nothing finished to continue), and the idle mini
/// player still names it as heard last, not "Nothing in Up Next". A
/// Musopen movement that ends with nothing in Up Next goes on to the next
/// movement of the same work, in the order of the Musopen page; what
/// waits in Up Next comes first, and the last movement ends.
struct HeardLastAndMovementTests {
    // MARK: Heard last

    @Test("measured: a title heard to its end is cleared from the standby, which left the idle bar empty")
    func theMechanism() {
        let verdict = PlayerCoordinator.standbyVerdict(
            stored: "mso:1", held: "mso:1", isPlaying: false, ownOpenedAtMs: 1, foreignStampMs: nil,
            heldFinished: true, storedFinished: true)
        #expect(verdict == .clearFinished)
        #expect(MiniBarFill.of(hasSession: false, waiting: [], lastPlayed: nil) == .empty, "before: the pointer alone fed the bar")
    }

    @Test("a title heard to its end with nothing waiting: the idle bar names it as heard last")
    func heardLastNamesTheEndedTitle() {
        #expect(MiniBarFill.of(hasSession: false, waiting: [], lastPlayed: nil, heardLast: "mso:1") == .lastPlayed("mso:1"))
        #expect(MiniBarFill.of(hasSession: false, waiting: ["sub:song:2"], lastPlayed: nil, heardLast: "mso:1") == .waiting("sub:song:2"),
                "what waits comes first")
        #expect(MiniBarFill.of(hasSession: false, waiting: [], lastPlayed: "abs:2", heardLast: "mso:1") == .lastPlayed("abs:2"),
                "the standby comes before what ended")
        #expect(MiniBarFill.of(hasSession: false, waiting: [], lastPlayed: nil, heardLast: nil) == .empty)
    }

    @Test("an empty bar says it once: no second line Up Next under Nothing in Up Next")
    func emptySaysItOnce() {
        #expect(IdleMiniBar.secondLine(.empty) == nil)
        #expect(IdleMiniBar.secondLine(.lastPlayed("x")) != nil)
        #expect(IdleMiniBar.secondLine(.waiting("x")) != nil)
    }

    @Test("Fence: both finished clears keep the title as heard last, the bar reads it, a close forgets it", .needsTheSources)
    func surfaces() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let coordinator = try source("Sources/ViewModels/PlayerCoordinator.swift")
        #expect(coordinator.components(separatedBy: "clearStandbyAsHeard(").count - 1 == 3,
                "the two finished clears and their one definition")
        let library = try source("Sources/Views/LibraryView.swift")
        #expect(library.contains("heardLast: AppStorageKeys.heardLastItemIdValue"), "the idle bar does not read what ended")
        #expect(UserChoiceCatalog.statics[AppStorageKeys.heardLastItemId] == .device, "what ended here is this device's")
    }

    // MARK: The next movement

    struct Recording: Equatable {
        let id: String
        let title: String
        let composer: String?
        var performer: String? = nil
    }

    static let brahms = [
        Recording(id: "mso:4", title: "Symphony No.3 in F major Op.90 - IV. Allegro", composer: "Johannes Brahms"),
        Recording(id: "mso:2", title: "Symphony No.3 in F major Op.90 - II. Andante", composer: "Johannes Brahms"),
        Recording(id: "mso:1", title: "Symphony No.3 in F major Op.90 - I. Allegro con brio", composer: "Johannes Brahms"),
        Recording(id: "mso:3", title: "Symphony No.3 in F major Op.90 - III. Poco allegretto", composer: "Johannes Brahms"),
        Recording(id: "mso:9", title: "Symphony No.4 in E minor Op.98 - I. Allegro non troppo", composer: "Johannes Brahms"),
        Recording(id: "mso:7", title: "Symphony No.3 in F major Op.90 - I. Allegro con brio", composer: "Ludwig van Beethoven"),
        Recording(id: "mso:8", title: "Symphony No.3 in F major Op.90 - II. Andante", composer: "Johannes Brahms",
                  performer: "Another Orchestra"),
        Recording(id: "mso:5", title: "Wiener Blut Op. 354", composer: "Johann Strauss"),
        Recording(id: "mso:6", title: "1st violin B 02", composer: nil),
    ]

    static func next(after id: String) -> String? {
        MusopenOrder.nextMovement(after: id, in: brahms, id: \.id, title: \.title,
                                  composer: \.composer, performer: \.performer)?.id
    }

    @Test("a middle movement goes on to the next of the same work, in the order of the page; the last ends")
    func nextMovement() {
        #expect(Self.next(after: "mso:1") == "mso:2")
        #expect(Self.next(after: "mso:2") == "mso:3")
        #expect(Self.next(after: "mso:3") == "mso:4")
        #expect(Self.next(after: "mso:4") == nil, "the last movement ends, no other work follows")
        #expect(Self.next(after: "mso:5") == nil, "a piece without movements ends")
        #expect(Self.next(after: "mso:6") == nil, "a single part of an orchestra recording ends")
        #expect(Self.next(after: "mso:7") == nil, "another composer's work of the same name is not this work")
        #expect(Self.next(after: "mso:404") == nil)
        // The order is the page's: the movements stand there in this order.
        let page = MusopenOrder.ordered(Self.brahms.filter { $0.composer == "Johannes Brahms" && $0.performer == nil },
                                        title: \.title, composer: \.composer).map(\.id)
        #expect(page.prefix(4) == ["mso:1", "mso:2", "mso:3", "mso:4"])
        #expect(MusopenOrder.workStem("Symphony No.3 in F major Op.90 - IV. Allegro") == MusopenOrder.workStem("Symphony No.3 in F major Op.90 - I. Allegro con brio"))
        #expect(MusopenOrder.workStem("Wiener Blut Op. 354") == nil)
    }

    @Test("Up Next comes before the next movement; with nothing waiting the movement follows")
    func upNextFirst() {
        func resolve(queue: [String]) -> (id: String, origin: PlaybackAdvance.Origin)? {
            PlaybackAdvance.resolveNext(after: "mso:1", queueIds: queue, contextIds: [],
                                        isPlayable: { _ in true }, resolves: { _ in true },
                                        isPodcast: { _ in false }, bingeNext: { _ in nil },
                                        workNext: { Self.next(after: $0) },
                                        seriesEnabled: true, seriesNext: { _ in "abs:series" })
        }
        #expect(resolve(queue: ["sub:song:9"])?.id == "sub:song:9")
        #expect(resolve(queue: [])?.id == "mso:2")
        #expect(resolve(queue: [])?.origin == .work)
    }

    @Test("Fence: the advance asks the catalog for the next movement", .needsTheSources)
    func advanceAsks() throws {
        let coordinator = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/ViewModels/PlayerCoordinator.swift"), encoding: .utf8))
        #expect(coordinator.contains("FreeCatalogProvider.shared.nextMovement(after: id)"))
    }
}
#endif
