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

/// 3ac9183: archive.org list-capable fields — the georgeblood classical
/// docs deliver `creator` as an ARRAY (composer + orchestra + conductor),
/// LibriVox docs as a plain string; title/subject can do the same. ONE
/// shared tolerant decode (lenientID spirit): both shapes accepted, any
/// OTHER type still throws (wire discipline unchanged).
nonisolated struct ArchiveStringList: Decodable, Sendable {
    let values: [String]
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            values = [single]
        } else {
            values = try container.decode([String].self)
        }
    }
    init(_ values: [String]) { self.values = values }
    /// Row display: the FIRST entry leads (archive.org puts the composer first).
    var first: String? { values.first }
    /// Detail display: everyone named, comma-joined.
    var joined: String? { values.isEmpty ? nil : values.joined(separator: ", ") }
}

nonisolated struct ArchivePopularDoc: Decodable, Sendable {
    let identifier: String?
    let title: ArchiveStringList?
    let creator: ArchiveStringList?
    let downloads: Int?
    /// ea6e002: the search index carries the total runtime as "H:MM:SS" for
    /// most (NOT all) items — the card's time line reads it via
    /// `FreeCatalog.runtimeSeconds`; absent stays honestly absent.
    let runtime: String?
    /// e948444: the stated licence — shown to the user, because a
    /// CC-BY-NC-ND title is not the same as public domain.
    let licenseurl: String?
    /// 50aefa8: recording year where the index has one. For sources without a
    /// licence field this is the user's only means of judging the age of a
    /// recording — so it is shown, and its ABSENCE stays visible too.
    let year: ArchiveStringList?
}

