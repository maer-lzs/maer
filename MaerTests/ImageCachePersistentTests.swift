// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import UIKit
@testable import Maer

/// The persistent cover of a downloaded item must be found by the same
/// read paths that serve every tile. It once was not: the persistent
/// name came from the item id without host, the read paths looked for
/// the URL key with host, and the offline cover of a downloaded book
/// did not exist for seven weeks without any test noticing.
@MainActor
@Suite(.serialized)
struct ImageCachePersistentTests {
    private func png(_ side: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.pngData { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    /// An ABS-shaped address with a token as long as a real one, so the
    /// case also covers the digest path of the key.
    private func coverURL(_ tag: String) -> URL {
        URL(string: "https://abs.example.lan/api/items/li_\(tag)/cover?token="
            + String(repeating: "x", count: 220))!
    }

    @Test("ein persistiertes Cover wird von Vorschau- und Vollbild-Pfad gefunden")
    func persistedCoverIsFoundByTheReadPaths() async {
        let url = coverURL(UUID().uuidString)
        await ImageCache.shared.makePersistent(coverURL: url, data: png(64))
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        #expect(await ImageCache.shared.thumbnail(for: url) != nil)
        #expect(await ImageCache.shared.image(for: url) != nil)
    }

    /// Rot-Probe: ein anderer Name wird NICHT gefunden. Der Vorschau-Pfad
    /// liest nur die Platte, also ist nil hier ein echtes Fehlen.
    @Test("ein anderer Name wird nicht gefunden")
    func aDifferentNameIsNotFound() async {
        let url = coverURL(UUID().uuidString)
        await ImageCache.shared.makePersistent(coverURL: url, data: png(64))
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        let other = coverURL(UUID().uuidString)
        #expect(await ImageCache.shared.thumbnail(for: other) == nil)
    }

    /// Nach dem Entfernen des Downloads bleibt das Bild lesbar: die Kopie
    /// wandert in den Cache statt zu verschwinden.
    @Test("nach dem Entfernen bleibt das Bild aus dem Cache lesbar")
    func unpersistedCoverStaysReadableFromTheCache() async {
        let url = coverURL(UUID().uuidString)
        await ImageCache.shared.makePersistent(coverURL: url, data: png(64))
        ImageCache.shared.removePersistent(coverURL: url)
        #expect(await ImageCache.shared.thumbnail(for: url) != nil)
    }

    /// A Navidrome-shaped cover address, the id in the query.
    private func navidromeCover(_ id: String) -> URL {
        URL(string: "https://nd.example.lan/rest/getCoverArt?id=\(id)&size=600")!
    }

    @Test("zwischen den Ordnern: ein aktives Cover nur im Cache geht hoch, ein geschuetztes ohne Download geht runter oder faellt")
    func theTierMoves() {
        let moves = ImageCache.tierMoves(persistent: ["kept", "orphan", "twin"],
                                         cache: ["active", "twin", "other"],
                                         active: ["kept", "active", "missing"], knowsAll: true)
        #expect(moves == [.promote("active"), .demote("orphan"), .drop("twin")])
        #expect(ImageCache.tierMoves(persistent: ["a"], cache: ["a"], active: ["a"], knowsAll: true).isEmpty,
                "a cover in both tiers that is active stays")
        let unsure = ImageCache.tierMoves(persistent: ["kept", "orphan", "twin"],
                                          cache: ["active", "twin", "other"],
                                          active: ["kept", "active", "missing"], knowsAll: false)
        #expect(unsure == [.promote("active")], "an incomplete answer only lifts, it demotes and drops nothing")
    }

    /// A download moved to a new id: its cover takes the new address
    /// without the network, and the read paths find it there.
    @Test("das geschuetzte Cover eines umgezogenen Downloads nimmt die neue Adresse an, ohne Netz")
    func aMovedDownloadsCoverIsRenamed() async {
        let tag = UUID().uuidString
        let old = navidromeCover("old-\(tag)")
        let new = navidromeCover("new-\(tag)")
        await ImageCache.shared.makePersistent(coverURL: old, data: png(64))
        defer { ImageCache.shared.removePersistent(coverURL: new) }
        #expect(ImageCache.shared.testIsPersistent(old), "the precondition: kept under the old address")
        ImageCache.shared.renamePersistent(from: old, to: new)
        #expect(ImageCache.shared.testIsPersistent(new), "the cover stands under the new address")
        #expect(!ImageCache.shared.testIsPersistent(old))
        #expect(await ImageCache.shared.thumbnail(for: new) != nil, "the read paths find it under the new address")
    }

    /// A kept cover an older build named with the key in it: the next sweep
    /// renames it, without the network, and it stays kept under today's name.
    /// The key in the old name is one the server no longer knows (the user
    /// made a new one since), so the rename must not depend on today's key.
    @Test("ein geschuetztes Cover mit Schluessel im Namen steht nach dem naechsten Fegelauf unter dem Namen ohne")
    func aKeptCoverLosesTheKeyInItsName() async {
        let tag = UUID().uuidString.prefix(8)
        let url = URL(string: "https://nc.example.lan/rest/getCoverArt.view?apiKey=NEWKEY2&id=al-\(tag)&size=600")!
        let old = "nc.example.lan__rest_getCoverArt.view_apiKey=SECRETKEY1_id=al-\(tag)_size=600"
        #expect(ImageCache.shared.testPlacePersistent(png(64), named: old), "the precondition: kept under the old name")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        #expect(!ImageCache.shared.testIsPersistent(url), "the precondition: not yet under today's name")
        // An incomplete answer, so the pass demotes nothing of its neighbours.
        await ImageCache.shared.performMaintenance(activeCoverURLs: [], knowsAll: false).value
        #expect(ImageCache.shared.testIsPersistent(url), "the cover stands kept under the name without the key")
        #expect(!ImageCache.shared.testIsPersistent(named: old), "no name carries the key any more")
    }

    /// The kept cover of a downloaded episode with a foreign cover address
    /// stands under the name the earlier rule gave it (without its `t`); the
    /// next sweep moves it to today's name, without the network, and a
    /// foreign name of today that carries `t=` is left as it is.
    @Test("ein geschuetztes fremdes Cover zieht ohne Netz unter den heutigen Namen, ein heutiger Name mit t bleibt stehen")
    func aKeptForeignCoverMovesToTodaysName() async {
        let tag = UUID().uuidString.prefix(8)
        let url = URL(string: "https://www.omnycontent.com/d/programs/\(tag)/image.jpg?t=1700000001&size=3000")!
        let old = ImageCache.legacyName(for: url)
        #expect(old != ImageCache.shared.testKey(for: url), "the precondition: the earlier rule gave another name")
        #expect(ImageCache.shared.testPlacePersistent(png(64), named: old), "the precondition: kept under the old name")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        let today = URL(string: "https://www.omnycontent.com/d/programs/\(tag)/other.jpg?t=1700000002")!
        #expect(ImageCache.shared.testPlacePersistent(png(64), for: today), "the precondition: a foreign name of today with t")
        defer { ImageCache.shared.removePersistent(coverURL: today) }
        // An incomplete answer moves nothing and demotes nothing of the
        // neighbours; the first step still runs and must leave `today` alone.
        await ImageCache.shared.performMaintenance(activeCoverURLs: [url], knowsAll: false).value
        #expect(ImageCache.shared.testIsPersistent(named: old), "an incomplete pass moved a name")
        #expect(ImageCache.shared.testIsPersistent(today), "a foreign name of today lost its t")
        // The move of a complete pass. `today` is not active: the move would
        // otherwise hand a name that the first step wrongly shortened back
        // to it, and hide that step.
        await ImageCache.shared.testMoveLegacyNames(activeCoverURLs: [url])
        #expect(ImageCache.shared.testIsPersistent(url), "the kept foreign cover is not under today's name")
        #expect(!ImageCache.shared.testIsPersistent(named: old), "the old name stayed")
    }

    /// Episode A has its own picture with a `t`, episode B of the same show
    /// falls back to the show's picture without it; both are downloaded. The
    /// earlier rule's name for A is today's name of B: the move leaves B's
    /// kept cover where it is and hands A nothing of it.
    @Test("der Umzug nimmt nie den Namen einer anderen aktiven Adresse: B behaelt sein Cover, A erbt es nicht")
    func theMoveNeverTakesTheNameOfAnotherActiveAddress() async throws {
        let tag = UUID().uuidString.prefix(8)
        let episodeA = URL(string: "https://cdn.example.org/\(tag)/x.jpg?t=2")!
        let episodeB = URL(string: "https://cdn.example.org/\(tag)/x.jpg")!
        #expect(ImageCache.legacyName(for: episodeA) == ImageCache.shared.testKey(for: episodeB),
                "the precondition: A's old name is B's name of today")
        let bytesB = png(48)
        #expect(ImageCache.shared.testPlacePersistent(bytesB, for: episodeB), "the precondition: B's cover is kept")
        defer {
            ImageCache.shared.removePersistent(coverURL: episodeA)
            ImageCache.shared.removePersistent(coverURL: episodeB)
        }
        // The move of a complete pass.
        await ImageCache.shared.testMoveLegacyNames(activeCoverURLs: [episodeA, episodeB])
        #expect(ImageCache.shared.testPersistentBytes(episodeB) == bytesB, "B lost its kept cover")
        #expect(ImageCache.shared.testPersistentBytes(episodeA) == nil, "A carries B's picture")
        // A already kept: the move would have deleted B's file.
        let bytesA = png(64)
        #expect(ImageCache.shared.testPlacePersistent(bytesA, for: episodeA))
        await ImageCache.shared.testMoveLegacyNames(activeCoverURLs: [episodeA, episodeB])
        #expect(ImageCache.shared.testPersistentBytes(episodeB) == bytesB, "B's cover was deleted")
        #expect(ImageCache.shared.testPersistentBytes(episodeA) == bytesA)
    }

