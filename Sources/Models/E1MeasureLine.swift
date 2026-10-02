// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The log lines of the bookmark measurement for linked folders. Pure and in
/// the normal build on purpose: the linked-folder code is to write the same
/// resolution line in every build, so a TestFlight update measures the real
/// path (a debug build installed from Xcode takes another one). Today only
/// the debug measure page writes the lines. Nothing here carries a path or a
/// file name; the place is the kind the person chose, never read from the
/// URL.
nonisolated enum E1MeasureLine {
    /// The four places of the plan, as the person names them on the page.
    enum Place: String, CaseIterable, Sendable {
        case intern, icloud, anbieter, usb
    }

    /// One audio file of the measured folder, by its real name, and whether
    /// its bytes are on the device.
    struct Audio: Equatable, Sendable {
        let name: String
        let loaded: Bool
    }

    /// The audio kinds the measurement counts, by extension.
    static let audioKinds: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "caf"]

    /// The name an entry stands for: an evicted iCloud file can show as the
    /// placeholder `.<name>.icloud`, with the real name inside it.
    static func realName(of entry: String) -> (name: String, placeholder: Bool) {
        let suffix = ".icloud"
        guard entry.hasPrefix("."), entry.hasSuffix(suffix), entry.count > suffix.count + 1 else { return (entry, false) }
        return (String(entry.dropFirst().dropLast(suffix.count)), true)
    }

    /// The audio among a folder's entries, sorted by name. An entry is not
    /// loaded when it is a placeholder or its own status says so: an
    /// evicted folder must not read as an empty one.
    static func audio(among entries: [(name: String, notDownloaded: Bool)]) -> [Audio] {
        entries.compactMap { entry in
            let real = realName(of: entry.name)
            guard audioKinds.contains((real.name as NSString).pathExtension.lowercased()) else { return nil }
            return Audio(name: real.name, loaded: !real.placeholder && !entry.notDownloaded)
        }
        .sorted { $0.name < $1.name }
    }

    /// One resolution of the bookmark. `files` counts all audio, loaded or
    /// not; `notLoaded` how many of them are not on the device.
    static func resolution(place: Place, resolved: Bool, stale: Bool, renewed: Bool,
                           access: Bool, files: Int?, notLoaded: Int?, reason: String?) -> String {
        var line = "E1MESS ort=\(place.rawValue) aufgeloest=\(yesNo(resolved)) veraltet=\(yesNo(stale))"
            + " erneuert=\(yesNo(renewed)) zugriff=\(yesNo(access))"
            + " dateien=\(files.map(String.init) ?? "-") nicht_geladen=\(notLoaded.map(String.init) ?? "-")"
        if let reason { line += " fehler=\(reason)" }
        return line
    }

    /// One minute of the background playback probe; minute 0 is the start,
    /// and a start that fails carries its reason.
    static func playback(minute: Int, playing: Bool, access: Bool, reason: String? = nil) -> String {
        var line = "E1MESS wiedergabe minute=\(minute) spielt=\(yesNo(playing)) zugriff=\(yesNo(access))"
        if let reason { line += " fehler=\(reason)" }
        return line
    }

    private static func yesNo(_ flag: Bool) -> String { flag ? "ja" : "nein" }
}
