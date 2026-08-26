// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import ABSPlayer

/// Loads corpus fixture files from the test bundle. The corpora live in
/// `Fixtures/OPMLCorpus` / `Fixtures/RSSEdgeCorpus`; depending on how the
/// synced folder bundles resources they may land flat or with their
/// subdirectory, so both locations are tried.
final class CorpusFixtureToken {}
enum CorpusFixture {
    nonisolated static func data(_ name: String, ext: String, subdirectory: String) throws -> Data {
        let bundle = Bundle(for: CorpusFixtureToken.self)
        let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/\(subdirectory)")
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory)
            ?? bundle.url(forResource: name, withExtension: ext)
        return try Data(contentsOf: try #require(url, "fixture \(name).\(ext) not in test bundle"))
    }
}

/// OPML import against the edge-case corpus (ballon8, corpus version 1.0).
/// Ground truth: `OPML-MANIFEST.json`. `expected_import_count` is the number
/// of feeds a correct importer pulls after EXACT-URL dedupe. Cases where Mär
/// deviates are wrapped in `withKnownIssue`, never silently bent green.
struct OPMLCorpusTests {

    nonisolated struct CorpusCase: Decodable, Sendable, CustomTestStringConvertible {
        let slug: String
        let file: String
        let wellFormed: Bool
        let expectedImportCount: Int
        enum CodingKeys: String, CodingKey {
            case slug, file, wellFormed = "well_formed", expectedImportCount = "expected_import_count"
        }
        var testDescription: String { slug }
    }
    private nonisolated struct Manifest: Decodable { let cases: [CorpusCase] }

    nonisolated static let corpus: [CorpusCase] = {
        guard let data = try? CorpusFixture.data("OPML-MANIFEST", ext: "json", subdirectory: "OPMLCorpus"),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        return manifest.cases
    }()

    // A failed parse returns nil.
    // Broken-xml imports 0 feeds instead of a silent partial list.

    /// Exact-URL dedupe, order-preserving. Mirrors the corpus reference
    /// importer (slash/scheme variants intentionally survive).
    private func uniqueExact(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0).inserted }
    }

    @Test func corpusManifestLoaded() {
        #expect(Self.corpus.count == 16)
    }

    @Test(arguments: corpus)
    func importCount(_ c: CorpusCase) throws {
        let data = try CorpusFixture.data(
            (c.file as NSString).deletingPathExtension, ext: "opml", subdirectory: "OPMLCorpus")
        let imported = uniqueExact(PodcastImport.parseOPML(data) ?? [])
        #expect(imported.count == c.expectedImportCount, "\(c.slug): \(imported)")
    }

    /// The dedupe semantics themselves (not just counts): exact duplicates
    /// collapse, slash/scheme variants stay distinct.
    @Test func duplicateFeedsKeepsVariants() throws {
        let data = try CorpusFixture.data("duplicate-feeds", ext: "opml", subdirectory: "OPMLCorpus")
        let imported = uniqueExact(try #require(PodcastImport.parseOPML(data)))
        #expect(imported == [
            "https://example.com/feed.xml",
            "https://example.com/feed.xml/",
            "http://example.com/feed.xml",
        ])
    }

    /// Multi-byte text must not corrupt neighbouring attribute parsing.
    @Test func umlautEmojiURLsIntact() throws {
        let data = try CorpusFixture.data("umlaut-emoji", ext: "opml", subdirectory: "OPMLCorpus")
        for url in try #require(PodcastImport.parseOPML(data)) {
            #expect(URL(string: url) != nil, "URL damaged by multi-byte neighbours: \(url)")
        }
    }
}
#endif
