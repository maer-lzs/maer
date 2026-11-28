// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The bar of the index (`laden` false) lives on the device and outlasts a
/// restart: an answer of archive.org before the first read of the index
/// keeps no barred title. A document that does not read, or one of another
/// form, is no empty one: until the index is read in this run no licence
/// of archive.org counts. Then the index's set holds and is written anew.
@MainActor
@Suite(.serialized)
struct IndexBarRestartTests {
    let licence = "http://creativecommons.org/licenses/by/3.0/"

    private func home() throws -> (Ablage, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("index-bars-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (Ablage(directory: directory), directory)
    }

    /// A row of the index for `identifier`, barred or not.
    private func indexRow(_ provider: FreeCatalogProvider, _ identifier: String, load: Bool) throws -> LibraryItem {
        let entry = try #require(CatalogIndexShelf.entry(CatalogIndexShelfTests.json(
            "lva:\(identifier)", step: 1, licence: licence, extra: ["laden": load])))
        return try #require(provider.remember(popular: CatalogIndexShelf.doc(entry, source: "schellack")))
    }

    /// The same title as archive.org answers it: a licence, nothing on `laden`.
    private func fromArchive(_ provider: FreeCatalogProvider, _ identifier: String) -> LibraryItem? {
        provider.remember(popular: ArchivePopularDoc(identifier: identifier, title: nil, creator: nil, downloads: nil,
                                                     runtime: nil, licenseurl: licence, year: nil, subject: nil))
    }

    private func id(_ identifier: String) -> String { FreeCatalog.archivePrefix + identifier }

    @Test("a bar of the index outlasts a restart")
    func theBarOutlastsARestart() async throws {
        let (ablage, directory) = try home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = FreeCatalogProvider(ablage: ablage)
        _ = try indexRow(before, "bar-a", load: false)
        await before.awaitPendingSave()
        let after = FreeCatalogProvider(ablage: ablage)
        _ = fromArchive(after, "bar-a")
        #expect(!after.mayKeep(itemId: id("bar-a")), "after a restart a licence of archive.org lifted the bar")
    }

    @Test("a lifted bar stays lifted after a restart")
    func theLiftOutlastsARestart() async throws {
        let (ablage, directory) = try home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = FreeCatalogProvider(ablage: ablage)
        _ = try indexRow(before, "bar-b", load: false)
        _ = try indexRow(before, "bar-b", load: true)
        await before.awaitPendingSave()
        let after = FreeCatalogProvider(ablage: ablage)
        _ = fromArchive(after, "bar-b")
        #expect(after.mayKeep(itemId: id("bar-b")), "the lifted bar came back after a restart")
        #expect(after.barSaves == 0)
        #expect(before.barSaves == 2)
    }

    @Test("the bars are written once per change")
    func aBarIsWrittenOnceAChange() throws {
        let (ablage, directory) = try home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = FreeCatalogProvider(ablage: ablage)
        _ = try indexRow(provider, "bar-c", load: false)
        _ = try indexRow(provider, "bar-c", load: false)
        _ = fromArchive(provider, "bar-c")
        #expect(provider.barSaves == 1, "a bar that did not change was written again: \(provider.barSaves)")
    }

    @Test("a document that does not read is not written over before the index is read")
    func anUnreadBarDocumentKeepsItsPlace() async throws {
        let (ablage, directory) = try home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent(FreeCatalogProvider.barsDocument)
        let held = Data("[\"\(id("old"))\"]".utf8)
        try held.write(to: document)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: document.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: document.path) }
        let provider = FreeCatalogProvider(ablage: ablage)
        _ = fromArchive(provider, "other")
        await provider.awaitPendingSave()
        #expect(provider.barSaves == 0, "the unread document was written over before the index was read")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: document.path)
        #expect(try Data(contentsOf: document) == held)
    }

    @Test("a document that does not read holds every archive.org title until the index is read")
    func anUnreadBarDocumentHoldsUntilTheIndex() async throws {
        let (ablage, directory) = try home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent(FreeCatalogProvider.barsDocument)
        try Data("[]".utf8).write(to: document)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: document.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: document.path) }
        let provider = FreeCatalogProvider(ablage: ablage)
        _ = fromArchive(provider, "held-a")
        #expect(!provider.mayKeep(itemId: id("held-a")), "an unread bar document counted as empty")
        _ = try indexRow(provider, "held-a", load: true)
        #expect(provider.mayKeep(itemId: id("held-a")), "the index read in this run did not end the caution")
        await provider.awaitPendingSave()
        #expect((try? Data(contentsOf: document)) != nil, "the bars were not written anew in a readable form")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(FreeCatalogProvider.keptDocument).path),
                "the kept titles were touched")
    }

    @Test("a document of another form holds every archive.org title until the index is read, then is written anew")
    func aBarDocumentOfAnotherFormHoldsUntilTheIndex() async throws {
        let (ablage, directory) = try home()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent(FreeCatalogProvider.barsDocument)
        try Data("{\"form\": 2, \"bars\": {}}".utf8).write(to: document)
        let provider = FreeCatalogProvider(ablage: ablage)
        _ = fromArchive(provider, "held-b")
        #expect(!provider.mayKeep(itemId: id("held-b")), "a bar document of another form counted as empty")
        _ = try indexRow(provider, "held-b", load: false)
        _ = try indexRow(provider, "free-b", load: true)
        await provider.awaitPendingSave()
        #expect(provider.mayKeep(itemId: id("free-b")))
        #expect(!provider.mayKeep(itemId: id("held-b")))
        let written = try JSONDecoder().decode([String].self, from: Data(contentsOf: document))
        #expect(written == [id("held-b")], "the document was not written anew in this build's form: \(written)")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(FreeCatalogProvider.keptDocument).path),
                "the kept titles were touched")
    }

    @Test("the bars change only where the index is read, and every change is written", .needsTheSources)
    func theBarsChangeInOnePlace() throws {
        let source = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Providers/FreeCatalogProvider.swift"))
        let changes = source.components(separatedBy: "indexBarred.").count - 1
        let reads = source.components(separatedBy: "indexBarred.contains(").count - 1
        #expect(changes - reads == 2, "the bars change elsewhere than at the row of the index: \(changes - reads)")
        let body = source.components(separatedBy: "if let load = doc.mayLoad {").dropFirst().first ?? ""
        let block = body.components(separatedBy: "\n        }\n").first ?? ""
        #expect(block.contains("saveBars()"), "a change of the bars is not written")
    }
}
#endif
