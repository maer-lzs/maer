// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Teil 2: MusicBrainz recording-search response (subset) — a recording carries
/// the releases it appears on; the first release MBID drives the Cover Art
/// Archive lookup. Foundation-only (MaerCore rule).
nonisolated struct MBRecordingResponse: Decodable, Sendable {
    let recordings: [MBRecording]?
}
nonisolated struct MBRecording: Decodable, Sendable {
    let releases: [MBRelease]?
}
nonisolated struct MBRelease: Decodable, Sendable {
    let id: String
}

/// Teil 2 (pure, tested): the decision + URL/parse logic for looking up
/// now-playing cover art from an ICY "Artist - Title" pair, via MusicBrainz →
/// Cover Art Archive. No key, no proprietary third party (Mär vision). The
/// network orchestration + caching lives in `RadioArtworkService`.
nonisolated enum RadioArtworkLookup {
    /// Worth a lookup only with BOTH a non-empty artist and title — a bare
    /// station slogan or jingle ("Radio XY", "News") never resolves and would
    /// just burn a MusicBrainz request.
    static func shouldLookup(artist: String?, title: String?) -> Bool {
        !normalized(artist).isEmpty && !normalized(title).isEmpty
    }

    /// A stable, case/space-insensitive cache key for an artist/title pair.
    static func cacheKey(artist: String, title: String) -> String {
        normalized(artist) + "\u{1F}" + normalized(title)   // unit separator
    }

    /// The MusicBrainz recording-search URL — a Lucene query over recording
    /// title AND artist, JSON, capped. `URLComponents` percent-encodes the query.
    static func musicBrainzQueryURL(artist: String, title: String) -> URL? {
        let a = escapeLucene(artist), t = escapeLucene(title)
        guard !a.isEmpty, !t.isEmpty,
              var comps = URLComponents(string: "https://musicbrainz.org/ws/2/recording") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "query", value: "recording:\"\(t)\" AND artist:\"\(a)\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "3"),
        ]
        return comps.url
    }

    /// The first release MBID across the returned recordings, or nil.
    static func firstReleaseMBID(_ response: MBRecordingResponse) -> String? {
        for recording in response.recordings ?? [] {
            if let id = recording.releases?.first?.id, !id.isEmpty { return id }
        }
        return nil
    }

    private static func normalized(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Escape Lucene special characters that would otherwise break the quoted
    /// query term (a title with a `"` or `\` is the realistic case).
    /// Shared with ArtistPortraitLookup — one Lucene escaper.
    static func escapeLucene(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
