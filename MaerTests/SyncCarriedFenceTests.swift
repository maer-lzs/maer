// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The sync seam (`SyncCarried`) is the one place a catalogue stub is built
/// (`LibraryItem(id: …, media: nil …)`), and views and view models resolve
/// an id only through `AppSession.resolve`, `resolveItem` or
/// `playableItem`, never by asking `FreeCatalog.allPrefixes.contains` as
/// an availability question. Both stocks are zero and stay zero.
struct SyncCarriedFenceTests {
    /// A `LibraryItem(` whose initializer names `media: nil` on the same
    /// line or the next two (the stub shape).
    nonisolated static func stubSites(in text: String) -> Int {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var count = 0
        for (index, line) in lines.enumerated() where line.contains("LibraryItem(") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            let window = lines[index...min(index + 2, lines.count - 1)].joined(separator: "\n")
            if window.contains("media: nil") { count += 1 }
        }
        return count
    }

    nonisolated static func prefixQuestions(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains("FreeCatalog.allPrefixes")
            }.count
    }

    @Test("Ein Katalog-Stub entsteht nur in SyncCarried", .needsTheSources)
    func stubOnlyInTheSeam() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where !file.path.hasSuffix("/SyncCarried.swift") {
            let count = Self.stubSites(in: try String(contentsOf: file, encoding: .utf8))
            if count > 0 { offenders.append("\(file.lastPathComponent): \(count)") }
        }
        #expect(offenders.isEmpty, "catalogue stubs built past the seam: \(offenders)")
        #expect(Self.stubSites(in: "let x = LibraryItem(\n    id: id,\n    media: nil, addedAt: nil)") == 1)
        #expect(Self.stubSites(in: "let x = LibraryItem(id: id, media: detail.media, addedAt: nil)") == 0)
    }

    @Test("Views und ViewModels fragen den Aufloeser, nie die Praefix-Liste", .needsTheSources)
    func viewsAskTheResolver() throws {
        var offenders: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles()
        where file.path.contains("/Sources/Views/") || file.path.contains("/Sources/ViewModels/") {
            let count = Self.prefixQuestions(in: try String(contentsOf: file, encoding: .utf8))
            if count > 0 { offenders.append("\(file.lastPathComponent): \(count)") }
        }
        #expect(offenders.isEmpty, "views spell the catalogue prefixes: \(offenders)")
        #expect(Self.prefixQuestions(in: "if FreeCatalog.allPrefixes.contains(where: id.hasPrefix) { }") == 1)
        #expect(Self.prefixQuestions(in: "if ItemNamespace.isCatalog(id) { }") == 0)
    }
}
#endif
