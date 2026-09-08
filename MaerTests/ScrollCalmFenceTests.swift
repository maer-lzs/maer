// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// GOAL 3.0 Punkt 3, Ruhe-Tor: „fuehre das aus, wenn das Scrollen ruht" ist
/// EINE Frage mit EINEM Namen. Vorher fragten ZWEIUNDZWANZIG Rufer die
/// untere Leiste direkt, darunter VIERZEHN Speicher und Ansichtsmodelle.
/// (Die erste Fassung dieses Kopfes sagte siebzehn und neun. Das waren die
/// Zahlen aus einer Zaehlung, die nur `Sources/Views` ansah; der Fall
/// darunter hat sie im selben Commit widerlegt, der Satz nicht.)
///
/// Der Zaun haelt zwei Sachen, und die zweite ist die wichtigere:
///
/// 1. Niemand ausser der Tuer ruft die Warteschlange der Leiste selbst.
/// 2. **Weg B als Rest MIT ZAHL, nicht als Absichtserklaerung.** Ein
///    Speicher, der UI-Arbeit einplant, ist die eigentliche
///    Schichtverletzung; das Tor umzubenennen hat sie nur besser benannt.
///    Der tiefere Schnitt dreht sie um: der Speicher gibt seinen frischen
///    Wert HERAUS, die Ansicht entscheidet, wann sie ihn anwendet. Er
///    gehoert zum Tab-Schnitt, wo diese Ansichtsmodelle ohnehin geoeffnet
///    werden. **Fertig ist er, wenn dieser Bestand null ist.**
struct ScrollCalmFenceTests {
    static func calls(of token: String, in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains(token)
            }.count
    }

    /// Wer die Warteschlange der Leiste noch selbst ruft. Nur die Tuer.
    nonisolated static let queueStock: [String: (count: Int, reason: String)] = [
        "ScrollCalm.swift": (1, "IST die Tuer; der eine Griff, der die einundzwanzig anderen ersetzt hat"),
        "BottomBarState.swift": (1, "die Leiste selbst, die die Warteschlange haelt und leert"),
    ]

    /// **Weg B, der benannte Rest mit Zahl.** Typen, die KEINE Ansicht sind
    /// und trotzdem UI-Arbeit einplanen. Er darf nur fallen; null heisst,
    /// dass Weg B getan ist.
    ///
    /// Gezaehlt wird am umschliessenden TYP, nicht an der Datei: eine Datei
    /// haelt oft einen Speicher UND seine Ansichten, und eine Zaehlung je
    /// Datei haette den halben Rest verschwiegen (`FreeCatalogRows.swift`
    /// hat beides).
    nonisolated static let schedulingStoresStock: [String: (count: Int, reason: String)] = [
        "MusicViewModel":
            (6, "Alben, Neuestes, Zuletzt, Haeufig, Kuenstler und Playlisten kommen nach; das "
                + "Ansichtsmodell plant heute selbst ein, statt den Wert herauszugeben"),
        "FreeCatalogStore":
            (3, "der Katalog-Speicher setzt seine geladenen Reihen selbst, aus demselben Grund"),
        "LateMusicValues":
            (3, "die nachlaufenden Musikwerte setzen sich selbst, sobald sie eintreffen"),
        "OERRLiveStore":
            (1, "der Hoerspiel-Speicher setzt seine Eintraege selbst"),
        "LibraryViewModel":
            (1, "das Bibliotheks-Modell wendet seine berechnete Ausgabe selbst an"),
    ]

    @Test("Die Warteschlange der Leiste ruft nur die Tuer")
    func onlyTheDoorAsksTheQueue() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let count = Self.calls(of: "runWhenCalm", in: try String(contentsOf: file, encoding: .utf8))
            let allowed = Self.queueStock[file.lastPathComponent]?.count ?? 0
            if count > allowed { offenders.append("\(file.lastPathComponent): \(count) > \(allowed)") }
        }
        #expect(offenders.isEmpty, "ein Rufer fragt die Leiste wieder selbst: \(offenders)")
        // Rot-Probe in beide Richtungen.
        #expect(Self.calls(of: "runWhenCalm", in: "BottomBarState.shared.runWhenCalm { x() }") == 1)
        #expect(Self.calls(of: "runWhenCalm", in: "// war BottomBarState.shared.runWhenCalm") == 0)
    }

    /// Wie oft ein Typ, der KEINE Ansicht ist, UI-Arbeit einplant. Der
    /// umschliessende Typ ist die naechste Deklaration ueber der Zeile.
    static func schedulingNonViews(in text: String) -> [String: Int] {
        var out: [String: Int] = [:]
        var enclosing = ""
        var isView = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // NUR Deklarationen der obersten Ebene. Ein verschachtelter Typ
            // (eine Aufzaehlung in einer Ansicht) waere sonst der
            // vermeintliche Wirt jedes Aufrufs darunter, und der Zaun
            // meldete Namen, die es als Rufer gar nicht gibt.
            if !trimmed.hasPrefix("//"), line.first != " ", line.first != "\t",
               let name = Self.declaredType(in: trimmed) {
                enclosing = name
                isView = trimmed.contains(": View") || trimmed.contains(": ViewModifier")
            }
            guard !trimmed.hasPrefix("//"), trimmed.contains("ScrollCalm.run"), !isView,
                  !enclosing.isEmpty else { continue }
            out[enclosing, default: 0] += 1
        }
        return out
    }

    static func declaredType(in line: String) -> String? {
        for keyword in ["final class ", "class ", "struct ", "enum ", "actor "]
        where line.contains(keyword) {
            guard let after = line.range(of: keyword) else { continue }
            let rest = line[after.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { return String(name) }
        }
        return nil
    }

    @Test("Weg B: Typen, die keine Ansicht sind und UI-Arbeit einplanen, werden nur weniger")
    func storesThatScheduleUIWorkOnlyShrink() throws {
        var offenders: [String] = []
        var total = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            for (type, count) in Self.schedulingNonViews(in: try String(contentsOf: file, encoding: .utf8)) {
                total += count
                let allowed = Self.schedulingStoresStock[type]?.count ?? 0
                if count > allowed { offenders.append("\(type): \(count) > \(allowed)") }
            }
        }
        #expect(offenders.isEmpty, "ein neuer Speicher plant UI-Arbeit ein: \(offenders)")
        // Der Rest ist gemessen, nicht behauptet: solange hier eine Zahl
        // ueber null steht, ist Weg B offen.
        #expect(total == Self.schedulingStoresStock.values.reduce(0) { $0 + $1.count },
                "der Rest von Weg B steht bei \(total)")
        // Rot-Probe: eine Ansicht darf einplanen, das ist ihre Aufgabe; ein
        // Speicher daneben nicht.
        let mixed = """
            struct EinBild: View {
                func f() { ScrollCalm.run { x() } }
            }
            final class EinSpeicher: ObservableObject {
                func g() { ScrollCalm.run { y() } }
            }
            """
        #expect(Self.schedulingNonViews(in: mixed) == ["EinSpeicher": 1])
    }
}
#endif