nonisolated struct ArchiveFile: Decodable, Sendable {
    let name: String?
    let length: String?
    let title: String?
    /// 37e4a23: archive.org's rendition label ("VBR MP3", "64Kbps MP3", …) —
    /// the format PREFERENCE chain picks by this, not by filename suffix.
    let format: String?
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

/// 5034add: THE gate hierarchy for every free-catalog surface — master
/// (General pill) > area feature toggles (audiobooks/music pill) > service
/// opt-outs (network-services page). ONE pure function all catalog paths
/// ask (Regel 2 — never five copied checks); master off means OFF: no UI
/// surface and no network traffic.
nonisolated enum FreeCatalogActivation {
    static func effective(master: Bool, feature: Bool, service: Bool) -> Bool {
        master && feature && service
    }
}

nonisolated enum FreeCatalog {
    static let librivoxPrefix = "lv:"
    static let archivePrefix = "lva:"
    static let jamendoPrefix = "jam:"
    /// 0ce5df3: Project Gutenberg audiobook (`gut:<bookId>`).
    static let gutenbergPrefix = "gut:"

    /// c3ab12e: THE list of catalog namespaces, kept BY THE SOURCE that owns
    /// them. The router used to carry string literals of its own — so when
    /// Gutenberg arrived, `gut:` was added here and forgotten there, and every
    /// Gutenberg cover request went to the Audiobookshelf server (with the
    /// access token in the query string) for a title that does not exist there.
    /// 41 × 404 later CrowdSec read it as an attack and locked the owner out of
    /// his own server. A new source now only has to appear in THIS list.
    static let allPrefixes = [librivoxPrefix, archivePrefix, jamendoPrefix, gutenbergPrefix]

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

    /// f374330: suggestion-language code → ISO-639-3 variants as archive.org
    /// stores them (probed: librivoxaudio carries "deu" [840] with 2 "ger"
    /// stragglers; plain names score 0) — the popular row filters SERVER-side.
    static func iso639_3(for code: String) -> [String] {
        switch code.lowercased() {
        case "de": return ["deu", "ger"]
        case "en": return ["eng"]
        case "fr": return ["fra", "fre"]
        case "es": return ["spa"]
        case "it": return ["ita"]
        case "nl": return ["nld", "dut"]
        case "pt": return ["por"]
        case "pl": return ["pol"]
        case "ja": return ["jpn"]
        case "sv": return ["swe"]
        case "no": return ["nor"]
        case "da": return ["dan"]
        case "fi": return ["fin"]
        case "ko": return ["kor"]
        default: return []
        }
    }

    /// The language clause for advancedsearch — OR over every ISO variant of
    /// every selected code; nil when nothing maps (then no filter, honest).
    static func archiveLanguageClause(codes: [String]) -> String? {
        let variants = codes.flatMap { iso639_3(for: $0) }
        guard !variants.isEmpty else { return nil }
        return "(" + variants.map { "language:\"\($0)\"" }.joined(separator: " OR ") + ")"
    }

    /// ea6e002 (pure): archive.org's `runtime` string → seconds. The field
    /// is user-entered metadata: "H:MM:SS", "MM:SS", and malformed variants
    /// like "16:31.09" (a dot for the last separator) all occur. Anything
    /// that does not read as a time is nil — a wrong duration is worse than
    /// none (the card then reserves the line without content).
    static func runtimeSeconds(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let parts = raw.split(whereSeparator: { $0 == ":" || $0 == "." })
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + Double(value)
        }
        // Minutes/seconds above 59 mean the string was not a duration.
        if parts.count >= 2, let last = Int(parts[parts.count - 1]), last > 59 { return nil }
        if parts.count == 3, let mid = Int(parts[1]), mid > 59 { return nil }
        return total > 0 ? total : nil
    }

    /// b81949f (pure): total runtime of an archive.org item from its file
    /// list. archive.org carries the length on the audio DERIVATIVES, and
    /// only some of them (the 128 kbps MP3 set is the reliable one; VBR/64k
    /// entries often ship without `length`). Strategy: group by format, take
    /// the group with the LARGEST total — that is the complete audio set —
    /// and ignore everything without a usable length.
    ///
    /// Measured against LibriVox's own `totaltimesecs` (Klein Zaches):
    /// 15731 s here vs. 15733 s there — a 2-second difference on 4:22 h.
    static func runtimeSeconds(fromFiles files: [(format: String?, length: String?)]) -> Double? {
        var byFormat: [String: Double] = [:]
        for file in files {
            guard let format = file.format, let raw = file.length,
                  let seconds = fileLength(raw), seconds > 0 else { continue }
            byFormat[format, default: 0] += seconds
        }
        return byFormat.values.max()
    }

    /// archive.org writes lengths as plain seconds ("1573.21") or as
    /// "MM:SS"/"H:MM:SS" depending on the derivative.
    static func fileLength(_ raw: String) -> Double? {
        if let plain = Double(raw) { return plain > 0 ? plain : nil }
        return runtimeSeconds(raw)
    }

    /// e948444 (pure): the licence URL as a short, honest label. Unknown
    /// forms keep the raw URL rather than being flattened to "free".
    static func licenceLabel(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        let lower = url.lowercased()
        if lower.contains("publicdomain") || lower.contains("mark/1.0") {
            return String(localized: "Public domain")
        }
        guard let range = lower.range(of: "creativecommons.org/licenses/") else { return url }
        let rest = lower[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        return rest.isEmpty ? url : "CC " + rest.uppercased()
    }

    /// bca2d20 (pure): user-made compilations of LibriVox recordings sit in
    /// `audio_bookspoetry` WITHOUT being in `collection:librivoxaudio` — the
    /// query filter misses them, and the same content would stand twice in
    /// the catalog (measured example: `LibriVoxHorror_2007-2017`). Identifier,
    /// title and creator carry the name, so a fold match is enough; being
    /// conservative here costs at most a duplicate-free false negative.
    static func isNotLibriVoxDuplicate(_ doc: ArchivePopularDoc) -> Bool {
        let haystack = [doc.identifier, doc.title?.joined, doc.creator?.joined]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return !haystack.contains("librivox")
    }

    /// 0ce5df3 (pure): is this Gutenberg audio a real AUDIOBOOK? Measured
    /// on the full stock (1.124 entries): the readings live under
    /// `/files/<id>/mp3/…` (885) and `/files/<id>/<id>-m/…` (184), while
    /// `/files/<id>/<id>-h/audio/…` holds MUSIC EXAMPLES inside scholarly
    /// texts ("Navaho Legends", "The Lhota Nagas") — those would go wrong in
    /// an audiobook row. Same class as the LibriVox junk filter: the path
    /// tells them apart, no guessing needed.
    /// The cover that rides in Gutendex' `formats` map. Pure so the choice of
    /// key (and the https guard) is testable — measured 05.08.: every entry on
    /// page 1 carries `image/jpeg`.
    /// 50aefa8: the tile's meta line — recording year and runtime, whichever
    /// is known. Pure so the "absent stays absent" rule is testable: where the
    /// source states no year we show none, we do not guess one. For sources
    /// without a licence field the year is the user's ONLY means of judging a
    /// recording's age, so it leads.
    static func catalogMetaLine(year: String?, runtime: String?) -> String {
        let parts = [year?.trimmingCharacters(in: .whitespaces), runtime]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        // A reserved blank keeps the cell heights uniform (Jank-Regel).
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    static func gutenbergCoverURL(formats: [String: String]?) -> URL? {
        guard let raw = formats?["image/jpeg"] ?? formats?["image/png"],
              let url = URL(string: raw), url.scheme == "https" else { return nil }
        return url
    }

    static func isGutenbergAudiobook(_ audioURL: String) -> Bool {
        !audioURL.contains("-h/audio/")
    }

    /// 938aebc (pure): fair round-robin over per-language result lists —
    /// ONE combined popularity query cannot work, English download counts
    /// bury every minority language. Empty lists are skipped, the caller's
    /// limit caps the row, duplicates (same identifier in two languages)
    /// drop on first come.
    static func interleaveByLanguage<T>(_ lists: [[T]], limit: Int,
                                        key: (T) -> String) -> [T] {
        var out: [T] = []
        var seen = Set<String>()
        var index = 0
        while out.count < limit {
            var progressed = false
            for list in lists where index < list.count {
                progressed = true
                let candidate = list[index]
                if seen.insert(key(candidate)).inserted {
                    out.append(candidate)
                    if out.count == limit { return out }
                }
            }
            if !progressed { break }
            index += 1
        }
        return out
    }

    /// 7edb21b: mix LibriVox books into the Discover row at a MODERATE
    /// share — after every `interval` recommendations one book, hard-capped
    /// (pure, tested; the Fortsetzen-Deckel-Denke).
    static func discoverMix<R, B>(recommendations: [R], books: [B],
                                  interval: Int = 4) -> [(rec: R?, book: B?)] {
        var out: [(rec: R?, book: B?)] = []
        var bookIndex = 0
        for (index, rec) in recommendations.enumerated() {
            out.append((rec: rec, book: nil))
            if (index + 1) % interval == 0, bookIndex < books.count {
                out.append((rec: nil, book: books[bookIndex]))
                bookIndex += 1
            }
        }
        // Leftover books trail when recommendations run short (never lost).
        while bookIndex < books.count {
            out.append((rec: nil, book: books[bookIndex]))
            bookIndex += 1
        }
        return out
    }

    /// b395e5f: pull the `itunes:image` href out of a book RSS WITHOUT a
    /// full feed parse (one tag scan; the hi-res cover behind it is a real
    /// archive.org scan, ~100 KB, reached via redirect — URLSession follows).
    static func extractItunesImage(_ rssData: Data) -> String? {
        guard let text = String(data: rssData, encoding: .utf8) else { return nil }
        guard let tagRange = text.range(of: "<itunes:image") else { return nil }
        let after = text[tagRange.upperBound...]
        guard let hrefRange = after.range(of: "href=\"") else { return nil }
        let start = after[hrefRange.upperBound...]
        guard let end = start.firstIndex(of: "\"") else { return nil }
        let url = String(start[..<end])
        return url.hasPrefix("http") ? url : nil
    }

    /// aed5d25: known artifact classes the downloads sort washes up —
    /// cover-art dumps, m4b/complete-collection bundles, thumbs, test items.
    /// Deny patterns match identifier OR title (folded); list extendable.
    static let artifactPatterns: [String] = [
        "cdcoverart", "thumbs", "m4b", "complete collection",
        "complete_collection", "librivox_test", "test_item",
    ]

    static func isArtifactDoc(identifier: String?, title: String?) -> Bool {
        let hay = ((identifier ?? "") + " " + (title ?? "")).lowercased()
        return artifactPatterns.contains { hay.contains($0) }
    }

    /// aed5d25 (2): plausibility bounds for an archive item's track list —
    /// a real audiobook has SOME parts; hundreds mean a collection bundle.
    ///
    /// e948444: the bound is a PARAMETER now, because the Old-Time-Radio
    /// collection inverts the assumption: there a bundle IS the unit (the
    /// Gunsmoke series item carries 487 episodes, Suspense 911), and seven of
    /// the twelve most-downloaded items would be thrown away by the default.
    /// The 200 stays the guard against ACCIDENTAL bundles in the generic
    /// searches; a curated series collection passes its own, higher bound.
    static let defaultTrackCap = 200
    static let seriesTrackCap = 1_000

    static func trackCountPlausible(_ count: Int, cap: Int = defaultTrackCap) -> Bool {
        count >= 1 && count <= cap
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
    /// 37e4a23: format PREFERENCE chain per item instead of the hard 64kb
    /// filter — georgeblood classical items carry ONLY "VBR MP3" (+ 24bit
    /// FLAC), so the 64kb-derived URL pointed nowhere (NSURLError -1008).
    /// Chain: 64kb MP3 → 128kb MP3 → VBR MP3 → M4A/AAC. Ogg is NOT in the
    /// chain (AVPlayer cannot play Vorbis); FLAC deliberately left out
    /// (AVPlayer capability unconfirmed here, and 24-bit 78rpm FLACs are
    /// huge — named in the report, not silently). Empty result falls under
    /// the existing plausibility gate at the call site.
    static let formatPreference: [String] = ["64kbps mp3", "128kbps mp3", "vbr mp3", "aac", "m4a"]

    static func preferredAudioFiles(_ files: [ArchiveFile]) -> [ArchiveFile] {
        for wanted in formatPreference {
            let group = files.filter { ($0.format ?? "").lowercased() == wanted }
            if !group.isEmpty { return group }
        }
        // format field missing entirely (older items): the legacy 64kb
        // filename suffix keeps those playable.
        return files.filter { ($0.name ?? "").hasSuffix("64kb.mp3") }
    }

    /// 37e4a23 (2): hard path-segment encoding — archive.org filenames carry
    /// spaces, umlauts, brackets, apostrophes ("Der Rosenkavalier - Richard
    /// Strauss - …-restored.mp3"). Only unreserved characters survive; the
    /// SAME encoder covers LibriVox and classical items (one path, Regel 2).
    static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encodedPathSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? segment
    }

    static func archiveTracks(identifier: String, files: [ArchiveFile]) -> [ABSAudioTrack] {
        var start: Double = 0
        var out: [ABSAudioTrack] = []
        let playable = preferredAudioFiles(files)
            .sorted { ($0.name ?? "") < ($1.name ?? "") }
        let encodedId = encodedPathSegment(identifier)
        for file in playable {
            guard let name = file.name else { continue }
            let encoded = name.split(separator: "/", omittingEmptySubsequences: false)
                .map { encodedPathSegment(String($0)) }
                .joined(separator: "/")
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
