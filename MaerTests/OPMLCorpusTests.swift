// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Loads fixture files from the test bundle. They live under
/// `MaerTests/Fixtures/<subdirectory>`, but the synced folder bundles them
/// flat (measured 08.10.2026: every fixture at the bundle's root), so the
/// bundle is asked by name, and the subdirectory says nothing there. The
/// loader only delivers the bytes. Whether the bundled file is the one
/// under `Fixtures/`, and whether a caller names the folder that holds it,
/// is asked by `CorpusFixtureTests`, which needs the tests folder and shows
/// as skipped without it; inside the loader that comparison fell away
/// silently in a copy without the tests folder.
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

/// The two questions the loader no longer asks, each a witness of its own
/// that needs the tests folder.
struct CorpusFixtureTests {
    /// Every fixture file, by its path below `MaerTests/Fixtures`.
    static func fixtureFiles() throws -> [String] {
        let folder = SourceTree.root.appendingPathComponent("MaerTests/Fixtures")
        var found: [String] = []
        for url in SourceTree.files(under: folder) where !url.lastPathComponent.hasPrefix(".") {
            found.append(String(SourceTree.relativePath(of: url).dropFirst("MaerTests/Fixtures/".count)))
        }
        return found.sorted()
    }

    @Test("every fixture in the test bundle is the same file as under Fixtures/", .needsTheTests)
    func everyBundledFixtureIsTheFileUnderFixtures() throws {
        let files = try Self.fixtureFiles()
        #expect(files.contains("OPMLCorpus/OPML-MANIFEST.json"), "the witness does not find the fixtures: \(files.count)")
        // The bundle is flat: two fixtures with one name would be one file there.
        let byName = Dictionary(grouping: files) { ($0 as NSString).lastPathComponent }
        let twice = byName.filter { $0.value.count > 1 }.keys.sorted()
        #expect(twice.isEmpty, "two fixtures share a name, the flat bundle holds only one: \(twice)")
        let bundle = Bundle(for: CorpusFixtureToken.self)
        var missing: [String] = []
        var other: [String] = []
        for relative in files {
            let file = relative as NSString
            let name = (file.lastPathComponent as NSString).deletingPathExtension
            let ext = file.pathExtension
            guard let url = bundle.url(forResource: name, withExtension: ext.isEmpty ? nil : ext) else {
                missing.append(relative); continue
            }
            let source = try Data(contentsOf: SourceTree.root.appendingPathComponent("MaerTests/Fixtures/\(relative)"))
            if try Data(contentsOf: url) != source { other.append(relative) }
        }
        #expect(missing.isEmpty, "under Fixtures/ but not in the test bundle: \(missing)")
        #expect(other.isEmpty, "the bundle holds another file than under Fixtures/: \(other)")
    }

    /// The arguments of every loader call in a source: a literal stands
    /// without its quotes, anything else is nil.
    nonisolated static func loaderCalls(in code: String) -> [(name: String?, ext: String?, subdirectory: String?)] {
        let call = #/CorpusFixture\.data\(\s*([^,\n]+?)\s*,\s*ext:\s*([^,\n]+?)\s*,\s*subdirectory:\s*([^)\n]+?)\s*\)/#
        func literal(_ raw: Substring) -> String? {
            guard let match = raw.wholeMatch(of: #/"([^"\\]*)"/#) else { return nil }
            return String(match.output.1)
        }
        return code.matches(of: call).map { (literal($0.output.1), literal($0.output.2), literal($0.output.3)) }
    }

    @Test("every call of the loader names the folder in which its file lies", .needsTheTests)
    func everyLoaderCallNamesTheFolderOfItsFile() throws {
        let fixtures = SourceTree.root.appendingPathComponent("MaerTests/Fixtures")
        var named: Set<String> = []
        var wrong: [String] = []
        for folder in ["MaerTests", "MaerUITests"] {
            for url in SourceTree.files(under: SourceTree.root.appendingPathComponent(folder))
            where url.pathExtension == "swift" {
                let code = SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8))
                for call in Self.loaderCalls(in: code) {
                    // A folder built at run time (`Shared/\(area)`) is the
                    // shared cases' own fence.
                    guard let subdirectory = call.subdirectory else { continue }
                    let place = fixtures.appendingPathComponent(subdirectory)
                    if let name = call.name, let ext = call.ext {
                        named.insert("\(subdirectory)/\(name).\(ext)")
                        if !FileManager.default.fileExists(atPath: place.appendingPathComponent("\(name).\(ext)").path) {
                            wrong.append("\(url.lastPathComponent): \(subdirectory)/\(name).\(ext)")
                        }
                    } else {
                        // A name built at run time: the folder must exist and
                        // hold files of the named kind.
                        let held = (try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? []
                        if held.isEmpty || (call.ext.map { ext in !held.contains { $0.hasSuffix(".\(ext)") } } ?? false) {
                            wrong.append("\(url.lastPathComponent): \(subdirectory)/* .\(call.ext ?? "?")")
                        }
                    }
                }
            }
        }
        // The precondition names a call the witness must see: the manifest.
        #expect(named.contains("OPMLCorpus/OPML-MANIFEST.json"), "the witness does not find the loader calls: \(named.count)")
        #expect(wrong.isEmpty, "a loader call names a folder that does not hold its file: \(wrong)")
        // Calibration, written with escaped quotes so this file's own text is
        // no call: one line, a name built at run time, a folder built at run time.
        let one = Self.loaderCalls(in: "CorpusFixture.data(\"a\", ext: \"json\", subdirectory: \"OPMLCorpus\")")
        #expect(one.count == 1 && one.first?.name == "a" && one.first?.ext == "json" && one.first?.subdirectory == "OPMLCorpus")
        let built = Self.loaderCalls(in: "CorpusFixture.data(name, ext: \"xml\", subdirectory: \"RSSEdgeCorpus\")")
        #expect(built.count == 1 && built.first?.name == nil && built.first?.subdirectory == "RSSEdgeCorpus")
        let shared = Self.loaderCalls(in: "CorpusFixture.data(name, ext: \"json\", subdirectory: \"Shared/\\(area)\")")
        #expect(shared.count == 1 && shared.first?.subdirectory == nil)
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
