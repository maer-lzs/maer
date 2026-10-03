// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Documents go through the seam (`Ablage`) or the rows (`Sources/Storage`).
/// Outside them, every `Data(contentsOf:` and `.write(to:` is a counted
/// site with a reason in the stock; the stock may only shrink, a new site
/// is red. Comment lines do not count.
struct AblageFenceTests {
    /// Die Heimaten der Naht, jede mit ihrem Grund IM Eintrag.
    nonisolated static let homes: [(suffix: String, reason: String)] = [
        ("/Sources/Storage/", "die Zeilen-Schicht; sie SCHREIBT die Dateien, an denen die Naht haengt"),
        ("/Ablage.swift", "die Naht selbst"),
        ("/CorruptStore.swift", "legt eine unlesbare Datei beiseite, statt sie durch Leere zu ersetzen"),
    ]

    nonisolated static func isAHome(_ path: String) -> Bool {
        homes.contains { path.contains($0.suffix) }
    }

    nonisolated static func fileSites(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && (trimmed.contains("Data(contentsOf:") || trimmed.contains(".write(to:"))
            }.count
    }

    /// The stock on the day the fence was built (05.09.2026, phase2-ablage),
    /// each with its reason: bytes that are not a document of the app.
    nonisolated static let stock: [String: (count: Int, reason: String)] = [
        "ImageCache.swift": (5, "cover bytes in the image cache, not a document"),
        "WidgetShared.swift": (4, "the app-group snapshot the widget reads, outside the app's own container"),
        "PlayerViewModel+Widget.swift": (2, "artwork bytes for the widget in the app group"),
        "Lyrics.swift": (2, "lyrics cache, bytes keyed by song"),
        "UITestSeed.swift": (1, "the silent fixture the harness plays"),
        "PodcastSubscriptions.swift": (1, "the wipe-refused tombstone note"),
        "PodcastSourceView.swift": (1, "the OPML export handed to the share sheet"),
        "PodcastImport.swift": (1, "a foreign OPML file the person picked"),
        "LocalLibrary.swift": (1, "the cover extracted from a local audio file"),
        "APIClient.swift": (1, "a file mapped for a multipart upload"),
    ]

    @Test("Dateien ausserhalb der Ablage und der Zeilen: nur der Bestand, jede mit Grund")
    func filesOnlyThroughTheSeam() throws {
        var offenders: [String] = []
        var seen: Set<String> = []
        for file in ProjectFileIntegrityTests.sourceFiles() where !Self.isAHome(file.path) {
            seen.insert(file.lastPathComponent)
            let count = Self.fileSites(in: try String(contentsOf: file, encoding: .utf8))
            let allowed = Self.stock[file.lastPathComponent]?.count ?? 0
            if count > allowed { offenders.append("\(file.lastPathComponent): \(count) > \(allowed)") }
        }
        #expect(offenders.isEmpty, "files past the seam: \(offenders)")
        // The stock names only files that are still there; an entry for a
        // file that left is a claim about nothing and stays green forever.
        let ghosts = Self.stock.keys.filter { !seen.contains($0) }.sorted()
        #expect(ghosts.isEmpty, "the stock names files that are gone: \(ghosts)")
        #expect(Self.fileSites(in: "let d = try? Data(contentsOf: url)\ntry d.write(to: url, options: .atomic)\n// Data(contentsOf: in a comment") == 2)
        #expect(Self.stock.values.allSatisfy { !$0.reason.isEmpty })
    }
}
#endif
