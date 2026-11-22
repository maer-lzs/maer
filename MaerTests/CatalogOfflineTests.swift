// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Catalog audiobooks can be kept offline where the source allows a copy:
/// LibriVox always, a Gutenberg reading whose record says public domain,
/// an archive.org item with a stated licence, never a Jamendo track. The
/// one rule is pure; the catalog answers it per title, every offer asks
/// it, and the downloader asks it again.
@MainActor
struct CatalogOfflineTests {
    @Test("the rule per source: LibriVox yes, Gutenberg in the public domain, archive.org with a stated licence, Jamendo never")
    func rulePerSource() {
        func keeps(_ id: String, licence: Bool = false, publicDomain: Bool = false) -> Bool {
            FreeCatalog.mayKeepOffline(itemId: id, statedLicence: licence, gutenbergPublicDomain: publicDomain)
        }
        #expect(keeps("lv:42"))
        #expect(keeps("gut:5884", publicDomain: true))
        #expect(!keeps("gut:5884"), "a Gutenberg reading whose rights are unknown or copyrighted")
        #expect(keeps("lva:some-item", licence: true))
        #expect(!keeps("lva:some-item"), "an archive item without a stated licence")
        #expect(!keeps("jam:1848357", licence: true, publicDomain: true), "Jamendo never")
        #expect(!keeps("rss:feed:1", licence: true, publicDomain: true), "no other source through this rule")
    }

    @Test("a Gutenberg record is public domain only when its rights say so")
    func gutenbergRights() {
        #expect(FreeCatalog.gutenbergIsPublicDomain("Public domain in the USA."))
        #expect(!FreeCatalog.gutenbergIsPublicDomain("Copyrighted. Read the copyright notice inside this book for details."))
        #expect(!FreeCatalog.gutenbergIsPublicDomain(nil))
        #expect(!FreeCatalog.gutenbergIsPublicDomain(""))
    }

    private static func provider() -> FreeCatalogProvider {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-offline-\(UUID().uuidString)")
        return FreeCatalogProvider(ablage: Ablage(directory: directory))
    }

    private static func archive(_ identifier: String, licence: String?, year: String? = nil) -> ArchivePopularDoc {
        ArchivePopularDoc(identifier: identifier, title: ArchiveStringList(["T"]), creator: nil, downloads: nil, runtime: nil,
                          licenseurl: licence, year: year.map { ArchiveStringList([$0]) }, subject: nil)
    }

    @Test("the catalog answers per remembered title; a recording old enough to be public domain by its year is no stated licence")
    func catalogAnswersPerTitle() throws {
        let provider = Self.provider()
        let book = provider.remember(book: LibriVoxBook(id: "42", title: "T", language: nil, totaltimesecs: nil, url_iarchive: nil,
                                                        url_librivox: nil, url_rss: nil, authors: nil, sections: [], genres: nil))
        #expect(provider.mayKeep(itemId: book.id))
        let licensed = try #require(provider.remember(popular: Self.archive("with-licence", licence: "https://creativecommons.org/licenses/by/4.0/")))
        #expect(provider.mayKeep(itemId: licensed.id))
        let unstated = try #require(provider.remember(popular: Self.archive("without-licence", licence: nil, year: "1920")))
        #expect(!provider.mayKeep(itemId: unstated.id), "the year makes a label, not a stated licence")
        let track = try #require(provider.remember(track: JamendoTrackByIdTests.track))
        #expect(!provider.mayKeep(itemId: track.id))
        #expect(!provider.mayKeep(itemId: "lva:never-seen"), "an archive item whose licence is not known here")
        #expect(provider.capabilities.contains(.downloadable), "the catalog can download, title by title")
    }

