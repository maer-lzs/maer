// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The cleanup after a fully loaded audiobook library removes the keys of
/// audiobooks that are gone, and nothing of any other source.
@Suite(.serialized)
struct BookCleanupTests {
    @Test("TF-12: die Aufraeumung entfernt nur rohe Hoerbuch-Kennungen, Position und Geschwindigkeit gleich")
    @MainActor
    func onlyRawBookIdsGo() {
        let name = "book-cleanup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let rings = JumpRingRows.matching(defaults)
        let bookmarks = BookmarkCacheRows.matching(defaults)
        let owner = CarrierRowsSpec.entryOwner
        // One title per source, and a namespace that does not exist yet.
        let kept = "li_book_kept", gone = "li_book_gone"
        let others = ["rss:feed:ep", "abspod:ep", "local:file", "sub:song", "jf:song",
                      "jam:album", "lva:book", "zz:new"]
        for id in [kept, gone] + others {
            ListeningStore.store(id, entry: [120, 1_000, 600], in: defaults)
            defaults.set(Float(1.5), forKey: AppStorageKeys.playbackRate(id))
            rings.setEntry(owner, id, [[1.0, 2, 3, 4, 5, 6]])
            bookmarks.setEntry(owner, id, [ABSBookmark(libraryItemId: id, title: "Mark", time: 60, createdAt: 1)])
        }
        AppStorageKeys.cleanupPerBookKeys(validItemIds: [kept], in: defaults)
        CarrierRowStores.cleanupPerBookRows(validItemIds: [kept], in: defaults)

        #expect(ListeningStore.backup(gone, in: defaults) == nil, "a book the library no longer holds goes")
        #expect(defaults.object(forKey: AppStorageKeys.playbackRate(gone)) == nil, "and its speed with it")
        #expect(rings.entry(owner, gone) == nil, "and its jump ring with it")
        #expect(bookmarks.entry(owner, gone) == nil, "and the offline copy of its bookmarks with it")
        for id in [kept] + others {
            #expect(ListeningStore.backup(id, in: defaults) == [120, 1_000, 600], "\(id) keeps its position")
            #expect(defaults.float(forKey: AppStorageKeys.playbackRate(id)) == 1.5, "\(id) keeps its speed")
            #expect(rings.entry(owner, id) != nil, "\(id) keeps its jump ring")
            #expect(bookmarks.entry(owner, id) != nil, "\(id) keeps its bookmarks")
        }
    }

    @Test("TF-12: die Regel ist positiv, eine Kennung ohne Namensraum und nicht in der Bibliothek")
    func theRuleIsPositive() {
        let valid: Set<String> = ["li_kept"]
        #expect(AppStorageKeys.prunedByBookCleanup("li_gone", validItemIds: valid))
        #expect(!AppStorageKeys.prunedByBookCleanup("li_kept", validItemIds: valid))
        for id in ["sub:x", "jf:x", "jam:x", "lva:x", "gut:x", "radio:x", "rss:f:x", "abspod:x", "local:x", "zz:x"] {
            #expect(!AppStorageKeys.prunedByBookCleanup(id, validItemIds: valid), "\(id) is not the cleanup's to judge")
        }
    }
}
#endif
