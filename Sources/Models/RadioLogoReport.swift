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
        /// Seconds since the result was stored — nil when nothing is stored.
        /// The age separates "the display just resolved it" from "this has been
        /// sitting here since the station was last played".
        let ageSeconds: Double?
        /// 4fe882b: "no result" is one of THREE causes, and the report must
        /// name which — waiting for its serialised turn, tried but the
        /// transport failed (nothing bookable), or given up for the session.
        var sessionVerdict: String? = nil
    }

    /// 4fe882b format rule: ids shorten to the FIRST characters after the
    /// `radio:rb:` prefix — the tail of a v1 UUID is the shared node field of
    /// an import batch, six different stations can end identically there.
    static func shortID(_ id: String) -> String {
        let stem = id.hasPrefix("radio:rb:") ? String(id.dropFirst(9)) : id
        return stem.count <= 13 ? stem : stem.prefix(13) + "…"
    }

    static func rows(stations: [(id: String, name: String, faviconURL: String?)],
                     chainResults: [String: (hasLogo: Bool, attempted: Bool, resolvedAt: Double)],
                     now: Double,
                     waiting: Set<String> = [], sessionFailed: Set<String> = [],
                     gaveUp: Set<String> = []) -> [Row] {
        stations.map { station in
            let result = chainResults[station.id]
            let verdict: String?
            if result != nil { verdict = nil }
            else if gaveUp.contains(station.id) { verdict = "aufgegeben (2 Fehlversuche diese Sitzung)" }
            else if sessionFailed.contains(station.id) { verdict = "versucht, nichts gebucht (Transport scheiterte)" }
            else if waiting.contains(station.id) { verdict = "in Arbeit (Warteschlange)" }
            else { verdict = "nie versucht" }
            return Row(id: station.id, name: station.name,
                       hasFaviconURL: !(station.faviconURL ?? "").isEmpty,
                       chainResolved: result?.hasLogo ?? false,
                       chainAttempted: result?.attempted ?? false,
                       ageSeconds: result.map { now - $0.resolvedAt },
                       sessionVerdict: verdict)
        }
    }

    /// The summary line first, because it is the one that decides which of the
    /// three causes it is.
    static func text(_ rows: [Row]) -> String {
        let resolved = rows.filter(\.chainResolved).count
        let fresh = rows.filter { ($0.ageSeconds ?? .infinity) < 600 }.count
        let attempted = rows.filter(\.chainAttempted).count
        let withFavicon = rows.filter(\.hasFaviconURL).count
        var out = """
        RADIO-LOGO-DIAGNOSE
        Sender in den Reihen: \(rows.count)
        mit Favicon-Adresse:  \(withFavicon)
        Kette versucht:       \(attempted)
        Kette mit Logo:       \(resolved)
        davon in den letzten 10 Minuten: \(fresh)
        OHNE ERGEBNIS:        \(rows.count - attempted)

        """
        for row in rows.sorted(by: { $0.name < $1.name }) {
            let age = row.ageSeconds.map { seconds -> String in
                seconds < 600 ? "gerade eben"
                    : (seconds < 86_400 ? "vor \(Int(seconds / 3600)) h"
                       : "vor \(Int(seconds / 86_400)) Tagen")
            } ?? "—"
            let chain = row.chainResolved ? "Logo"
                : (row.chainAttempted ? "kein Treffer"
                   : "OHNE ERGEBNIS — \(row.sessionVerdict ?? "nie versucht")")
            out += "\(row.name) · Favicon \(row.hasFaviconURL ? "ja" : "nein") · Kette \(chain) · \(age)\n"
        }
        return out
    }

    /// What the TILE actually gets: the URL it loads, whether the image
    /// arrives, its pixel size, and the gate's verdict. Three separate answers,
    /// because they fail for three different reasons — and until now the report
    /// could not tell them apart, so every conclusion about the display was an
    /// inference.
    struct Loaded: Equatable {
        let name: String
        let url: String
        let pixels: String
        let verdict: String
    }

    /// b10aa93: "laedt nicht" without a WHY forced guessing (dead version
    /// paths vs. ATS vs. server down are different findings). Pure label from
    /// what one probe request learned.
    static func failureLabel(statusCode: Int?, urlErrorCode: Int?) -> String {
        if let statusCode, !(200...299).contains(statusCode) {
            return "laedt nicht (HTTP \(statusCode))"
        }
        if let urlErrorCode {
            switch urlErrorCode {
            case NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return "laedt nicht (ATS blockiert http)"
            case NSURLErrorTimedOut: return "laedt nicht (Timeout)"
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return "laedt nicht (Host unbekannt)"
            case NSURLErrorCannotConnectToHost: return "laedt nicht (Host antwortet nicht)"
            case NSURLErrorSecureConnectionFailed: return "laedt nicht (TLS)"
            default: return "laedt nicht (Transport \(urlErrorCode))"
            }
        }
        if let statusCode { return "laedt nicht (HTTP \(statusCode), Bild undekodierbar)" }
        return "laedt nicht (Grund unbekannt)"
    }

    static func loadedText(_ entries: [Loaded]) -> String {
        guard !entries.isEmpty else { return "\nANZEIGE: keine gespeicherte Adresse zum Pruefen.\n" }
        let rejected = entries.filter { $0.verdict == "verworfen" }.count
        let failed = entries.filter { $0.verdict.hasPrefix("laedt nicht") }.count
        var out = """

        ANZEIGE (was die Kachel wirklich laedt)
        geprueft:     \(entries.count)
        laedt nicht:  \(failed)
        verworfen:    \(rejected)
        angezeigt:    \(entries.count - failed - rejected)

        """
        for entry in entries {
            out += "\(entry.name) · \(entry.pixels) · \(entry.verdict)\n   \(entry.url)\n"
        }
        return out
    }
}
