// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Free-catalog models + pure mappers. LibriVox (public-domain
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
    /// The API DOES deliver genres (objects with `name`).
    /// This type silently dropped them at decode time, which left the whole
    /// genre axis dead: the provider had nothing to pass on, the shelf row
    /// never rendered. Epoch entries ("Published 1800 -1900") stay in. The
    /// axis filters them itself.
    struct Genre: Decodable, Sendable { let name: String? }
    let genres: [Genre]?
}

nonisolated struct LibriVoxFeed: Decodable, Sendable {
    let books: [LibriVoxBook]?
}

// MARK: - archive.org wire

/// Archive.org list-capable fields. The georgeblood classical
/// docs deliver `creator` as an ARRAY (composer + orchestra + conductor),
/// LibriVox docs as a plain string; title/subject can do the same. ONE
/// shared tolerant decode (lenientID spirit): both shapes accepted, any
/// OTHER type still throws (wire discipline unchanged).
nonisolated struct ArchiveStringList: Codable, Sendable {
    let values: [String]
    /// Writes the LIST shape, which the decoder below accepts unchanged. The
    /// single string and the bare number are shapes the SERVER sends; what
    /// this app writes down only has to survive its own reading.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            values = [single]
        } else if let number = try? container.decode(Int.self) {
            // archive.org delivers `year` as a NUMBER (measured on four
            // queries). A string-only tolerance throws typeMismatch and
            // kills EVERY archive row at once, classical included. The 429
            // suspicion
            // is refuted (A3's decode-prefix line decided it). ONE place,
            // number-tolerant, like the string/list split above.
            values = [String(number)]
        } else if let numbers = try? container.decode([Int].self) {
            values = numbers.map(String.init)
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

nonisolated struct ArchivePopularDoc: Codable, Sendable {
    let identifier: String?
    let title: ArchiveStringList?
    let creator: ArchiveStringList?
    let downloads: Int?
    /// The search index carries the total runtime as "H:MM:SS" for
    /// most (NOT all) items. The card's time line reads it via
    /// `FreeCatalog.runtimeSeconds`; absent stays honestly absent.
    let runtime: String?
    /// The stated licence. Shown to the user, because a
    /// CC-BY-NC-ND title is not the same as public domain.
    let licenseurl: String?
    /// Recording year where the index has one. For sources without a
    /// licence field this is the user's only means of judging the age of a
    /// recording. So it is shown, and its ABSENCE stays visible too.
    let year: ArchiveStringList?
    /// Subjects (string or list, like title/creator). The genre
    /// axis' material for archive.org rows.
    let subject: ArchiveStringList?
    /// The collections the item belongs to. What decides its FORM (one work
    /// in parts or an album of tracks, see `ArchiveItemForm`). Present on every
    /// measured item and always containing the queried collection.
    var collection: ArchiveStringList? = nil
}

nonisolated struct ArchiveFile: Decodable, Sendable {
    let name: String?
    let length: String?
    let title: String?
    /// Per-file tags the source ships and the app used to drop: on a netlabel
    /// release these carry the real song title, its performer and the track
    /// number, which is why track names had to be derived from file names.
    var creator: String? = nil
    var track: String? = nil
    var album: String? = nil
    /// Archive.org's rendition label ("VBR MP3", "64Kbps MP3", …).
    /// The format PREFERENCE chain picks by this, not by filename suffix.
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

/// THE gate hierarchy for every free-catalog surface. Master
/// (General pill) > area feature toggles ("Free Catalogs" area of the source map) > service
/// opt-outs (network-services page). ONE pure function all catalog paths
/// ask. Never five copied checks; master off means OFF: no UI
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
    /// Project Gutenberg audiobook (`gut:<bookId>`).
    static let gutenbergPrefix = "gut:"

    /// THE list of catalog namespaces, kept BY THE SOURCE that owns
    /// them. The router used to carry string literals of its own. So when
    /// Gutenberg arrived, `gut:` was added here and forgotten there, and every
    /// Gutenberg cover request went to the Audiobookshelf server (with the
    /// access token in the query string) for a title that does not exist there.
    /// 41 × 404 later CrowdSec read it as an attack and locked the user out of
    /// his own server. A new source now only has to appear in THIS list.
    static let allPrefixes = [librivoxPrefix, archivePrefix, jamendoPrefix, gutenbergPrefix]

    /// The ONE enumeration of the catalog AREAS. Every area steers a
    /// visible surface and therefore MUST have its own switch in the areas
    /// list (network services answer a different question: privacy per
    /// service, not presence of an area). A new catalog adds its case here
    /// and the fence (`SourceMapAreasTests`) fails until its switch exists,
    /// so the list can no longer look complete while it is not.
    enum Area: String, CaseIterable, Sendable {
        case freeAudiobooks, freeMusic, netlabels, oldRecords

        /// The stored key that switches this area.
        var storageKey: String {
            switch self {
            case .freeAudiobooks: return AppStorageKeys.freeAudiobooksEnabled
            case .freeMusic:      return AppStorageKeys.jamendoRowEnabled
            case .netlabels:      return AppStorageKeys.netlabelsRowEnabled
            case .oldRecords:     return AppStorageKeys.shellacRowsEnabled
            }
        }

        /// The switch's accessibility identifier in the areas list.
        var toggleIdentifier: String {
            switch self {
            case .freeAudiobooks: return "books-free-audiobooks-toggle"
            case .freeMusic:      return "music-jamendo-toggle"
            case .netlabels:      return "music-netlabels-toggle"
            case .oldRecords:     return "music-shellac-toggle"
            }
        }
    }

    /// Suggestion-language code → the English language NAME LibriVox stores.
    /// The API ignores language parameters (probed). Filtering is client-side
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

    /// Suggestion-language code → ISO-639-3 variants as archive.org
    /// stores them (probed: librivoxaudio carries "deu" [840] with 2 "ger"
    /// stragglers; plain names score 0). The popular row filters SERVER-side.
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

    /// The language clause for advancedsearch. OR over every ISO variant of
    /// every selected code; nil when nothing maps (then no filter, honest).
    static func archiveLanguageClause(codes: [String]) -> String? {
        let variants = codes.flatMap { iso639_3(for: $0) }
        guard !variants.isEmpty else { return nil }
        return "(" + variants.map { "language:\"\($0)\"" }.joined(separator: " OR ") + ")"
    }

    /// Archive.org's `runtime` string → seconds. The field
    /// is user-entered metadata: "H:MM:SS", "MM:SS", and malformed variants
    /// like "16:31.09" (a dot for the last separator) all occur. Anything
    /// that does not read as a time is nil. A wrong duration is worse than
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

    /// Total runtime of an archive.org item from its file
    /// list. archive.org carries the length on the audio DERIVATIVES, and
    /// only some of them (the 128 kbps MP3 set is the reliable one; VBR/64k
    /// entries often ship without `length`). Strategy: group by format, take
    /// the group with the LARGEST total. That is the complete audio set.
    /// And ignore everything without a usable length.
    ///
    /// Measured against LibriVox's own `totaltimesecs` (Klein Zaches):
    /// 15731 s here vs. 15733 s there. A 2-second difference on 4:22 h.
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

    /// LibriVox catalog titles arrive as
    /// "Struwwelpeter, Der by Heinrich Hoffmann (1809 - 1894), version 2".
    /// Normalize for EVERY display surface (rows, pages, search):
    /// 1. strip the " by <author> (<dates>)" tail (the author has his own
    ///    line; conservative. Only with a parenthesized date, so a title
    ///    that merely contains "by" survives),
    /// 2. lift a trailing "version N" into its own field (multiple readings
    ///    are LEGITIMATE. The marker moves to a meta line, the duplicate is
    ///    never hidden),
    /// 3. turn a trailing article back around ("X, The" → "The X"; de/en/fr).
    static func normalizedTitle(_ raw: String) -> (title: String, version: Int?) {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // (1) trailing ", version 2" / "(version 2)" FIRST. It sits AFTER
        // the by-tail ("… by Sun Tzu (554 - 496), version 2"), so the dated
        // by-anchor only matches once the version marker is gone.
        var version: Int?
        if let range = title.range(of: #"[,(\-\s]+version\s+(\d+)\)?\s*$"#,
                                   options: [.regularExpression, .caseInsensitive]) {
            let matched = String(title[range])
            version = Int(matched.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .joined())
            title.removeSubrange(range)
        }
        // (2) " by Author (1809 - 1894)". Anchored at the end via the dates.
        if let range = title.range(of: #"\s+by\s+[^()]+\(\d{3,4}[^)]*\)\s*$"#,
                                   options: .regularExpression) {
            title.removeSubrange(range)
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // (3) ", Der" tail → leading article.
        let articles = ["der", "die", "das", "ein", "eine",
                        "the", "a", "an", "le", "la", "les", "l'", "un", "une"]
        for article in articles {
            for candidate in [", \(article)", ", \(article.capitalized)"] {
                if title.lowercased().hasSuffix(candidate.lowercased()),
                   title.count > candidate.count {
                    let stem = String(title.dropLast(candidate.count))
                    let lifted = String(title.suffix(candidate.count).dropFirst(2))
                    title = "\(lifted) \(stem)".trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        return (title, version)
    }

    /// The licence URL as a short, honest label. Unknown
    /// forms keep the raw URL rather than being flattened to "free".
    /// May a COPY be taken of this entry? Only with a declared licence.
    /// Showing and streaming are untouched by this; that is the same act as a
    /// visitor's browser performing it.
    static func mayDownload(licenceURL: String?) -> Bool {
        guard let licenceURL else { return false }
        return !licenceURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What the tile carries when the source states nothing. NEVER nothing
    /// at all. A missing statement is information rather than a gap, and it
    /// is explicitly NOT a claim about the rights situation.
    static let unstatedRights = String(localized: "Rights not stated")

    static func licenceLabel(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return unstatedRights }
        let lower = url.lowercased()
        if lower.contains("publicdomain") || lower.contains("mark/1.0") {
            // P6a: claim and derived fact stop sharing one word.
            // An uploader's PD DECLARATION renders as "per source"; the plain
            // "Public domain" stays reserved for OUR term-based derivation
            // (rightsNote). The MacLean class would never have stood under
            // our word. CC licences are licence statements and stay as-is.
            return String(localized: "Public domain (per source)")
        }
        guard let range = lower.range(of: "creativecommons.org/licenses/") else { return url }
        let rest = lower[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
        return rest.isEmpty ? url : "CC " + rest.uppercased()
    }

    /// User-made compilations of LibriVox recordings sit in
    /// `audio_bookspoetry` WITHOUT being in `collection:librivoxaudio`. The
    /// query filter misses them, and the same content would stand twice in
    /// the catalog (measured example: `LibriVoxHorror_2007-2017`). Identifier,
    /// title and creator carry the name, so a fold match is enough; being
    /// conservative here costs at most a duplicate-free false negative.
    /// The curated EXCLUSION denylist, measured over 4.257 titles. Data,
    /// not a code branch per case, and
    /// deliberately the ONLY exclusion form in the repo (curation elsewhere
    /// uses positive lists/queries only). Exactly these six: all
    /// Alistair-MacLean novels of one uploader (1955–1983 commercial works
    /// with an invented public-domain dedication; the wider bestseller-author
    /// probe found nothing else). The measured "PD contradicts year" rule was
    /// withdrawn (207 false alarms. The year field holds the RECORDING
    /// year). A denylist is never complete. P6b's periodic probe feeds it.
    static let curatedExclusions: Set<String> = [
        "BearislandAM", "IceStationZebraAM", "AthabascaAM",
        "HMSUlyssesAM", "PuppetOnAChainAM", "AlistairMacleanTheLastFrontierChapter5",
    ]

    /// The one curation gate of the archive audiobook rows: not on the
    /// exclusion denylist, and, where it applies, not a LibriVox
    /// duplicate.
    ///
    /// `separatingFromLibriVox` exists because that second half
    /// is a SEPARATION between two sources, and a separation must never run
    /// on the source it defines. On the LibriVox page it was a self-filter:
    /// measured at the live endpoint with the page's own query
    /// (`collection:librivoxaudio … subject:"poetry"`, 12 rows), it threw
    /// away **12 of 12**. A shelf whose chevron says 2.865 showed two tiles.
    /// Where it belongs it costs nothing: 0 of 50 on the archive audiobooks
    /// (the `NOT collection:librivoxaudio` clause already does the work; the
    /// text check stays as the cross-collection safety net).
    static func isCuratedArchiveDoc(_ doc: ArchivePopularDoc,
                                    separatingFromLibriVox: Bool = true) -> Bool {
        guard let id = doc.identifier, !curatedExclusions.contains(id) else {
            guard doc.identifier == nil else { return false }
            return separatingFromLibriVox ? isNotLibriVoxDuplicate(doc) : true
        }
        return separatingFromLibriVox ? isNotLibriVoxDuplicate(doc) : true
    }

    /// Does this source NEED the separation? Only a source that is not
    /// LibriVox itself. Asking the source instead of the call site keeps the
    /// answer in one place. The same rule the shelf query follows.
    static func separatesFromLibriVox(_ source: CatalogSource) -> Bool {
        source != .librivox
    }

    static func isNotLibriVoxDuplicate(_ doc: ArchivePopularDoc) -> Bool {
        let haystack = [doc.identifier, doc.title?.joined, doc.creator?.joined]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return !haystack.contains("librivox")
    }

    /// Is this Gutenberg audio a real AUDIOBOOK? Measured
    /// on the full stock (1.124 entries): the readings live under
    /// `/files/<id>/mp3/…` (885) and `/files/<id>/<id>-m/…` (184), while
    /// `/files/<id>/<id>-h/audio/…` holds MUSIC EXAMPLES inside scholarly
    /// texts ("Navaho Legends", "The Lhota Nagas"). Those would go wrong in
    /// an audiobook row. Same class as the LibriVox junk filter: the path
    /// tells them apart, no guessing needed.
    /// The cover that rides in Gutendex' `formats` map. Pure so the choice of
    /// key (and the https guard) is testable. Measured 05.08.: every entry on
    /// page 1 carries `image/jpeg`.
    /// The tile's meta line. Recording year and runtime, whichever
    /// is known. Pure so the "absent stays absent" rule is testable: where the
    /// source states no year we show none, we do not guess one. For sources
    /// without a licence field the year is the user's ONLY means of judging a
    /// recording's age, so it leads.
    /// What we may say about a catalog title's rights. As a PURE
    /// decision, because it is the same question on every catalog surface.
    ///
    /// Protection terms for SOUND RECORDINGS differ by country, and that turns
    /// a blanket plaque into a false statement somewhere: Switzerland 50 years
    /// (Art. 39 URG), EU 70 (2011/77/EU), USA 100 for 1923–1946 (Music
    /// Modernization Act). A 1945 recording is free in Zurich and protected in
    /// New York. So "public domain" as a default was ungrounded, not merely
    /// inaccurate.
    ///
    /// Measured for the classical row (4271 titles): 408 are ≤ 1925, 1021 are
    /// later, 2842 carry no year at all.
    nonisolated enum RightsNote: Equatable {
        /// Published early enough that even the LONGEST term has expired.
        /// True in every one of the three legal areas, so we may simply say it.
        case publicDomain
        /// A year is known, the answer depends on where the listener sits.
        /// We state the TERMS, never a verdict about this title.
        case termsApply(year: String)
        /// No year, no licence field: we know nothing and say so.
        case unknown
    }

    /// A fixed constant (1925) would silently AGE. On
    /// 2027-01-01 the 1926 vintage joins the free set and the plaque would
    /// have stayed one year too timid, forever. The US term is the longest of
    /// the three, so its schedule (Music Modernization Act, pre-1972 sound
    /// recordings) decides; computed from the CURRENT year:
    /// before 1923 free since 2022 · 1923–1946 after 100 years ·
    /// 1947–1956 after 110 · 1957–1972 protected until 2067.
    static func usTermExpired(year: Int, currentYear: Int) -> Bool {
        switch year {
        case ..<1923:   return true
        case ...1946:   return currentYear >= year + 101
        case ...1956:   return currentYear >= year + 111
        case ...1972:   return currentYear >= 2068
        default:
            // Recordings AFTER 1972 follow regular
            // copyright (95 years from publication), not the pre-1972
            // 2067 sunset. The old default would have claimed PD for a
            // 1980 recording come 2068. Our historical collections never
            // reach this branch; correctness costs nothing.
            return currentYear >= year + 96
        }
    }

    /// Note that the licence field OVERRIDES this. A stated CC licence is a
    /// fact from the source and always wins (handled by the caller).
    /// `currentYear` is injectable for tests; callers use the default.
    static func rightsNote(year: String?,
                           currentYear: Int = Calendar.current.component(.year, from: Date())) -> RightsNote {
        guard let raw = year?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .unknown
        }
        // Years arrive as "1945", sometimes as "1945-06-01". Take the leading
        // four digits, and treat anything else as no year rather than guessing.
        let digits = raw.prefix(4)
        guard digits.count == 4, let value = Int(digits) else { return .unknown }
        return usTermExpired(year: value, currentYear: currentYear)
            ? .publicDomain : .termsApply(year: String(digits))
    }

    /// A 200-with-HTML answer must be tellable from transport.
    struct CatalogDecodeError: Error {
        let status: Int?
        let answerPrefix: String
    }

    /// The PURE classification of a source failure: nil = cancellation (NOT
    /// a failure; the next task run fetches again), otherwise a short reason
    /// for log AND error line. One look then tells 429 / HTML answer /
    /// transport apart, so a cancelled task is never booked as a broken
    /// source.
    /// Does this failure say the entry is gone, or only that it could not be
    /// asked right now? Only the first may mark an entry as dead; the second
    /// has to stay repeatable, otherwise a dead spot empties the row. The
    /// same three-way split as the negative-cache rule: data, empty, failed.
    /// Does this id belong to one of the free catalogs? Only for those may a
    /// failure be recorded as gone. A book on a server is the server's
    /// business.
    /// Is this a multi-author COLLECTION? They rank high in many shelves and
    /// push single works out of the first places.
    ///
    /// Measured over 150 LibriVox entries: the number of subjects is not the
    /// signal (collections carry 6.2 on average, the rest 6.4), and the title
    /// is not one either. `Vanished Arizona: Recollections` contains
    /// `collection` and is a single work.
    ///
    /// What carries is LibriVox's own convention: `creator` is EXACTLY
    /// `Various`. Five of a hundred and fifty, all of them genuine. And
    /// because it is an exact equality, no substring can slip in.
    static func isMultiAuthorCollection(_ doc: ArchivePopularDoc) -> Bool {
        guard let creator = doc.creator?.values.first else { return false }
        return creator.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "various"
    }

    static func isCatalogId(_ id: String) -> Bool {
        [librivoxPrefix, archivePrefix, jamendoPrefix, gutenbergPrefix]
            .contains { id.hasPrefix($0) }
    }

    static func isGone(_ error: Error) -> Bool {
        if let url = error as? URLError { return url.code == .resourceUnavailable }
        if let api = error as? APIError, case .http(let code, _) = api { return code == 404 }
        return false
    }

    static func failureReason(_ error: Error) -> String? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return nil }
            return "URLError \(urlError.code.rawValue)"
        }
        if let apiError = error as? APIError, case .http(let code, _) = apiError {
            return "HTTP \(code)"
        }
        if let decode = error as? CatalogDecodeError {
            let status = decode.status.map(String.init) ?? "?"
            return "decode (HTTP \(status)): \(decode.answerPrefix.prefix(80))"
        }
        return String(describing: type(of: error))
    }

    static func catalogMetaLine(year: String?, runtime: String?,
                                readingVersion: Int? = nil) -> String {
        // The reading marker is a META fact ("Lesung 2"), never part of
        // the title and never a dedupe. Multiple readings are legitimate.
        let version = readingVersion.map { String(localized: "Reading \($0)") }
        let parts = [year?.trimmingCharacters(in: .whitespaces), runtime, version]
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

    /// Fair round-robin over per-language result lists.
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

    /// Mix LibriVox books into the Discover row at a MODERATE
    /// share. After every `interval` recommendations one book, hard-capped
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

    /// Pull the `itunes:image` href out of a book RSS WITHOUT a
    /// full feed parse (one tag scan; the hi-res cover behind it is a real
    /// archive.org scan, ~100 KB, reached via redirect. URLSession follows).
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

    /// Known artifact classes the downloads sort washes up.
    /// Cover-art dumps, m4b/complete-collection bundles, thumbs, test items.
    /// Deny patterns match identifier OR title (folded); list extendable.
    static let artifactPatterns: [String] = [
        "cdcoverart", "thumbs", "m4b", "complete collection",
        "complete_collection", "librivox_test", "test_item",
    ]

    static func isArtifactDoc(identifier: String?, title: String?) -> Bool {
        let hay = ((identifier ?? "") + " " + (title ?? "")).lowercased()
        return artifactPatterns.contains { hay.contains($0) }
    }

    /// Plausibility bounds for an archive item's track list.
    /// A real audiobook has SOME parts; hundreds mean a collection bundle.
    ///
    /// The bound is a PARAMETER now, because the Old-Time-Radio
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
    /// Format PREFERENCE chain per item instead of the hard 64kb
    /// filter. Georgeblood classical items carry ONLY "VBR MP3" (+ 24bit
    /// FLAC), so the 64kb-derived URL pointed nowhere (NSURLError -1008).
    /// Chain: 64kb MP3 → 128kb MP3 → VBR MP3 → M4A/AAC. Ogg is NOT in the
    /// chain (AVPlayer cannot play Vorbis); FLAC deliberately left out
    /// (AVPlayer capability unconfirmed here, and 24-bit 78rpm FLACs are
    /// huge. Named in the report, not silently). Empty result falls under
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

    /// Hard path-segment encoding. Archive.org filenames carry
    /// spaces, umlauts, brackets, apostrophes ("Der Rosenkavalier - Richard
    /// Strauss - …-restored.mp3"). Only unreserved characters survive; the
    /// SAME encoder covers LibriVox and classical items. One path.
    static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func encodedPathSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? segment
    }

    /// Display title of one series track. The FILE name is the
    /// episode title in archive.org series bundles (percent-decoded, extension
    /// dropped). Pure, so the episode list never guesses.
    /// The OTR title family. Same house as
    /// `normalizedTitle` (Q2), because it is the same problem: a source
    /// writes housekeeping into the name and it eats the work's title.
    ///
    /// MEASURED over eight collections; the patterns differ widely:
    /// ```
    /// Gunsmoke 52-04-26 (001) Billy the Kid
    /// YTJD 1948-12-07 000 Milford Brooks III (Dick Powell Audition)
    /// Dragnet_49-06-10_002_Production_2_aka_Homicide
    /// Richard Diamond 49-05-01 (002) Diamond In the Rough (AFRS)
    /// Suspense 420617 001 The Burning Court (128-44) 28455 30m00s
    /// Philip_Marlowe_47-06-12_xxx_Who_Shot_Waldo
    /// XMinusOne55-04-24001NoContact          ← no separators at all
    /// ```
    /// The rule is conservative and never guesses: a head is cut off ONLY
    /// when a DATE was recognised. The date is worth keeping (first
    /// broadcast) and moves into the meta line instead of being thrown away;
    /// the show shorthand and the running number are redundant, because the
    /// show name stands above and the number to the left. If nothing
    /// matches, the title stays as it is.
    static func otrEpisode(fromFileName raw: String) -> (title: String, airDate: String?) {
        var name = raw.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        // The technical tail some collections carry: "(128-44) 28455 30m00s".
        name = name.replacingOccurrences(
            of: #"\s*\(\d{2,3}-\d{2}\)\s*\d+\s*\d+m\d+s\s*$"#,
            with: "", options: .regularExpression)

        // The date in the four measured spellings, with an optional
        // shorthand before it and an optional number after it ("000",
        // "(001)", "xxx").
        let pattern = #"^(.*?)((?:19|20)\d{2}-\d{2}-\d{2}|\d{2}-\d{2}-\d{2}|(?:19|20)\d{6}|\d{6})[\s._-]*(?:\(?(?:\d{1,4}|[xX]{3})\)?)?[\s._-]*(.*)$"#
        guard let match = name.range(of: pattern, options: .regularExpression) else {
            return (name, nil)
        }
        let ns = name as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 4
        else { _ = match; return (name, nil) }
        let rest = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
        // If nothing is left after the cut, it was not a head pattern.
        guard !rest.isEmpty else { return (name, nil) }
        let date = isoAirDate(ns.substring(with: m.range(at: 2)))
        return (rest, date)
    }

    /// The measured date shapes → ISO. Two-digit years are OTR: 20-99 ⇒ 19xx,
    /// 00-19 ⇒ 20xx would be wrong here (radio plays predate 2000), so a
    /// two-digit year is always 19xx.
    static func isoAirDate(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        switch digits.count {
        case 8:
            let y = digits.prefix(4), m = digits.dropFirst(4).prefix(2), d = digits.suffix(2)
            return "\(y)-\(m)-\(d)"
        case 6:
            let y = digits.prefix(2), m = digits.dropFirst(2).prefix(2), d = digits.suffix(2)
            return "19\(y)-\(m)-\(d)"
        default:
            return nil
        }
    }

    /// Measured: archive.org descriptions of the OTR collections open with a
    /// CENTRED HTML HEADING that repeats the title
    /// (`<p align=center><b>…</b></p>`), followed by blank lines. On screen
    /// that reads as a duplicated sender line plus a hole. It is NOT the
    /// author field. That one carries the uploading group.
    ///
    /// Pure: drop a leading line that is the title again (case/punctuation
    /// tolerant), then collapse runs of blank lines.
    static func tidiedDescription(_ text: String, title: String) -> String {
        var lines = text.components(separatedBy: .newlines)
        func fold(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        // The heading names the WORK; the item title may still carry the
        // collection housekeeping (`… - Single Episodes`), so both forms
        // count as a match.
        let wanted = Set([fold(title), fold(normalizedCollectionTitle(title))]).subtracting([""])
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { lines.removeFirst(); continue }
            if wanted.contains(fold(trimmed)) { lines.removeFirst(); continue }
            break
        }
        var out: [String] = []
        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank, out.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// archive.org collection housekeeping in the WORK title, e.g.
    /// `Yours Truly, Johnny Dollar - Single Episodes`. Measured: 12 of the
    /// top 25 OTR collections carry such a suffix, in three shapes. Only
    /// KNOWN shapes are cut; anything else stays untouched.
    static func normalizedCollectionTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespaces)
        for pattern in [#"\s*-\s*Single Episodes\b.*$"#,
                        #"\s*-\s*\d+\s+Episodes\b.*$"#,
                        #"\s*-\s*The Complete Series\b.*$"#,
                        #"\s*\(OTRR Certified\)\s*$"#] {
            title = title.replacingOccurrences(of: pattern, with: "",
                                               options: [.regularExpression, .caseInsensitive])
        }
        let cleaned = title.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? raw : cleaned
    }

    /// Track numbers come as "7" or "7/15"; a source without them keeps the
    /// file-name order, which is what the app relied on before.
    static func trackNumber(_ file: ArchiveFile) -> Int? {
        guard let raw = file.track?.split(separator: "/").first else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    /// Sort key: the stated track number first, file name as the tie-break.
    static func orderKey(_ file: ArchiveFile) -> String {
        let number = trackNumber(file).map { String(format: "%05d", $0) } ?? "zzzzz"
        return number + "|" + (file.name ?? "")
    }

    /// The name a track shows. The source's own title wins; the file name is
    /// the fallback for items that state none.
    static func trackTitle(_ file: ArchiveFile) -> String {
        let stated = file.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stated.isEmpty { return stated }
        return trackDisplayTitle(contentUrl: file.name ?? "")
    }

    static func trackDisplayTitle(contentUrl: String) -> String {
        let last = contentUrl.split(separator: "/").last.map(String.init) ?? contentUrl
        let decoded = last.removingPercentEncoding ?? last
        var name = decoded
        if let dot = name.lastIndex(of: "."), dot > name.startIndex {
            name = String(name[..<dot])
        }
        return name.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Which track the ONE item position falls into (honest
    /// minimal marking. No per-episode progress system). nil = no position
    /// or before the first track.
    static func trackIndex(at position: Double, tracks: [ABSAudioTrack]) -> Int? {
        guard position > 0 else { return nil }
        for (i, track) in tracks.enumerated() {
            let start = track.startOffset ?? 0
            let end = start + (track.duration ?? 0)
            if position >= start && position < end { return i }
        }
        return tracks.isEmpty ? nil : tracks.count - 1
    }

    static func archiveTracks(identifier: String, files: [ArchiveFile]) -> [ABSAudioTrack] {
        var start: Double = 0
        var out: [ABSAudioTrack] = []
        let playable = preferredAudioFiles(files)
            .sorted { orderKey($0) < orderKey($1) }
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
                metadata: ABSFileMetadata(size: nil, title: trackTitle(file))))
            start += duration ?? 0
        }
        return out
    }
}

/// The three axes `musicinfo` carries besides the genres. They are FILTERS
/// on a shelf's full page, not rows of their own.
///
/// Measured over 200 popular tracks: `vocalinstrumental` vocal 179 /
/// instrumental 21 · `speed` medium 142, high 38, low 12, verylow 2 · moods
/// in the `vartags` (energetic 58, love 52, happy 24, emotional 18, upbeat
/// 11, sentimental 10, romantic 9).
///
/// Instrumental is a SWITCH rather than a shelf, because it is a yes-no
/// question.
nonisolated struct JamendoFilter: Equatable, Sendable {
    enum Tempo: String, CaseIterable, Sendable {
        case slow, medium, fast
        /// Jamendo's own steps. `verylow` folds into `low`, because two of
        /// two hundred tracks do not justify a step of their own.
        var apiValues: [String] {
            switch self {
            case .slow: ["low", "verylow"]
            case .medium: ["medium"]
            case .fast: ["high"]
            }
        }
    }

    /// The moods that actually occur in the measured stock, not an invented
    /// list. They run over `fuzzytags`, because that is where Jamendo carries
    /// them rather than in a field of their own.
    enum Mood: String, CaseIterable, Sendable {
        case energetic, happy, emotional, romantic, upbeat
    }

    var tempo: Tempo?
    var mood: Mood?
    var instrumentalOnly = false

    static let none = JamendoFilter()

    var isActive: Bool { tempo != nil || mood != nil || instrumentalOnly }

    var extraTags: [String] { mood.map { [$0.rawValue] } ?? [] }

    var queryItems: [URLQueryItem] {
        var out: [URLQueryItem] = []
        if let tempo {
            out.append(URLQueryItem(name: "speed", value: tempo.apiValues.joined(separator: "+")))
        }
        if instrumentalOnly {
            out.append(URLQueryItem(name: "vocalinstrumental", value: "instrumental"))
        }
        return out
    }
}
