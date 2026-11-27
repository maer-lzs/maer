// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The music works of Project Gutenberg (class M of the Library of
/// Congress) leave the audiobook surfaces and stand in the classical area;
/// the kind of the title stays as it is.
@MainActor
struct GutenbergMusicTests {
    static func entry(_ number: Int, music: Bool?, downloads: Int, authors: String? = nil) -> CatalogStockEntry {
        CatalogStockEntry(id: "gut:\(number)", title: "Work \(number)", creator: authors, subjects: ["Music"],
                          downloads: downloads, licenseurl: nil, year: nil, music: music)
    }

    static func stock(_ entries: [CatalogStockEntry]) -> CatalogStock {
        CatalogStock(surface: CatalogSource.gutenberg.rawValue, takenAt: Date().timeIntervalSince1970,
                     watermark: nil, entries: entries)
    }

    @Test("the rule: one class is exactly M")
    func rule() {
        #expect(GutenbergMusic.isMusic(loCC: "M"))
        #expect(GutenbergMusic.isMusic(loCC: " M "))
        #expect(GutenbergMusic.isMusic(loCC: "M; PS"))
        #expect(!GutenbergMusic.isMusic(loCC: "ML"))
        #expect(!GutenbergMusic.isMusic(loCC: "PR"))
        #expect(!GutenbergMusic.isMusic(loCC: ""))
        #expect(!GutenbergMusic.isMusic(loCC: nil))
    }

    @Test("the dump: the class is read, a music row is music and the others are not", .needsTheTests)
    func dump() throws {
        let csv = try String(contentsOf: SourceTree.root.appendingPathComponent("MaerTests/Fixtures/GutenbergDump/pg_catalog-excerpt.csv"),
                             encoding: .utf8)
        let entries = CatalogStockFetch.gutenbergEntries(fromCSV: csv)
        #expect(entries.first { $0.id == "gut:3002" }?.music == true)
        #expect(entries.first { $0.id == "gut:5884" }?.music == false)
    }

    @Test("a kept stock without the class still reads, and is due for a full fetch once")
    func oldStock() throws {
        let old = #"{"surface":"gutenberg","takenAt":\#(Date().timeIntervalSince1970),"entries":[{"id":"gut:1","title":"T","subjects":[]}]}"#
        let stock = try JSONDecoder().decode(CatalogStock.self, from: Data(old.utf8))
        #expect(stock.entries.first?.music == nil)
        #expect(GutenbergMusic.needsClass(stock))
        #expect(CatalogStockRules.needsRun(stock, isDump: true), "a stock without the class waits up to 30 days")
        let fresh = Self.stock([Self.entry(1, music: false, downloads: 1)])
        #expect(!CatalogStockRules.needsRun(fresh, isDump: true))
    }

