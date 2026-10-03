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