    @Test("a netlabel or 78 release with a stated licence offers its download, one without does not; its page carries the entry as an album")
    func archiveMusicOffersItsDownload() throws {
        let provider = Self.provider()
        let licensed = try #require(provider.remember(popular: Self.archive("netlabel-with-licence", licence: "https://creativecommons.org/licenses/by-nc-sa/3.0/")))
        #expect(MediaDownloadOffer.isPossible(provider.capabilities, mayKeep: provider.mayKeep(itemId: licensed.id)))
        let unstated = try #require(provider.remember(popular: Self.archive("78-without-licence", licence: nil, year: "1928")))
        #expect(!MediaDownloadOffer.isPossible(provider.capabilities, mayKeep: provider.mayKeep(itemId: unstated.id)),
                "a record without a stated licence offers its download")
        #expect(ArchiveSeriesPage.offersMusicDownload(licensed.id, isAlbum: true), "the page of a release has no download entry")
        #expect(!ArchiveSeriesPage.offersMusicDownload(licensed.id, isAlbum: false), "a reading of the archive is no music")
        #expect(ArchiveSeriesPage.offersMusicDownload("mso:1", isAlbum: false))
    }

    @Test("every tile menu of the archive's music carries the download entry of music", .needsTheSources)
    func archiveMusicTilesCarryTheEntry() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.path.hasSuffix("/Sources/Views/Music/ArchiveMusicPages.swift") })
        let text = try SourceTree.text(file)
        let menus = text.components(separatedBy: ".contextMenu {").dropFirst().map { String($0.prefix(260)) }
        let tileMenus = menus.filter { $0.contains("CatalogDetailsButton(itemId: item.id)") }
        #expect(tileMenus.count >= 5, "the fence sees \(tileMenus.count) tile menus")
        #expect(tileMenus.allSatisfy { $0.contains("MusicDownloadMenuItems(itemId: item.id)") },
                "\(tileMenus.filter { !$0.contains("MusicDownloadMenuItems") }.count) tile menus without the download entry")
        // The 78s row on the Music tab.
        let shellac = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.path.hasSuffix("/Sources/Views/Music/ShellacSection.swift") })
        let shellacMenus = try SourceTree.text(shellac).components(separatedBy: ".contextMenu {").dropFirst()
            .map { String($0.prefix(320)) }
        #expect(!shellacMenus.isEmpty, "the fence sees no menu in the 78s row")
        #expect(shellacMenus.allSatisfy { $0.contains("MusicDownloadMenuItems(itemId: item.id)") },
                "a 78s tile menu without the download entry")
        // The catalogue music tiles of Browse and of the Music tab's rows share one menu.
        let music = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.path.hasSuffix("/Sources/Views/Music/MusicView.swift") })
        let musicText = try SourceTree.text(music)
        #expect(musicText.contains("if let musicDownload {\n            MusicDownloadMenuItems(itemId: musicDownload)"),
                "the shared collection menu draws no download entry")
        let catalogMenu = try #require(musicText.components(separatedBy: "static func catalog(_ item: LibraryItem").dropFirst().first)
        #expect(String(catalogMenu.prefix(900)).contains("musicDownload: item.id"),
                "the catalogue music tile menu passes no download entry")
        for path in ["/Sources/Views/BrowseRow.swift", "/Sources/Views/Music/MusicView.swift"] {
            let tiles = try #require(ProjectFileIntegrityTests.sourceFiles().first { $0.path.hasSuffix(path) })
            #expect(try SourceTree.text(tiles).contains("CollectionMenuItems.catalog(item, playerCoordinator: playerCoordinator)"),
                    "\(path) draws its catalogue music tiles with another menu")
        }
        let page = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.path.hasSuffix("/Sources/Views/CatalogSourcePage.swift") })
        #expect(try SourceTree.text(page).contains("Self.offersMusicDownload(itemId, isAlbum: effectiveFlavor == .album)"),
                "the page asks another rule for its download entry")
    }

    @Test("an offer needs a source that downloads and a title it may keep; a server title is kept as before")
    func offer() {
        #expect(MediaDownloadOffer.isPossible([.downloadable], mayKeep: true))
        #expect(!MediaDownloadOffer.isPossible([.downloadable], mayKeep: false))
        #expect(!MediaDownloadOffer.isPossible([], mayKeep: true))
        #expect(RSSProvider.shared.mayKeep(itemId: "rss:feed:1"), "a source without a rule keeps every title")
    }

    /// A source that may keep nothing and notes what it was asked.
    final class Withholding: AudioProvider {
        private(set) var asked: [String] = []
        var providerId: String { "withholding" }
        var keepsMarksOnDevice: Bool { true }
        var capabilities: ProviderCapabilities { [.downloadable] }
        var streamAuthHeaders: [String: String] { [:] }
        func mayKeep(itemId: String) -> Bool { false }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail { throw URLError(.resourceUnavailable) }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? {
            asked.append(contentPath)
            return nil
        }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    @Test("the downloader asks the rule again: a title its source may not keep is not fetched")
    func downloaderAsksAgain() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-withheld-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = DownloadManager(documents: directory, database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
        await manager.ensureScanned()
        let source = Withholding()
        await manager.download(item: TrackFileSizeTests.book("jam:withheld-\(UUID().uuidString)", path: "track.mp3", size: 10),
                               provider: source, kind: nil)
        #expect(source.asked.isEmpty, "the downloader asked for a track it may not keep: \(source.asked)")
    }

    @Test("Fence: every view that offers a download asks whether the title may be kept", .needsTheSources)
    func everyOfferAsks() throws {
        var unasked: [String] = []
        var offers = 0
        for (file, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = SyncContractFenceTests.stripped(text)
            let calls = code.components(separatedBy: "MediaDownloadOffer.isPossible(").count - 1
            guard calls > 0, file != "MediaDownloadOffer.swift" else { continue }
            offers += calls
            if code.components(separatedBy: "mayKeep:").count - 1 < calls { unasked.append(file) }
        }
        #expect(offers >= 6, "the precondition: the offers were read, \(offers)")
        #expect(unasked.isEmpty, "an offer that does not ask whether the title may be kept: \(unasked.sorted())")
    }
}
#endif
