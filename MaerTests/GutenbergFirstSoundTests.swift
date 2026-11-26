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
        /// From this part on a read fails, for a read behind that breaks.
        var failFrom: Int?
        func read(_ url: URL) async -> GutenbergPartReading.Outcome {
            lock.withLock { count += 1; inFlight += 1; most = max(most, inFlight) }
            try? await Task.sleep(for: .milliseconds(20))
            let index = Int(url.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "0") ?? 0
            let bytes = lock.withLock { sizes.first { url.absoluteString.hasSuffix($0.key.split(separator: "/").last ?? "") }?.value } ?? 0
            let rate = (index == 0 ? 128_000 : (kbps[index] ?? 32_000))
            lock.withLock { inFlight -= 1 }
            if let failFrom = lock.withLock({ self.failFrom }), index >= failFrom { return .failed }
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

    @Test("Fence: the question is a requirement of the protocol, so the player asks the source and not the default", .needsTheSources)
    func requirementOfTheProtocol() throws {
        let text = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Providers/AudioProvider.swift"), encoding: .utf8))
        let start = try #require(text.range(of: "protocol AudioProvider:"))
        let end = try #require(text.range(of: "extension AudioProvider {", range: start.upperBound..<text.endIndex))
        #expect(text[start.upperBound..<end.lowerBound].contains("func estimatesDurations(itemId: String, beforeTrack index: Int) -> Bool"),
                "only the extension declares it: through any AudioProvider the default answers for every source")
    }

    @Test("the Gutenberg source, asked as the player asks it, says estimated after an estimated start; its plan writes no stand then and writes again once the durations are read")
    func providerAnswersThroughTheProtocol() async throws {
        let number = 990_000 + Int.random(in: 1...9_999)
        let id = FreeCatalog.gutenbergPrefix + String(number)
        let sizes = [967_056] + Array(repeating: 2_000_000, count: 11)
        let data = Self.record(number, sizes: sizes)
        let reads = Reads()
        for (index, size) in sizes.enumerated() { reads.sizes[String(format: "%d-%03d.mp3", number, index)] = size }
        let works = GutenbergWorks(wire: GutenbergWorks.Wire(record: { _ in (data, 200) }, duration: { await reads.read($0) }),
                                   suiteName: "first-sound-\(UUID().uuidString)")
        let provider: any AudioProvider = FreeCatalogProvider.shared
        _ = try await FreeCatalogProvider.shared.gutenbergDetail(itemId: id, works: works)
        #expect(provider.estimatesDurations(itemId: id, beforeTrack: 5), "the source said nothing is estimated")
        var state = SyncPlanTests.state()
        state.durationsEstimated = provider.estimatesDurations(itemId: id, beforeTrack: 5)
        #expect(SyncRules.plan(origin: .pause, state: state).gate == .estimatedDurations, "a stand was written from estimated durations")
        await works.awaitBehind()
        _ = try await FreeCatalogProvider.shared.gutenbergDetail(itemId: id, works: works)
        #expect(!provider.estimatesDurations(itemId: id, beforeTrack: 5), "the real durations did not end the estimate")
        state.durationsEstimated = provider.estimatesDurations(itemId: id, beforeTrack: 5)
        #expect(SyncRules.plan(origin: .pause, state: state).gate == .write)
    }

    /// The works and reads of one generated work, for the follow-up witnesses.
    static func works(_ number: Int, sizes: [Int], kbps: [Int: Double] = [:], failFrom: Int? = nil)
        -> (GutenbergWorks, Reads, RecordCount) {
        let data = Self.record(number, sizes: sizes)
        let reads = Reads()
        reads.kbps = kbps
        reads.failFrom = failFrom
        for (index, size) in sizes.enumerated() { reads.sizes[String(format: "%d-%03d.mp3", number, index)] = size }
        let records = RecordCount()
        let works = GutenbergWorks(wire: GutenbergWorks.Wire(record: { _ in records.add(); return (data, 200) },
                                                             duration: { await reads.read($0) }),
                                   suiteName: "first-sound-\(UUID().uuidString)")
        return (works, reads, records)
    }

    /// Unchecked because the lock guards the count.
    nonisolated final class RecordCount: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        func add() { lock.withLock { count += 1 } }
    }

    @Test("Q-4-a: a stand may be written only when no duration of the work is estimated; a mark waits for the real ones and then writes")
    func standWrite() async throws {
        let number = 980_000 + Int.random(in: 1...9_999)
        let id = FreeCatalog.gutenbergPrefix + String(number)
        let (works, _, _) = Self.works(number, sizes: [967_056] + Array(repeating: 2_000_000, count: 11))
        let provider: any AudioProvider = FreeCatalogProvider.shared
        _ = try await FreeCatalogProvider.shared.gutenbergDetail(itemId: id, works: works)
        #expect(!StandWrite.allowed(itemId: id, provider: provider), "a stand may be written from estimated durations")
        #expect(await provider.resolveDurations(itemId: id), "the mark did not get the real durations")
        #expect(StandWrite.allowed(itemId: id, provider: provider))
    }

    @Test("Fence Q-4-a: every writer of a stand asks before it writes, the marks wait for the real durations", .needsTheSources)
    func everyWriterAsks() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let writers = [("Sources/ViewModels/PlayerViewModel.swift", "ListeningStore.record("),
                       ("Sources/ViewModels/PlayerViewModel+Sync.swift", "ListeningStore.record("),
                       ("Sources/ViewModels/PlayerViewModel+Sync.swift", "ListeningStore.store(")]
        var counted = 0
        for (path, writer) in writers {
            let text = try code(path)
            var from = text.startIndex
            while let hit = text.range(of: writer, range: from..<text.endIndex) {
                counted += 1
                let start = text.index(hit.lowerBound, offsetBy: -900, limitedBy: text.startIndex) ?? text.startIndex
                let before = String(text[start..<hit.lowerBound])
                #expect(before.contains("StandWrite.allowed(") || before.contains("resolveDurations("), "\(path) writes a stand without asking")
                from = hit.upperBound
            }
        }
        #expect(counted == 5, "the writers counted: \(counted)")
        let mark = try code("Sources/ViewModels/BookFinishMark.swift")
        let apply = try #require(mark.range(of: "static func apply("))
        #expect(mark[apply.upperBound...].prefix(1_500).contains("await provider.resolveDurations(itemId:"), "a mark writes before the real durations")
    }

    @Test("Q-4-b: a start inside the book while the reads behind run gets no estimate")
    func insideWhileRunning() async throws {
        let (works, _, _) = Self.works(9727, sizes: [967_056] + Array(repeating: 2_000_000, count: 11))
        _ = try await works.start(number: 9727, atBeginning: true)
        let inside = try #require(try await works.start(number: 9727, atBeginning: false))
        #expect(inside.estimated.isEmpty, "a start inside the book got the estimate of a running read")
    }

    @Test("Q-4-c: reads behind that fail keep nothing, and the next start reads again")
    func behindFails() async throws {
        let (works, reads, _) = Self.works(9727, sizes: [967_056] + Array(repeating: 2_000_000, count: 11), failFrom: 3)
        _ = try await works.start(number: 9727, atBeginning: true)
        await works.awaitBehind()
        let before = reads.count
        reads.failFrom = nil
        let again = try #require(try await works.start(number: 9727, atBeginning: true))
        await works.awaitBehind()
        #expect(reads.count > before, "the next start did not read again")
        #expect(!again.estimated.isEmpty || reads.count >= before + 3)
    }

    @Test("Q-4-f: one read per work, and never more than four reads at once across works")
    func limitAcrossWorks() async throws {
        let sizes = [967_056] + Array(repeating: 2_000_000, count: 11)
        let data1 = Self.record(9727, sizes: sizes), data2 = Self.record(9728, sizes: sizes)
        let reads = Reads()
        for (index, size) in sizes.enumerated() {
            reads.sizes[String(format: "9727-%03d.mp3", index)] = size
            reads.sizes[String(format: "9728-%03d.mp3", index)] = size
        }
        let records = RecordCount()
        let works = GutenbergWorks(wire: GutenbergWorks.Wire(record: { number in records.add(); return (number == 9727 ? data1 : data2, 200) },
                                                             duration: { await reads.read($0) }),
                                   suiteName: "first-sound-\(UUID().uuidString)")
        async let a = works.start(number: 9727, atBeginning: false)
        async let b = works.start(number: 9728, atBeginning: false)
        async let c = works.start(number: 9727, atBeginning: false)
        _ = try await (a, b, c)
        #expect(reads.most <= 4, "\(reads.most) reads at once across works")
        #expect(records.count == 2, "the record of one work was read \(records.count - 1) times more")
    }

    @Test("Q-4-h: a part off its estimate by more than two percent: after the reads behind the real durations stand and nothing is estimated")
    func deviation() async throws {
        let number = 970_000 + Int.random(in: 1...9_999)
        let id = FreeCatalog.gutenbergPrefix + String(number)
        // Parts two and three at 32 kbit/s, part eight at 40: its estimate is 20 percent off.
        let (works, _, _) = Self.works(number, sizes: [967_056] + Array(repeating: 2_000_000, count: 11), kbps: [8: 40_000])
        let provider: any AudioProvider = FreeCatalogProvider.shared
        let estimated = try await FreeCatalogProvider.shared.gutenbergDetail(itemId: id, works: works)
        await works.awaitBehind()
        let real = try await FreeCatalogProvider.shared.gutenbergDetail(itemId: id, works: works)
        let guess = try #require(estimated.media.tracks?[8].duration), truth = try #require(real.media.tracks?[8].duration)
        #expect(GutenbergEstimate.deviates(estimate: guess, real: truth), "the precondition: part eight is off")
        #expect(!provider.estimatesDurations(itemId: id, beforeTrack: .max))
        #expect(StandWrite.allowed(itemId: id, provider: provider))
    }

    @Test("Fence Q-4-d, -e, -g: the taken durations bring their chapters, a download keeps only real durations, VoiceOver says what the line shows", .needsTheSources)
    func chaptersDownloadVoiceOver() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let player = try code("Sources/ViewModels/PlayerViewModel.swift")
        let adopt = try #require(player.range(of: "func adoptResolvedDurations("))
        #expect(player[adopt.upperBound...].prefix(1_200).contains("ChapterModel.resolved(detail:"), "the chapters stay on the estimated bounds")
        let downloads = try code("Sources/Networking/DownloadManager.swift")
        let save = try #require(downloads.range(of: "await saveDetail(item)"))
        #expect(downloads[..<save.lowerBound].suffix(900).contains("resolveDurations(itemId:"), "a download keeps estimated durations")
        #expect(try code("Sources/Views/PlayerView.swift").contains("let whole = viewModel.durationsEstimated ? Text(verbatim: left) :"))
    }

    @Test("a second start while the reads behind run answers the same estimate and reads nothing twice")
    func secondStartCoalesces() async throws {
        let sizes = [967_056] + Array(repeating: 2_000_000, count: 11)
        let data = Self.record(9727, sizes: sizes)
        let reads = Reads()
        for (index, size) in sizes.enumerated() { reads.sizes[String(format: "9727-%03d.mp3", index)] = size }
        let works = GutenbergWorks(wire: GutenbergWorks.Wire(record: { _ in (data, 200) }, duration: { await reads.read($0) }),
                                   suiteName: "first-sound-\(UUID().uuidString)")
        let first = try #require(try await works.start(number: 9727, atBeginning: true))
        let second = try #require(try await works.start(number: 9727, atBeginning: true))
        #expect(second.estimated == first.estimated)
        await works.awaitBehind()
        #expect(reads.count == 12, "the durations were read \(reads.count) times for 12 parts")
    }

    @Test("the plan writes no stand while durations before the place are estimated, not even a deliberate one")
    func planGate() {
        var state = SyncPlanTests.state()
        state.durationsEstimated = true
        #expect(SyncRules.plan(origin: .pause, state: state).gate == .estimatedDurations)
        state.durationsEstimated = false
        #expect(SyncRules.plan(origin: .pause, state: state).gate == .write)
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
