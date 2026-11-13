// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
import UIKit
@testable import Maer

/// Die Bild-Tuer sagt, ob sie ein Bild hat, ob die Adresse keines nennt,
/// oder ob sie nichts gelernt hat. Nur das saubere Nein darf jemand als
/// „kein Bild“ merken; alles andere wird beim naechsten Mal wieder gefragt.
///
/// `.serialized`: several cases set the one disk hook of the shared cache
/// (`ImageCache.shared.testDiskHold`); run side by side, one case's hook
/// replaced another's, and that case waited for a hold that never came.
@Suite(.serialized)
struct ArtworkVerdictTests {
    private static func name(_ verdict: Artwork.Verdict) -> String {
        switch verdict {
        case .picture(let answer): return "picture:\(answer.pot)"
        case .absent: return "absent"
        case .unanswered: return "unanswered"
        }
    }

    private static func url(_ stand: BulkImportTests.Stand, _ name: String) -> URL {
        URL(string: "http://127.0.0.1:\(stand.port)/\(name)-\(UUID().uuidString).png")!
    }

    private static func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    /// A picture exactly `pixels` wide, so the old and the new cover can be
    /// told apart on disk.
    private static func png(pixels: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: pixels, height: pixels)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// The persistent copy's width once the background write landed.
    private static func persistentWidth(_ url: URL, becomes width: Int) async throws -> Int? {
        for _ in 0..<40 {
            if persistentWidth(url) == width { return width }
            try await Task.sleep(for: .milliseconds(50))
        }
        return persistentWidth(url)
    }

    /// The persistent copy's pixel width, nil without one.
    private static func persistentWidth(_ url: URL) -> Int? {
        guard let data = ImageCache.shared.testPersistentBytes(url), let image = UIImage(data: data) else { return nil }
        return Int(image.size.width * image.scale)
    }

