// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// V7: `podcast:transcript` parsing — SRT, WebVTT and the Podcasting-2.0
/// JSON shape, sniffed by CONTENT (the tag's `type` attribute is community
/// data and lies). Everything maps onto the SAME `SongLyrics` shape the
/// lyrics panel renders (Regel 2 — one synced-text surface, no second
/// panel idiom). Pure + tested; an unparseable document yields nil and the
/// player entry simply stays away (no false affordance).
nonisolated enum PodcastTranscript {

    static func parse(_ data: Data) -> SongLyrics? {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lines: [LyricsLine]
        if trimmed.hasPrefix("WEBVTT") {
            lines = parseCues(trimmed, header: true)
        } else if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            lines = parseJSON(data)
        } else if trimmed.range(of: "-->") != nil {
            lines = parseCues(trimmed, header: false)   // SRT
        } else {
            return nil
        }
        guard !lines.isEmpty else { return nil }
        return SongLyrics(synced: lines.contains { $0.start != nil }, lines: lines)
    }

    /// SRT and VTT share the cue structure: optional index line, a
    /// "start --> end" line, then text lines until a blank line.
    static func parseCues(_ text: String, header: Bool) -> [LyricsLine] {
        var out: [LyricsLine] = []
        var currentStart: Double?
        var currentText: [String] = []
        func flush() {
            let body = currentText.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if let start = currentStart, !body.isEmpty {
                out.append(LyricsLine(start: start, text: body))
            }
            currentStart = nil
            currentText = []
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if header, line.hasPrefix("WEBVTT") || line.hasPrefix("NOTE") { continue }
            if let range = line.range(of: "-->") {
                flush()
                currentStart = timestamp(String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces))
                continue
            }
            // A pure cue-index line (SRT) opens a cue — skip it.
            if currentStart == nil, Int(line) != nil { continue }
            if currentStart != nil {
                // Strip inline VTT voice/markup tags (<v Speaker>, <i>, …).
                currentText.append(stripTags(line))
            }
        }
        flush()
        return out
    }

    /// Podcasting-2.0 JSON: {"segments":[{"startTime": 1.2, "body": "…"}]}.
    static func parseJSON(_ data: Data) -> [LyricsLine] {
        struct Segment: Decodable {
            let startTime: Double?
            let body: String?
        }
        struct Doc: Decodable { let segments: [Segment]? }
        guard let doc = try? JSONDecoder().decode(Doc.self, from: data) else { return [] }
        return (doc.segments ?? []).compactMap { segment in
            guard let body = segment.body?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else { return nil }
            return LyricsLine(start: segment.startTime, text: body)
        }
    }

    /// "HH:MM:SS.mmm" / "MM:SS.mmm" / SRT's comma variant → seconds.
    static func timestamp(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3,
              let seconds = Double(parts.last ?? "") else { return nil }
        var total = seconds
        if parts.count >= 2, let minutes = Double(parts[parts.count - 2]) { total += minutes * 60 }
        if parts.count == 3, let hours = Double(parts[0]) { total += hours * 3600 }
        return total
    }

    static func stripTags(_ line: String) -> String {
        var out = ""
        var inTag = false
        for ch in line {
            if ch == "<" { inTag = true; continue }
            if ch == ">" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// V7: fetch + session-cache for episode transcripts (URL → parsed panel
/// data). Network fetch is best-effort; a failure logs and the panel entry
/// stays away (the tag promised something the server didn't deliver).
@MainActor
final class PodcastTranscriptService {
    static let shared = PodcastTranscriptService()
    private var cache: [String: SongLyrics?] = [:]

    func transcript(for url: String) async -> SongLyrics? {
        if let hit = cache[url] { return hit }
        guard let remote = URL(string: url) else {
            cache[url] = SongLyrics?.none
            return nil
        }
        let parsed: SongLyrics?
        do {
            let (data, _) = try await RequestRetryPolicy.fetch(URLRequest(url: remote))
            parsed = PodcastTranscript.parse(data)
            if parsed == nil {
                Logger.rss.notice("transcript at \(remote.host ?? "?", privacy: .public) did not parse (SRT/VTT/JSON sniff failed)")
            }
        } catch {
            Logger.rss.notice("transcript fetch failed: \(String(describing: error), privacy: .public)")
            parsed = nil
        }
        cache[url] = parsed
        return parsed
    }
}
