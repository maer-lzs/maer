// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Mass deletion exists only per kind. The rule that says which downloads
/// belong to a kind must never hand one kind's downloads to another, and no
/// surface may delete everything at once any more.
struct DownloadKindTests {
    static let downloaded: Set<String> = [
        "8f2a-uuid", "local:file",          // audiobooks
        "rss:feed:ep", "abspod:1",          // podcasts
        "sub:song:1", "jf:1",               // music
        "radio:1", "lv:176",                // neither: no kind of download
    ]

    @Test("das Loeschen einer Art erreicht keine andere")
    func deletingOneKindNeverReachesAnother() {
        #expect(Set(DownloadKind.audiobooks.ids(in: Self.downloaded)) == ["8f2a-uuid", "local:file"])
        #expect(Set(DownloadKind.podcasts.ids(in: Self.downloaded)) == ["rss:feed:ep", "abspod:1"])
        #expect(Set(DownloadKind.music.ids(in: Self.downloaded)) == ["sub:song:1", "jf:1"])

        // No id belongs to two kinds, and together they reach every
        // audiobook, podcast and music id.
        let all = DownloadKind.allCases.flatMap { $0.ids(in: Self.downloaded) }
        #expect(all.count == Set(all).count, "eine Kennung gehoert zu zwei Arten")
        #expect(Set(all) == Self.downloaded.subtracting(["radio:1", "lv:176"]))
    }

    /// The rows in the settings delete per kind, and the one call that
    /// removed every download is no longer reached from any view.
    @Test("keine Ansicht loescht mehr alle Downloads auf einmal", .needsTheSources)
    func noViewDeletesEverythingAtOnce() throws {
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(files.count > 100, "der Zeuge hat den Ansichtsbaum nicht gelesen")
        var callers: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && line.contains("deleteAllDownloads(") {
                callers.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(callers.isEmpty, "eine Ansicht loescht wieder alles auf einmal: \(callers)")
    }
}
#endif
