// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The log lines of the bookmark measurement before E1b (linked folders).
///
/// Pure and in the normal build on purpose: the debug measure page writes
/// them now, and E1b writes the same resolution line in every build, so the
/// first TestFlight update measures the real path (a debug build installed
/// from Xcode takes another one). Nothing here carries a path or a file
/// name; the place is the kind the person chose, never read from the URL.
nonisolated enum E1MeasureLine {
    /// The four places of the plan, as the person names them on the page.
    enum Place: String, CaseIterable, Sendable {
        case intern, icloud, anbieter, usb
    }

    /// One resolution of the bookmark.
    static func resolution(place: Place, resolved: Bool, stale: Bool, renewed: Bool,
                           access: Bool, files: Int?, reason: String?) -> String {
        var line = "E1MESS ort=\(place.rawValue) aufgeloest=\(yesNo(resolved)) veraltet=\(yesNo(stale))"
            + " erneuert=\(yesNo(renewed)) zugriff=\(yesNo(access))"
            + " dateien=\(files.map(String.init) ?? "-")"
        if let reason { line += " fehler=\(reason)" }
        return line
    }

    /// One minute of the background playback probe.
    static func playback(minute: Int, playing: Bool, access: Bool) -> String {
        "E1MESS wiedergabe minute=\(minute) spielt=\(yesNo(playing)) zugriff=\(yesNo(access))"
    }

    private static func yesNo(_ flag: Bool) -> String { flag ? "ja" : "nein" }
}
