// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Radio Browser API. The open, key-free community catalog. Served by
/// volunteer MIRRORS behind round-robin DNS; we try a fixed mirror list in
/// order (the de-dupe against double-serves lives in `RadioMapping`). Every
/// request rides the shared retry policy.
nonisolated enum RadioBrowserClient {
    /// Known stable mirrors, tried in order. Deliberately NOT the round-robin
    /// `all.api.radio-browser.info` host: its DNS answer varies per lookup,
    /// which makes failures unreproducible.
    static let mirrors = [
        "https://de1.api.radio-browser.info",
        "https://at1.api.radio-browser.info",
        "https://nl1.api.radio-browser.info",
    ]

    static let catalogLimit = 40

    /// A catalog request as pure data (path + query). Built without a network
    /// call so the URL construction per endpoint is testable on its own.
    enum Query: Equatable {
        case search(name: String, limit: Int)
        case popular(limit: Int)
        case byRegion(countryCode: String, limit: Int)
        /// A genre, optionally narrowed to ONE country. Measured:
        /// `search?tag=<v>&tagExact=true` returns byte-identical results to
        /// the old `bytagexact/<v>` path, so one endpoint serves both the
        /// worldwide and the narrowed case. `tagExact` is a BOOLEAN. Passing
        /// the tag as its value silently drops the tag and answers with the
        /// whole country.
        case byTag(tag: String, countryCode: String?, limit: Int)
        /// The available states (Kantone/Bundesländer) of a country.
        case states(countryName: String)
        /// All countries with station counts (explicit country choice).
        case countries
        /// Stations of ONE state, by votes (the REAL region section).
        case byState(state: String, limit: Int)
        /// Current click-trend. Nationwide or per state.
        case byRegionClicktrend(countryCode: String, limit: Int)
        case byStateClicktrend(state: String, limit: Int)

        /// Path relative to a mirror host. Region/tag go into the PATH (exact-
        /// match endpoints), percent-encoded.
        var path: String {
            switch self {
            case .search:
                return "/json/stations/search"
            case .popular:
                return "/json/stations/topvote"
            case .byRegion(let cc, _):
                return "/json/stations/bycountrycodeexact/\(Self.pathEscaped(cc))"
            case .byTag:
                return "/json/stations/search"
            case .states(let country):
                return "/json/states/\(Self.pathEscaped(country))/"
            case .countries:
                return "/json/countries/"
            case .byState(let state, _):
                return "/json/stations/bystateexact/\(Self.pathEscaped(state))"
            case .byRegionClicktrend(let cc, _):
                return "/json/stations/bycountrycodeexact/\(Self.pathEscaped(cc))"
            case .byStateClicktrend(let state, _):
                return "/json/stations/bystateexact/\(Self.pathEscaped(state))"
            }
        }

        var queryItems: [URLQueryItem] {
            switch self {
            case .search(let name, let limit):
                // Search keeps its own name parameter; the others sort by votes.
                return [
                    .init(name: "name", value: name),
                    .init(name: "limit", value: String(limit)),
                    .init(name: "hidebroken", value: "true"),
                    .init(name: "order", value: "votes"),
                    .init(name: "reverse", value: "true"),
                ]
            case .popular(let limit):
                return [
                    .init(name: "limit", value: String(limit)),
                    .init(name: "hidebroken", value: "true"),
                ]
            case .states, .countries:
                return [.init(name: "hidebroken", value: "true")]
            case .byRegion(_, let limit), .byState(_, let limit):
                return [
                    .init(name: "order", value: "votes"),
                    .init(name: "reverse", value: "true"),
                    .init(name: "limit", value: String(limit)),
                    .init(name: "hidebroken", value: "true"),
                ]
            case .byTag(let tag, let countryCode, let limit):
                var items: [URLQueryItem] = [
                    .init(name: "tag", value: tag),
                    .init(name: "tagExact", value: "true"),
                    .init(name: "order", value: "votes"),
                    .init(name: "reverse", value: "true"),
                    .init(name: "limit", value: String(limit)),
                    .init(name: "hidebroken", value: "true"),
                ]
                if let countryCode, !countryCode.isEmpty {
                    items.append(.init(name: "countrycode", value: countryCode.uppercased()))
                }
                return items
            case .byRegionClicktrend(_, let limit), .byStateClicktrend(_, let limit):
                return [
                    .init(name: "order", value: "clicktrend"),
                    .init(name: "reverse", value: "true"),
                    .init(name: "limit", value: String(limit)),
                    .init(name: "hidebroken", value: "true"),
                ]
            }
        }

        private static func pathEscaped(_ raw: String) -> String {
            raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? raw
        }
    }

    // MARK: - Convenience endpoints

    static func search(name: String, limit: Int = 50) async throws -> [RadioStation] {
        try await stations(.search(name: name, limit: limit))
    }

    /// Top stations by votes (catalog browse. "Popular").
    static func popular(limit: Int = catalogLimit) async throws -> [RadioStation] {
        try await stations(.popular(limit: limit))
    }

    /// Stations for an exact ISO country code, by votes ("From your region").
    static func byRegion(countryCode: String, limit: Int = catalogLimit) async throws -> [RadioStation] {
        try await stations(.byRegion(countryCode: countryCode, limit: limit))
    }

    static func byRegionClicktrend(countryCode: String, limit: Int = catalogLimit) async throws -> [RadioStation] {
        try await stations(.byRegionClicktrend(countryCode: countryCode, limit: limit))
    }

    static func byStateClicktrend(state: String, limit: Int = catalogLimit) async throws -> [RadioStation] {
        try await stations(.byStateClicktrend(state: state, limit: limit))
    }

    static func byState(state: String, limit: Int = catalogLimit) async throws -> [RadioStation] {
        try await stations(.byState(state: state, limit: limit))
    }

    struct RBState: Decodable { let name: String?; let stationcount: Int? }

    /// Decode failures THROW (like the stations path) instead
    /// of collapsing to []. Inside the mirror loop a broken mirror then
    /// fails over to the next one; a total failure surfaces to the caller.
    /// Pure (tested against the wire corpus).
    nonisolated static func decodeStates(_ data: Data) throws -> [RadioBrowseEntry] {
        try JSONDecoder().decode([RBState].self, from: data).compactMap { entry in
            guard let name = entry.name, !name.isEmpty else { return nil }
            return RadioBrowseEntry(name: name, stationCount: entry.stationcount ?? 0)
        }
    }

    /// Raw state entries of a country (name + stationcount. The pure
    /// `RadioBrowseCuration` turns them into the display list).
    static func states(countryName: String) async throws -> [RadioBrowseEntry] {
        try await request(.states(countryName: countryName)) { try decodeStates($0) }
    }

    /// All countries (name + ISO code + stationcount) for the explicit
    /// country choice (first cascade step).
    struct RBCountry: Decodable, Sendable {
        let name: String?
        let iso_3166_1: String?
        let stationcount: Int?
    }

    /// Throws like `decodeStates` (mirror failover, no silent
    /// empty country list). Pure (tested against the wire corpus).
    nonisolated static func decodeCountries(_ data: Data) throws -> [RBCountry] {
        try JSONDecoder().decode([RBCountry].self, from: data)
    }

    static func countries() async throws -> [RBCountry] {
        try await request(.countries) { try decodeCountries($0) }
    }

    /// Stations for an exact tag, by votes (genre drilldown), optionally
    /// narrowed to one country.
    static func byTag(tag: String, countryCode: String? = nil,
                      limit: Int = catalogLimit) async throws -> [RadioStation] {
        try await stations(.byTag(tag: tag, countryCode: countryCode, limit: limit))
    }

    /// The union over SEVERAL countries. Radio Browser has no
    /// server-side multi-country filter (measured: `CH,DE` answers 0, a
    /// repeated parameter keeps only the first), so the countries are asked
    /// in parallel and joined here. An empty list means worldwide. ONE
    /// query without a country narrowing.
    ///
    /// A country whose query fails contributes nothing rather than failing
    /// the page; a total failure throws, so the view can tell "nothing found"
    /// from "could not load".
    static func byTag(tag: String, countryCodes: [String],
                      limit: Int = catalogLimit) async throws -> [RadioStation] {
        guard !countryCodes.isEmpty else {
            // Worldwide is TWO pots. The global top by votes AND the
            // device language's top. One pot alone caps before the bonus: the
            // world's top 40 is RU/UA/IR-dominated and DLF (worldwide ~49)
            // never entered it. Same union mechanic as the countries.
            //
            // The language pot degrading is allowed, but never again
            // SILENT. A swallowed failure here showed as "refresh runs clean,
            // list unchanged, DLF missing" on the device, with no witness.
            // The language pot is filtered CLIENT-side from one
            // broad fetch. The server's `languagecodes=` filter matches the
            // mixed-case catalog field case-SENSITIVELY (DLF carries "DE",
            // WDR 5 "de". One case alone lost half the pot) and silently
            // ignores an uppercase parameter altogether (measured live).
            // One request also removes the second transport, so the pot can
            // no longer degrade separately. The pot log stays the witness.
            let broad = try await byTag(tag: tag, countryCode: nil,
                                        limit: max(limit * 5, 200))
            let worldwide = Array(broad.prefix(limit))
            var union = worldwide
            if let language = Locale.current.language.languageCode?.identifier,
               !language.isEmpty {
                let wanted = language.lowercased()
                let languagePot = broad.filter { RadioGenreCuration.speaks($0, wanted) }
                union += languagePot
                Logger.library.notice("RADIO worldwide pots: global=\(worldwide.count) lang(\(language, privacy: .public))=\(languagePot.count)")
            }
            return union
        }
        // Each country reports WHAT happened. A refresh cancelling
        // the in-flight group produced three swallowed cancels, an all-nil
        // collection, and a thrown cannotConnectToHost: a cancellation
        // counted as a connection failure, one level above the fixed catches.
        // The verdict is pure (`groupVerdict`) so the fence can drive it.
        enum CountryAnswer { case hit([RadioStation]); case failed; case cancelled }
        let answers: [CountryAnswer] = try await withThrowingTaskGroup(
            of: (Int, CountryAnswer).self
        ) { group in
            for (index, code) in countryCodes.enumerated() {
                group.addTask {
                    do {
                        return (index, .hit(try await byTag(tag: tag, countryCode: code, limit: limit)))
                    } catch {
                        return (index, error.isCancellation ? .cancelled : .failed)
                    }
                }
            }
            // Keep the caller's country order. The union's sort must not
            // depend on which mirror answered first.
            var collected = [CountryAnswer](repeating: .failed, count: countryCodes.count)
            for try await (index, answer) in group { collected[index] = answer }
            return collected
        }
        let hits = answers.compactMap { if case .hit(let stations) = $0 { stations } else { nil } }
        let cancels = answers.filter { if case .cancelled = $0 { true } else { false } }.count
        switch Self.groupVerdict(hitCount: hits.count, cancelCount: cancels,
                                 total: answers.count) {
        case .cancelled: throw CancellationError()
        case .unreachable:
            // NOT "no stations": every single country failed. The view must be
            // able to tell an empty genre from an unreachable catalog.
            throw URLError(.cannotConnectToHost)
        case .union: break
        }
        return hits.flatMap { $0 }
            .sorted { ($0.votes ?? 0) > ($1.votes ?? 0) }
    }

    /// The group's failure semantics, pure: a cancel is not a failure. Not
    /// in the single catches and not in the COUNT. Only
    /// "every country genuinely failed" is unreachable; any cancel in an
    /// otherwise hitless group means the RUN was cancelled, and the page
    /// keeps what it has.
    nonisolated enum GroupVerdict: Equatable { case union, cancelled, unreachable }
    nonisolated static func groupVerdict(hitCount: Int, cancelCount: Int, total: Int) -> GroupVerdict {
        if hitCount > 0 { return .union }
        if cancelCount > 0 { return .cancelled }
        return total > 0 ? .unreachable : .union
    }

    // MARK: - Shared mirror loop (ONE source for policy + drift-free)

    /// Runs a query across the mirror list in order; each request rides the
    /// shared retry policy; a mirror failure tries the next. The payload
    /// shape is the caller's `decode` closure. Stations and states collapse
    /// onto this ONE loop, which the copied loop had already drifted from.
    private static func request<T>(_ query: Query,
                                   decode: (Data) throws -> T) async throws -> T {
        // The ONE source gate: with radio-browser off no request leaves,
        // whichever surface asks (tab browse, pickers, genre pages, search).
        // Cancellation shape on purpose: every caller treats it as "not
        // loaded", never as a broken catalog.
        guard ExternalSources.isAllowed(ExternalSources.radioBrowser) else {
            throw CancellationError()
        }
        var lastError: Error = URLError(.cannotConnectToHost)
        for mirror in mirrors {
            // A cancelled task must not walk the remaining mirrors.
            try Task.checkCancellation()
            guard var comps = URLComponents(string: mirror + query.path) else {
                lastError = URLError(.badURL)
                continue
            }
            comps.queryItems = query.queryItems
            guard let url = comps.url else {
                lastError = URLError(.badURL)
                continue
            }
            // The API asks clients to identify themselves; the fetch does.
            let request = URLRequest(url: url)
            do {
                let (data, http) = try await RequestRetryPolicy.fetch(request)
                if let status = http?.statusCode, !(200...299).contains(status) {
                    // The policy has already waited for a 429 twice. A pause
                    // that survives it is the service saying "not now", and
                    // the mirrors are one service: the next one gets no
                    // request. Every other answer tries the next mirror, and
                    // the number is no longer dropped on the way.
                    let meaning = StatusMeaning.from(status: status)
                    Logger.library.notice("RADIO browser mirror refused status=\(status) meaning=\(String(describing: meaning), privacy: .public)")
                    lastError = URLError(.badServerResponse)
                    if meaning == .throttled { break }
                    continue
                }
                guard http != nil else {
                    lastError = URLError(.badServerResponse)
                    continue
                }
                return try decode(data)
            } catch is CancellationError {
                // Propagate cancellation immediately. No next-mirror attempt.
                throw CancellationError()
            } catch {
                // Next mirror. The policy already retried transients here.
                lastError = error
            }
        }
        throw lastError
    }

    static func stations(_ query: Query) async throws -> [RadioStation] {
        try await request(query) { data in
            let raw = try JSONDecoder().decode([RadioBrowserStation].self, from: data)
            return RadioMapping.stations(from: raw)
        }
    }
}