    @Test("out: the audiobook surfaces of the stock and of gutendex leave the music works out")
    func out() throws {
        let stock = Self.stock([Self.entry(1, music: true, downloads: 9), Self.entry(2, music: false, downloads: 8),
                                Self.entry(3, music: nil, downloads: 7)])
        guard case .archive(let docs, _) = try #require(CatalogShelfSource.localBrowse(rows: 10, stock: stock, source: .gutenberg)) else {
            Issue.record("no answer"); return
        }
        #expect(docs.compactMap(\.identifier).sorted() == ["gut:2", "gut:3"])
        guard case .archive(let shelf, _) = try #require(CatalogShelfSource.localShelf(terms: ["Music"], shelf: "x", rows: 10, stock: stock)) else {
            Issue.record("no shelf"); return
        }
        #expect(!shelf.compactMap(\.identifier).contains("gut:1"))
        GutenbergMusic.note(stock)
        let book = GutenbergClient.Book(id: 1, title: "Work 1", authors: nil, languages: ["en"],
                                        formats: ["audio/mpeg": "https://www.gutenberg.org/files/1/1-m/1-m-001.mp3"], subjects: nil)
        #expect(FreeCatalogProvider.shared.remember(gutenberg: book) == nil, "a known music work came as an audiobook")
        #expect(FreeCatalogProvider.shared.remember(gutenberg: book, includingMusic: true) != nil)
    }

    @Test("in: the classical lane holds only the music works, in popularity order")
    func lane() {
        let stock = Self.stock([Self.entry(1, music: true, downloads: 5), Self.entry(2, music: false, downloads: 99),
                                Self.entry(3, music: true, downloads: 50)])
        #expect(GutenbergMusic.lane(stock, rows: 10, on: Date()).map(\.id) == ["gut:3", "gut:1"])
    }

    @Test("the tile: the composer is the author, the performers are the narrators")
    func parts() {
        let liszt = GutenbergMusic.parts(authors: "Edison Concert Band; Liszt, Franz, 1811-1886 [Composer]")
        #expect(liszt == .init(composer: "Franz Liszt", performer: "Edison Concert Band"))
        let sousa = GutenbergMusic.parts(authors: "United States Marine Band [Performer]; Sousa, John Philip, 1854-1932 [Composer]")
        #expect(sousa == .init(composer: "John Philip Sousa", performer: "United States Marine Band"))
        let ian = GutenbergMusic.parts(authors: "Ian, Janis, 1951- [Performer]")
        #expect(ian == .init(composer: "Janis Ian", performer: nil))
        #expect(GutenbergMusic.parts(authors: nil) == .init(composer: nil, performer: nil))
        let item = FreeCatalogProvider.shared.remember(gutenbergMusic: Self.entry(10173, music: true, downloads: 1,
            authors: "Edison Concert Band; Liszt, Franz, 1811-1886 [Composer]"))
        #expect(item?.media?.metadata?.authorName == "Franz Liszt")
        #expect(item?.media?.metadata?.narratorName == "Edison Concert Band")
    }

    @Test("the kind stays: a Gutenberg title is a book for the player, Continue and history")
    func kindStays() {
        #expect(MediaFamily.booksTabMember("gut:10173", markedForm: nil))
        #expect(!MediaFamily.isMusicByForm("gut:10173", markedForm: nil))
    }

    @Test("Fence: the classical page shows the Gutenberg lane, search marks a known music work", .needsTheSources)
    func surfaces() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let page = try code("Sources/Views/Music/ArchiveMusicPages.swift")
        let classical = try #require(page.range(of: "if area.isClassicalPage {"))
        #expect(page[classical.upperBound...].prefix(400).contains("GutenbergMusicRow("))
        #expect(try code("Sources/ViewModels/GlobalSearchModel.swift").contains("remember(gutenberg: $0, includingMusic: true)"))
    }

    @Test("all the music works, for the page behind the row, in popularity order")
    func all() {
        let stock = Self.stock([Self.entry(1, music: true, downloads: 5), Self.entry(2, music: false, downloads: 99),
                                Self.entry(3, music: true, downloads: 50), Self.entry(4, music: true, downloads: 7)])
        #expect(GutenbergMusic.all(stock).map(\.id) == ["gut:3", "gut:4", "gut:1"])
    }

    @Test("the row says what the rights are, like Musopen")
    func rights() {
        #expect(!GutenbergMusic.rightsNotice.isEmpty)
    }

    @Test("Fence: the row leads to its page and shows its sentence, the page is a route of the music tab", .needsTheSources)
    func rowLeadsToPage() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let row = try code("Sources/Views/Music/GutenbergMusicRow.swift")
        #expect(row.contains("RowHeading.entry(verbatim: \"Project Gutenberg\", destination: MusicRoute.gutenbergMusic)"))
        #expect(row.contains("Text(GutenbergMusic.rightsNotice)"))
        let navigation = try code("Sources/Views/Music/MusicNavigation.swift")
        #expect(navigation.contains("case .gutenbergMusic:\n                GutenbergMusicPage("))
    }
}
#endif
