// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The first sound of a Gutenberg work not kept yet waits for three
/// durations, not for all: the first part (it plays first) and the two
/// after it, whose bitrates, when they agree, estimate the others from
/// their size in the record. The rest is read behind, four at once, and
/// only the work with every real duration is kept. A start inside the book
/// reads all first; no stand is written from estimated durations.
@MainActor
struct GutenbergFirstSoundTests {
    /// A record of `count` parts: the first an introduction of 967 056
    /// bytes, the others of the given bytes.
    static func record(_ number: Int, sizes: [Int]) -> Data {
        var files = ""
        for (index, size) in sizes.enumerated() {
            files += """
            <dcterms:hasFormat><pgterms:file rdf:about="https://www.gutenberg.org/files/\(number)/mp3/\(number)-\(String(format: "%03d", index)).mp3">
            <dcterms:extent rdf:datatype="http://www.w3.org/2001/XMLSchema#integer">\(size)</dcterms:extent>
            <dcterms:format><rdf:Description><rdf:value rdf:datatype="http://purl.org/dc/terms/IMT">audio/mpeg</rdf:value></rdf:Description></dcterms:format>
            </pgterms:file></dcterms:hasFormat>
            """
        }
        return Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:pgterms="http://www.gutenberg.org/2009/pgterms/" xmlns:dcterms="http://purl.org/dc/terms/">
        <pgterms:ebook rdf:about="ebooks/\(number)"><dcterms:title>Work</dcterms:title><dcterms:rights>Public domain in the USA.</dcterms:rights>
        \(files)
        </pgterms:ebook></rdf:RDF>
        """.utf8)
    }

    /// Counts the duration reads and the most at once; answers by size at
    /// a bitrate per file, the first at 128 kbit/s.
    /// Unchecked because the lock guards every field.
    final class Reads: @unchecked Sendable {
        let lock = NSLock()
        var count = 0, inFlight = 0, most = 0
        var kbps: [Int: Double] = [:]
        var sizes: [String: Int] = [:]
        func read(_ url: URL) async -> GutenbergPartReading.Outcome {
            lock.withLock { count += 1; inFlight += 1; most = max(most, inFlight) }
            try? await Task.sleep(for: .milliseconds(20))
            let index = Int(url.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "0") ?? 0
            let bytes = lock.withLock { sizes.first { url.absoluteString.hasSuffix($0.key.split(separator: "/").last ?? "") }?.value } ?? 0
            let rate = (index == 0 ? 128_000 : (kbps[index] ?? 32_000))
            lock.withLock { inFlight -= 1 }
            return .seconds(Double(bytes) * 8 / rate)
        }
    }

    @Test("the record gives each sound file its size")
    func sizes() throws {
        let record = try #require(GutenbergRDF.parse(Self.record(9727, sizes: [967_056, 4_000_000, 2_000_000])))
        #expect(record.sizes.count == 3)
        #expect(record.sizes["https://www.gutenberg.org/files/9727/mp3/9727-001.mp3"] == 4_000_000)
    }

    @Test("the estimate: the bitrate of parts two and three when they agree on one percent, not of the introduction; none below four parts, without a size, or out of 16 to 320 kbit/s")
    func estimate() {
        // 9727: an introduction at 128, the book at 32 kbit/s.
        let sizes: [Int?] = [967_056, 4_008_461, 2_440_592, 1_000_000, 2_000_000]
        let read: [Int: Double] = [0: 60.37, 1: 4_008_461 * 8 / 32_000, 2: 2_440_592 * 8 / 32_000]
        let estimated = GutenbergEstimate.estimate(sizes: sizes, read: read)
        #expect(estimated?[3].map { abs($0 - 250) < 0.5 } == true, "estimated at the introduction's bitrate")
        #expect(estimated?[0] == nil && estimated?[1] == nil, "a read part is not estimated")
        #expect(GutenbergEstimate.readFirst(count: 52) == [0, 1, 2])
        #expect(GutenbergEstimate.readFirst(count: 3) == [0, 1, 2])
        #expect(GutenbergEstimate.estimate(sizes: [1, 2, 3], read: [0: 1, 1: 1, 2: 1]) == nil, "below four parts all are read")
        var disagree = read; disagree[2] = 2_440_592 * 8 / 40_000
        #expect(GutenbergEstimate.estimate(sizes: sizes, read: disagree) == nil)
        #expect(GutenbergEstimate.estimate(sizes: [967_056, 4_008_461, 2_440_592, nil, 2], read: read) == nil)
        var slow = read; slow[1] = 4_008_461 * 8 / 8_000; slow[2] = 2_440_592 * 8 / 8_000
        #expect(GutenbergEstimate.estimate(sizes: sizes, read: slow) == nil, "8 kbit/s is not plausible")
        #expect(GutenbergEstimate.concurrent == 4)
        #expect(GutenbergEstimate.deviates(estimate: 100, real: 102.1) && !GutenbergEstimate.deviates(estimate: 100, real: 101.9))
    }

    @Test("a start at the beginning reads three durations before it answers, estimates the rest, keeps nothing yet; behind, every other is read four at once and the real work is kept")
    func startAtTheBeginning() async throws {
        let sizes = [967_056] + Array(repeating: 2_000_000, count: 11)
        let data = Self.record(9727, sizes: sizes)
        let reads = Reads()
        for (index, size) in sizes.enumerated() { reads.sizes[String(format: "9727-%03d.mp3", index)] = size }
        let suite = "first-sound-\(UUID().uuidString)"
        let works = GutenbergWorks(wire: GutenbergWorks.Wire(record: { _ in (data, 200) }, duration: { await reads.read($0) }), suiteName: suite)
        let started = try #require(try await works.start(number: 9727, atBeginning: true))
        #expect(reads.count == 3, "the first sound waited for \(reads.count) durations")
        #expect(started.estimated == Set(3..<12))
        await works.awaitBehind()
        #expect(reads.count == 12)
        #expect(reads.most <= 4, "the reads behind ran \(reads.most) at once")
        let kept = try #require(try await works.work(number: 9727))
        #expect(kept.parts.allSatisfy { $0.seconds != nil })
    }

    @Test("a start inside the book reads every duration first, four at once, and estimates nothing")
    func startInside() async throws {
        let sizes = [967_056] + Array(repeating: 2_000_000, count: 11)
        let data = Self.record(9727, sizes: sizes)
        let reads = Reads()
        for (index, size) in sizes.enumerated() { reads.sizes[String(format: "9727-%03d.mp3", index)] = size }
        let works = GutenbergWorks(wire: GutenbergWorks.Wire(record: { _ in (data, 200) }, duration: { await reads.read($0) }),
                                   suiteName: "first-sound-\(UUID().uuidString)")
        let started = try #require(try await works.start(number: 9727, atBeginning: false))
        #expect(started.estimated.isEmpty && reads.count == 12)
        #expect(reads.most > 1 && reads.most <= 4, "read one after the other or more than four at once: \(reads.most)")
    }

    @Test("Fence: the player writes no stand while durations before its place are estimated, takes the real ones when they come, and shows no total it does not know", .needsTheSources)
    func playerFences() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let sync = try code("Sources/ViewModels/PlayerViewModel+Sync.swift")
        #expect(sync.contains("provider.estimatesDurations(itemId:"), "a stand is written from estimated durations")
        let player = try code("Sources/ViewModels/PlayerViewModel.swift")
        #expect(player.contains("func adoptResolvedDurations("))
        #expect(player.contains(".gutenbergDurationsResolved"))
        #expect(try code("Sources/Views/PlayerView.swift").contains("viewModel.durationsEstimated"), "the full player shows a total it does not know")
        let provider = try code("Sources/Providers/FreeCatalogProvider.swift")
        #expect(provider.contains("works.start(number: number, atBeginning:"))
    }
}
#endif
