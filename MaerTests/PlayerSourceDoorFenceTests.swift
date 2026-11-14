// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// `PlayerSourceRouter` is ONE navigation point, and `open(_:)` is its
/// door: the diagnostic line sits there, showing on the device whether a tap
/// fires and whether it routes. The router was built for exactly this reason:
/// the previous wiring through the environment could swallow a tap silently.
///
/// Two places called the registered closure DIRECTLY and so went past the
/// door, and the comment above them literally said „through the
/// ONE navigation point, not past it". A jump from a notification therefore
/// left no trace, and without a registered closure it was a silent
/// failure: exactly what the router was meant to end.
///
/// The count is the measure, not the intent: `handler` may occur outside
/// its own file EXACTLY ONCE, namely as the registration.
struct PlayerSourceDoorFenceTests {
    private func codeOf(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("Only the registration touches the callback, all others go through the door", .needsTheSources)
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
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let relative = SourceTree.relativePath(of: url)
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

    /// And the opposite direction, so the count above does not hold merely
    /// because the door has vanished: `open(_:)` really calls the closure
    /// and logs before it.
    @Test("The door logs and then calls", .needsTheSources)
    func theDoorLogsAndThenCalls() throws {
        let code = try codeOf("Sources/Views/PlayerSourceNavigation.swift")
        guard let door = code.range(of: "func open(_ target: PlayerSourceTarget)"),
              let log = code.range(of: "PLAYERSOURCE route target="),
              let call = code.range(of: "handler?(target)") else {
            Issue.record("die Tuer wurde umgebaut"); return
        }
        #expect(door.lowerBound < log.lowerBound && log.lowerBound < call.lowerBound,
                "die Diagnose-Zeile steht nicht mehr vor dem Ruf")
        // And it says WHETHER a closure was there. Without this half, a silent
        // failure looks in the log like a successful jump.
        #expect(code.contains("handler != nil"),
                "die Diagnose sagt nicht mehr, ob ueberhaupt ein Verschluss registriert war")
    }
}
#endif
