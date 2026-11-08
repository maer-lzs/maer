// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Where a device playlist stands (`PlaylistHome`): by what it holds.
struct PlaylistHomeTests {
    private static func home(_ ids: [String], form: ProgressMark.StartedForm? = nil) -> PlaylistHome {
        PlaylistHome.of(itemIds: ids, isRoutine: ids.contains(where: ItemNamespace.isRoutineRule)) { _ in form }
    }

    @Test("je Art ihr Ort: Musik im Musik-Reiter, Podcasts bei Podcasts, Hoerbuecher in der Bibliothek")
    func eachKindHasItsPlace() {
        #expect(Self.home(["sub:song:1", "jf:album:2"]) == .music)
        #expect(Self.home(["rss:feed:ep1", "abspod:lib:ep2"]) == .podcasts)
        #expect(Self.home(["li_book1", "local:file", "jf:book:3", "lv:42"]) == .library)
    }

    @Test("gemischt, Radio und eine unbekannte Art stehen auf Start, eine Routine immer")
    func mixedListsStandOnStart() {
        #expect(Self.home(["sub:song:1", "rss:feed:ep1"]) == .start)
        #expect(Self.home(["li_book1", "rss:feed:ep1"]) == .start)
        #expect(Self.home(["radio:station"]) == .start)
        #expect(Self.home(["weird:thing"]) == .start)
        #expect(Self.home(["rss:feed:ep1", "rule:newest:feed"]) == .start, "a routine")
        #expect(PlaylistHome.of(kinds: [.music], isRoutine: true) == .start)
    }

    @Test("eine leere Liste bleibt im Musik-Reiter, wo sie angelegt wird")
    func anEmptyListStaysInMusic() {
        #expect(Self.home([]) == .music)
    }

    @Test("ein Katalogtitel folgt seiner Form: eine Lesung ist ein Hoerbuch, ein Album Musik")
    func aCatalogTitleFollowsItsForm() {
        #expect(Self.home(["lv:42"]) == .library)
        #expect(Self.home(["jam:7"]) == .music)
        #expect(Self.home(["lva:x"], form: .album) == .music)
        #expect(Self.home(["lva:x"]) == .library)
    }

    @Test("die Seite aller Listen traegt den Namen ihres Abschnitts, Routinen oder Playlisten", .needsTheSources)
    func thePageTakesTheSectionsName() throws {
        let text = try FetchAnswerTests.squeezedSource("Sources/Views/Music/PlaylistNameList.swift")
        #expect(text.contains("if limit == nil { section(lists, title: title) .navigationTitle(title) }"),
                "the page of all lists has a name of its own")
        #expect(!text.contains(".navigationTitle(\"Playlists\")"), "the page is always called Playlists")
    }

    @Test("eine Liste, deren Inhalt wechselt, wandert mit")
    func aListMovesWithItsContent() {
        var ids = ["rss:feed:ep1"]
        #expect(Self.home(ids) == .podcasts)
        ids.append("sub:song:1")
        #expect(Self.home(ids) == .start, "a song joined the episodes")
        ids.removeFirst()
        #expect(Self.home(ids) == .music, "only the song is left")
        ids.removeAll()
        #expect(Self.home(ids) == .music, "emptied")
    }
}
#endif
