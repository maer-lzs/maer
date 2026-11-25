// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The Musopen recordings on Wikimedia Commons as a catalog. The category
/// and its Chopin subcategory are read page by page; each file is decided
/// on its own from what its file page states: a sound, public domain or
/// the Creative Commons zero waiver, and a form the player takes (the
/// MP3 Commons derives, or an MP3 original). Pure: an answer goes in,
/// recordings and the counted rest come out.
nonisolated enum MusopenCatalog {
    /// `mso:<pageid>`: the file page's number, which a rename keeps.
    static let prefix = "mso:"
    static let apiURL = URL(string: "https://commons.wikimedia.org/w/api.php")!
    /// The category and the subcategory whose files it does not list
    /// itself, read in this order. The third subcategory, the Kickstarter
    /// project, lists only files the category lists too.
    static let categories = ["Category:Musopen", "Category:Set Chopin Free"]
    /// Files per answer; the file pages' metadata keeps an answer of 50
    /// at a size a phone reads in one go.
    static let pageSize = 50
    static let readingLimit = 0

    /// The rights of the catalog, once at the top of its surfaces and under
    /// its switch; each recording names its own licence on its page.
    static var rightsNotice: String {
        String(localized: "Recordings of the Musopen collection on Wikimedia Commons. Public domain and CC0 recordings only; each recording names its licence on its page.")
    }

    /// The three rights the catalog keeps. Everything else stays out and
    /// is counted (`Dropped.licence`).
    enum Licence: String, Codable, Sendable, CaseIterable {
        case publicDomain, cc0, publicDomainMark

        /// From the file page's `License` field, which Commons fills from
        /// the licence template (`pd`, `cc0`, `cc-by-3.0`, …). The owner's
        /// Public Domain Mark leaves that field empty and names itself in
        /// the short name (`PDM-owner`); it is the owner's word, so its
        /// label says whose. The mark counts only where the field states no
        /// licence: a file that names another one (`cc-by-3.0`) is under
        /// that licence, whatever its short name says.
        init?(stated: String?, shortName: String? = nil) {
            let named = stated?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            switch named {
            case "pd": self = .publicDomain
            case "cc0": self = .cc0
            case "":
                guard shortName?.trimmingCharacters(in: .whitespaces) == "PDM-owner" else { return nil }
                self = .publicDomainMark
            default:
                return nil
            }
        }

        var label: String {
            switch self {
            case .publicDomain: String(localized: "Public domain")
            case .cc0: "CC0"
            // The words archive.org's mark carries as well (`FreeCatalog`).
            case .publicDomainMark: String(localized: "Public domain (per source)")
            }
        }
    }

    /// Why a file of the category is not a recording of the catalog.
    enum Dropped: String, CaseIterable, Sendable, Error {
        /// A picture, a video.
        case notAudio
        /// Neither public domain nor the Creative Commons zero waiver.
        case licence
        /// No MP3, neither derived nor original.
        case noPlayableForm
    }

    struct Recording: Codable, Sendable, Equatable {
        let pageId: Int
        let title: String
        /// As the file page states it, with its links; the provider makes
        /// plain text of it where every catalog name becomes text.
        let artistHTML: String?
        let duration: Double?
        let licence: Licence
        let audioURL: URL
        let pageURL: URL?

        var itemId: String { MusopenCatalog.prefix + String(pageId) }
    }

    /// The artist field of a file page as text, its parts apart: an element
    /// the page hides goes (Commons writes "Unknown author" a second time in
    /// a hidden span, and the two used to meet as "Unknown authorUnknown
    /// author"), a link to a Commons user names the uploader, not an artist,
    /// and goes as well; line breaks and " / " part the names, "Unknown
    /// author" is no name. nil when nothing is left. `plain` makes text of
    /// the rest as every catalog name becomes it (`htmlPlainText`).
    static func artistText(_ html: String?, plain: (String) -> String) -> String? {
        guard var text = html else { return nil }
        let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
        text = text.replacingOccurrences(of: "<(\\w+)[^>]*display:\\s*none[^>]*>.*?</\\1>", with: "", options: options)
        text = text.replacingOccurrences(of: "<a [^>]*/wiki/User:[^>]*>.*?</a>", with: "", options: options)
        text = text.replacingOccurrences(of: " / ", with: ";")
        text = plain(text)
        var seen: Set<String> = []
        let parts = text.split(whereSeparator: { $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != "unknown author" && seen.insert($0.lowercased()).inserted }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Where the reader stands: which category, and the token Commons
    /// handed out for its next answer.
    struct Cursor: Equatable, Sendable {
        var category: Int = 0
        var token: String? = nil
    }

    struct Page: Sendable {
        var recordings: [Recording] = []
        var dropped: [Dropped: Int] = [:]
        /// nil when the category is read to its end.
        var token: String? = nil
    }

    /// Where the reader goes after an answer: on in the same category with
    /// its token, else to the start of the next; nil after the last.
    static func cursor(after cursor: Cursor, token: String?) -> Cursor? {
        if let token { return Cursor(category: cursor.category, token: token) }
        let next = cursor.category + 1
        return next < categories.count ? Cursor(category: next, token: nil) : nil
    }

    /// The page id behind an item id; nil for other sources.
    static func pageId(of itemId: String) -> Int? {
        guard itemId.hasPrefix(prefix) else { return nil }
        return Int(itemId.dropFirst(prefix.count))
    }

    /// The fields every answer asks for.
    private static let fileFields = [
        URLQueryItem(name: "action", value: "query"),
        URLQueryItem(name: "format", value: "json"),
        URLQueryItem(name: "formatversion", value: "2"),
        URLQueryItem(name: "prop", value: "videoinfo"),
        URLQueryItem(name: "viprop", value: "url|size|mime|derivatives|extmetadata"),
    ]

    /// One answer of a category. `startingAt` begins the category at a
    /// sort key (the row's place of the day); a token goes on from the
    /// answer before.
    static func categoryURL(_ category: String, token: String?, startingAt: String? = nil, limit: Int = pageSize) -> URL {
        var comp = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        var items = fileFields + [
            URLQueryItem(name: "generator", value: "categorymembers"),
            URLQueryItem(name: "gcmtitle", value: category),
            URLQueryItem(name: "gcmtype", value: "file"),
            URLQueryItem(name: "gcmlimit", value: String(limit)),
        ]
        if let token { items.append(URLQueryItem(name: "gcmcontinue", value: token)) }
        if let startingAt { items.append(URLQueryItem(name: "gcmstartsortkeyprefix", value: startingAt)) }
        comp.setQuery(items)
        return comp.url!
    }

    /// One file page by its number, for a title kept or linked before the
    /// rows of this run were read.
    static func fileURL(pageId: Int) -> URL {
        var comp = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        comp.setQuery(fileFields + [URLQueryItem(name: "pageids", value: String(pageId))])
        return comp.url!
    }

    /// The row's place of the day: a letter the category starts at, so the
    /// row shows another stretch of the alphabet each day with one answer.
    static func rowLetter(on date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        return String(letters[day % letters.count])
    }

    // MARK: - Reading an answer

    static func page(from data: Data) throws -> Page {
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        var page = Page(token: answer.continueToken)
        for file in (answer.query?.pages ?? []).sorted(by: { ($0.title ?? "") < ($1.title ?? "") }) {
            switch recording(file) {
            case .success(let recording): page.recordings.append(recording)
            case .failure(let reason): page.dropped[reason, default: 0] += 1
            }
        }
        return page
    }

    /// The one decision per file, in this order: a sound at all, then the
    /// licence, then a form the player takes.
    static func recording(_ file: WireFile) -> Result<Recording, Dropped> {
        guard let pageId = file.pageid, let info = file.videoinfo?.first,
              isSound(mime: info.mime, derivatives: info.derivatives ?? []) else {
            return .failure(.notAudio)
        }
        guard let licence = Licence(stated: info.extmetadata?["License"]?.value,
                                    shortName: info.extmetadata?["LicenseShortName"]?.value) else {
            return .failure(.licence)
        }
        guard let audioURL = playableURL(info) else { return .failure(.noPlayableForm) }
        return .success(Recording(
            pageId: pageId,
            title: shownTitle(objectName: info.extmetadata?["ObjectName"]?.value, fileTitle: file.title),
            artistHTML: info.extmetadata?["Artist"]?.value,
            duration: info.duration,
            licence: licence,
            audioURL: audioURL,
            pageURL: info.descriptionurl.flatMap(URL.init(string:))))
    }

    /// A sound file: an audio type, or Ogg that Commons derives no video
    /// from (an `.ogv` is Ogg too).
    static func isSound(mime: String?, derivatives: [WireDerivative]) -> Bool {
        guard let mime else { return false }
        if mime.hasPrefix("audio/") { return true }
        return mime == "application/ogg" && !derivatives.contains { ($0.type ?? "").hasPrefix("video/") }
    }

    /// The MP3 Commons derives, else an MP3 original without the tracking
    /// query the API appends to it.
    static func playableURL(_ info: WireInfo) -> URL? {
        if let derived = info.derivatives?.first(where: { $0.transcodekey == "mp3" || ($0.type ?? "").hasPrefix("audio/mpeg") }),
           let src = derived.src, let url = URL(string: src) {
            return url
        }
        guard info.mime == "audio/mpeg", let original = info.url,
              var comp = URLComponents(string: original) else { return nil }
        comp.query = nil
        return comp.url
    }

    /// The object name the file page states, else the file name without
    /// its namespace and extension. An object name with markup is the
    /// rendering of a template, not a name.
    static func shownTitle(objectName: String?, fileTitle: String?) -> String {
        if let name = objectName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
           !name.contains("<") { return name }
        var name = fileTitle ?? ""
        if name.hasPrefix("File:") { name.removeFirst("File:".count) }
        if let dot = name.lastIndex(of: ".") { name = String(name[..<dot]) }
        return name
    }

    // MARK: - Wire

    struct Answer: Decodable {
        struct Query: Decodable { let pages: [WireFile]? }
        let query: Query?
        let `continue`: [String: String]?
        var continueToken: String? { `continue`?["gcmcontinue"] }
    }

    struct WireFile: Decodable, Sendable {
        let pageid: Int?
        let title: String?
        let videoinfo: [WireInfo]?
    }

    struct WireInfo: Decodable, Sendable {
        let url: String?
        let descriptionurl: String?
        let mime: String?
        let duration: Double?
        let derivatives: [WireDerivative]?
        let extmetadata: [String: WireField]?
    }

    struct WireDerivative: Decodable, Sendable {
        let src: String?
        let type: String?
        let transcodekey: String?
    }

    /// A metadata field. Commons states most as text and some as numbers;
    /// only the text ones are read, a number decodes to nothing.
    struct WireField: Decodable, Sendable {
        let value: String?
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            value = try? box.decode(String.self, forKey: .value)
        }
        enum CodingKeys: String, CodingKey { case value }
    }
}
