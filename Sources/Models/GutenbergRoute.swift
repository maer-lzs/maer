// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Gutenberg's main server and its mirror pglaf, measured 26.11.2026 while
/// www answered 503 for a day: pglaf holds the record, the covers and the
/// catalog dump at the same path (`/cache/epub/…`) and a sound file under
/// every digit of its number but the last (`/files/9272/…` →
/// `/9/2/7/9272/…`, a single digit under `0/`). The one place that names
/// the mirror.
nonisolated enum GutenbergRoute {
    static let mainHost = "www.gutenberg.org"
    static let mirrorHost = "gutenberg.pglaf.org"

    /// The mirror's address of a file of www over https; nil for every
    /// other address, a page included.
    static func mirror(of url: URL) -> URL? {
        guard url.scheme == "https", url.host()?.lowercased() == mainHost,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = parts.percentEncodedPath
        if path.hasPrefix("/cache/epub/") {
            parts.host = mirrorHost
            return parts.url
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        // "", "files", number, rest…
        guard segments.count > 3, segments[1] == "files", let number = Int(segments[2]), number > 0 else { return nil }
        parts.host = mirrorHost
        parts.percentEncodedPath = "/" + digitPath(number) + "/" + segments.dropFirst(3).joined(separator: "/")
        return parts.url
    }

    /// `9272` → `9/2/7/9272`, `12` → `1/12`, `9` → `0/9`.
    static func digitPath(_ number: Int) -> String {
        let digits = String(number)
        let folders = digits.count == 1 ? ["0"] : digits.dropLast().map(String.init)
        return (folders + [digits]).joined(separator: "/")
    }

    /// The mirror is asked after a server error of www or while www rests;
    /// an absence (404) is a finding, and a 429 asks for patience, not for
    /// another server.
    static func asksMirror(status: Int?, resting: Bool) -> Bool {
        if resting { return true }
        guard let status else { return false }
        return (500...599).contains(status)
    }
}

/// Gutenberg did not answer, its main server nor its mirror.
nonisolated struct GutenbergUnavailable: Error, Equatable {}
