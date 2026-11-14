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
        "sub:song:1", "jf:song:1",               // music
        "radio:1", "lv:176",                // neither: no kind of download
    ]

    @Test("deleting one kind reaches no other")
    func deletingOneKindNeverReachesAnother() {
        let recorded: [String: DownloadKind] = ["sub:song:1": .music, "jf:song:1": .music]
        #expect(Set(DownloadKind.audiobooks.ids(in: Self.downloaded, recorded: recorded, sole: { _ in nil }))
                == ["8f2a-uuid", "local:file"])
        #expect(Set(DownloadKind.podcasts.ids(in: Self.downloaded, recorded: recorded, sole: { _ in nil }))
                == ["rss:feed:ep", "abspod:1"])
        #expect(Set(DownloadKind.music.ids(in: Self.downloaded, recorded: recorded, sole: { _ in nil }))
                == ["sub:song:1", "jf:song:1"])

        // No id belongs to two kinds, and together they reach every
        // audiobook, podcast and recorded music id.
        let all = DownloadKind.allCases.flatMap { $0.ids(in: Self.downloaded, recorded: recorded, sole: { _ in nil }) }
        #expect(all.count == Set(all).count, "eine Kennung gehoert zu zwei Arten")
        #expect(Set(all) == Self.downloaded.subtracting(["radio:1", "lv:176"]))
    }

    /// A book from a Subsonic (Booksonic) server carries a music prefix
    /// (`sub:album:`). It belongs to the kind its download was started as,
    /// and without one to no kind at all: when in doubt, nothing is deleted.
    /// A Jellyfin book names itself (`jf:book:`) and is an audiobook anyway.
    @Test("a book with a music prefix follows its recorded kind, without a kind none")
    func aMusicPrefixedTitleFollowsItsRecordedKind() {
        let recorded: [String: DownloadKind] = [
            "sub:album:7": .audiobooks, "jf:book:2": .audiobooks,
            "sub:song:1": .music, "jf:song:1": .music,
        ]
        let downloaded = Self.downloaded.union(["sub:album:7", "jf:book:2", "sub:album:9"])
        #expect(Set(DownloadKind.audiobooks.ids(in: downloaded, recorded: recorded, sole: { _ in nil }))
                == ["8f2a-uuid", "local:file", "sub:album:7", "jf:book:2"])
        #expect(Set(DownloadKind.music.ids(in: downloaded, recorded: recorded, sole: { _ in nil }))
                == ["sub:song:1", "jf:song:1"], "Musik loeschen darf das Buch nicht erreichen")
        #expect(Set(DownloadKind.podcasts.ids(in: downloaded, recorded: recorded, sole: { _ in nil }))
                == ["rss:feed:ep", "abspod:1"])
        #expect(DownloadKind.unassigned(in: downloaded, recorded: recorded, sole: { _ in nil }) == ["sub:album:9"],
                "ein Musik-Praefix ohne festgehaltene Art gehoert zu keiner Art")
        let all = DownloadKind.allCases.flatMap { $0.ids(in: downloaded, recorded: recorded, sole: { _ in nil }) }
        #expect(all.count == Set(all).count, "eine Kennung gehoert zu zwei Arten")
        #expect(!all.contains("sub:album:9"), "im Zweifel wird nichts geloescht")
    }

    /// Downloads from before the kind was recorded: a source that serves
    /// only music gives music, one that serves both gives no kind. The
    /// source's roles decide at the time of deletion, never a stored guess.
    @Test("Old stock: only music counts as music, a server with both roles leaves it unassigned")
    func legacyDownloadsFollowASourceWithOneRoleOnly() {
        #expect(DownloadKind.sole(servedTypes: [.music]) == .music)
        #expect(DownloadKind.sole(servedTypes: [.audiobooks]) == .audiobooks)
        #expect(DownloadKind.sole(servedTypes: [.music, .audiobooks]) == nil)
        #expect(DownloadKind.sole(servedTypes: []) == nil, "eine Quelle ohne Rolle ist keine Aussage")

        // Navidrome for music only ("sub:"), a Jellyfin with books and music ("jf:").
        let sole: (String) -> DownloadKind? = { id in
            id.hasPrefix("sub:") ? DownloadKind.sole(servedTypes: [.music])
                                 : DownloadKind.sole(servedTypes: [.music, .audiobooks])
        }
        let legacy: Set<String> = ["sub:song:40", "sub:album:41", "jf:album:42"]
        #expect(Set(DownloadKind.music.ids(in: legacy, recorded: [:], sole: sole))
                == ["sub:song:40", "sub:album:41"], "reine Musik aus dem Altbestand ist Musik")
        #expect(DownloadKind.audiobooks.ids(in: legacy, recorded: [:], sole: sole).isEmpty)
        #expect(DownloadKind.unassigned(in: legacy, recorded: [:], sole: sole) == ["jf:album:42"],
                "ein Server mit beiden Rollen: im Zweifel nicht loeschen")
        // A recorded kind always wins over the source's roles.
        #expect(DownloadKind.audiobooks.ids(in: ["sub:album:41"], recorded: ["sub:album:41": .audiobooks], sole: sole)
                == ["sub:album:41"])
    }

    /// The kind survives a restart: it is written beside the downloads and
    /// read back by a new manager on the same folder.
    @Test("the recorded kind survives a restart")
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

    /// Deleting every download at once is reached from exactly one view: the
    /// last destructive row of the storage section in the settings. Every
    /// other bulk deletion goes per kind, and the audiobook tab deletes
    /// nothing at once.
    @Test("exactly one view deletes all downloads at once, the row in the settings", .needsTheSources)
    func exactlyOneViewDeletesEverythingAtOnce() throws {
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(files.count > 100, "der Zeuge hat den Ansichtsbaum nicht gelesen")
        var callers: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            var owner = "?"
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if let declared = line.firstMatch(of: #/^(?:private |fileprivate )?struct (\w+)/#) {
                    owner = String(declared.output.1)
                }
                if IdQuestionDoorFenceTests.withoutComment(line).contains("deleteAllDownloads(") {
                    callers.append("\(file.lastPathComponent):\(owner)")
                }
            }
        }
        #expect(callers == ["SettingsView.swift:StorageDeleteRow"],
                "alles auf einmal loeschen darf nur die eine Zeile in den Einstellungen: \(callers)")
    }

    @Test("every kind is deleted in its own tab, under General Delete all downloads and a kind only while its tab is missing", .needsTheSources)
    func eachKindIsDeletedInItsOwnPill() throws {
        let pills = SettingsView.Tab.allCases.compactMap(\.downloads)
        #expect(pills.sorted { $0.rawValue < $1.rawValue } == DownloadKind.allCases.sorted { $0.rawValue < $1.rawValue },
                "jede Art hat genau einen Reiter: \(pills)")
        #expect(SettingsView.Tab.general.downloads == nil, "Allgemein loescht keine einzelne Art")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Views/SettingsView.swift"), encoding: .utf8)
        var rows: [String] = []
        var owner = "?"
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let declared = line.firstMatch(of: #/^(?:private |fileprivate )?struct (\w+)/#) {
                owner = String(declared.output.1)
            }
            let code = IdQuestionDoorFenceTests.withoutComment(line)
            if let row = code.firstMatch(of: #/StorageDeleteRow\(kind: (\w+)\)/#) {
                rows.append("\(owner):\(row.output.1)")
            }
        }
        #expect(rows == ["SettingsView:nil", "StorageKindSection:kind", "StorageUnreachableKindRows:kind"],
                "unter Allgemein die Zeile fuer alles und dieselbe Zeile fuer eine Art ohne Reiter, jede Art in ihrem Reiter: \(rows)")
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        #expect(flat.contains("if let kind = tab.downloads { StorageKindSection(kind: kind) }"),
                "der Reiter zeigt seinen Abschnitt nach seiner Regel")
        #expect(flat.contains("StorageUnreachableKindRows(pillsShown: Set(visibleTabs.compactMap(\\.downloads)))"),
                "Allgemein fragt die gezeigten Reiter, nicht eine eigene Liste")
    }

    @Test("#271: a kind whose tab is off and which still has downloads can be deleted under General; without downloads nothing appears there")
    func aKindWithoutItsPillIsDeletableInGeneral() {
        let all = Set(DownloadKind.allCases)
        func holds(_ kinds: Set<DownloadKind>) -> (DownloadKind) -> Bool { { kinds.contains($0) } }
        #expect(DownloadKind.deletableOnlyInGeneral(pillsShown: all, holdsDownloads: holds(all)).isEmpty,
                "every pill shown: each kind is deleted in its own")
        #expect(DownloadKind.deletableOnlyInGeneral(pillsShown: [.podcasts, .music], holdsDownloads: holds(all))
                == [.audiobooks], "the audiobook tab is off and books lie on the device")
        #expect(DownloadKind.deletableOnlyInGeneral(pillsShown: [.podcasts, .music], holdsDownloads: holds([.music]))
                .isEmpty, "the audiobook tab is off, but no book lies on the device")
        #expect(DownloadKind.deletableOnlyInGeneral(pillsShown: [], holdsDownloads: holds([.podcasts, .music]))
                == [.podcasts, .music], "every tab off: each kind that holds downloads, in the order of the kinds")
    }
}
#endif
