// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
@testable import Maer

struct PlaybackSkipTests {
    @Test("Musik springt kuerzer: Familie und Form entscheiden")
    func contentByIdentifier() {
        #expect(PlaybackSkip.content(forItemId: "sub:song-1") == .music)
        #expect(PlaybackSkip.content(forItemId: "jf:track-1") == .music)
        #expect(PlaybackSkip.content(forItemId: FreeCatalog.jamendoPrefix + "album-1") == .music)
        #expect(PlaybackSkip.content(forItemId: FreeCatalog.archivePrefix + "work" + String(CatalogSongID.separator) + "3") == .music)
        #expect(PlaybackSkip.content(forItemId: FreeCatalog.librivoxPrefix + "reading-1") == .spokenWord)
        #expect(PlaybackSkip.content(forItemId: "rss:episode-1") == .spokenWord)
        #expect(PlaybackSkip.content(forItemId: "abs-item-id") == .spokenWord)
        #expect(PlaybackSkip.content(forItemId: "radio:station") == .spokenWord)
    }

    @Test("Die Vorgabe steht in den Wahlen, Musik unter dem gesprochenen Wort")
    func standardsAndOptions() {
        for content in [PlaybackSkip.Content.spokenWord, .music] {
            #expect(PlaybackSkip.options(for: content).contains(PlaybackSkip.standardInterval(for: content)))
        }
        #expect(PlaybackSkip.standardInterval(for: .music) < PlaybackSkip.standardInterval(for: .spokenWord))
        #expect(AppStorageKeys.skipInterval != AppStorageKeys.musicSkipInterval)
    }
}
#endif
