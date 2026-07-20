// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

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
            case .byRegion(_, let limit), .byTag(_, let limit):
                return [
                    .init(name: "order", value: "votes"),
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

    /// Stations for an exact tag, by votes (genre drilldown).
    static func byTag(tag: String, limit: Int = catalogLimit) async throws -> [RadioStation] {
        try await stations(.byTag(tag: tag, limit: limit))
    }

    // MARK: - Shared mirror loop

    /// Runs a query across the mirror list in order (the de-dupe + Y57 variant
    /// fold happen in `RadioMapping.stations`). Each request rides the Y39 retry
    /// policy; on a mirror failure the next is tried.
    static func stations(_ query: Query) async throws -> [RadioStation] {
        var lastError: Error = URLError(.cannotConnectToHost)
        for mirror in mirrors {
            var comps = URLComponents(string: mirror + query.path)!
            comps.queryItems = query.queryItems
            var request = URLRequest(url: comps.url!)
            // The API asks clients to identify themselves.
            request.setValue("Maer/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, http) = try await RequestRetryPolicy.fetch(request)
                guard let status = http?.statusCode, (200...299).contains(status) else {
                    lastError = URLError(.badServerResponse)
                    continue
                }
                let raw = try JSONDecoder().decode([RadioBrowserStation].self, from: data)
                return RadioMapping.stations(from: raw)
            } catch {
                // Next mirror — the policy already retried transients here.
                lastError = error
            }
        }
        throw lastError
    }
}
