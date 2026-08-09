// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// F1: Radio Browser API — the open, key-free community catalog. Served by
/// volunteer MIRRORS behind round-robin DNS; we try a fixed mirror list in
/// order (the de-dupe against double-serves lives in `RadioMapping`). Every
/// request rides the shared retry policy (Y39).
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

    /// A catalog request as pure data (path + query) — built without a network
    /// call so the URL construction per endpoint is testable on its own.
    enum Query: Equatable {
        case search(name: String, limit: Int)
        case popular(limit: Int)
        case byRegion(countryCode: String, limit: Int)
        case byTag(tag: String, limit: Int)
        /// The available states (Kantone/Bundesländer) of a country.
        case states(countryName: String)
        /// All countries with station counts (explicit country choice).
        case countries
        /// Stations of ONE state, by votes (the REAL region section).
        case byState(state: String, limit: Int)
        /// e4bd910 rotation: current click-trend — nationwide or per state.
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
            case .byTag(let tag, _):
                return "/json/stations/bytagexact/\(Self.pathEscaped(tag))"
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
            case .byRegion(_, let limit), .byTag(_, let limit), .byState(_, let limit):
                return [
                    .init(name: "order", value: "votes"),
                    .init(name: "reverse", value: "true"),
                    .init(name: "limit", value: String(limit)),
                    .init(name: "hidebroken", value: "true"),
                ]
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

    /// Top stations by votes (catalog browse — "Popular").
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

    /// V2 audit fix: decode failures THROW (like the stations path) instead
    /// of collapsing to [] — inside the mirror loop a broken mirror then
    /// fails over to the next one; a total failure surfaces to the caller.
    /// Pure (tested against the wire corpus).
    nonisolated static func decodeStates(_ data: Data) throws -> [RadioBrowseEntry] {
        try JSONDecoder().decode([RBState].self, from: data).compactMap { entry in
            guard let name = entry.name, !name.isEmpty else { return nil }
            return RadioBrowseEntry(name: name, stationCount: entry.stationcount ?? 0)
        }
    }

    /// Raw state entries of a country (name + stationcount — the pure
    /// `RadioBrowseCuration` turns them into the display list).
    static func states(countryName: String) async throws -> [RadioBrowseEntry] {
        try await request(.states(countryName: countryName)) { try decodeStates($0) }
    }

    /// All countries (name + ISO code + stationcount) for the explicit
    /// country choice (b1ab99d cascade step a).
    struct RBCountry: Decodable, Sendable {
        let name: String?
        let iso_3166_1: String?
        let stationcount: Int?
    }

    /// V2 audit fix: throws like `decodeStates` (mirror failover, no silent
    /// empty country list). Pure (tested against the wire corpus).
    nonisolated static func decodeCountries(_ data: Data) throws -> [RBCountry] {
        try JSONDecoder().decode([RBCountry].self, from: data)
    }

    static func countries() async throws -> [RBCountry] {
        try await request(.countries) { try decodeCountries($0) }
    }

    /// Stations for an exact tag, by votes (genre drilldown).
    static func byTag(tag: String, limit: Int = catalogLimit) async throws -> [RadioStation] {
        try await stations(.byTag(tag: tag, limit: limit))
    }

    // MARK: - Shared mirror loop (ONE source for policy + drift-free)

    /// Runs a query across the mirror list in order; each request rides the
    /// Y39 retry policy; a mirror failure tries the next. The payload shape
    /// is the caller's `decode` closure — stations and states collapse onto
    /// this ONE loop (fixlet 4575a76: the copied loop had already drifted).
    private static func request<T>(_ query: Query,
                                   decode: (Data) throws -> T) async throws -> T {
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
            var request = URLRequest(url: url)
            // The API asks clients to identify themselves.
            request.setValue("Maer/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, http) = try await RequestRetryPolicy.fetch(request)
                guard let status = http?.statusCode, (200...299).contains(status) else {
                    lastError = URLError(.badServerResponse)
                    continue
                }
                return try decode(data)
            } catch is CancellationError {
                // Propagate cancellation immediately — no next-mirror attempt.
                throw CancellationError()
            } catch {
                // Next mirror — the policy already retried transients here.
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
