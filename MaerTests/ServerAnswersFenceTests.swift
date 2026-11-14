// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The measured server answers under `MaerTests/Fixtures/ServerAnswers`:
/// each is kept byte for byte as the server sent it, so it cannot carry its
/// origin inside; the origin stands here, one line per file. Every file has
/// its line and at least one witness that reads it, so no answer lies there
/// unread or of unknown source.
struct ServerAnswersFenceTests {
    /// Where each answer came from, by its path below `ServerAnswers`.
    static let origins: [String: String] = [
        "abs/podcast_feed.json":
            "Audiobookshelf 2.37 on the test server, the answer to POST api/podcasts/feed (APIClient.fetchPodcastFeed) for a synthetic feed",
    ]

    /// Every answer file, by its path below `ServerAnswers`.
    static func files() throws -> Set<String> {
        let folder = SourceTree.root.appendingPathComponent("MaerTests/Fixtures/ServerAnswers")
        var found: Set<String> = []
        for url in SourceTree.files(under: folder) where !url.lastPathComponent.hasPrefix(".") {
            found.insert(String(SourceTree.relativePath(of: url).dropFirst("MaerTests/Fixtures/ServerAnswers/".count)))
        }
        return found
    }

    /// The answer files a source reads, by their path below `ServerAnswers`.
    nonisolated static func readFiles(in code: String) -> Set<String> {
        var read: Set<String> = []
        let call = #/CorpusFixture\.data\(\s*"([^"]+)"\s*,\s*ext:\s*"([^"]+)"\s*,\s*subdirectory:\s*"ServerAnswers/([^"]+)"\s*\)/#
        for match in code.matches(of: call) {
            read.insert("\(match.output.3)/\(match.output.1).\(match.output.2)")
        }
        return read
    }

    @Test("every measured server answer carries its origin and has a reader", .needsTheTests)
    func everyAnswerHasItsOriginAndAReader() throws {
        let files = try Self.files()
        // The precondition names what the fence must see: the answer the
        // feed witness reads.
        #expect(files.contains("abs/podcast_feed.json"), "the fence does not find the answers: \(files.sorted())")
        let keys = Set(Self.origins.keys)
        #expect(files.subtracting(keys).isEmpty, "an answer without its origin: \(files.subtracting(keys).sorted())")
        #expect(keys.subtracting(files).isEmpty, "an origin whose answer is gone: \(keys.subtracting(files).sorted())")
        var read: Set<String> = []
        for folder in ["MaerTests", "MaerUITests"] {
            for url in SourceTree.files(under: SourceTree.root.appendingPathComponent(folder)) where url.pathExtension == "swift" {
                read.formUnion(Self.readFiles(in: SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8))))
            }
        }
        #expect(files.subtracting(read).isEmpty, "an answer no witness reads: \(files.subtracting(read).sorted())")
        #expect(read.subtracting(files).isEmpty, "a witness reads an answer that is not there: \(read.subtracting(files).sorted())")
        // Calibration: one line, a call wrapped over lines, a shared case
        // file (not an answer). Written with escaped quotes, so this file's
        // own text is no reader.
        #expect(Self.readFiles(in: "CorpusFixture.data(\"a\", ext: \"json\", subdirectory: \"ServerAnswers/abs\")") == ["abs/a.json"])
        #expect(Self.readFiles(in: "CorpusFixture.data(\n  \"b\", ext: \"xml\",\n  subdirectory: \"ServerAnswers/rss\")") == ["rss/b.xml"])
        #expect(Self.readFiles(in: "CorpusFixture.data(\"c\", ext: \"json\", subdirectory: \"Shared/abos\")").isEmpty)
    }
}
#endif