    /// The measured defect: pull-to-refresh on the music tab invalidated a
    /// downloaded album's cover, but the read paths found the persistent
    /// copy first, so the old cover stayed for good. Now the next display
    /// asks the server, and its picture replaces the persistent copy.
    @Test("nach einer Invalidierung zeigt ein geschuetztes Cover das Bild vom Server und steht danach geschuetzt als neues")
    func anInvalidatedKeptCoverIsReplacedByTheServer() async throws {
        let served = try await BulkImportTests.Stand.start(.answer(status: 200, body: Self.png(pixels: 24)))
        defer { served.stop() }
        let url = Self.url(served, "kept")
        #expect(ImageCache.shared.testPlacePersistent(Self.png(pixels: 8), for: url), "the precondition: an old kept cover")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        #expect(Self.name(await Artwork.verdict(for: url)) == "picture:full", "the precondition: the kept cover answers")
        // The write ends after the replaced file lands: the address stops
        // waiting one step later, so the witness waits for the write's end.
        let key = ImageCache.shared.testKey(for: url)
        let (written, writtenGo) = AsyncStream<Void>.makeStream()
        ImageCache.shared.testDiskHold = { stage, fileKey in
            if stage == "written", fileKey == key { writtenGo.yield() }
        }
        defer { ImageCache.shared.testDiskHold = nil }
        Artwork.invalidate(url)
        // The count in the message tells a failure apart: 0 means no request
        // reached the stand (the test host), more means the stand was asked
        // and its answer did not arrive.
        let fresh = Self.name(await Artwork.verdict(for: url))
        #expect(fresh == "picture:net",
                "the old kept cover answered after the invalidation: \(fresh), the stand was asked \(served.requestCount) times")
        try #require(await Self.arrives(written), "the precondition: the write finished")
        #expect(Self.persistentWidth(url) == 24, "the server's picture did not replace the kept one")
        #expect(!ImageCache.shared.testIsRefreshing(url), "the address still waits for the network")
    }

    /// Offline, or with a server that fails, the kept cover is not lost: it
    /// stays on disk and on screen, and the next display asks again.
    @Test("scheitert das Laden nach einer Invalidierung, bleibt das alte geschuetzte Cover stehen und sichtbar")
    func aFailedLoadKeepsTheOldCover() async throws {
        let broken = try await BulkImportTests.Stand.start(.answer(status: 403, body: Data()))
        defer { broken.stop() }
        let url = Self.url(broken, "kept-broken")
        #expect(ImageCache.shared.testPlacePersistent(Self.png(pixels: 8), for: url), "the precondition: an old kept cover")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        Artwork.invalidate(url)
        #expect(Self.name(await Artwork.verdict(for: url)) == "picture:kept", "a failed load left the placeholder")
        #expect(await broken.settledCount(expected: 2) == 2, "the server was not asked")
        #expect(Self.persistentWidth(url) == 8, "the kept cover was lost")
        #expect(ImageCache.shared.testIsRefreshing(url), "the next display does not ask again")
    }

    /// CarPlay and the widget read without the network (`Artwork.thumbnail`):
    /// after an invalidation they still get the kept picture, and their read
    /// does not answer the network gate's next look in its place.
    @Test("nach einer Invalidierung liefert der Leseweg ohne Netz die geschuetzte Fassung, und das Netz-Tor fragt trotzdem den Server")
    func aReaderWithoutTheNetworkStillGetsTheKeptCover() async throws {
        let served = try await BulkImportTests.Stand.start(.answer(status: 200, body: Self.png(pixels: 24)))
        defer { served.stop() }
        let url = Self.url(served, "kept-reader")
        #expect(ImageCache.shared.testPlacePersistent(Self.png(pixels: 8), for: url), "the precondition: an old kept cover")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        Artwork.invalidate(url)
        let read = await Artwork.thumbnail(for: url, maxPixel: 100)
        #expect(read.map { Int($0.size.width * $0.scale) } == 8, "CarPlay and the widget lost the kept cover")
        #expect(Self.name(await Artwork.verdict(for: url, thumbnail: 100)) == "picture:net", "the reader's look answered the network gate")
        #expect(try await Self.persistentWidth(url, becomes: 24) == 24)
    }

    /// An answer to a request that left before the invalidation is the old
    /// picture: it does not become the new kept copy, and the address keeps
    /// waiting for a fresh one.
    @Test("eine Antwort, die vor der Invalidierung losging, wird nicht die neue geschuetzte Fassung")
    func anAnswerOlderThanTheInvalidationIsNotKept() async throws {
        let url = URL(string: "http://127.0.0.1:9/stale-\(UUID().uuidString).png")!
        #expect(ImageCache.shared.testPlacePersistent(Self.png(pixels: 8), for: url), "the precondition: an old kept cover")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        let startedAt = ImageCache.shared.invalidationCount(for: url)
        Artwork.invalidate(url)
        let stale = Self.png(pixels: 24)
        ImageCache.shared.set(try #require(UIImage(data: stale)), data: stale, for: url, startedAt: startedAt)
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.persistentWidth(url) == 8, "an answer from before the invalidation replaced the kept cover")
        #expect(ImageCache.shared.testIsRefreshing(url), "the address stopped waiting for a fresh picture")
        #expect(await ImageCache.shared.image(for: url, allowKept: false) == nil, "the stale answer was stored")
    }

    /// True once `stream` yields, false after `seconds`: a witness that
    /// waits for a held stage must not hang when the stage never comes.
    private static func arrives(_ stream: AsyncStream<Void>, within seconds: Double = 5) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in stream { return true }; return false }
            group.addTask {
                // bearable, because a cancelled sleep only ends the deadline early
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// The answer passed `set`'s entry, then a second pull invalidated
    /// before its background write began: nothing of it reaches the disk.
    @Test("eine Invalidierung nach dem Eintritt von set und vor dem Schreiben laesst weder Cache noch geschuetzte Fassung mit dem Bild davor")
    func anInvalidationBeforeTheWriteKeepsTheDiskClean() async throws {
        let url = URL(string: "http://127.0.0.1:9/race-\(UUID().uuidString).png")!
        #expect(ImageCache.shared.testPlacePersistent(Self.png(pixels: 8), for: url), "the precondition: an old kept cover")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        let answer = Self.png(pixels: 24)
        ImageCache.shared.set(try #require(UIImage(data: answer)), data: answer, for: url,
                              startedAt: ImageCache.shared.invalidationCount(for: url))
        Artwork.invalidate(url)
        await ImageCache.shared.testDiskSettled(url)
        #expect(ImageCache.shared.testCacheBytes(url) == nil, "the overtaken write left its picture in the cache file")
        #expect(Self.persistentWidth(url) == 8, "the overtaken write replaced the kept cover")
        #expect(ImageCache.shared.testIsRefreshing(url), "the address stopped waiting for a fresh picture")
        #expect(await ImageCache.shared.image(for: url, allowKept: false) == nil,
                "the network gate found the picture from before the invalidation")
    }

    /// The invalidation comes while the write runs, after its last look at
    /// the count: the removal runs after the write, as if the invalidation
    /// had come after a finished write.
    @Test("eine Invalidierung waehrend des Schreibens raeumt die Cache-Datei danach, und der Speicher bleibt leer")
    func anInvalidationDuringTheWriteRemovesWhatTheWriteLeft() async throws {
        let url = URL(string: "http://127.0.0.1:9/race-hold-\(UUID().uuidString).png")!
        let key = ImageCache.shared.testKey(for: url)
        let (reached, reachedGo) = AsyncStream<Void>.makeStream()
        let (release, releaseGo) = AsyncStream<Void>.makeStream()
        let (written, writtenGo) = AsyncStream<Void>.makeStream()
        ImageCache.shared.testDiskHold = { stage, fileKey in
            if stage == "write", fileKey == key {
                reachedGo.yield()
                for await _ in release { break }
            }
            if stage == "written", fileKey == key { writtenGo.yield() }
        }
        defer {
            ImageCache.shared.testDiskHold = nil
            releaseGo.finish()
        }
        let answer = Self.png(pixels: 24)
        ImageCache.shared.set(try #require(UIImage(data: answer)), data: answer, for: url,
                              startedAt: ImageCache.shared.invalidationCount(for: url))
        try #require(await Self.arrives(reached), "the precondition: the write reached its first byte")
        Artwork.invalidate(url)
        releaseGo.yield()
        // Waits for the write itself, not through the order under test.
        try #require(await Self.arrives(written), "the precondition: the write finished")
        await ImageCache.shared.testDiskSettled(url)
        #expect(ImageCache.shared.testCacheBytes(url) == nil, "the removal ran before the write it interrupted")
        #expect(ImageCache.shared.testIsRefreshing(url), "the address stopped waiting for a fresh picture")
        #expect(await ImageCache.shared.image(for: url, allowKept: false) == nil,
                "the network gate found the picture from before the invalidation")
    }

    /// A read that began before an invalidation and ended after it holds
    /// the picture from before it: it is handed to its caller, not stored.
    @Test("ein Lesen ueber eine Invalidierung hinweg legt das Bild davor nicht in den Speicher")
    func aReadAcrossAnInvalidationIsNotStored() async throws {
        let url = URL(string: "http://127.0.0.1:9/race-read-\(UUID().uuidString).png")!
        let key = ImageCache.shared.testKey(for: url)
        #expect(ImageCache.shared.testPlaceInCache(Self.png(pixels: 8), for: url), "the precondition: a cached cover")
        let (reached, reachedGo) = AsyncStream<Void>.makeStream()
        let (release, releaseGo) = AsyncStream<Void>.makeStream()
        ImageCache.shared.testDiskHold = { stage, fileKey in
            if stage == "read", fileKey == key {
                reachedGo.yield()
                for await _ in release { break }
            }
        }
        defer {
            ImageCache.shared.testDiskHold = nil
            releaseGo.finish()
        }
        let read = Task { await ImageCache.shared.thumbnail(for: url, maxPixelSize: 400) }
        try #require(await Self.arrives(reached), "the precondition: the read found the cached cover")
        Artwork.invalidate(url)
        releaseGo.yield()
        #expect(await read.value.map { Int($0.size.width * $0.scale) } == 8, "the read lost its own answer")
        await ImageCache.shared.testDiskSettled(url)
        #expect(await ImageCache.shared.thumbnail(for: url, maxPixelSize: 400, allowKept: false) == nil,
                "a read across the invalidation answered the network gate with the picture from before it")
    }

    /// Offline an invalidated address waits the whole session. Its kept
    /// picture stays in memory under its own name: the second look does not
    /// decode from disk again, and the network gate still never sees it.
    @Test("offline trifft der zweite Blick auf eine wartende Adresse den Speicher, das Netz-Tor nie")
    func aWaitingAddressIsWarmForReadersButNotForTheGate() async throws {
        let url = URL(string: "http://127.0.0.1:9/waiting-\(UUID().uuidString).png")!
        #expect(ImageCache.shared.testPlacePersistent(Self.png(pixels: 8), for: url), "the precondition: an old kept cover")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        Artwork.invalidate(url)
        let first = await Artwork.thumbnail(for: url, maxPixel: 400)
        #expect(first.map { Int($0.size.width * $0.scale) } == 8, "the precondition: the first look read the kept cover")
        #expect(ImageCache.shared.testRemovePersistent(named: ImageCache.shared.testKey(for: url)),
                "the precondition: the disk no longer holds it")
        let second = await Artwork.thumbnail(for: url, maxPixel: 400)
        #expect(second.map { Int($0.size.width * $0.scale) } == 8, "the second look found nothing in memory")
        #expect(Artwork.cachedThumbnail(for: url, maxPixel: 400).map { Int($0.size.width * $0.scale) } == 8,
                "the first frame of a cell shows the placeholder again")
        #expect(await ImageCache.shared.thumbnail(for: url, maxPixelSize: 400, allowKept: false) == nil,
                "the kept picture in memory answered the network gate")
        #expect(ImageCache.shared.testIsRefreshing(url), "the address stopped waiting for a fresh picture")
    }

    /// Holds the disk queue of `url` behind a write that waits at its first
    /// byte, so the removal an invalidation queues stays queued and the old
    /// cache file stands. The returned release lets the write and everything
    /// behind it run and waits for that.
    private static func holdQueue(of url: URL) async throws -> @MainActor () async -> Void {
        let key = ImageCache.shared.testKey(for: url)
        let (reached, reachedGo) = AsyncStream<Void>.makeStream()
        let (release, releaseGo) = AsyncStream<Void>.makeStream()
        let (written, writtenGo) = AsyncStream<Void>.makeStream()
        ImageCache.shared.testDiskHold = { stage, fileKey in
            if stage == "write", fileKey == key {
                reachedGo.yield()
                for await _ in release { break }
            }
            if stage == "written", fileKey == key { writtenGo.yield() }
        }
        let answer = Self.png(pixels: 24)
        ImageCache.shared.set(try #require(UIImage(data: answer)), data: answer, for: url,
                              startedAt: ImageCache.shared.invalidationCount(for: url))
        try #require(await Self.arrives(reached), "the precondition: the disk queue is held")
        return {
            releaseGo.finish()
            _ = await Self.arrives(written)
            await ImageCache.shared.testDiskSettled(url)
            ImageCache.shared.testDiskHold = nil
        }
    }

    /// A read after the invalidation and before its queued removal finds
    /// the old cache file first. The reader gets it, the waiting name does
    /// not: under it stand only bytes of the persistent copy.
    @Test("ein Lesen zwischen Invalidierung und Loeschen legt die alte Cache-Datei nicht unter den Wartenamen")
    func theWaitingNameHoldsOnlyKeptBytes() async throws {
        let url = URL(string: "http://127.0.0.1:9/window-\(UUID().uuidString).png")!
        #expect(ImageCache.shared.testPlaceInCache(Self.png(pixels: 8), for: url), "the precondition: an old cache file")
        #expect(ImageCache.shared.testPlacePersistent(Self.png(pixels: 16), for: url), "the precondition: a kept cover")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        let release = try await Self.holdQueue(of: url)
        Artwork.invalidate(url)
        #expect(ImageCache.shared.testCacheBytes(url) != nil, "the precondition: the removal is still queued")
        let read = await ImageCache.shared.thumbnail(for: url, maxPixelSize: 400)
        #expect(read.map { Int($0.size.width * $0.scale) } == 8, "the precondition: the read found the old cache file")
        #expect(Artwork.cachedThumbnail(for: url, maxPixel: 400) == nil,
                "the cache file from before the invalidation stands under the waiting name")
        await release()
    }

    /// The wait ends during a read (a `set` lands and replaces the kept
    /// copy): the kept bytes the read holds are stored nowhere, so the
    /// network gate finds the new picture, not the old one under the plain
    /// name.
    @Test("endet das Warten waehrend eines Lesens, findet das Netz-Tor danach das neue Bild, nicht das alte")
    func aWaitThatEndsDuringAReadStoresNothing() async throws {
        let url = URL(string: "http://127.0.0.1:9/ended-\(UUID().uuidString).png")!
        let key = ImageCache.shared.testKey(for: url)
        #expect(ImageCache.shared.testPlacePersistent(Self.png(pixels: 8), for: url), "the precondition: an old kept cover")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        Artwork.invalidate(url)
        await ImageCache.shared.testDiskSettled(url)
        let (reached, reachedGo) = AsyncStream<Void>.makeStream()
        let (release, releaseGo) = AsyncStream<Void>.makeStream()
        ImageCache.shared.testDiskHold = { stage, fileKey in
            if stage == "read", fileKey == key {
                reachedGo.yield()
                for await _ in release { break }
            }
        }
        defer {
            ImageCache.shared.testDiskHold = nil
            releaseGo.finish()
        }
        let read = Task { await ImageCache.shared.thumbnail(for: url, maxPixelSize: 400) }
        try #require(await Self.arrives(reached), "the precondition: the read holds the kept cover")
        let answer = Self.png(pixels: 24)
        ImageCache.shared.set(try #require(UIImage(data: answer)), data: answer, for: url,
                              startedAt: ImageCache.shared.invalidationCount(for: url))
        await ImageCache.shared.testDiskSettled(url)
        #expect(!ImageCache.shared.testIsRefreshing(url), "the precondition: the set landed and ended the wait")
        // Finished, not yielded: the gate's read below passes the same stage
        // and must not be held a second time.
        releaseGo.finish()
        #expect(await read.value.map { Int($0.size.width * $0.scale) } == 8, "the precondition: the read held the old cover")
        let gate = await ImageCache.shared.thumbnail(for: url, maxPixelSize: 400, allowKept: false)
        #expect(gate.map { Int($0.size.width * $0.scale) } == 24, "the network gate found the old kept cover")
    }

    /// A download that finishes while an invalidation's removal is queued
    /// does not lift the old cache file into the persistent tier.
    @Test("ein Download waehrend des eingereihten Loeschens hebt die alte Cache-Datei nicht in die geschuetzte Ablage")
    func makePersistentLeavesAWaitingCacheFileDown() async throws {
        let url = URL(string: "http://127.0.0.1:9/persist-\(UUID().uuidString).png")!
        #expect(ImageCache.shared.testPlaceInCache(Self.png(pixels: 8), for: url), "the precondition: an old cache file")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        let release = try await Self.holdQueue(of: url)
        Artwork.invalidate(url)
        await ImageCache.shared.makePersistent(coverURL: url)
        #expect(!ImageCache.shared.testIsPersistent(url), "the old cache file went up past its queued removal")
        await release()
    }

    /// The sweep's lift of an active cover asks the same question.
    @Test("der Fegelauf hebt die Cache-Datei einer wartenden Adresse nicht hoch")
    func theSweepLeavesAWaitingCacheFileDown() async throws {
        let url = URL(string: "http://127.0.0.1:9/sweep-\(UUID().uuidString).png")!
        #expect(ImageCache.shared.testPlaceInCache(Self.png(pixels: 8), for: url), "the precondition: an old cache file")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        let release = try await Self.holdQueue(of: url)
        Artwork.invalidate(url)
        await ImageCache.shared.performMaintenance(activeCoverURLs: [url], knowsAll: false).value
        #expect(!ImageCache.shared.testIsPersistent(url), "the sweep lifted the old cache file past its queued removal")
        await release()
    }

    /// A download moved to a new id takes its demoted cover up under the new
    /// name, but not the cache file of a waiting address. The rename runs in
    /// the disk chain of both addresses, so it waits for the removal the
    /// invalidation queued; nothing moves while that is held.
    @Test("ein Umbenennen hebt die Cache-Datei einer wartenden Adresse nicht unter den neuen Namen")
    func aRenameLeavesAWaitingCacheFileDown() async throws {
        let old = URL(string: "http://127.0.0.1:9/rename-old-\(UUID().uuidString).png")!
        let new = URL(string: "http://127.0.0.1:9/rename-new-\(UUID().uuidString).png")!
        #expect(ImageCache.shared.testPlaceInCache(Self.png(pixels: 8), for: old), "the precondition: an old cache file")
        defer { ImageCache.shared.removePersistent(coverURL: new) }
        let release = try await Self.holdQueue(of: old)
        Artwork.invalidate(old)
        ImageCache.shared.renamePersistent(from: old, to: new)
        #expect(!ImageCache.shared.testIsPersistent(new), "the rename ran past the held disk work of the old address")
        await release()
        await ImageCache.shared.testDiskSettled(new)
        #expect(!ImageCache.shared.testIsPersistent(new), "the old cache file went up under the new name")
    }

    /// Only the gates that go to the network next skip the kept copy.
    @Test("die geschuetzte Fassung ueberspringen nur die Tore, die danach ins Netz gehen", .needsTheSources)
    func onlyNetworkGatesSkipTheKeptCopy() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = SourceTree.files(under: sources).filter { $0.pathExtension == "swift" }
        var skipping: Set<String> = []
        for file in files {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains("allowKept: false") { skipping.insert(file.lastPathComponent) }
        }
        #expect(skipping == ["Artwork.swift", "ImageCache.swift"], "a reader skips the kept copy: \(skipping.sorted())")
    }

    @Test("Tuer: ein 404 ist absent, ein 403 und Bytes ohne Bild sind unanswered und werden noch einmal gefragt, ein Bild ist picture und liegt danach auf der Platte")
    func theVerdictNamesWhatWasLearned() async throws {
        let gone = try await BulkImportTests.Stand.start(.answer(status: 404, body: Data("{\"error\":\"none\"}".utf8)))
        defer { gone.stop() }
        #expect(Self.name(await Artwork.verdict(for: Self.url(gone, "gone"))) == "absent")
        #expect(await gone.settledCount(expected: 1) == 1, "an absence was asked twice")

        let refused = try await BulkImportTests.Stand.start(.answer(status: 403, body: Data()))
        defer { refused.stop() }
        #expect(Self.name(await Artwork.verdict(for: Self.url(refused, "refused"))) == "unanswered")
        #expect(await refused.settledCount(expected: 2) == 2, "a status that is no answer gets the second attempt")

        let garbage = try await BulkImportTests.Stand.start(.answer(status: 200, body: Data("{\"detail\":\"not a picture\"}".utf8)))
        defer { garbage.stop() }
        #expect(Self.name(await Artwork.verdict(for: Self.url(garbage, "garbage"))) == "unanswered")

        let served = try await BulkImportTests.Stand.start(.answer(status: 200, body: Self.png()))
        defer { served.stop() }
        let picture = Self.url(served, "picture")
        #expect(Self.name(await Artwork.verdict(for: picture)) == "picture:net")
        // The disk write lands after the verdict (measured in every one of
        // fifty repetitions); until then only the memory cache holds the
        // picture, and the system may empty that at any time. The claim is
        // the disk, so the case waits for the write.
        await ImageCache.shared.testDiskSettled(picture)
        #expect(ImageCache.shared.testCacheBytes(picture) != nil, "the picture did not reach the disk")
        #expect(await Artwork.full(for: picture) != nil, "the picture did not reach the cache")
        #expect(Self.name(await Artwork.verdict(for: picture)) == "picture:full", "the second look asked the network again")
    }

    @Test("Tuer: eine Kachel, die waehrend ihrer Frist verschwindet, bekommt unanswered, kein Nein")
    func aTileThatLeftLearnsNothing() async throws {
        let served = try await BulkImportTests.Stand.start(.answer(status: 200, body: Self.png()))
        defer { served.stop() }
        let leaving = Task {
            await TileDwell.standing { Self.name(await Artwork.verdict(for: Self.url(served, "left"))) }
        }
        try await Task.sleep(for: .milliseconds(100))
        leaving.cancel()
        #expect(await leaving.value == "unanswered")
        #expect(await served.settledCount(expected: 0) == 0, "a tile that left was asked")
    }

    @Test("Zaun: die zwei Merker rufen verdict, nie image, und ihr unanswered-Zweig bucht nichts", .needsTheSources)
    func theRememberersReadTheVerdict() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/Networking/CoverArtArchive.swift", "Sources/Networking/RadioArtworkService.swift"] {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
            #expect(!text.contains("Artwork.image("), "\(path) asks without the verdict")
            #expect(text.contains("Artwork.verdict("), "\(path) does not ask the door")
            let lines = text.split(separator: "\n")
                .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
                .filter { $0.contains("case .unanswered") }
            #expect(!lines.isEmpty, "\(path) has no unanswered branch")
            for line in lines {
                #expect(line.contains("return nil") && !line.contains("missing"), "\(path) books on unanswered: \(line)")
            }
        }
    }
}
