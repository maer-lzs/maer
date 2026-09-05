// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

// The pure decoders of the free catalogues: `Data` in, entries out, nothing
// else. Same cut as the importer (decoding pure, reading impure): the
// clients in `FreeCatalogClients` fetch and hand the bytes here. This file
// knows no stock, no store, no settings and no session, so a Linux build of
// the pure layer needs the decoders and the models, not half a client.

/// LibriVox's JSON feed.
nonisolated enum LibriVoxDecoder {
    static func decodeFeed(_ data: Data) throws -> [LibriVoxBook] {
        try JSONDecoder().decode(LibriVoxFeed.self, from: data).books ?? []
    }
}

/// gutendex (Project Gutenberg).
nonisolated enum GutenbergDecoder {
    /// Also Encodable: the Gutenberg shelf stock is cached for a day, and
    /// caching the SOURCE form means a cached shelf rebuilds exactly the tiles
    /// a live one would, through the same `remember(gutenberg:)`. No second
    /// shape, no second truth.
    nonisolated struct Book: Codable, Sendable {
        let id: Int
        let title: String?
        let authors: [Author]?
        let languages: [String]?
        let formats: [String: String]?
        /// Gutendex delivers `subjects` as plain strings. Passed on
        /// so the genre axis has material here too.
        let subjects: [String]?

        nonisolated struct Author: Codable, Sendable { let name: String? }
    }

    nonisolated struct Response: Decodable, Sendable {
        let count: Int?
        let results: [Book]?
    }

    static func decode(_ data: Data) throws -> [Book] {
        try JSONDecoder().decode(Response.self, from: data).results ?? []
    }

    /// The stock rides in the answer we fetch anyway (`count`). The same
    /// shape as `numFound` on the archive.org side. A shelf can therefore
    /// state its real size instead of its loaded excerpt.
    static func decodeWithCount(_ data: Data) throws -> (books: [Book], total: Int?) {
        let answer = try JSONDecoder().decode(Response.self, from: data)
        return (answer.results ?? [], answer.count)
    }
}

/// archive.org's advanced search and metadata endpoints.
nonisolated enum ArchiveDecoder {
    nonisolated struct SearchResponse: Decodable {
        struct Body: Decodable {
            let docs: [ArchivePopularDoc]?
            /// The STOCK behind a query. How much there is, not how much
            /// happened to be loaded. The server states it; this only carries
            /// it through to the shelf heading.
            let numFound: Int?
        }
        let response: Body?
    }
    nonisolated struct MetadataResponse: Decodable {
        struct Meta: Decodable {
            // Same list-capable fields on the metadata endpoint.
            let title: ArchiveStringList?
            let creator: ArchiveStringList?
            /// The item description for the series and detail pages.
            let description: ArchiveStringList?
            /// The collections. The item's FORM is read from them, and on
            /// this endpoint it arrives even for an item that was never in a
            /// row (a deep link, a playlist entry, a cold start).
            let collection: ArchiveStringList?
        }
        let files: [ArchiveFile]?
        let metadata: Meta?
    }

    static func decodePopular(_ data: Data) throws -> [ArchivePopularDoc] {
        try JSONDecoder().decode(SearchResponse.self, from: data).response?.docs ?? []
    }

    /// How many items the query has IN TOTAL. The number a shelf heading
    /// names. No second request: the stock rides along with the page that is
    /// being fetched anyway.
    static func decodeTotal(_ data: Data) throws -> Int? {
        try JSONDecoder().decode(SearchResponse.self, from: data).response?.numFound
    }

    static func decodeMetadata(_ data: Data) throws -> MetadataResponse {
        try JSONDecoder().decode(MetadataResponse.self, from: data)
    }

    /// The metadata SUB-PATH wraps its answer in `result`. MEASURED, not
    /// assumed (8.282 B against 1.359.765 B for the same item. Factor 164).
    /// Decoding it as the bare block would have answered nothing at all,
    /// silently, which is exactly how the cover field was almost lost.
    static func decodeMetadataSubPath(_ data: Data) throws -> MetadataResponse.Meta? {
        struct SubPath: Decodable { let result: MetadataResponse.Meta? }
        return try JSONDecoder().decode(SubPath.self, from: data).result
    }
}

/// Jamendo's envelope.
nonisolated enum JamendoDecoder {
    nonisolated struct TracksResponse: Decodable {
        /// Jamendo's answer envelope. Errors arrive INSIDE a 200: the
        /// envelope then says `status: "failed"` with a code and a message,
        /// and carries no `results` key at all.
        nonisolated struct Headers: Decodable {
            let status: String?
            let code: Int?
            let error_message: String?
        }
        let headers: Headers?
        let results: [JamendoTrack]?
    }

    /// A failure Jamendo STATED, as opposed to one the transport had. The
    /// row's line and the log both hang on knowing which one it was.
    nonisolated struct JamendoFailure: Error {
        let status: Int?
        let code: Int?
        let message: String?
        let retryAfter: String?
    }

    /// A stated failure THROWS instead of decaying to an empty list.
    ///
    /// Jamendo reports errors inside a 200: the envelope says `failed` and
    /// carries no `results` key. Decoded as `results ?? []`, a throttled or
    /// rejected answer was indistinguishable from "the chart is empty", and
    /// the row showed "answered without tracks" for something that was
    /// never an empty answer. The same class as the gpodder captive-portal
    /// lesson: empty is a meaningful value, so nothing may decay into it.
    static func decodeTracks(_ data: Data) throws -> [JamendoTrack] {
        let envelope = try JSONDecoder().decode(TracksResponse.self, from: data)
        if let headers = envelope.headers, headers.status == "failed" {
            throw JamendoFailure(status: nil, code: headers.code,
                                 message: headers.error_message, retryAfter: nil)
        }
        return envelope.results ?? []
    }
}
