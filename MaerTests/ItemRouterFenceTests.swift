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
/// nicht selbst gebaut. Anders als beim Netz-Wert traegt hier keine
/// „genau eine Setz-Stelle"-Aussage, weil der Vorgabewert der echte Router
/// ist und ein vergessenes Reichen darum harmlos bleibt. Alles haengt am
/// BESTAND: welche Flaechen die Sitzung noch selbst nach einer
/// Cover-Adresse fragen, je Datei, mit Grund.
struct ItemRouterFenceTests {
    static func reaches(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains("AppSession.shared.coverURL")
            }.count
    }

    /// Der Bestand des Tages, an dem der Zaun gebaut wurde. Er darf nur
    /// fallen, und jeder Eintrag steht mit Grund:
    ///
    /// - `ItemRouterEnvironment` IST die Tuer; dort steht der eine Griff,
    ///   der die 35 anderen ersetzt hat.
    /// - `PlaylistCard` baut die Kachel-Mosaike in einer Erweiterung von
    ///   `PlaylistCardSource`, also in einem Wert und nicht in einer
    ///   Ansicht. Dort gibt es keine Umgebung. Der Rufer koennte die Adresse
    ///   hineinreichen; das gehoert in die Scheibe, die den Rest des
    ///   Router-Blatts umzieht.
    nonisolated static let stock: [String: Int] = [
        "ItemRouterEnvironment.swift": 1,
        "PlaylistCard.swift": 1,
    ]

    @Test("Die Cover-Adresse wird nur noch im Bestand selbst gebaut")
    func theCoverAddressIsAskedForNotBuilt() throws {
        var offenders: [String] = []
        var total = 0
        for file in ProjectFileIntegrityTests.sourceFiles() where file.path.contains("/Sources/Views/") {
            let count = Self.reaches(in: try String(contentsOf: file, encoding: .utf8))
            total += count
            let allowed = Self.stock[file.lastPathComponent] ?? 0
            if count > allowed { offenders.append("\(file.lastPathComponent): \(count) > \(allowed)") }
        }
        #expect(offenders.isEmpty, "eine Ansicht baut die Adresse wieder selbst: \(offenders)")
        #expect(total <= Self.stock.values.reduce(0, +))
        // Rot-Probe in beide Richtungen: der Pruefer sieht den Griff…
        #expect(Self.reaches(in: "let u = AppSession.shared.coverURL(forItemId: id)") == 1)
        // …und einen Kommentar ueber den Griff sieht er NICHT.
        #expect(Self.reaches(in: "// was AppSession.shared.coverURL(forItemId:)") == 0)
    }

    @Test("Der Vorgabewert ist der ECHTE Router, ein vergessenes Reichen bricht nichts")
    func theDefaultIsTheRealRouter() {
        // Anders als beim Netz-Wert gaebe es hier keinen harmlosen Ersatz:
        // ein Router, der nichts weiss, liefert keine Adresse, und Bilder
        // blieben still weg. Deshalb ist der Standard der echte, wie bei
        // den Umgebungs-Aktionen von SwiftUI selbst.
        let fromEnvironment = EnvironmentValues().itemRouter
        // Der Vorgabewert ANTWORTET, er ist nicht leer: er haelt die Regel
        // der Sitzung, dass eine Kennung aus einem unbekannten Namensraum
        // nie zu einer Anfrage an den Bibliotheksserver wird. Ein leerer
        // Ersatz-Router wuerde hier ebenfalls nil geben, deshalb steht der
        // Gegenfall daneben: eine BEKANNTE Kennung bekommt eine Adresse.
        #expect(fromEnvironment.coverURL("quatsch:42") == nil)
        #expect(fromEnvironment.coverURL("radio:beispiel")
                    == AppSession.shared.coverURL(forItemId: "radio:beispiel"))
        // Und er ist ersetzbar: genau das ist der Gewinn dieser Scheibe.
        let stub = ItemRouter(coverURL: { _ in URL(string: "https://example.org/x.jpg") })
        #expect(stub.coverURL("egal")?.host() == "example.org")
    }
}
#endif
