// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// `PlayerSourceRouter` ist EIN Navigationspunkt, und `open(_:)` ist seine
/// Tuer: dort steht die Diagnose-Zeile, die auf dem Geraet zeigt, ob ein Tipp
/// feuert und ob er routet. Der Router wurde genau deshalb gebaut, weil die
/// vorige Verdrahtung ueber die Umgebung einen Tipp still verschlucken konnte.
///
/// Zwei Stellen riefen den registrierten Verschluss DIREKT und gingen damit an
/// der Tuer vorbei — und der Kommentar darueber sagte woertlich „through the
/// ONE navigation point, not past it". Ein Sprung aus einer Mitteilung hinter-
/// liess also keine Spur, und ohne registrierten Verschluss war er ein stiller
/// Fehlschlag: genau das, was der Router beenden sollte.
///
/// Der Bestand ist die Zahl, nicht die Absicht: `handler` darf ausserhalb
/// seiner eigenen Datei GENAU EINMAL vorkommen, naemlich als Registrierung.
struct PlayerSourceDoorFenceTests {
    private func codeOf(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("Nur die Registrierung fasst den Rueckruf an, alle anderen gehen durch die Tuer")
    func onlyTheRegistrationTouchesTheClosure() throws {
        let ownFile = "Sources/Views/PlayerSourceNavigation.swift"
        let expected: [String: (count: Int, reason: String)] = [
            "Sources/Views/LibraryView.swift":
                (1, "die REGISTRIERUNG. LibraryView besitzt den Navigations-Pfad, also setzt sie "
                    + "den Verschluss ein einziges Mal. Jeder Sprung geht danach durch open(_:)"),
        ]
        var found: [String: Int] = [:]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        for case let name as String in walker where name.hasSuffix(".swift") {
            let relative = "Sources/" + name
            if relative == ownFile { continue }
            let count = try codeOf(relative)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.contains("PlayerSourceRouter.shared.handler") }
                .count
            if count > 0 { found[relative] = count }
        }
        #expect(found == expected.mapValues(\.count),
                "jemand fasst den Rueckruf ausserhalb der Registrierung an")
    }

    /// Und die Gegenrichtung, damit der Bestand oben nicht deshalb stimmt,
    /// weil die Tuer verschwunden ist: `open(_:)` ruft den Verschluss wirklich
    /// und protokolliert davor.
    @Test("Die Tuer protokolliert und ruft dann")
    func theDoorLogsAndThenCalls() throws {
        let code = try codeOf("Sources/Views/PlayerSourceNavigation.swift")
        guard let door = code.range(of: "func open(_ target: PlayerSourceTarget)"),
              let log = code.range(of: "PLAYERSOURCE route target="),
              let call = code.range(of: "handler?(target)") else {
            Issue.record("die Tuer wurde umgebaut"); return
        }
        #expect(door.lowerBound < log.lowerBound && log.lowerBound < call.lowerBound,
                "die Diagnose-Zeile steht nicht mehr vor dem Ruf")
        // Und sie nennt, OB ein Verschluss da war. Ohne diese Haelfte sieht
        // ein stiller Fehlschlag im Log aus wie ein gelungener Sprung.
        #expect(code.contains("handler != nil"),
                "die Diagnose sagt nicht mehr, ob ueberhaupt ein Verschluss registriert war")
    }
}
#endif
