// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import AVFoundation
import Foundation
import OSLog

/// Resolves a Gutenberg work to its files and durations when ONE work is
/// opened or played, and keeps the answer on the device. A row full of tiles
/// asks nothing: the tiles come from the kept stock, which carries number,
/// title and author but no sound.
///
/// Per work: one RDF request, then one duration read per file, one after the
/// other (measured 0.5 to 1 s each at gutenberg.org). Kept for good, "no
/// sound file" and "duration not readable" included; a failed request is no
/// finding and stores nothing.
actor GutenbergWorks {
    /// The key stands in `DerivedStores`, because it is derived.
    static let storeKey = "gutenbergWorks"

    typealias PartDuration = GutenbergPartReading.Outcome

    /// The two ways out, so a witness counts them without a network.
    struct Wire: Sendable {
        var record: @Sendable (Int) async throws -> (Data, Int?)
        var duration: @Sendable (URL) async -> PartDuration

        static let live = Wire(
            record: { number in
                let request = URLRequest(url: GutenbergRDF.url(number: number))
                // pglaf once when www answers a server error or rests.
                let (data, response) = try await GutenbergMirror.fetch(request) { try await RequestRetryPolicy.fetch($0) }
                return (data, response?.statusCode)
            },
            duration: { url in
                do {
                    // The asset asks gutenberg.org itself, past every door,
                    // so it names the app the way the doors do.
                    // pglaf while www rests; the part keeps the address of www.
                    let asset = AVURLAsset(url: GutenbergMirror.address(for: url),
                                           options: [AVURLAssetHTTPUserAgentKey: AppUserAgent.value])
                    return GutenbergPartReading.outcome(seconds: try await asset.load(.duration).seconds)
                } catch {
                    return GutenbergPartReading.outcome(error: error as NSError)
                }
            })
    }

    private let wire: Wire
    private let defaults: UserDefaults
    private let store = ResolutionCacheStore<GutenbergWork>(
        key: storeKey, positiveTTL: 10 * 365 * 24 * 3600, negativeTTL: 10 * 365 * 24 * 3600)
    private var kept: [String: GutenbergWork?]?
    private let flights = CoalescedFlights<GutenbergWork?>(capacity: .none)

    /// `suiteName` gives a witness its own defaults; nil is the app's.
    init(wire: Wire = .live, suiteName: String? = nil) {
        self.wire = wire
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// A start: the work, and the parts whose durations are estimated.
    struct Resolution: Sendable {
        var work: GutenbergWork
        var estimated: Set<Int>
    }

    /// The reads behind of the last estimated start.
    private var behind: Task<Void, Never>?
    /// The estimated starts whose reads behind still run: a second start of
    /// the same work answers the same and reads nothing twice.
    private var running: [String: Resolution] = [:]

    /// For a witness: returns when the reads behind are done.
    func awaitBehind() async { await behind?.value }

    /// The work for a start. A kept work as it is. A start inside the book
    /// reads every duration first. A start at the beginning reads the first
    /// three (`GutenbergEstimate.readFirst`) and, when they allow it,
    /// answers with the others estimated; the rest is read behind, four at
    /// once, and only the work with every real duration is kept.
    func start(number: Int, atBeginning: Bool) async throws -> Resolution? {
        let id = FreeCatalog.gutenbergPrefix + String(number)
        if kept == nil {
            kept = store.load(defaults: defaults, rule: { _ in GutenbergWork.rule })
        }
        if let known = kept?[id] { return known.map { Resolution(work: $0, estimated: []) } }
        if let started = running[id] { return started }
        guard atBeginning else { return try await work(number: number).map { Resolution(work: $0, estimated: []) } }
        guard let (record, files) = try await readRecord(number: number, id: id) else { return nil }
        let first = GutenbergEstimate.readFirst(count: files.count)
        let read = try await readDurations(first, of: files, id: id)
        let seconds = read.compactMapValues { $0 }
        guard let estimate = GutenbergEstimate.estimate(sizes: files.map { record.sizes[$0] }, read: seconds) else {
            let rest = try await readDurations(Array(files.indices).filter { read[$0] == nil }, of: files, id: id)
            return Resolution(work: finish(record: record, files: files, read: read.merging(rest) { a, _ in a }, id: id), estimated: [])
        }
        let parts = files.enumerated().map { index, file in
            GutenbergWork.Part(url: file, seconds: read[index] ?? estimate[index])
        }
        let estimated = GutenbergWork(title: record.title, author: record.author, parts: parts, rights: record.rights)
        Logger.library.notice("GUTENBERG \(id, privacy: .public) starts with \(estimate.count) of \(files.count) durations estimated")
        // A start that came while these reads ran answers what they started.
        if let started = running[id] { return started }
        let resolution = Resolution(work: estimated, estimated: Set(estimate.keys))
        running[id] = resolution
        behind = Task { [self] in await self.readBehind(record: record, files: files, read: read, estimate: estimate, id: id) }
        return resolution
    }

    /// Reads the rest behind; keeps the real work, and tells the app.
    private func readBehind(record: GutenbergRDF.Record, files: [String], read: [Int: Double?],
                            estimate: [Int: Double], id: String) async {
        defer { running[id] = nil }
        do {
            let rest = try await readDurations(Array(estimate.keys).sorted(), of: files, id: id)
            let all = read.merging(rest) { a, _ in a }
            let deviated = estimate.contains { index, guess in
                (all[index] ?? nil).map { GutenbergEstimate.deviates(estimate: guess, real: $0) } ?? true
            }
            _ = finish(record: record, files: files, read: all, id: id)
            Logger.library.notice("GUTENBERG \(id, privacy: .public) durations read behind, deviated=\(deviated, privacy: .public)")
            await MainActor.run {
                NotificationCenter.default.post(name: .gutenbergDurationsResolved, object: nil, userInfo: ["id": id])
            }
        } catch {
            Logger.library.notice("GUTENBERG \(id, privacy: .public) durations behind failed: \(FailureReason.of(error), privacy: .public); nothing kept")
        }
    }

    /// The work behind `gut:<number>`, or nil when its record names no
    /// sound file. Throws when the source could not be reached.
    func work(number: Int) async throws -> GutenbergWork? {
        let id = FreeCatalog.gutenbergPrefix + String(number)
        if kept == nil {
            kept = store.load(defaults: defaults, rule: { _ in GutenbergWork.rule })
        }
        if let known = kept?[id] { return known }
        let found = try await flights.value(for: id) { [self] in
            // The answer goes into a `let` before the tuple (`TupleTryAwaitFenceTests`).
            let work = try await self.resolve(number: number, id: id)
            return (work, 0)
        }
        return found
    }

    /// The record and its reading files; nil when it names no sound file
    /// (kept as such).
    private func readRecord(number: Int, id: String) async throws -> (GutenbergRDF.Record, [String])? {
        let data: Data
        let status: Int?
        do {
            (data, status) = try await wire.record(number)
        } catch is HostCourtesy.Resting {
            // www rests and pglaf does too: Gutenberg does not answer.
            throw GutenbergUnavailable()
        }
        if let status, !(200...299).contains(status) {
            // Only an absence is a finding about the work; a refusal, a
            // pause or a server error keeps nothing and the next open asks.
            if StatusMeaning.from(status: status).isAbsence {
                keep(nil, id: id)
                Logger.library.notice("GUTENBERG \(id, privacy: .public) record absent status=\(status)")
                return nil
            }
            Logger.library.notice("GUTENBERG \(id, privacy: .public) record failed status=\(status)")
            // A server error, of www and pglaf both: Gutenberg does not answer.
            if (500...599).contains(status) { throw GutenbergUnavailable() }
            throw URLError(.badServerResponse)
        }
        guard let record = GutenbergRDF.parse(data) else {
            Logger.library.notice("GUTENBERG \(id, privacy: .public) record failed status=\(status ?? 0)")
            throw URLError(.badServerResponse)
        }
        let files = GutenbergRDF.readingFiles(record.audio)
        guard !files.isEmpty else {
            keep(nil, id: id)
            Logger.library.notice("GUTENBERG \(id, privacy: .public) no sound file among \(record.audio.count)")
            return nil
        }
        return (record, files)
    }

    private func resolve(number: Int, id: String) async throws -> GutenbergWork? {
        guard let (record, files) = try await readRecord(number: number, id: id) else { return nil }
        let read = try await readDurations(Array(files.indices), of: files, id: id)
        return finish(record: record, files: files, read: read, id: id)
    }

    /// The durations of the given parts, four at once; nil seconds for a
    /// part that cannot be read. A failed read throws and keeps nothing.
    private func readDurations(_ indices: [Int], of files: [String], id: String) async throws -> [Int: Double?] {
        let wire = self.wire
        var out: [Int: Double?] = [:]
        var failed = false
        await withTaskGroup(of: (Int, PartDuration?).self) { group in
            var next = indices.makeIterator()
            func add() {
                guard let index = next.next() else { return }
                group.addTask {
                    guard let url = URL(string: files[index]) else { return (index, nil) }
                    return (index, await wire.duration(url))
                }
            }
            for _ in 0..<GutenbergEstimate.concurrent { add() }
            for await (index, outcome) in group {
                switch outcome {
                case .seconds(let seconds)?: out[index] = .some(seconds)
                case .unreadable?, nil: out[index] = .some(nil)
                case .failed?: failed = true
                }
                add()
            }
        }
        if failed {
            Logger.library.notice("GUTENBERG \(id, privacy: .public) a duration failed; nothing kept")
            throw URLError(.networkConnectionLost)
        }
        return out
    }

    /// The real work from the record and every duration; kept.
    private func finish(record: GutenbergRDF.Record, files: [String], read: [Int: Double?], id: String) -> GutenbergWork {
        let parts = files.enumerated().map { index, file in GutenbergWork.Part(url: file, seconds: read[index] ?? nil) }
        let work = GutenbergWork(title: record.title, author: record.author, parts: parts, rights: record.rights)
        keep(work, id: id)
        let unreadable = parts.filter { $0.seconds == nil }.count
        Logger.library.notice("GUTENBERG \(id, privacy: .public) kept parts=\(parts.count) unreadable=\(unreadable) seconds=\(Int(work.totalSeconds ?? 0))")
        return work
    }

    private func keep(_ work: GutenbergWork?, id: String) {
        kept?[id] = .some(work)
        store.store(work.map { .found($0) } ?? .absent, for: id, rule: GutenbergWork.rule, defaults: defaults)
    }
}

extension Notification.Name {
    /// A Gutenberg work's durations were read behind its estimated start;
    /// `userInfo["id"]` names the work.
    static let gutenbergDurationsResolved = Notification.Name("gutenbergDurationsResolved")
}
