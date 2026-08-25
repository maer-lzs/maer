// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// 96cb043 + 2100b09: the ONE collection of what may appear in "Keep
/// listening" — server library, LOCAL files and CATALOG works.
///
/// Third instance of "the row only knows the source it was born from": the
/// row read the server library's `continueListening`, so a locally sideloaded
/// book that is actively playing (the owner's Winterfell) and a started LibriVox
/// work were structurally invisible — for a serverless user the row was empty
/// while he was in the middle of a book.
///
/// Both extra classes keep their position in the SAME place: the
/// `localPosition` second-backup. So this is one collection, not two add-on
/// points — the next class plugs in here instead of being forgotten again.
nonisolated enum ContinueSources {
    /// A started title outside the server library.
    struct Extra: Equatable {
        let id: String
        let position: Double
        let updatedAtMs: Double
        let duration: Double
    }

    /// Which id namespaces carry their progress locally.
    static func isLocallyTracked(_ id: String) -> Bool {
        id.hasPrefix("local:") || FreeCatalog.allPrefixes.contains(where: id.hasPrefix)
    }

    /// THE switch, and it has two sides that must never both be true.
    ///
    /// An entry started as an ALBUM track is music: it has no place to return
    /// to in the product sense, so it belongs in "Listen Again" and must leave
    /// Continue — otherwise the same title stands in both rows, and the row
    /// that drops duplicates (Listen Again) would drop it, leaving the feature
    /// with no effect at all.
    ///
    /// **An entry WITHOUT a form is not guessed.** It behaves exactly as it did
    /// before: Continue keeps it, "Listen Again" never shows it. That is what
    /// makes this change invisible for everything already on the device.
    static func belongsInContinue(_ stored: [Double]) -> Bool {
        ProgressMark.markedForm(stored) != .album
    }

    /// 305a292: "started" must be asked of the SAME won source the start uses,
    /// not of the raw cached progress. Measured: a downloaded book whose cached
    /// detail froze at zero counted as unbegun and fell out of the Continue row
    /// entirely — the third appearance of the frozen zero, after the null start
    /// and the false 00:00 display.
    ///
    /// The flushed witness is what this device last pushed, so it is proof of
    /// having started even when every server-fed value says otherwise.
    static func isStarted(serverSaysStarted: Bool,
                          flushed: [Double]?,
                          finished: Bool = false,
                          minimumSeconds: Double = 30) -> Bool {
        // The witness proves HAVING STARTED — it says nothing about the end,
        // and it must not outvote the finished answer. Measured on a book that
        // stood at exactly its duration with the server flag set: the row kept
        // it anyway, because this device had once pushed a position and the
        // push was read as "started". A witness for the beginning cannot
        // decide a question about the end.
        if finished { return false }
        if serverSaysStarted { return true }
        guard let flushed, flushed.count >= 2 else { return false }
        return flushed[0] >= minimumSeconds
    }

    /// Read the started titles from the second-backup store. Pure over the
    /// passed dictionary so the rule is testable without UserDefaults.
    ///
    /// **Dedupe rule (96cb043):** an ABS book that is additionally downloaded
    /// stays ONE entry — the server identity leads, so ids the server library
    /// already knows are skipped here. Local sideloads are their own identity.
    static func started(in defaults: [String: Any],
                        serverKnows: Set<String>,
                        minimumSeconds: Double = 30) -> [Extra] {
        var out: [Extra] = []
        for (key, value) in defaults {
            guard key.hasPrefix("localPosition.") else { continue }
            let id = String(key.dropFirst("localPosition.".count))
            guard isLocallyTracked(id), !serverKnows.contains(id),
                  let stored = value as? [Double], stored.count >= 2 else { continue }
            guard belongsInContinue(stored) else { continue }
            // R33: the BOOKS-tab rows ask the ONE membership test — a jam:
            // album and a track-addressed lva: id are music, whatever their
            // (possibly missing) started form says. Unknown stays visible.
            guard MediaFamily.booksTabMember(id, markedForm: ProgressMark.markedForm(stored))
            else {
                if MediaFamily.of(id) == .unknown {
                    Logger.library.notice("CONTINUE unknown namespace filtered: \(id, privacy: .public)")
                }
                continue
            }
            let position = stored[0]
            // A few seconds are a tap, not a started book.
            guard position >= minimumSeconds else { continue }
            let duration = ProgressMark.markedDuration(stored) ?? 0
            // Finished titles belong to "played", not to "keep listening" —
            // asked through the ONE played rule, never re-implemented here
            // (the project fence caught exactly that in the first draft).
            if duration > 0, ProgressMark.isPlayed(stored: stored, currentDuration: duration) {
                continue
            }
            out.append(Extra(id: id, position: position,
                             updatedAtMs: stored[1], duration: duration))
        }
        return out.sorted { $0.updatedAtMs > $1.updatedAtMs }
    }

    /// The other side of the same switch: titles started as album tracks, newest
    /// first — the catalogue input of the "Listen Again" row.
    ///
    /// Deliberately WITHOUT a minimum-seconds threshold, unlike `started`
    /// above. The sibling class decides it: a radio station tapped and left
    /// after five seconds stands in "recently played" too, because that row
    /// answers "what did I play", not "what did I get into". Inventing a
    /// different number for the same row would be the asymmetry, not the
    /// symmetry.
    static func positionless(in defaults: [String: Any],
                             serverKnows: Set<String>,
                             deadStore: UserDefaults = .standard) -> [Extra] {
        var out: [Extra] = []
        for (key, value) in defaults {
            guard key.hasPrefix("localPosition.") else { continue }
            let id = String(key.dropFirst("localPosition.".count))
            guard isLocallyTracked(id), !serverKnows.contains(id),
                  let stored = value as? [Double], stored.count >= 2 else { continue }
            // The started FORM is the primary witness; the ID FORM is the
            // second (R33): a jam: id or a track-addressed lva: id is music
            // by construction — pre-form stock (started before the form
            // existed) must reach the music row instead of vanishing when
            // the books tab rightly refuses it.
            let isMusicById = id.hasPrefix(FreeCatalog.jamendoPrefix)
                || (id.hasPrefix(FreeCatalog.archivePrefix)
                    && id.contains(CatalogSongID.separator))
            guard ProgressMark.markedForm(stored) == .album || isMusicById else { continue }
            // R59 (the owner am Geraet: die erste Kachel heisst „Unbekannter
            // Titel" und laeuft nicht): der Tot-Vermerk wurde bisher NUR beim
            // Bauen der Katalogreihen gelesen — diese Reihe liest den
            // HOERVERLAUF und kam an ihm vorbei. Ein Stueck, das die Quelle
            // nicht mehr kennt, verlaesst damit auch hier die Reihe.
            //
            // Der EINTRAG bleibt: ein Hoerstand ist Nutzerbesitz, und
            // „vermerkt" ist kein Urteil auf Dauer (der Vermerk altert). Nur
            // die Kachel geht.
            guard !DeadCatalogItems.isDead(id, defaults: deadStore) else { continue }
            out.append(Extra(id: id, position: stored[0], updatedAtMs: stored[1],
                             duration: ProgressMark.markedDuration(stored) ?? 0))
        }
        return out.sorted { $0.updatedAtMs > $1.updatedAtMs }
    }
}
