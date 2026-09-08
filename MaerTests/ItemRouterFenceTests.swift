// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import SwiftUI
@testable import Maer

/// GOAL 3.0 Punkt 3, zweite Scheibe: die Adresse eines Covers wird GEFRAGT,
/// nicht selbst gebaut. Der BESTAND traegt das meiste: welche Flaechen die
/// Sitzung noch selbst nach einer Cover-Adresse fragen, je Datei, mit Grund.
///
/// Dazu eine Aussage ueber die Setz-Stellen, aber aus einem anderen Grund
/// als beim Netz-Wert. Dort hielt sie die RICHTIGKEIT (ein vergessenes
/// Reichen waere still geblieben); hier ist ein vergessenes Reichen
/// harmlos, weil der Vorgabewert der echte Router ist. Sie haelt hier die
/// KOSTEN: `ItemRouter` traegt einen Verschluss und ist darum nicht
/// vergleichbar. Wer ihn in einem `body` setzt, baut bei jedem Durchlauf
/// einen neuen Wert, den SwiftUI nicht als gleich erkennen kann, und alle
/// Leser darunter werden neu ausgewertet. Solange nur der Vorgabewert gilt,
/// wird nie verglichen und nichts invalidiert.
struct ItemRouterFenceTests {
    /// Die fuenf Fragen des Blatts, so wie sie an der Sitzung heissen.
    private static let questions = ["AppSession.shared.coverURL",
                                    "AppSession.shared.libraryItem",
                                    "AppSession.shared.playableItem",
                                    "AppSession.shared.provider(",
                                    "AppSession.shared.resolve("]

