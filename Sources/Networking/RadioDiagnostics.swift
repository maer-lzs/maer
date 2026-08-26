// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// Permanent play diagnosis, LOG ONLY. After a station starts,
/// one short header probe reads the stream's `icy-name` and compares it to
/// the tile name. A gross mismatch logs loudly; that single line catches
/// both app-side tile↔stream swaps and hijacked Radio-Browser entries (which
/// exist in the ecosystem). Fire-and-forget; the probe aborts right after
/// the headers, so the data cost stays a few KB per play.
nonisolated enum RadioDiagnostics {

    /// Pure (tested): does the announced station name roughly match the
    /// stream's icy-name? Folded containment in EITHER direction counts.
    /// Icy names carry slogans ("ROCK ANTENNE – der beste Rock nonstop").
    /// Empty/absent icy-name is NO mismatch (many streams omit it).
    static func roughlyMatches(expectedName: String, icyName: String?) -> Bool {
        guard let icyName, !icyName.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        let a = fold(expectedName)
        let b = fold(icyName)
        guard !a.isEmpty, !b.isEmpty else { return true }
        return a.contains(b) || b.contains(a)
    }

    private static func fold(_ raw: String) -> String {
        raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func compareICYName(streamURL: String, expectedName: String, stationID: String) {
        guard let url = URL(string: streamURL), !url.isFileURL else { return }
        Task.detached(priority: .utility) {
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("0", forHTTPHeaderField: "Icy-MetaData")
            guard let (bytes, response) = try? await URLSession.shared.bytes(for: request) else { return }
            // Headers are in. Never consume the body.
            bytes.task.cancel()
            let headers = (response as? HTTPURLResponse)?.allHeaderFields
            let icyName = (headers?["icy-name"] as? String) ?? (headers?["Icy-Name"] as? String)
            if roughlyMatches(expectedName: expectedName, icyName: icyName) {
                Logger.library.notice("RADIO icy-check ok station=\(expectedName, privacy: .public) icy=\(icyName ?? "-", privacy: .public)")
            } else {
                Logger.library.error("RADIO icy-check MISMATCH station=\(expectedName, privacy: .public) icy=\(icyName ?? "-", privacy: .public) id=\(stationID, privacy: .public) url=\(streamURL, privacy: .public)")
            }
        }
    }
}
