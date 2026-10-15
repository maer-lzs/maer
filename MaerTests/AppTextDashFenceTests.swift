// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// App text carries no em or en dash: a sentence is rebuilt with a full
/// stop, a colon, a comma or a semicolon instead. The fence reads the
/// catalog (every key and every German value) and every string literal in
/// `Sources` that can reach the screen. Log lines, comments and a few
/// named files are not app text: parsers that split on a dash, generated
/// data tables, feed titles from a source, and the diagnosis exports.
struct AppTextDashFenceTests {
    nonisolated static let dashes: Set<Character> = ["—", "–"]

    /// Files whose dashes are input or data, not prose the app shows.
    nonisolated static let namedExceptions = [
        "/PodcastWorkOrder.swift",      // title splitter, dashes are separators it accepts
        "/RadioModels.swift",           // now-playing splitter, same
        "/RadioLogoData.swift",         // generated table of Commons file names
        "/HoerspielCuration.swift",     // feed titles as the broadcaster spells them
        "/ProgressDiagnosis.swift",     // diagnosis export text, copied to the pasteboard
        "/RadioLogoReport.swift",       // diagnosis export text, copied to the pasteboard
        "/LibraryViewModel.swift"       // one regular expression stripping "#1-3" suffixes
    ]

    /// Lines that are never app text: comments, log calls, regexes.
    nonisolated static func isExemptLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return true }
        for marker in ["Logger", "logger.", "os_log", "privacy:", ".regularExpression", "Text(verbatim:"]
        where line.contains(marker) { return true }
        return false
    }

    /// The string literals on one line that carry a dash. A trailing line
    /// comment is cut off first; a dash inside a literal is what counts.
    nonisolated static func offendingLiterals(in line: String) -> [String] {
        guard !isExemptLine(line), line.contains(where: { dashes.contains($0) }) else { return [] }
        var literals: [String] = []
        var current = ""
        var inside = false
        var previous: Character = " "
        for ch in line {
            if ch == "\"" && previous != "\\" {
                if inside { literals.append(current); current = "" }
                inside.toggle()
            } else if inside {
                current.append(ch)
            } else if ch == "/" && previous == "/" {
                break
            }
            previous = ch
        }
        return literals.filter { $0.contains(where: { dashes.contains($0) }) }
    }

    @Test("Kein Katalog-Schluessel und kein deutscher Wert traegt einen Gedankenstrich", .needsTheSources)
    func catalogCarriesNoDash() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: Any])
        var offenders: [String] = []
        for (key, value) in strings {
            if key.contains(where: { Self.dashes.contains($0) }) { offenders.append("en: \(key.prefix(60))") }
            let de = ((value as? [String: Any])?["localizations"] as? [String: Any])?["de"] as? [String: Any]
            if let text = (de?["stringUnit"] as? [String: Any])?["value"] as? String,
               text.contains(where: { Self.dashes.contains($0) }) {
                offenders.append("de: \(text.prefix(60))")
            }
        }
        #expect(offenders.isEmpty, "dashes in the catalog: \(offenders.sorted())")
    }

    @Test("Kein sichtbares Literal in Sources traegt einen Gedankenstrich", .needsTheSources)
    func sourceLiteralsCarryNoDash() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles()
        where !Self.namedExceptions.contains(where: file.path.hasSuffix) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let found = Self.offendingLiterals(in: String(line))
                if !found.isEmpty { offenders.append("\(file.lastPathComponent):\(index + 1) \(found.first!.prefix(50))") }
            }
        }
        #expect(offenders.isEmpty, "dashes in app text: \(offenders)")
    }

    @Test("Der Pruefer saehe den Strich (Rot-Probe in beide Richtungen)")
    func checkerSeesTheDash() {
        #expect(Self.offendingLiterals(in: #"Text("Offline — last known state")"#) == ["Offline — last known state"])
        #expect(Self.offendingLiterals(in: #"return String(localized: "Name A–Z")"#) == ["Name A–Z"])
        #expect(Self.offendingLiterals(in: #"Text("Offline: last known state")"#).isEmpty)
        #expect(Self.offendingLiterals(in: #"// the old text said "Offline — last known state""#).isEmpty)
        #expect(Self.offendingLiterals(in: #"let x = 1 // "a — b""#).isEmpty)
        #expect(Self.offendingLiterals(in: #"Logger.app.info("COVER pot=memo — \(url)")"#).isEmpty)
        // A sentence about the catalog ends in "log." and is app text all
        // the same; the marker that once exempted it is gone.
        #expect(Self.offendingLiterals(in: #"Text("Reload the catalog. Nothing — yet")"#) == ["Reload the catalog. Nothing — yet"])
        #expect(Self.offendingLiterals(in: #"Text("Could not load the catalog — try again")"#) == ["Could not load the catalog — try again"])
        #expect(Self.offendingLiterals(in: #"Text(verbatim: "a — b")"#).isEmpty)
    }
}
#endif
