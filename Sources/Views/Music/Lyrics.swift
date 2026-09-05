// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine

/// One lyrics line; `start` in SECONDS from song start (nil = unsynced).
nonisolated struct LyricsLine: Equatable, Identifiable, Codable {
    var start: Double?
    var text: String
    var id: Double { start ?? -1 }   // unsynced lines are identified by index in the view
}

/// Lyrics of one song. Synced (timestamps) or plain text.
/// `fromWeb` marks LRCLIB results so the opt-out can gate cached
/// entries too (off = neither load nor SHOW). Old disk entries decode with
/// nil → treated as server lyrics (they age out via the 60-day TTL; honest
/// deviation, named in the report).
nonisolated struct SongLyrics: Equatable, Codable {
    var synced: Bool
    var lines: [LyricsLine]
    var fromWeb: Bool? = nil
}

/// Pure lyrics helpers: LRC parsing (LRCLIB fallback) and the OpenSubsonic
/// structured-lyrics mapping. Extracted as pure functions for tests.
nonisolated enum LyricsParser {

    /// Parse an LRC document ("[mm:ss.xx] text" per line, multiple timestamps
    /// per line allowed). Lines without a timestamp are kept unsynced-in-order;
    /// a document without ANY timestamp yields unsynced lyrics. Garbage lines
    /// (metadata tags like [ar:...]) are skipped.
    static func parseLRC(_ raw: String) -> SongLyrics? {
        var timed: [(start: Double, text: String)] = []
        var plain: [String] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let (stamps, text) = extractTimestamps(line)
            if stamps.isEmpty {
                // Metadata tags ([ar:..], [ti:..]) are not lyrics.
                if !(line.hasPrefix("[") && line.contains(":") && line.hasSuffix("]")) {
                    plain.append(line)
                }
            } else {
                for stamp in stamps where !text.isEmpty {
                    timed.append((stamp, text))
                }
            }
        }
        if !timed.isEmpty {
            let lines = timed.sorted { $0.start < $1.start }
                .map { LyricsLine(start: $0.start, text: $0.text) }
            return SongLyrics(synced: true, lines: lines)
        }
        guard !plain.isEmpty else { return nil }
        return SongLyrics(synced: false, lines: plain.map { LyricsLine(start: nil, text: $0) })
    }

    /// All leading "[mm:ss.xx]" stamps of a line (seconds) + the remaining text.
    private static func extractTimestamps(_ line: String) -> ([Double], String) {
        var stamps: [Double] = []
        var rest = Substring(line)
        while rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { break }
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            let parts = inner.split(separator: ":")
            guard parts.count == 2, let minutes = Double(parts[0]),
                  let seconds = Double(parts[1].replacingOccurrences(of: ",", with: ".")) else { break }
            stamps.append(minutes * 60 + seconds)
            rest = rest[rest.index(after: close)...]
        }
        return (stamps, rest.trimmingCharacters(in: .whitespaces))
    }

    /// LRCLIB result sanity check: their matching is by artist+title (+fuzzy
    /// duration). Reject only when both durations are known and clearly apart.
    static func lrclibDurationAcceptable(result: Double?, song: Double, tolerance: Double = 5) -> Bool {
        guard song > 0, let result, result > 0 else { return true }
        return abs(result - song) <= tolerance
    }
}

/// Fetches and caches lyrics per song: server-first (OpenSubsonic), LRCLIB as
/// an open fallback (no API key), disk-cached incl. negative hits, offline =
/// cache only. See the music settings toggle for the online lookup opt-out.
@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()
    private init() {}

    private var memory: [String: SongLyrics?] = [:]

    private nonisolated static var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated struct CacheEntry: Codable {
        var fetchedAt: Double
        var lyrics: SongLyrics?   // nil = negative hit (remembered, no re-lookup)
    }

    /// Generous TTL. Lyrics don't change; negative hits retry after expiry.
    private nonisolated static let ttl: TimeInterval = 60 * 60 * 24 * 60

    /// Cached WEB lyrics never surface while the opt-out is off.
    /// One shared gate for memory AND disk hits.
    private nonisolated static func gated(_ lyrics: SongLyrics?) -> SongLyrics? {
        guard let lyrics else { return nil }
        if lyrics.fromWeb == true, !AppStorageKeys.musicLyricsOnlineLookupValue { return nil }
        return lyrics
    }

    func lyrics(songId: String, artist: String?, title: String?, duration: Double) async -> SongLyrics? {
        if let hit = memory[songId] { return Self.gated(hit) }

        // Disk cache (positive AND negative). Off-main decode.
        let key = PodcastSubscriptions.stableHash("lyrics:\(songId)")
        let file = Self.cacheDir.appendingPathComponent("\(key).json")
        // detached because the cache read is disk work off the MainActor
        if let entry = await Task.detached(priority: .userInitiated, operation: { () -> CacheEntry? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(CacheEntry.self, from: data)
        }).value, Date().timeIntervalSince1970 - entry.fetchedAt < Self.ttl {
            memory[songId] = entry.lyrics
            return Self.gated(entry.lyrics)
        }

        // 1. Server (OpenSubsonic). Already mapped to SongLyrics at the
        // provider boundary (stage 1½).
        var result = await AppSession.shared.musicProvider.lyrics(songId: songId)

        // 2. LRCLIB fallback. Only online, only when enabled (opt-out toggle).
        if result == nil,
           AppStorageKeys.musicLyricsOnlineLookupValue,
           NetworkMonitor.shared.isConnected,
           let artist, let title {
            result = await Self.fetchLRCLIB(artist: artist, title: title, duration: duration)
            result?.fromWeb = true
        }

        memory[songId] = result
        let entry = CacheEntry(fetchedAt: Date().timeIntervalSince1970, lyrics: result)
        // detached because the cache write must finish once started
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(entry) else { return }
            try? data.write(to: file, options: .atomic)
        }
        return result
    }

    private nonisolated static func fetchLRCLIB(artist: String, title: String, duration: Double) async -> SongLyrics? {
        var comps = URLComponents(string: "https://lrclib.net/api/get")
        comps?.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        if duration > 0 {
            comps?.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration))))
        }
        guard let url = comps?.url else { return nil }
        var request = URLRequest(url: url)
        AppUserAgent.apply(to: &request)
        guard let (data, http) = try? await RequestRetryPolicy.fetch(request),
              http?.statusCode == 200 else { return nil }

        struct LRCLIBResponse: Decodable {
            let syncedLyrics: String?
            let plainLyrics: String?
            let duration: Double?
            let instrumental: Bool?
        }
        guard let decoded = try? JSONDecoder().decode(LRCLIBResponse.self, from: data),
              decoded.instrumental != true,
              LyricsParser.lrclibDurationAcceptable(result: decoded.duration, song: duration) else { return nil }
        if let synced = decoded.syncedLyrics, !synced.isEmpty, let parsed = LyricsParser.parseLRC(synced) {
            return parsed
        }
        if let plain = decoded.plainLyrics, !plain.isEmpty {
            let lines = plain.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { LyricsLine(start: nil, text: $0) }
            return lines.isEmpty ? nil : SongLyrics(synced: false, lines: lines)
        }
        return nil
    }
}
