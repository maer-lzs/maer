// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A witness does not read a fact of its ENVIRONMENT.
///
/// `ExternalSource.isSwitchable`, `ExternalSources.switchable` and
/// `ExternalSources.disableAll` take as input the fact
/// „traegt dieser Bau einen PodcastIndex-Schluessel". There was a convenient
/// version each that read the fact itself from `AppStorageKeys`. For a witness it was
/// a silent fault: the key is not in the repo, so one machine carries it
/// and the other does not, and the same source text is green here
/// and red there. Measured on a case that on a machine with the
/// key saw eleven sources move and on one without ten. For the
/// sources file it was the one binding to the keychain
/// (`podcastIndexConfigured` reads `KeychainStore`, which needs `Security`),
/// and thus what kept the file out of the pure layer. Since the
/// move (GOAL-3-2 place 7) the page passes the fact itself; the
/// second fence keeps the file free of it.
///
/// The stock is ZERO: in `MaerTests` every call names the fact
/// explicitly. The only exception is THIS file, because it has to carry the
/// forbidden forms as search words.
struct ExternalSourcesWitnessFenceTests {
    private static let selfName = "ExternalSourcesWitnessFenceTests.swift"

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("The sources file does not read the PodcastIndex fact itself and knows no keychain", .needsTheSources)
    func theSourcesFileReadsNoFactAndNoKeychain() throws {
        let text = try Self.source("Sources/Models/ExternalSources.swift")
        // The precondition: the three forms with a passed fact are there,
        // otherwise the fence measures a file that no longer exists.
        for form in ["func isSwitchable(podcastIndexConfigured: Bool)",
                     "static func switchable(podcastIndexConfigured: Bool)",
                     "static func disableAll(defaults: UserDefaults = .standard, podcastIndexConfigured: Bool)"] {
            #expect(text.contains(form), "die Form fehlt: \(form)")
        }
        for forbidden in ["AppStorageKeys.podcastIndexConfigured", "KeychainStore", "import Security"] {
            #expect(!text.contains(forbidden), "die Datei der Quellen nennt \(forbidden)")
        }
        // And the page passes the fact itself at each of its places.
        let page = try Self.source("Sources/Views/SourcesSettingsView.swift")
        let handed = page.components(separatedBy: "podcastIndexConfigured: AppStorageKeys.podcastIndexConfigured").count - 1
        #expect(handed == 3, "die Seite reicht die Tatsache an \(handed) Stellen, erwartet 3")
    }

    /// Source text of a test file without comment lines, whitespace pulled together.
    /// Without pulling it together the finder checks the line length instead of the
    /// statement and breaks at the next formatter.
    private func code(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func testFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let all = try FileManager.default.contentsOfDirectory(at: root,
                                                              includingPropertiesForKeys: nil)
        return all.filter { $0.pathExtension == "swift" && $0.lastPathComponent != Self.selfName }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The argument of a call, from the opening to the matching
    /// closing bracket. The question is thus LOCAL: it sees only the
    /// call it explains, never its neighborhood.
    private func argumentsOfCalls(named name: String, in code: String) -> [String] {
        var found: [String] = []
        var rest = Substring(code)
        while let hit = rest.range(of: name + "(") {
            var depth = 1
            var index = hit.upperBound
            var argument = ""
            while index < rest.endIndex, depth > 0 {
                let character = rest[index]
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1; if depth == 0 { break } }
                argument.append(character)
                index = rest.index(after: index)
            }
            found.append(argument)
            rest = rest[hit.upperBound...]
        }
        return found
    }

    @Test("No witness lets the PodcastIndex fact come from the environment", .needsTheTests)
    func noWitnessReadsTheConfiguredFactFromItsEnvironment() throws {
        var offenders: [String] = []
        var explicitCalls = 0

        for file in try testFiles() {
            let text = try code(of: file)
            let name = file.lastPathComponent

            for argument in argumentsOfCalls(named: "ExternalSources.disableAll", in: text) {
                if argument.contains("podcastIndexConfigured:") { explicitCalls += 1 }
                else { offenders.append("\(name): disableAll ohne die Tatsache") }
            }
            for argument in argumentsOfCalls(named: "ExternalSources.switchable", in: text) {
                if argument.contains("podcastIndexConfigured:") { explicitCalls += 1 }
                else { offenders.append("\(name): switchable ohne die Tatsache") }
            }
            for argument in argumentsOfCalls(named: "isSwitchable", in: text) {
                if argument.contains("podcastIndexConfigured:") { explicitCalls += 1 }
                else { offenders.append("\(name): isSwitchable ohne die Tatsache") }
            }
            // The PROPERTY forms carry no bracket, so the call finder
            // never sees them. They are just as dangerous.
            for form in ["ExternalSources.switchable.", "ExternalSources.switchable ",
                         ".isSwitchable ", ".isSwitchable)", ".isSwitchable,"] where text.contains(form) {
                offenders.append("\(name): \(form.trimmingCharacters(in: .whitespaces)) liest die Umgebung")
            }
        }

        #expect(offenders.isEmpty,
                "ein Zeuge liest die PodcastIndex-Tatsache selbst: \(offenders.sorted())")
        // Without this assertion a finder that finds nothing any more would be
        // a green fence without a measurement.
        #expect(explicitCalls >= 3,
                "der Sucher findet keine Aufrufe mehr, er misst nichts (gefunden: \(explicitCalls))")
    }
}
#endif
