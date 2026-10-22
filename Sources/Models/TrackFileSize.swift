// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether a stored track holds the whole file its source names.
///
/// Measured: a download whose body ends early still reports success when
/// the server sends no length, and when a chunked body lacks its last
/// chunk. The short file was then kept as a finished track, the resumed
/// download skipped it, and playback ended it early and jumped over the
/// rest. The one size to hold it against is the one the source states for
/// exactly this file, and only a source whose download IS that file can be
/// held to it: a server that transcodes while it streams sends another
/// size on purpose.
nonisolated enum TrackFileSize {
    enum Verdict: Equatable {
        /// As many bytes as the source states.
        case whole
        /// Fewer bytes than the source states: not a finished track.
        case short
        /// More bytes than stated: kept, a server that sends more loses
        /// nothing.
        case larger
        /// No size to hold it against: the source states none, or its
        /// download is not the stated file.
        case unstated
        /// The bytes on disk could not be read: no verdict, the file stays.
        /// Not knowing is no reason to delete.
        case unread
    }

    /// The size a stored track is held to: the stated size of the file,
    /// only where the source's download is that file.
    static func stated(_ size: Int64?, downloadsTheOriginalFile: Bool) -> Int64? {
        guard downloadsTheOriginalFile, let size, size > 0 else { return nil }
        return size
    }

    /// What a source that may transcode states for a file: its size and
    /// type as the original. It holds only when the answer shows the
    /// original arrived (`statedByAnswer`).
    struct Claim: Equatable, Sendable {
        let size: Int64
        let contentType: String
    }

    /// Why a claim held a file to no size.
    enum Unheld: String, Equatable {
        /// The answer carried no length.
        case noLength
        /// The answer names another size or type than the original's: the
        /// server transcoded (a lower bitrate keeps the type, so the size
        /// decides) or sent another file.
        case transcoded
    }

    /// The size a claim holds a finished download to, read from the answer:
    /// the claimed size only when the answer itself names it (its length,
    /// or for a partial answer the whole size in its range) and the
    /// original's type, else none and why. Measured on Navidrome: `stream`
    /// without `format` delivers the original byte for byte.
    static func statedByAnswer(_ claim: Claim, answerLength: Int64, answerTotal: Int64? = nil,
                               answerType: String?) -> (stated: Int64?, unheld: Unheld?) {
        let named = answerTotal ?? answerLength
        guard named > 0 else { return (nil, .noLength) }
        guard named == claim.size, let answerType,
              answerType.lowercased() == claim.contentType.lowercased() else {
            return (nil, .transcoded)
        }
        return (claim.size, nil)
    }

    /// The whole size a partial answer names in `Content-Range`
    /// (`bytes 0-99/1234` → 1234); nil without one or for `*`.
    static func total(contentRange: String?) -> Int64? {
        guard let contentRange, let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// The claim of a track whose source may transcode: only with a size
    /// above zero and a type.
    static func claim(size: Int64?, contentType: String?) -> Claim? {
        guard let size, size > 0, let contentType, !contentType.isEmpty else { return nil }
        return Claim(size: size, contentType: contentType)
    }

    static func verdict(bytes: Int64?, stated: Int64?) -> Verdict {
        guard let stated else { return .unstated }
        guard let bytes else { return .unread }
        if bytes < stated { return .short }
        return bytes > stated ? .larger : .whole
    }

    /// The bytes of a file on disk, nil when it cannot be read.
    static func bytes(at url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}