    static func reaches(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && questions.contains { trimmed.contains($0) }
            }.count
    }

    /// Der Bestand des Tages, an dem der Zaun gebaut wurde. Er darf nur
    /// fallen, und jeder Eintrag steht mit Grund:
    ///
    /// - `ItemRouterEnvironment` IST die Tuer; dort stehen die fuenf Griffe,
    ///   die die sechzig anderen ersetzt haben.
    /// - `PlaylistCard` baut die Kachel-Mosaike in einer Erweiterung von
    ///   `PlaylistCardSource`, also in einem Wert und nicht in einer
    ///   Ansicht. Dort gibt es keine Umgebung; der Rufer muesste die Adresse
    ///   hineinreichen, und das ist ein Umbau der Karte, keine Umleitung.
    /// - `PodcastNavigation` und `PodcastHelpers` sind `extension View`-
    ///   Helfer ohne eigenes `self`, `PodcastPlayState` ist ein Speicher und
    ///   `PodcastAutoDownload` eine Regel; beide wohnen nur unter
    ///   `Sources/Views`. Fuer alle vier ist die Umgebung kein Weg. Sie
    ///   bekommen die Antwort als Parameter, wenn ihre Rufer an der Reihe
    ///   sind (Podcast-Scheibe des Tab-Schnitts).
    nonisolated static let stock: [String: Int] = [
        "ItemRouterEnvironment.swift": 5,
        "PlaylistCard.swift": 1,
        "PodcastNavigation.swift": 1,
        "PodcastPlayState.swift": 1,
        "PodcastHelpers.swift": 2,
    ]

    @Test("Das Router-Blatt wird nur noch im Bestand selbst gefragt")
    func theRouterLeafIsAskedForNotBuilt() throws {
        var offenders: [String] = []
        var total = 0
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            let count = Self.reaches(in: try String(contentsOf: file, encoding: .utf8))
            total += count
            let allowed = Self.stock[file.lastPathComponent] ?? 0
            if count > allowed { offenders.append("\(file.lastPathComponent): \(count) > \(allowed)") }
        }
        #expect(offenders.isEmpty, "eine Ansicht fragt die Sitzung wieder selbst: \(offenders)")
        #expect(total <= Self.stock.values.reduce(0, +))
        // Rot-Probe in beide Richtungen, ueber alle fuenf Fragen: der
        // Pruefer sieht jeden Griff…
        #expect(Self.reaches(in: "let u = AppSession.shared.coverURL(forItemId: id)") == 1)
        #expect(Self.reaches(in: "let i = AppSession.shared.libraryItem(forId: id)") == 1)
        #expect(Self.reaches(in: "let p = AppSession.shared.provider(for: id)") == 1)
        // …und einen Kommentar ueber einen Griff sieht er NICHT.
        #expect(Self.reaches(in: "// was AppSession.shared.coverURL(forItemId:)") == 0)
    }

    @Test("Niemand setzt den Router im Programm, sonst kosten alle Leser")
    func nobodyHandsTheRouterDownInTheApp() throws {
        var setters: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let count = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !trimmed.hasPrefix("//") && trimmed.contains(".environment(\\.itemRouter")
                }.count
            if count > 0 { setters.append("\(file.lastPathComponent): \(count)") }
        }
        // Der Zaun sieht nur `Sources`. Eine Vorschau oder ein Zeuge setzt
        // den Router ausserhalb eines Koerpers und faellt nicht darunter;
        // das ist die Ausnahme, die keine Regel braucht.
        #expect(setters.isEmpty,
                """
                der Router wird im Programm gesetzt (\(setters)). Er traegt einen \
                Verschluss und ist nicht vergleichbar: in einem `body` gesetzt \
                entsteht je Durchlauf ein neuer Wert, und ALLE Leser darunter \
                werden neu ausgewertet. Wer ihn wirklich reichen muss, macht ihn \
                vorher vergleichbar oder haelt ihn ausserhalb des Koerpers
                """)
        // Rot-Probe: der Pruefer saehe die Form, wenn sie kaeme.
        let probe = "content.environment(\\.itemRouter, ItemRouter(coverURL: { _ in nil }))"
        #expect(probe.contains(".environment(\\.itemRouter"))
    }

    @Test("Der Vorgabewert ist der ECHTE Router, ein vergessenes Reichen bricht nichts")
    func theDefaultIsTheRealRouter() {
        // Anders als beim Netz-Wert gaebe es hier keinen harmlosen Ersatz:
        // ein Router, der nichts weiss, liefert keine Adresse, und Bilder
        // blieben still weg. Deshalb ist der Standard der echte, wie bei
        // den Umgebungs-Aktionen von SwiftUI selbst.
        let fromEnvironment = EnvironmentValues().itemRouter
        // Der Vorgabewert ANTWORTET. Der Fall braucht eine Kennung, deren
        // Anbieter OHNE Sitzungszustand antwortet, sonst prueft er nichts:
        // eine Radio-Kennung gaebe hier nil, weil im Lauf niemand die
        // Station kennt, und `nil == nil` bestuende auch ein leerer
        // Ersatz-Router. Eine Archiv-Kennung leitet die Adresse REIN aus
        // der Kennung ab.
        let derived = fromEnvironment.coverURL("\(FreeCatalog.archivePrefix)beispielwerk")
        #expect(derived != nil)
        #expect(derived?.absoluteString.contains("beispielwerk") == true)
        // Und die Regel der Sitzung gilt weiter: eine Kennung aus einem
        // unbekannten Namensraum bekommt keine Adresse (der Schutz, der den
        // 404-Sturm beendet hat).
        #expect(fromEnvironment.coverURL("quatsch:42") == nil)
        // Ersetzbar zu sein IST der Gewinn dieser Scheibe, also steht er als
        // Fall da: ein untergeschobener Router antwortet anders, und ein
        // leerer faellt an der ersten Zusicherung durch.
        let stub = ItemRouter(coverURL: { _ in URL(string: "https://example.org/x.jpg") })
        #expect(stub.coverURL("egal")?.host() == "example.org")
        let empty = ItemRouter(coverURL: { _ in nil })
        #expect(empty.coverURL("\(FreeCatalog.archivePrefix)beispielwerk") == nil)
    }
}
#endif
