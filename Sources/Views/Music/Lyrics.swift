// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog

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
        /// Whether the open service was really consulted for this entry.
        /// A no written while the lookup was off answers a narrower
        /// question than the one asked after it is on. Old entries decode
        /// as nil and keep their meaning, see `LyricsCaching`.
        var webAsked: Bool? = nil
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
        }).value, Date().timeIntervalSince1970 - entry.fetchedAt < Self.ttl,
           !LyricsCaching.negativeIsOvertaken(hasLyrics: entry.lyrics != nil,
                                              webAsked: entry.webAsked,
                                              lookupEnabled: AppStorageKeys.musicLyricsOnlineLookupValue) {
            memory[songId] = entry.lyrics
            return Self.gated(entry.lyrics)
        }

        // 1. Server (OpenSubsonic). Already mapped to SongLyrics at the
        // provider boundary (stage 1½).
        var result = await AppSession.shared.musicProvider.lyrics(songId: songId)
        // The provider swallows its own failure (`try?` at the boundary),
        // so this side cannot yet tell "the server says none" from "the
        // server did not answer". Named as the remaining half, not
        // pretended away: a server that refuses still books a no.
        var outcomes: [LyricsCaching.Outcome] = [.answered]
        /// Was the open service really consulted in this round?
        var webAsked = false

        // 2. LRCLIB fallback. Only online, only when enabled (opt-out toggle).
        if result != nil {
            outcomes.append(.notAsked)
        } else if !NetworkMonitor.shared.isConnected {
            // Nobody could be asked. A round without a question has no
            // answer to write down.
            outcomes.append(.failed)
        } else if AppStorageKeys.musicLyricsOnlineLookupValue, let artist, let title {
            let answer = await Self.fetchLRCLIB(artist: artist, title: title, duration: duration)
            outcomes.append(answer.outcome)
            result = answer.lyrics
            result?.fromWeb = true
            webAsked = true
        } else {
            // The person turned the lookup off, or the song has no artist
            // and title to ask with. A deliberate choice, not a failure.
            outcomes.append(.notAsked)
        }

        memory[songId] = result
        // A negative is written down only when a source really answered.
        // Sixty days are too long a sentence for a refusal.
        guard result != nil || LyricsCaching.mayRemember(outcomes) else { return result }
        let entry = CacheEntry(fetchedAt: Date().timeIntervalSince1970, lyrics: result, webAsked: webAsked)
        // detached because the cache write must finish once started
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(entry) else { return }
            try? data.write(to: file, options: .atomic)
        }
        return result
    }

    /// What LRCLIB said, and whether it said anything at all. The outcome
    /// travels beside the lyrics because a refusal (429 is the likely one
    /// here: the service throttles a series of questions) must not be
    /// written down as "this song has no lyrics" for sixty days.
    nonisolated struct FallbackAnswer {
        var lyrics: SongLyrics?
        var outcome: LyricsCaching.Outcome
    }

    private nonisolated static func fetchLRCLIB(artist: String, title: String, duration: Double) async -> FallbackAnswer {
        var comps = URLComponents(string: "https://lrclib.net/api/get")
        comps?.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        if duration > 0 {
            comps?.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration))))
        }
        guard let url = comps?.url else { return .init(lyrics: nil, outcome: .failed) }
        var request = URLRequest(url: url)
        AppUserAgent.apply(to: &request)
        // A status that is not 200 is an ANSWER that refuses, and no
        // answer at all is a failure. Neither says anything about the song.
        guard let (data, http) = try? await RequestRetryPolicy.fetch(request) else {
            return .init(lyrics: nil, outcome: .failed)
        }
        guard http?.statusCode == 200 else {
            Logger.music.notice("LYRICS lrclib refused status=\(http?.statusCode ?? -1)")
            return .init(lyrics: nil, outcome: .failed)
        }

        struct LRCLIBResponse: Decodable {
            let syncedLyrics: String?
            let plainLyrics: String?
            let duration: Double?
            let instrumental: Bool?
        }
        guard let decoded = try? JSONDecoder().decode(LRCLIBResponse.self, from: data),
              decoded.instrumental != true,
              LyricsParser.lrclibDurationAcceptable(result: decoded.duration, song: duration) else {
            // It answered, and what lies there is not this song's lyrics.
            // A clean no, and bookable.
            return .init(lyrics: nil, outcome: .answered)
        }
        if let synced = decoded.syncedLyrics, !synced.isEmpty, let parsed = LyricsParser.parseLRC(synced) {
            return .init(lyrics: parsed, outcome: .answered)
        }
        if let plain = decoded.plainLyrics, !plain.isEmpty {
            let lines = plain.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { LyricsLine(start: nil, text: $0) }
            return .init(lyrics: lines.isEmpty ? nil : SongLyrics(synced: false, lines: lines), outcome: .answered)
        }
        return .init(lyrics: nil, outcome: .answered)
    }
}
