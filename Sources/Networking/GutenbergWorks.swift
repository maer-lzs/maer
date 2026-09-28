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

    enum PartDuration: Sendable, Equatable {
        case seconds(Double)
        /// The file answered and its length could not be read.
        case unreadable
        /// No way to the file; says nothing about it.
        case failed
    }

    /// The two ways out, so a witness counts them without a network.
    struct Wire: Sendable {
        var record: @Sendable (Int) async throws -> (Data, Int?)
        var duration: @Sendable (URL) async -> PartDuration

        static let live = Wire(
            record: { number in
                var request = URLRequest(url: GutenbergRDF.url(number: number))
                request.setValue(LibriVoxClient.userAgent, forHTTPHeaderField: "User-Agent")
                let (data, response) = try await RequestRetryPolicy.fetch(request)
                return (data, response?.statusCode)
            },
            duration: { url in
                do {
                    let seconds = try await AVURLAsset(url: url).load(.duration).seconds
                    return seconds.isFinite && seconds > 0 ? .seconds(seconds) : .unreadable
                } catch {
                    return NetworkReach.isOffline(error as NSError) ? .failed : .unreadable
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

    /// The work behind `gut:<number>`, or nil when its record names no
    /// sound file. Throws when the source could not be reached.
    func work(number: Int) async throws -> GutenbergWork? {
        let id = FreeCatalog.gutenbergPrefix + String(number)
        if kept == nil {
            kept = store.load(defaults: defaults, rule: { _ in GutenbergWork.rule })
        }
        if let known = kept?[id] { return known }
        let found = try await flights.value(for: id) { [self] in
            (try await self.resolve(number: number, id: id), 0)
        }
        return found
    }

    private func resolve(number: Int, id: String) async throws -> GutenbergWork? {
        let (data, status) = try await wire.record(number)
        if let status, !(200...299).contains(status) {
            // Only an absence is a finding about the work; a refusal, a
            // pause or a server error keeps nothing and the next open asks.
            if StatusMeaning.from(status: status).isAbsence {
                keep(nil, id: id)
                Logger.library.notice("GUTENBERG \(id, privacy: .public) record absent status=\(status)")
                return nil
            }
            Logger.library.notice("GUTENBERG \(id, privacy: .public) record failed status=\(status)")
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
        var parts: [GutenbergWork.Part] = []
        for file in files {
            guard let url = URL(string: file) else {
                parts.append(.init(url: file, seconds: nil))
                continue
            }
            switch await wire.duration(url) {
            case .seconds(let seconds): parts.append(.init(url: file, seconds: seconds))
            case .unreadable: parts.append(.init(url: file, seconds: nil))
            case .failed:
                Logger.library.notice("GUTENBERG \(id, privacy: .public) duration failed at part \(parts.count + 1) of \(files.count); nothing kept")
                throw URLError(.networkConnectionLost)
            }
        }
        let work = GutenbergWork(title: record.title, author: record.author, parts: parts)
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
