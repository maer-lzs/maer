// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Why a station tile shows letters instead of a logo — as a text block that
/// can be copied out of the app.
///
/// The reason this exists rather than a log line: reading the device log needs
/// a Mac, a cable and root. A report that the person holding the phone can copy
/// turns "I cannot reproduce it" into a measurement, and it is the same idiom
/// the book progress diagnosis already uses.
///
/// It states what the STORED state says — it never re-runs the chain, because a
/// diagnosis that changes what it measures is worthless.
nonisolated enum RadioLogoReport {

    /// One station's answer. `chain` is nil when nothing was ever stored for it
    /// — and that is the interesting case: it means the resolution never
    /// FINISHED, not that it failed.
    struct Row: Equatable {
        let id: String
        let name: String
        let hasFaviconURL: Bool
        let chainResolved: Bool
        let chainAttempted: Bool
    }

    static func rows(stations: [(id: String, name: String, faviconURL: String?)],
                     chainResults: [String: (hasLogo: Bool, attempted: Bool)]) -> [Row] {
        stations.map { station in
            let result = chainResults[station.id]
            return Row(id: station.id, name: station.name,
                       hasFaviconURL: !(station.faviconURL ?? "").isEmpty,
                       chainResolved: result?.hasLogo ?? false,
                       chainAttempted: result?.attempted ?? false)
        }
    }

    /// The summary line first, because it is the one that decides which of the
    /// three causes it is.
    static func text(_ rows: [Row]) -> String {
        let resolved = rows.filter(\.chainResolved).count
        let attempted = rows.filter(\.chainAttempted).count
        let withFavicon = rows.filter(\.hasFaviconURL).count
        var out = """
        RADIO-LOGO-DIAGNOSE
        Sender in den Reihen: \(rows.count)
        mit Favicon-Adresse:  \(withFavicon)
        Kette versucht:       \(attempted)
        Kette mit Logo:       \(resolved)
        NIE FERTIG GEWORDEN:  \(rows.count - attempted)

        """
        for row in rows.sorted(by: { $0.name < $1.name }) {
            let chain = row.chainResolved ? "Logo"
                : (row.chainAttempted ? "kein Treffer" : "NICHT FERTIG")
            out += "\(row.name) · Favicon \(row.hasFaviconURL ? "ja" : "nein") · Kette \(chain)\n"
        }
        return out
    }
}
