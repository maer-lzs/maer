// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Der Start der App und jeder Szenenwechsel gehoerten `LibraryView`: 42
/// Singleton-Griffe in einer Ansicht, deren Aufgabe das Beherbergen der Tabs
/// ist. Sie standen dort aus einem einzigen Grund, naemlich dass die
/// Bibliothek zufaellig der erste Bildschirm ist.
///
/// Der Zaun haelt zwei Sachen, und die zweite ist die wichtigere:
///
/// 1. Die Ansicht holt den Haushalt nicht zurueck.
/// 2. **Die REIHENFOLGE.** Sie war vorher eine Eigenschaft eines 1584-zeiligen
///    Ansichts-Rumpfs und nirgends aussprechbar. Sie folgt derselben Regel,
///    die der E55-Auftrag fuer die Katalog-Laeufe festschreibt: Haushalt kommt
///    NACH dem Inhalt, auf den gewartet wird.
struct AppHousekeepingFenceTests {
    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func codeOf(_ relative: String) throws -> String {
        try sourceText(relative)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Bestand mit Grund je Name. Alle auf NULL: keiner dieser Dienste hat in
    /// der Ansicht etwas zu suchen, und wer einen zurueckholt, muss diesen
    /// Eintrag anfassen.
    @Test("Die Tab-Wirtin ruft keinen App-Dienst mehr selbst")
    func theTabHostCallsNoAppServiceItself() throws {
        let forbidden: [String: String] = [
            "SyncQueue": "Fortschritts-Warteschlange, gehoert AppHousekeeping.flushQueues (zwei Rufer)",
            "BookmarkQueue": "Lesezeichen-Warteschlange, dieselbe Tuer wie SyncQueue",
            "CloudQuotaWatch": "iCloud-Kontingent, steht VOR den Diensten und haengt an keinem",
            "PodcastCloudSync": "Podcast-Fortschritt ueber iCloud, Start und beide Szenen-Zweige",
            "ListeningStatsStore": "Hoerstatistik, derselbe Schalter",
            "MaerPlaylistCloudSync": "Playlists reisen mit dem Podcast-Fortschritt",
            "UserChoiceCloudSync": "die reisenden Nutzer-Entscheidungen",
            "PlaybackClaimSync": "Uebernahme-Kanal",
        ]
        let code = try codeOf("Sources/Views/LibraryView.swift")
        var offenders: [String] = []
        for name in forbidden.keys.sorted() where code.contains(name) { offenders.append(name) }
        #expect(offenders.isEmpty, "LibraryView ruft App-Dienste selbst: \(offenders)")
    }

    /// `Artwork` steht bewusst NICHT in der Liste oben, und der Grund gehoert
    /// hierher statt in eine Ausnahme: die zwei bedingungslosen Fegelaeufe
    /// (Start, Hintergrund) sind Haushalt und sind umgezogen. Der dritte
    /// haengt am RUHE-TOR, und „wann ruht das Scrollen" ist die Frage der
    /// Ansicht. Haette ich ihn mitgenommen, waere `AppHousekeeping` ein Typ
    /// geworden, der keine Ansicht ist und UI-Arbeit einplant — genau der
    /// Bestand, den `ScrollCalmFenceTests` als Weg B herunterzaehlt. Dieser
    /// Zaun hat es einen Lauf vor dem Commit gefangen.
    @Test("Der Cover-Deckel beim Zurueckkommen bleibt am Ruhe-Tor der Ansicht")
    func theCalmGatedSweepStaysInTheView() throws {
        let code = try codeOf("Sources/Views/LibraryView.swift")
        #expect(code.contains("Artwork.sweepIfOverCap"),
                "der Deckel-Lauf beim Zurueckkommen ist verschwunden")
        #expect(!code.contains("Artwork.sweep(active:"),
                "ein bedingungsloser Fegelauf ist in die Ansicht zurueckgekehrt")
        // Und er haengt wirklich am Tor, nicht daneben.
        guard let calm = code.range(of: "ScrollCalm.run"),
              let sweep = code.range(of: "Artwork.sweepIfOverCap") else {
            Issue.record("eine der zwei Marken fehlt"); return
        }
        #expect(calm.lowerBound < sweep.lowerBound,
                "der Fegelauf steht nicht mehr im Ruhe-Tor")
        // Gegenprobe: der Haushalt haelt das Tor NICHT, sonst waere der
        // Weg-B-Bestand um eins gestiegen.
        #expect(!(try codeOf("Sources/ViewModels/AppHousekeeping.swift")).contains("ScrollCalm"),
                "AppHousekeeping plant UI-Arbeit ein und erhoeht damit Weg B")
    }

    /// Die Reihenfolge am Quelltext. Ein Zeuge kann eine `.task` nicht
    /// ausfuehren, also wird die STELLUNG geprueft — das ist genau die
    /// Aussage, die vorher nirgends stand.
    @Test("Der Haushalt steht hinter Bibliothek und Weiterhoeren")
    func housekeepingStandsBehindTheContent() throws {
        let code = try codeOf("Sources/Views/LibraryView.swift")
        guard let cachedLibrary = code.range(of: "showCachedLibraryIfAvailable"),
              let restore = code.range(of: "restoreLastSession"),
              let maintenance = code.range(of: "AppHousekeeping.maintenance()"),
              let services = code.range(of: "AppHousekeeping.startServices()")
        else {
            Issue.record("eine der vier Marken fehlt: die Startsequenz wurde umgebaut")
            return
        }
        #expect(cachedLibrary.lowerBound < maintenance.lowerBound,
                "die Wartung steht wieder VOR der zwischengespeicherten Bibliothek")
        #expect(restore.lowerBound < maintenance.lowerBound,
                "die Wartung steht vor dem Weiterhoeren")
        #expect(services.lowerBound < maintenance.lowerBound,
                "die Wartung ist nicht mehr der letzte Schritt")
    }

    /// Und die Gegenrichtung, damit der Fall oben nicht gruen ist, weil die
    /// Marken irgendwo stehen: der Haushalt selbst nennt seine Dienste auch
    /// wirklich, sonst bewacht der Bestand oben eine leere Datei.
    @Test("Der Haushalt nennt die Dienste, die er uebernommen hat")
    func housekeepingActuallyHoldsThem() throws {
        let code = try codeOf("Sources/ViewModels/AppHousekeeping.swift")
        for name in ["SyncQueue", "BookmarkQueue", "CloudQuotaWatch", "PodcastCloudSync",
                     "ListeningStatsStore", "MaerPlaylistCloudSync", "UserChoiceCloudSync",
                     "PlaybackClaimSync", "Artwork"] {
            #expect(code.contains(name), "\(name) ist nirgends: der Umzug ist unvollstaendig")
        }
        // Der Szenenwechsel fragt die Fahrmodus-Uhr fuer JEDE Phase, auch
        // `.inactive`, also darf sie nicht in einem der zwei Zweige stehen.
        guard let driveMode = code.range(of: "DriveModeController"),
              let firstBranch = code.range(of: "case .active:") else {
            Issue.record("der Szenenwechsel wurde umgebaut"); return
        }
        #expect(driveMode.lowerBound < firstBranch.lowerBound,
                "die Fahrmodus-Uhr steht in einem Zweig und verpasst .inactive")
    }
}
#endif
