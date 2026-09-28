// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// A Project Gutenberg audiobook as the player needs it: its sound files in
/// order, each with its duration. Pure; `GutenbergWorks` fetches and keeps it.
///
/// Measured before building: a reading is usually SEVERAL files (5884: three
/// mp3 of 60, 53 and 206 minutes), and the RDF record of a work names them
/// all, but no durations. The player places a position in a multi-file book
/// by the durations of the files before it (`TrackMath`); without them every
/// file starts at 0 and a resume lands in the last one. So the durations are
/// read once per file when the work is opened and kept with the addresses.
nonisolated struct GutenbergWork: Codable, Equatable, Sendable {
    struct Part: Codable, Equatable, Sendable {
        let url: String
        /// nil: the file was reached and its duration could not be read. A
        /// finding, kept like the others; a failed fetch is never stored.
        let seconds: Double?
    }

    let title: String?
    let author: String?
    let parts: [Part]

    /// Bumped when the reading of a record changes (which files count, in
    /// what order), so a work kept under the old rule is read again.
    static let rule = "files-1"

    /// The work as tracks. More than one file with a duration missing would
    /// put every later file at the wrong place, so that work is refused with
    /// its reason instead of playing wrongly. A single file needs no
    /// duration to be placed.
    func tracks() throws -> [ABSAudioTrack] {
        if parts.count > 1, let missing = parts.firstIndex(where: { $0.seconds == nil }) {
            throw GutenbergWorkError.partUnreadable(part: missing + 1)
        }
        var start = 0.0
        return parts.enumerated().map { index, part in
            defer { start += part.seconds ?? 0 }
            return ABSAudioTrack(index: index, startOffset: start, duration: part.seconds,
                                 contentUrl: part.url, metadata: nil)
        }
    }

    /// The whole length, when every part has one.
    var totalSeconds: Double? {
        let known = parts.compactMap(\.seconds)
        guard !known.isEmpty, known.count == parts.count else { return nil }
        return known.reduce(0, +)
    }
}

/// What reading one file's duration found. Only two things are findings
/// about the file: it was delivered and has no readable length, or it is
/// absent (404, 410). A refusal, a throttle, a server error or no way to the
/// host is no finding and keeps nothing.
///
/// Measured with `AVURLAsset.load(.duration)` against a local server with
/// fixed answers: a delivered body that is no audio (junk, an HTML page)
/// does NOT throw, it answers a non-finite length. Every thrown error is
/// therefore transport or status: 404 is NSURLErrorDomain -1100; 410 is
/// -1008 with CoreMediaErrorDomain -12668 beneath; 400, 408, 429, 451 and
/// 5xx are -1008 with other CoreMedia codes beneath; 401 is -1013; 403 is
/// AVFoundationErrorDomain -11849; a refused connection is -1004.
nonisolated enum GutenbergPartReading {
    enum Outcome: Sendable, Equatable {
        case seconds(Double)
        /// Delivered without a readable length, or absent.
        case unreadable
        /// No finding about the file; the next open asks again.
        case failed
    }

    static func outcome(seconds: Double) -> Outcome {
        seconds.isFinite && seconds > 0 ? .seconds(seconds) : .unreadable
    }

    static func outcome(error: NSError) -> Outcome {
        guard error.domain == NSURLErrorDomain else { return .failed }
        if error.code == NSURLErrorFileDoesNotExist { return .unreadable }
        let beneath = error.userInfo[NSUnderlyingErrorKey] as? NSError
        if error.code == NSURLErrorResourceUnavailable,
           beneath?.domain == "CoreMediaErrorDomain", beneath?.code == goneCode {
            return .unreadable
        }
        return .failed
    }

    /// The CoreMedia code beneath -1008 when the server answered 410.
    static let goneCode = -12668
}

nonisolated enum GutenbergWorkError: LocalizedError, Equatable {
    case partUnreadable(part: Int)

    var errorDescription: String? {
        switch self {
        case .partUnreadable(let part):
            String(localized: "Part \(part) of this title cannot be read, so it cannot be played from the right place.")
        }
    }
}

/// The RDF record of a Gutenberg work (`cache/epub/N/pgN.rdf`): title,
/// first author, and the sound files in playing order.
nonisolated enum GutenbergRDF {
    static func url(number: Int) -> URL {
        URL(string: "https://www.gutenberg.org/cache/epub/\(number)/pg\(number).rdf")!
    }

    struct Record: Equatable, Sendable {
        let title: String?
        let author: String?
        /// Every `audio/mpeg` file the record names, in record order.
        let audio: [String]
    }

    static func parse(_ data: Data) -> Record? {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return nil }
        return Record(title: reader.title, author: reader.author, audio: reader.audio)
    }

    /// The files that are the reading, in order. One quality rule: the same
    /// stem in `-high`, `-med` and `-low` is ONE recording in three sizes
    /// (3002 names `sochi-high.mp3` and `sochi-med.mp3`), never three parts;
    /// the highest stays. Music examples inside a text (`-h/audio/`) are no
    /// reading. The order follows the file names with numbers read as
    /// numbers (`5884-02` before `5884-10`).
    static func readingFiles(_ audio: [String]) -> [String] {
        var best: [String: (url: String, rank: Int)] = [:]
        for url in audio where FreeCatalog.isGutenbergAudiobook(url) {
            let (key, rank) = qualityKey(url)
            if let held = best[key], held.rank >= rank { continue }
            best[key] = (url, rank)
        }
        return best.values.map(\.url).sorted {
            fileName($0).compare(fileName($1), options: [.numeric, .caseInsensitive]) == .orderedAscending
        }
    }

    private static let qualities = ["-high": 3, "-med": 2, "-low": 1]

    /// The address without its quality suffix, and the rank of that suffix.
    /// A file without one ranks above all: it is the recording itself.
    private static func qualityKey(_ url: String) -> (String, Int) {
        // Cut at the last dot by hand: the NSString path calls fold the
        // "//" of "https://", and the key of `a.mp3` stopped matching the
        // key of `a-high.mp3` (the witness caught it).
        guard let dot = url.lastIndex(of: "."), !url[dot...].contains("/") else { return (url, 4) }
        let stem = url[..<dot]
        let ext = url[dot...]
        for (suffix, rank) in qualities where stem.hasSuffix(suffix) {
            return (String(stem.dropLast(suffix.count)) + ext, rank)
        }
        return (url, 4)
    }

    private static func fileName(_ url: String) -> String { (url as NSString).lastPathComponent }

    nonisolated private final class Reader: NSObject, XMLParserDelegate {
        var title: String?
        var author: String?
        var audio: [String] = []
        private var text = ""
        private var fileAbout: String?
        private var inFormat = false
        private var inCreator = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "pgterms:file": fileAbout = attributes["rdf:about"]
            case "dcterms:format": inFormat = true
            case "dcterms:creator": inCreator = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "dcterms:title" where title == nil && fileAbout == nil: title = value
            case "pgterms:name" where inCreator && author == nil: author = value
            case "dcterms:creator": inCreator = false
            case "rdf:value" where inFormat && value == "audio/mpeg":
                if let fileAbout { audio.append(fileAbout) }
            case "dcterms:format": inFormat = false
            case "pgterms:file": fileAbout = nil
            default: break
            }
            text = ""
        }
    }
}
