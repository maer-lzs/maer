// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import SwiftUI
@testable import Maer

/// GOAL 3.0 Punkt 3, erste Scheibe: „bin ich online" ist ein WERT, kein
/// Griff an eine Wache. Die Naht kommt mit ihrem Zaun: er haelt fest, dass
/// der Wert an genau EINER Stelle gesetzt wird (ein vergessenes Reichen
/// waere sonst still, weil der Vorgabewert „online" ist), und er
/// inventarisiert die Stellen, die die Wache noch selbst fragen, damit der
/// Bestand nur fallen kann.
struct OnlineValueFenceTests {
    private static func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// Nicht-Kommentarzeilen einer Datei, die den Griff nennen.
    static func reaches(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains("NetworkMonitor.shared")
            }.count
    }

    /// Der Bestand des Tages, an dem der Zaun gebaut wurde, je Datei. Er
    /// darf nur fallen, und jeder Eintrag traegt seinen Grund NEBEN SICH.
    ///
    /// Das Musik-Kontextmenue stand hier einmal mit dem Grund „Helfer ohne
    /// eigenes `self`" und zu Unrecht: seine zwei Griffe sassen in einem
    /// `ViewModifier` mit eigenem `body`. Geheilt statt umbegruendet. Genau
    /// dieser Fall ist der Grund, warum der Grund jetzt im Eintrag steht
    /// und nicht in einem Absatz darueber: dort konnte er von seinem
    /// Eintrag abdriften, ohne dass es jemand sieht.
    nonisolated static let stock: [String: (count: Int, reason: String)] = [
        "RootView.swift":
            (1, "die EINE Stelle, die die Wache beobachtet und den Wert reicht"),
        "PodcastHelpers.swift":
            (2, "die Griffe sitzen in extension-View-Helfern ohne eigenes self; sie bekommen "
                + "den Wert in einer spaeteren Scheibe als Parameter vom Rufer"),
        "Lyrics.swift":
            (1, "ein Dienst, der nur unter Sources/Views wohnt, keine Ansicht"),
        "PodcastAutoContinue.swift":
            (1, "eine Regel, die nur unter Sources/Views wohnt, keine Ansicht"),
        "RadioArtwork.swift":
            (2, "fragt in zwei ASYNCHRONEN Seiteneffekten, ob das Netz stand, als ein Bild "
                + "nicht kam; das ist keine Zeichen-Frage, und ein Umgebungswert waere dort "
                + "der Stand vom Aufgabenbeginn"),
    ]

    @Test("Die Wache wird in den Ansichten nur noch im Bestand gefragt")
    func viewsAskTheMonitorOnlyWhereTheStockSaysSo() throws {
        var offenders: [String] = []
        var total = 0
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            let count = Self.reaches(in: try String(contentsOf: file, encoding: .utf8))
            total += count
            let allowed = Self.stock[file.lastPathComponent]?.count ?? 0
            if count > allowed { offenders.append("\(file.lastPathComponent): \(count) > \(allowed)") }
        }
        #expect(offenders.isEmpty, "die Wache ist zurueck in einer Ansicht: \(offenders)")
        #expect(total <= Self.stock.values.reduce(0) { $0 + $1.count })
        // Rot-Probe in beide Richtungen: der Pruefer sieht den Griff…
        #expect(Self.reaches(in: "guard NetworkMonitor.shared.isConnected else { return }") == 1)
        // …und einen Kommentar ueber den Griff sieht er NICHT.
        #expect(Self.reaches(in: "// used to ask NetworkMonitor.shared") == 0)
    }

    @Test("Der Wert wird an genau EINER Stelle gereicht")
    func exactlyOnePlaceHandsTheValueDown() throws {
        var setters: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let count = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !trimmed.hasPrefix("//") && trimmed.contains(".environment(\\.isOnline")
                }.count
            if count > 0 { setters.append("\(file.lastPathComponent): \(count)") }
        }
        // Ein zweiter Setzer waere kein Fehler, den man sieht: der Vorgabewert
        // ist „online", eine falsch gereichte Stelle bliebe also still.
        #expect(setters == ["RootView.swift: 1"], "gesetzt wird an: \(setters)")
    }

    @Test("Die Wache veroeffentlicht GENAU eine Antwort, sonst kostet der Wurzel-Beobachter")
    func theMonitorPublishesExactlyOneAnswer() throws {
        // Die Bedingung, an der die Ausnahme haengt. `@ObservedObject` haengt
        // am OBJEKT, nicht am Feld: ein zweites `@Published` an dieser Wache
        // (Verbindungsart, teures Netz, ein Zaehler) wuerde bei jeder seiner
        // Aenderungen die Wurzel neu auswerten, also den ganzen Baum, obwohl
        // die Online-Antwort stillsteht. Das waere die Ruckler-Konstruktion
        // an der schlechtestmoeglichen Stelle. Wer hier ein Feld ergaenzen
        // will, muss den Beobachter vorher aus der Wurzel holen.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Networking/NetworkMonitor.swift"),
                              encoding: .utf8)
        let published = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains("@Published")
            }
        #expect(published.count == 1,
                """
                die Wache traegt \(published.count) veroeffentlichte Felder; \
                die Wurzel beobachtet sie und wuerde bei jeder Aenderung \
                jedes Feldes den ganzen Baum neu auswerten
                """)
        #expect(published.first?.contains("isConnected") == true)
    }

    @Test("Der Vorgabewert ist ONLINE, weil die Tore nur daempfen")
    func theDefaultIsOnline() {
        // Eine Flaeche, die den Wert nie bekommt, verhaelt sich wie heute,
        // statt alles zu dimmen. Die Gegenrichtung waere die schlimmere:
        // eine Bibliothek, die sich ohne Grund als offline zeigt.
        #expect(EnvironmentValues().isOnline)
        // Und die Regel dahinter bleibt die alte, pure: offline UND nicht
        // geladen heisst nicht abspielbar, alles andere ist verfuegbar.
        #expect(MediaAvailability.offlineUnavailable(isConnected: false, isDownloaded: false))
        #expect(!MediaAvailability.offlineUnavailable(isConnected: false, isDownloaded: true))
        #expect(!MediaAvailability.offlineUnavailable(isConnected: true, isDownloaded: false))
    }
}
#endif
