// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// 0714d26: free-catalog models + pure mappers — LibriVox (public-domain
/// audiobooks, keyless), archive.org (popularity + streams, keyless) and
/// Jamendo (CC music, client_id via build injection or user key).
/// Id namespaces: `lv:<bookId>` (LibriVox book) · `lva:<identifier>`
/// (archive.org item) · `jam:<trackId>` (Jamendo track).

// MARK: - LibriVox wire

nonisolated struct LibriVoxBook: Decodable, Sendable {
    struct Author: Decodable, Sendable {
        let first_name: String?
        let last_name: String?
    }
    struct Section: Decodable, Sendable {
        let section_number: String?
        let title: String?
        let listen_url: String?
        let playtime: String?
    }
    let id: String
    let title: String?
    let language: String?
    let totaltimesecs: Int?
    let url_iarchive: String?
    let url_librivox: String?
    let url_rss: String?
    let authors: [Author]?
    let sections: [Section]?
}

nonisolated struct LibriVoxFeed: Decodable, Sendable {
    let books: [LibriVoxBook]?
}

// MARK: - archive.org wire

nonisolated struct ArchivePopularDoc: Decodable, Sendable {
    let identifier: String?
    let title: String?
    let creator: String?
    let downloads: Int?
}

nonisolated struct ArchiveFile: Decodable, Sendable {
    let name: String?
    let length: String?
    let title: String?
}

// MARK: - Jamendo wire

nonisolated struct JamendoTrack: Decodable, Sendable {
    let id: String?
    let name: String?
    let artist_name: String?
    let image: String?
    let audio: String?
    let shareurl: String?
    let duration: Int?
}

// MARK: - Pure mappers

nonisolated enum FreeCatalog {
    static let librivoxPrefix = "lv:"
    static let archivePrefix = "lva:"
    static let jamendoPrefix = "jam:"

    /// Suggestion-language code → the English language NAME LibriVox stores.
    /// The API ignores language parameters (probed) — filtering is client-side
    /// over the `language` field; unknown codes filter nothing (honest).
    static func languageName(for code: String) -> String? {
        switch code.lowercased() {
        case "de": return "German"
        case "en": return "English"
        case "fr": return "French"
        case "es": return "Spanish"
        case "it": return "Italian"
        case "nl": return "Dutch"
        case "pt": return "Portuguese"
        case "pl": return "Polish"
        case "ja": return "Japanese"
        default: return nil
        }
    }

    /// Client-side language filter: keeps books whose language matches ANY
    /// selected code; when NO selected code maps (exotic locale), everything
    /// stays (an empty row would be worse than an unfiltered one).
    static func filterByLanguages(_ books: [LibriVoxBook], codes: [String]) -> [LibriVoxBook] {
        let names = Set(codes.compactMap { languageName(for: $0) })
        guard !names.isEmpty else { return books }
        let filtered = books.filter { names.contains($0.language ?? "") }
        return filtered.isEmpty ? books : filtered
    }

    /// The archive.org identifier out of `url_iarchive` (last path component).
    static func iarchiveIdentifier(from url: String?) -> String? {
        guard let url, let last = url.split(separator: "/").last, !last.isEmpty else { return nil }
        return String(last)
    }

    /// Keyless cover: the archive.org item image service.
    static func archiveCoverURL(identifier: String) -> URL? {
        URL(string: "https://archive.org/services/img/\(identifier)")
    }

    static func authorLine(_ authors: [LibriVoxBook.Author]?) -> String? {
        let names = (authors ?? []).compactMap { author -> String? in
            let name = [author.first_name, author.last_name]
                .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return name.isEmpty ? nil : name
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// "SS" / "MM:SS" / "H:MM:SS" → seconds (LibriVox playtime, archive length).
    static func seconds(_ raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count <= 3, parts.allSatisfy({ Double($0) != nil }) else { return Double(raw) }
        return parts.reversed().enumerated().reduce(0.0) { sum, pair in
            sum + (Double(pair.element) ?? 0) * pow(60, Double(pair.offset))
        }
    }

    /// LibriVox sections → sequential tracks with cumulative start offsets.
    /// Sections without a listen_url are skipped (text/intro rows).
    static func tracks(from sections: [LibriVoxBook.Section]?) -> [ABSAudioTrack] {
        var start: Double = 0
        var out: [ABSAudioTrack] = []
        for section in sections ?? [] {
            guard let url = section.listen_url, !url.isEmpty else { continue }
            let duration = seconds(section.playtime)
            out.append(ABSAudioTrack(index: out.count, startOffset: start,
                                     duration: duration, contentUrl: url,
                                     metadata: nil))
            start += duration ?? 0
        }
        return out
    }

    /// archive.org files → tracks: the 64kb MP3 rendition, name-sorted (the
    /// LibriVox naming carries the order), direct download URLs.
    static func archiveTracks(identifier: String, files: [ArchiveFile]) -> [ABSAudioTrack] {
        var start: Double = 0
        var out: [ABSAudioTrack] = []
        let mp3s = files
            .filter { ($0.name ?? "").hasSuffix("64kb.mp3") }
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
        let encodedId = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? identifier
        for file in mp3s {
            guard let name = file.name,
                  let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            else { continue }
            let duration = seconds(file.length)
            out.append(ABSAudioTrack(
                index: out.count, startOffset: start, duration: duration,
                contentUrl: "https://archive.org/download/\(encodedId)/\(encoded)",
                metadata: nil))
            start += duration ?? 0
        }
        return out
    }
}
