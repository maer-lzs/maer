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
        let recorded: [String: DownloadKind] = ["sub:song:1": .music, "jf:1": .music]
        #expect(Set(DownloadKind.audiobooks.ids(in: Self.downloaded, recorded: recorded))
                == ["8f2a-uuid", "local:file"])
        #expect(Set(DownloadKind.podcasts.ids(in: Self.downloaded, recorded: recorded))
                == ["rss:feed:ep", "abspod:1"])
        #expect(Set(DownloadKind.music.ids(in: Self.downloaded, recorded: recorded))
                == ["sub:song:1", "jf:1"])

        // No id belongs to two kinds, and together they reach every
        // audiobook, podcast and recorded music id.
        let all = DownloadKind.allCases.flatMap { $0.ids(in: Self.downloaded, recorded: recorded) }
        #expect(all.count == Set(all).count, "eine Kennung gehoert zu zwei Arten")
        #expect(Set(all) == Self.downloaded.subtracting(["radio:1", "lv:176"]))
    }

    /// A book from a Subsonic (Booksonic) or Jellyfin server carries a music
    /// prefix. It belongs to the kind its download was started as, and
    /// without one to no kind at all: when in doubt, nothing is deleted.
    @Test("ein Buch mit Musik-Praefix folgt seiner festgehaltenen Art, ohne Art keiner")
    func aMusicPrefixedTitleFollowsItsRecordedKind() {
        let recorded: [String: DownloadKind] = [
            "sub:album:7": .audiobooks, "jf:book-2": .audiobooks,
            "sub:song:1": .music, "jf:1": .music,
        ]
        let downloaded = Self.downloaded.union(["sub:album:7", "jf:book-2", "sub:unknown-9"])
        #expect(Set(DownloadKind.audiobooks.ids(in: downloaded, recorded: recorded))
                == ["8f2a-uuid", "local:file", "sub:album:7", "jf:book-2"])
        #expect(Set(DownloadKind.music.ids(in: downloaded, recorded: recorded))
                == ["sub:song:1", "jf:1"], "Musik loeschen darf das Buch nicht erreichen")
        #expect(Set(DownloadKind.podcasts.ids(in: downloaded, recorded: recorded))
                == ["rss:feed:ep", "abspod:1"])
        #expect(DownloadKind.unassigned(in: downloaded, recorded: recorded) == ["sub:unknown-9"],
                "ein Musik-Praefix ohne festgehaltene Art gehoert zu keiner Art")
        let all = DownloadKind.allCases.flatMap { $0.ids(in: downloaded, recorded: recorded) }
        #expect(all.count == Set(all).count, "eine Kennung gehoert zu zwei Arten")
        #expect(!all.contains("sub:unknown-9"), "im Zweifel wird nichts geloescht")
    }

    /// The kind survives a restart: it is written beside the downloads and
    /// read back by a new manager on the same folder.
    @Test("die festgehaltene Art ueberlebt einen Neustart")
    @MainActor
    func theRecordedKindSurvivesARestart() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-kinds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ablage = Ablage(directory: folder)
        #expect(DownloadManager.readKinds(from: ablage).isEmpty, "ohne Dokument keine Art")
        try ablage.saveNow(["sub:album:7": "audiobooks", "sub:song:1": "music", "x": "nonsense"],
                           name: DownloadManager.kindsDocument)
        #expect(DownloadManager.readKinds(from: ablage) == ["sub:album:7": .audiobooks, "sub:song:1": .music],
                "eine unbekannte Art wird ausgelassen, nicht geraten")
        try ablage.saveNow("not a map", name: DownloadManager.kindsDocument)
        #expect(DownloadManager.readKinds(from: ablage).isEmpty,
                "eine unlesbare Ablage heisst: keine Art, also loescht keine Massenhandlung")
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