    /// Two active sizes of one picture share the earlier rule's name: which
    /// one would inherit is a matter of order, so neither moves.
    @Test("zwei aktive Groessen mit einem alten Namen: keine zieht um")
    func twoSizesWithOneOldNameDoNotMove() async throws {
        let tag = UUID().uuidString.prefix(8)
        let small = URL(string: "https://cdn.example.org/\(tag)/y.jpg?s=600")!
        let large = URL(string: "https://cdn.example.org/\(tag)/y.jpg?s=1400")!
        let old = ImageCache.legacyName(for: small)
        #expect(old == ImageCache.legacyName(for: large), "the precondition: one old name")
        #expect(ImageCache.shared.testKey(for: small) != ImageCache.shared.testKey(for: large),
                "the precondition: two names of today")
        let moves = ImageCache.legacyMoves(for: [small, large], knowsAll: true) { ImageCache.shared.testKey(for: $0) }
        #expect(moves[old] == nil, "an ambiguous old name moves: \(moves)")
        #expect(ImageCache.shared.testPlacePersistent(png(48), named: old), "the precondition: kept under the old name")
        defer {
            ImageCache.shared.removePersistent(coverURL: small)
            ImageCache.shared.removePersistent(coverURL: large)
            ImageCache.shared.testRemovePersistent(named: old)
        }
        await ImageCache.shared.testMoveLegacyNames(activeCoverURLs: [small, large])
        #expect(ImageCache.shared.testPersistentBytes(small) == nil, "the small size inherited")
        #expect(ImageCache.shared.testPersistentBytes(large) == nil, "the large size inherited")
    }

    /// A kept cover whose address this pass could not build (a download of
    /// a show no longer followed) is missing from the list, while an active
    /// neighbour carries its name as its old name. An incomplete pass moves
    /// nothing: the cover stays where it is, and nothing is handed over.
    @Test("ein geschuetztes Cover ohne baubare Adresse uebersteht einen unvollstaendigen Lauf, auch wenn ein aktiver Nachbar seinen Namen als alten traegt")
    func anIncompletePassMovesNoName() async throws {
        let tag = UUID().uuidString.prefix(8)
        let neighbour = URL(string: "https://cdn.example.org/\(tag)/z.jpg?t=7")!
        let unresolved = URL(string: "https://cdn.example.org/\(tag)/z.jpg")!
        #expect(ImageCache.legacyName(for: neighbour) == ImageCache.shared.testKey(for: unresolved),
                "the precondition: the neighbour's old name is the unresolved cover's name")
        #expect(!ImageCache.legacyMoves(for: [neighbour], knowsAll: true) { ImageCache.shared.testKey(for: $0) }.isEmpty,
                "the precondition: a complete pass with this list would move it")
        let bytes = png(48)
        #expect(ImageCache.shared.testPlacePersistent(bytes, for: unresolved), "the precondition: the cover is kept")
        defer {
            ImageCache.shared.removePersistent(coverURL: unresolved)
            ImageCache.shared.removePersistent(coverURL: neighbour)
        }
        await ImageCache.shared.performMaintenance(activeCoverURLs: [neighbour], knowsAll: false).value
        #expect(ImageCache.shared.testPersistentBytes(unresolved) == bytes, "the unresolved cover was moved away")
        #expect(ImageCache.shared.testPersistentBytes(neighbour) == nil, "the neighbour carries the unresolved cover")
        #expect(ImageCache.legacyMoves(for: [neighbour], knowsAll: false) { ImageCache.shared.testKey(for: $0) }.isEmpty)
    }

    /// A cover an earlier sweep already demoted stands in the cache under the
    /// old name. The move finds it there and puts it up under the new one.
    @Test("ein schon abgestuftes Cover eines umgezogenen Downloads wird im Cache gefunden und steht danach geschuetzt unter der neuen Adresse")
    func aDemotedCoverOfAMovedDownloadIsRenamedToo() {
        let tag = UUID().uuidString
        let old = navidromeCover("demoted-old-\(tag)")
        let new = navidromeCover("demoted-new-\(tag)")
        #expect(ImageCache.shared.testPlaceInCache(png(64), for: old), "the precondition: the cover stands in the cache")
        defer { ImageCache.shared.removePersistent(coverURL: new) }
        #expect(!ImageCache.shared.testIsPersistent(old))
        ImageCache.shared.renamePersistent(from: old, to: new)
        #expect(ImageCache.shared.testIsPersistent(new), "the demoted cover went up under the new address")
    }

    /// A cover that was demoted once (the sweep ran before the download
    /// moved) is protected again by the next sweep, because it is active.
    @Test("ein aktives Cover, das nur im Cache steht, wird vom naechsten Fegelauf wieder geschuetzt")
    func theSweepPromotesAnActiveCover() async throws {
        let url = navidromeCover("active-\(UUID().uuidString)")
        #expect(ImageCache.shared.testPlaceInCache(png(64), for: url), "the precondition: the cover stands in the cache")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        #expect(!ImageCache.shared.testIsPersistent(url))
        // An incomplete answer, so the pass lifts and leaves every
        // neighbour's persistent cover where it is.
        await ImageCache.shared.performMaintenance(activeCoverURLs: [url], knowsAll: false).value
        #expect(ImageCache.shared.testIsPersistent(url), "the active cover went up into the persistent tier")
    }

    /// A cover demoted by an earlier sweep keeps its old moment; the TTL
    /// step of the same pass would delete it. It goes up first.
    @Test("ein abgestuftes Cover mit 31 Tagen kommt hoch, bevor die Frist es loescht")
    func anOldDemotedCoverGoesUpBeforeTheTTL() async {
        let url = navidromeCover("old-active-\(UUID().uuidString)")
        let monthAgo = Date().addingTimeInterval(-31 * 86_400)
        #expect(ImageCache.shared.testPlaceInCache(png(64), for: url, modified: monthAgo),
                "the precondition: a cover older than the TTL stands in the cache")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        await ImageCache.shared.performMaintenance(activeCoverURLs: [url], knowsAll: false).value
        #expect(ImageCache.shared.testIsPersistent(url), "the active cover went up instead of being deleted")
    }

    /// A pass that cannot name every download's cover (the scan is not done,
    /// or a music title without its client) demotes nothing.
    @Test("ein Fegelauf ohne vollstaendige Antwort laesst ein geschuetztes Cover stehen")
    func anIncompleteAnswerDemotesNothing() async {
        let url = navidromeCover("unnamed-\(UUID().uuidString)")
        #expect(ImageCache.shared.testPlacePersistent(png(64), for: url), "the precondition: a persistent cover")
        defer { ImageCache.shared.removePersistent(coverURL: url) }
        await ImageCache.shared.performMaintenance(activeCoverURLs: [], knowsAll: false).value
        #expect(ImageCache.shared.testIsPersistent(url), "the cover nobody could name stays protected")
    }

    /// The active covers come after the downloads' scan, and a download
    /// whose cover address cannot be built makes the answer incomplete.
    @Test("die aktiven Cover kommen nach dem Scan, ein Download ohne Adresse macht die Antwort unvollstaendig")
    func theActiveCoversWaitForTheScan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-covers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await NavidromeRekeyTests.plant([("li_book", [NavidromeRekeyTests.old]),
                                             ("sub:album:a", [NavidromeRekeyTests.old])], in: directory)
        let manager = DownloadManager(documents: directory,
                                      database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        // Asked right after construction: the answer waits for the scan.
        let all = await manager.activeCovers(address: { URL(string: "https://example.lan/cover/\($0)") },
                                             idMovePending: { false })
        #expect(all.urls.count == 2 && all.knowsAll, "both downloads were known, the scan was awaited")
        let noClient = await manager.activeCovers(
            address: { $0.hasPrefix("sub:") ? nil : URL(string: "https://example.lan/cover/\($0)") },
            idMovePending: { false })
        #expect(noClient.urls.count == 1 && noClient.unresolved == 1 && !noClient.knowsAll,
                "a music title without its client makes the answer incomplete")
    }

    /// Between "the server reports 0.64" and the id move, the address built
    /// now names the new form while the kept cover stands under the old
    /// one: a music download makes the answer incomplete. A book does not
    /// wait on the move.
    @Test("ein offener Umzug macht die Antwort mit einem Musik-Download unvollstaendig, ohne Musik-Download nicht")
    func aPendingMoveMakesTheAnswerIncomplete() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("move-pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await NavidromeRekeyTests.plant([("li_book", [NavidromeRekeyTests.old]),
                                             ("sub:album:a", [NavidromeRekeyTests.old])], in: directory)
        let manager = DownloadManager(documents: directory,
                                      database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        let address: (String) -> URL? = { URL(string: "https://example.lan/cover/\($0)") }
        let pending = await manager.activeCovers(address: address, idMovePending: { true })
        #expect(pending.urls.count == 2 && pending.unresolved == 0, "the precondition: every address can be built")
        #expect(pending.movePending && !pending.knowsAll, "a music download waiting for the move holds the sweep")
        let done = await manager.activeCovers(address: address, idMovePending: { false })
        #expect(done.knowsAll, "after the move the answer is complete again")

        let bookOnly = FileManager.default.temporaryDirectory
            .appendingPathComponent("move-pending-books-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bookOnly) }
        try await NavidromeRekeyTests.plant([("li_book", [NavidromeRekeyTests.old])], in: bookOnly)
        let books = DownloadManager(documents: bookOnly,
                                    database: MaerDatabase(path: bookOnly.appendingPathComponent("maer.sqlite").path))
        let booksAnswer = await books.activeCovers(address: address, idMovePending: { true })
        #expect(!booksAnswer.movePending && booksAnswer.knowsAll, "a book does not wait on Navidrome's move")
    }

    /// The window itself: the kept cover under the old form, the active
    /// address in the new one, the move open. The sweep with that answer
    /// demotes nothing; the move's rename then puts the cover under the new
    /// form, where a complete answer keeps it.
    @Test("im Fenster vor dem Umzug bleibt das Cover unter der alten Form geschuetzt, danach steht es unter der neuen")
    func theWindowBeforeTheMoveKeepsTheCover() async throws {
        let tag = UUID().uuidString
        let old = navidromeCover("old-\(tag)")
        let new = navidromeCover("new-\(tag)")
        #expect(ImageCache.shared.testPlacePersistent(png(64), for: old), "the precondition: kept under the old form")
        defer { ImageCache.shared.removePersistent(coverURL: new); ImageCache.shared.removePersistent(coverURL: old) }

        let window = DownloadManager.ActiveCovers(urls: [new], unresolved: 0, movePending: true)
        #expect(!window.knowsAll)
        // The rule over names: kept under the old form, active by the new.
        #expect(ImageCache.tierMoves(persistent: ["old"], cache: [], active: ["new"], knowsAll: true) == [.demote("old")],
                "the danger: a complete answer by the new form would demote the kept cover")
        await ImageCache.shared.performMaintenance(activeCoverURLs: window.urls, knowsAll: window.knowsAll).value
        #expect(ImageCache.shared.testIsPersistent(old), "the sweep in the window demoted nothing")

        ImageCache.shared.renamePersistent(from: old, to: new)
        #expect(ImageCache.shared.testIsPersistent(new), "after the move the cover stands under the new form")
        #expect(ImageCache.tierMoves(persistent: ["new"], cache: [], active: ["new"], knowsAll: true).isEmpty,
                "and a complete answer keeps it there")
    }

    @Test("der Umzug ist offen, solange die Regel gilt, ein Server da ist und die Marke fehlt")
    func theMoveIsPendingUntilItsMarker() throws {
        let suite = "move-pending-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!NavidromeRekeyRun.isPending(server: "nd.example.lan", applies: false, defaults: defaults), "no rule, no move")
        #expect(!NavidromeRekeyRun.isPending(server: nil, applies: true, defaults: defaults), "no server, no move")
        #expect(NavidromeRekeyRun.isPending(server: "nd.example.lan", applies: true, defaults: defaults))
        defaults.set(true, forKey: NavidromeRekey.markerKey(server: "nd.example.lan"))
        #expect(!NavidromeRekeyRun.isPending(server: "nd.example.lan", applies: true, defaults: defaults),
                "the marker of a whole pass ends it")
    }

    // MARK: - No move feeds the network gate of a waiting address

    /// What the network gate of an address asks first: the purgeable tier
    /// alone while the address waits (`allowKept: false`).
    private func gate(_ url: URL) async -> UIImage? {
        await ImageCache.shared.thumbnail(for: url, maxPixelSize: 64, allowKept: false)
    }

    /// A kept cover, then an invalidation: the address waits, and its gate
    /// finds nothing, so it asks the server.
    private func keptAndWaiting(_ url: URL) async {
        await ImageCache.shared.makePersistent(coverURL: url, data: png(64))
        ImageCache.shared.invalidate(url: url)
        await ImageCache.shared.testDiskSettled(url)
    }

    @Test("das Entfernen eines Downloads legt das geschuetzte Cover einer wartenden Adresse nicht dorthin, wo das Netz-Tor liest")
    func removingADownloadKeepsAWaitingCopyFromTheGate() async {
        let url = coverURL(UUID().uuidString)
        await keptAndWaiting(url)
        defer { ImageCache.shared.testRemovePersistent(named: ImageCache.shared.testKey(for: url)) }
        #expect(ImageCache.shared.testIsRefreshing(url), "the precondition: the address waits")
        #expect(await gate(url) == nil, "the precondition: the gate finds nothing and asks the server")
        ImageCache.shared.removePersistent(coverURL: url)
        #expect(await gate(url) == nil, "the gate answers with the picture from before the invalidation")
        #expect(ImageCache.shared.testCacheBytes(url) == nil)
        #expect(await ImageCache.shared.thumbnail(for: url, maxPixelSize: 64) != nil, "every other reader still finds the kept copy")
    }

    @Test("das geschuetzte Cover einer wartenden Adresse zieht mit um, und die neue Adresse wartet: das Netz-Tor findet nichts")
    func renamingAWaitingCopyKeepsTheNewAddressWaiting() async {
        let tag = UUID().uuidString
        let old = navidromeCover("old-\(tag)")
        let new = navidromeCover("new-\(tag)")
        await keptAndWaiting(old)
        defer { ImageCache.shared.testRemovePersistent(named: ImageCache.shared.testKey(for: new)) }
        #expect(await gate(new) == nil, "the precondition: nothing stands under the new address")
        ImageCache.shared.renamePersistent(from: old, to: new)
        await ImageCache.shared.testDiskSettled(new)
        #expect(ImageCache.shared.testIsPersistent(new), "the kept copy follows the download")
        #expect(ImageCache.shared.testIsRefreshing(new), "the new address waits like the old one")
        #expect(await gate(new) == nil, "the gate of the new address answers with the picture from before the invalidation")
        #expect(await ImageCache.shared.thumbnail(for: new, maxPixelSize: 64) != nil, "every other reader finds the kept copy")
    }

    @Test("der Fegelauf stuft das geschuetzte Cover einer wartenden Adresse nicht ab; eines, das nicht wartet, schon")
    func theSweepKeepsAWaitingCopyUp() async {
        let url = coverURL(UUID().uuidString)
        await keptAndWaiting(url)
        defer { ImageCache.shared.testRemovePersistent(named: ImageCache.shared.testKey(for: url)) }
        await ImageCache.shared.testApplyTierMoves([.demote(ImageCache.shared.testKey(for: url))])
        #expect(ImageCache.shared.testIsPersistent(url), "the kept copy of a waiting address went down")
        #expect(await gate(url) == nil, "the gate answers with the picture from before the invalidation")

        let other = coverURL(UUID().uuidString)
        await ImageCache.shared.makePersistent(coverURL: other, data: png(64))
        await ImageCache.shared.testApplyTierMoves([.demote(ImageCache.shared.testKey(for: other))])
        #expect(!ImageCache.shared.testIsPersistent(other) && ImageCache.shared.testCacheBytes(other) != nil,
                "the control: a copy that does not wait goes down")
    }

    @Test("ein Altname im Cache-Ordner zieht nicht unter den Namen einer wartenden Adresse; ohne Warten zieht er um")
    func aLegacyNameDoesNotMoveOntoAWaitingName() async {
        let tag = UUID().uuidString.prefix(8)
        let url = URL(string: "https://www.omnycontent.com/d/programs/\(tag)/image.jpg?t=1700000001&size=3000")!
        let free = URL(string: "https://www.omnycontent.com/d/programs/\(tag)/free.jpg?t=1700000003&size=3000")!
        for each in [url, free] {
            #expect(ImageCache.legacyName(for: each) != ImageCache.shared.testKey(for: each), "the precondition: an earlier name")
            #expect(ImageCache.shared.testPlaceInCache(png(64), named: ImageCache.legacyName(for: each)))
        }
        ImageCache.shared.invalidate(url: url)
        await ImageCache.shared.testDiskSettled(url)
        await ImageCache.shared.testMoveLegacyNames(activeCoverURLs: [url, free])
        // At the place, not at the gate: the clearing after the step would
        // make the gate empty too, so the gate alone could not tell which
        // rule held.
        #expect(ImageCache.shared.testIsInCache(named: ImageCache.legacyName(for: url)), "the old name moved")
        #expect(!ImageCache.shared.testIsInCache(named: ImageCache.shared.testKey(for: url)),
                "the old bytes landed under the name of a waiting address")
        #expect(await gate(free) != nil, "the control: an old name moves where no address waits")
    }

    /// Fresh bytes of the new address in the cache: the carried copy from
    /// before the old address's invalidation is the one too many and goes,
    /// and the new address does not wait, so every reader finds the fresh
    /// bytes (an invalidation would remove exactly those). They go up under
    /// the new name in the same step: the moved download keeps a persistent
    /// copy, not only from the next sweep on.
    @Test("ein Umbenennen macht frische Bytes der neuen Adresse nie unsichtbar und hebt sie fuer den Download hoch")
    func renamingKeepsFreshBytesOfTheNewAddress() async {
        let tag = UUID().uuidString
        let old = navidromeCover("old-\(tag)")
        let new = navidromeCover("new-\(tag)")
        await keptAndWaiting(old)
        let fresh = png(32)
        #expect(ImageCache.shared.testPlaceInCache(fresh, for: new), "the precondition: fresh bytes under the new name")
        defer {
            ImageCache.shared.testRemovePersistent(named: ImageCache.shared.testKey(for: new))
            ImageCache.shared.testRemovePersistent(named: ImageCache.shared.testKey(for: old))
        }
        ImageCache.shared.renamePersistent(from: old, to: new)
        await ImageCache.shared.testDiskSettled(new)
        #expect(ImageCache.shared.testPersistentBytes(new) == fresh,
                "the fresh bytes did not go up, or the copy from before the invalidation took the new name")
        #expect(ImageCache.shared.testCacheBytes(new) == nil, "the fresh bytes stand twice")
        #expect(!ImageCache.shared.testIsRefreshing(new), "the new address waits although fresh bytes stand")
        #expect(await gate(new) != nil, "the network gate of the new address finds no picture")
        #expect(!ImageCache.shared.testIsPersistent(old), "the carried copy stayed under the old name")
    }

    /// An invalidation during step 0: the waiting names as the step began do
    /// not hold the address, so a rename puts an old name's file under its
    /// name; the sweep clears it when it is done, behind the disk work of
    /// that address. A file the step did not put there is not its matter.
    @Test("nach den Umbenennungen raeumt der Fegelauf eine Datei, die sie unter einen inzwischen wartenden Namen legten")
    func theSweepClearsAWaitingNameFromTheCache() async {
        let tag = UUID().uuidString.prefix(8)
        let url = URL(string: "https://www.omnycontent.com/d/programs/\(tag)/late.jpg?t=1700000005&size=3000")!
        let old = ImageCache.legacyName(for: url)
        #expect(old != ImageCache.shared.testKey(for: url), "the precondition: an earlier name")
        #expect(ImageCache.shared.testPlaceInCache(png(64), named: old), "the precondition: the old name in the cache")
        ImageCache.shared.invalidate(url: url)
        await ImageCache.shared.testDiskSettled(url)
        // As the step began, the address did not wait yet.
        await ImageCache.shared.testMoveLegacyNames(activeCoverURLs: [url], waitingAtStart: [])
        await ImageCache.shared.testDiskSettled(url)
        #expect(!ImageCache.shared.testIsInCache(named: old), "the precondition: the step moved the old name")
        #expect(ImageCache.shared.testCacheBytes(url) == nil, "the file the step put under the waiting name stayed")
        #expect(await gate(url) == nil, "the gate answers instead of the network")
    }

    /// The clearing after step 0 asks only the names the renames placed: a
    /// file under a waiting name that came another way (fresh bytes of a
    /// load whose replacing of the kept copy failed) is not its matter.
    @Test("eine Datei unter einem wartenden Namen, die Schritt 0 nicht legte, laesst der Fegelauf stehen")
    func theSweepLeavesAFileItDidNotPlace() async {
        let url = coverURL(UUID().uuidString)
        ImageCache.shared.invalidate(url: url)
        await ImageCache.shared.testDiskSettled(url)
        #expect(ImageCache.shared.testIsRefreshing(url), "the precondition: the address waits")
        let fresh = png(48)
        #expect(ImageCache.shared.testPlaceInCache(fresh, for: url), "the precondition: bytes under the waiting name")
        await ImageCache.shared.testMoveLegacyNames(activeCoverURLs: [url], waitingAtStart: [])
        await ImageCache.shared.testDiskSettled(url)
        #expect(ImageCache.shared.testCacheBytes(url) == fresh, "step 0 cleared a file it did not place")
    }

    @Test("der Fegelauf laesst die geschuetzte Fassung einer wartenden Adresse stehen, auch wenn der Cache denselben Namen haelt")
    func theSweepDropsNoWaitingCopy() async {
        let url = coverURL(UUID().uuidString)
        await keptAndWaiting(url)
        defer { ImageCache.shared.testRemovePersistent(named: ImageCache.shared.testKey(for: url)) }
        #expect(ImageCache.shared.testPlaceInCache(png(64), for: url), "the precondition: the cache holds the same name")
        await ImageCache.shared.testApplyTierMoves([.drop(ImageCache.shared.testKey(for: url))])
        #expect(ImageCache.shared.testIsPersistent(url), "the kept copy of a waiting address was dropped")
    }

    /// The `.moveItem(` sites in the cover cache, counted: a new one has to
    /// answer whether it puts bytes of a waiting address under a name the
    /// network gate answers (makePersistent, removePersistent,
    /// renamePersistent twice: the kept copy and the fresh file of a new
    /// address that does not wait, the renames of step 0, up and down in
    /// the sweep).
    /// What the count does not see: the writers of fresh bytes (`write(to:)`,
    /// `copyItem` with `replaceItemAt`), which lay down a loaded picture.
    @Test("jede moveItem-Stelle im Cover-Cache steht im Bestand", .needsTheSources)
    func everyMoveInTheCoverCacheIsCounted() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/ImageCache.swift"), encoding: .utf8))
        // With the dot: `removeItem(` holds `moveItem(` as well.
        #expect(ConcurrencyFenceTests.sites(of: ".moveItem(", in: code) == 7,
                "a move came or went; ask it the question of the gate of a waiting address, then set the count")
    }

    /// Rule 5 in the sweep, which came back twice: on the main actor the
    /// clearing after step 0 asks the set of waiting names only, and no hop
    /// of `renameStep` onto the main actor asks a file; files are asked in
    /// the disk chain (`onDisk`) and in the step itself, off the main actor.
    @Test("Regel 5 im Fegelauf: das Raeumen nach Schritt 0 fragt auf dem Hauptstrang keine Datei", .needsTheSources)
    func theSweepAsksNoFileOnTheMainActor() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/ImageCache.swift"), encoding: .utf8))
        let clearing = try #require(functionBody(of: "private func clearWaitingFromCache(names: [String])", in: code))
        #expect(!Self.withoutDiskChain(clearing).contains("FileManager"),
                "the clearing asks a file on the main actor; ask it in onDisk")
        let step = try #require(functionBody(of: "nonisolated func renameStep(", in: code))
        let hops = Self.blocks(after: "MainActor.run", in: step)
        #expect(hops.count == 2, "the hops of the step onto the main actor came or went: \(hops.count)")
        #expect(!hops.contains { $0.contains("FileManager") }, "a hop of the step asks a file on the main actor")
        // Calibration, both ways: a file asked on the main actor is seen, one
        // asked in the disk chain is not, and a hop's block is read whole.
        #expect(Self.withoutDiskChain("for n in names { FileManager.default.fileExists(atPath: n) }").contains("FileManager"))
        #expect(!Self.withoutDiskChain("for n in names { onDisk(n) { if a { FileManager.default.removeItem(at: n) } } }")
            .contains("FileManager"))
        #expect(Self.blocks(after: "MainActor.run", in: "await MainActor.run { if a { b() }; FileManager.default }")
            .first?.contains("FileManager") == true)
    }

    /// The block in braces that follows `head`, brace-exact, with its braces.
    private static func braceRange(after head: Range<String.Index>, in text: String) -> Range<String.Index>? {
        var depth = 0
        var open: String.Index?
        var index = head.upperBound
        while index < text.endIndex {
            let character = text[index]
            if character == "{" {
                if depth == 0 { open = index }
                depth += 1
            }
            if character == "}", let open {
                depth -= 1
                if depth == 0 { return open..<text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// `text` without the closures handed to the disk chain (`onDisk(…) { … }`).
    private static func withoutDiskChain(_ text: String) -> String {
        var out = text
        while let head = out.range(of: "onDisk("), let block = braceRange(after: head, in: out) {
            out.removeSubrange(head.lowerBound..<block.upperBound)
        }
        return out
    }

    /// Every block in braces that follows an occurrence of `head`.
    private static func blocks(after head: String, in text: String) -> [String] {
        var found: [String] = []
        var from = text.startIndex
        while let hit = text.range(of: head, range: from..<text.endIndex),
              let block = braceRange(after: hit, in: text) {
            found.append(String(text[block]))
            from = hit.upperBound
        }
        return found
    }

    @Test("die Frage, in welchem Ordner eine Datei steht, hat eine Antwort fuer Schraegstrich und Punkt")
    func theFolderQuestionHasOneAnswer() {
        let file = URL(fileURLWithPath: "/a/b/c.png")
        #expect(ImageCache.stands(file, in: URL(fileURLWithPath: "/a/b", isDirectory: true)))
        #expect(ImageCache.stands(file, in: URL(fileURLWithPath: "/a/b", isDirectory: false)))
        #expect(ImageCache.stands(file, in: URL(fileURLWithPath: "/a/./b/")))
        #expect(!ImageCache.stands(file, in: URL(fileURLWithPath: "/a")))
        #expect(!ImageCache.stands(file, in: URL(fileURLWithPath: "/a/bb")))
    }

    /// The one place that knows which covers are active is the downloads'
    /// own answer; nowhere else builds one. Every witness above injects the
    /// pending move, so the production wiring is held here: the default asks
    /// the pass itself, and the one production caller keeps that default.
    @Test("die Antwort auf aktive Cover entsteht nur im DownloadManager", .needsTheSources)
    func activeCoversAreBuiltInOnePlace() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, "the fence read the sources")
        var builders: [String] = []
        var moveNamers: [String] = []
        var askers: [String] = []
        for file in files {
            let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if code.contains("ActiveCovers(urls:") { builders.append(file.lastPathComponent) }
            if code.contains("idMovePending:") { moveNamers.append(file.lastPathComponent) }
            if code.contains(".activeCovers(") { askers.append(file.lastPathComponent) }
            #expect(!code.contains("downloadedCoverURLs"), "\(file.lastPathComponent) asks for covers without the scan")
            if file.lastPathComponent == "DownloadManager.swift" {
                #expect(code.contains("idMovePending: () -> Bool = { NavidromeRekeyRun.isPending() }"),
                        "the answer does not ask the pass whether the ids still move")
            }
            if file.lastPathComponent == "Artwork.swift" {
                #expect(code.contains("await downloads.activeCovers()"), "the sweep does not keep the default")
            }
        }
        #expect(builders == ["DownloadManager.swift"], "active covers built elsewhere: \(builders)")
        #expect(moveNamers == ["DownloadManager.swift"], "the pending move is set outside its default: \(moveNamers)")
        #expect(askers == ["Artwork.swift"], "the active covers are asked elsewhere: \(askers)")
    }
}
#endif
