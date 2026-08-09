// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Paket 1: die Regeln der Mär-Playlists — die Grenze, die Rückmeldungen und
/// der Grundsatz „was in die Warteschlange darf, darf in eine Playlist".
@MainActor
struct MaerPlaylistTests {
    private func fresh() -> MaerPlaylists {
        let store = MaerPlaylists.shared
        for list in store.playlists { store.delete(playlistId: list.id) }
        return store
    }

    @Test("die Grenze ist die VORHANDENE canEnqueue-Regel, keine zweite")
    func gateIsTheQueueRule() {
        let store = fresh()
        let list = store.create(name: "Test")
        // Radio ist ein endloser Strom — kein Listeneintrag (Entscheid F3).
        #expect(store.add(itemId: "radio:swr2", to: list.id) == .notQueueable)
        #expect(!PlayQueue.canEnqueue("radio:swr2"))
        // Katalog-Kennungen dürfen — das ist der ganze Zweck des Typs.
        #expect(store.add(itemId: "jam:1886432", to: list.id) == .added)
        #expect(store.add(itemId: "lva:OTRR_Gunsmoke_Singles", to: list.id) == .added)
        store.delete(playlistId: list.id)
    }

    @Test("eine Liste mischt Namensräume — das ist ihr Zweck")
    func mixesNamespaces() {
        let store = fresh()
        let list = store.create(name: "Gemischt",
                                itemIds: ["jam:1", "lva:x", "lv:176", "sub:song:abc"])
        #expect(store.playlist(id: list.id)?.itemIds.count == 4)
        store.delete(playlistId: list.id)
    }

    @Test("doppelt hinzufügen meldet sich, statt still zu wiederholen")
    func duplicateIsReported() {
        let store = fresh()
        let list = store.create(name: "Test")
        #expect(store.add(itemId: "jam:7", to: list.id) == .added)
        #expect(store.add(itemId: "jam:7", to: list.id) == .alreadyThere)
        #expect(store.playlist(id: list.id)?.itemIds.count == 1)
        store.delete(playlistId: list.id)
    }

    @Test("jedes Ergebnis bekommt einen Satz — außer dem Erfolg")
    func everyOutcomeSpeaks() {
        // Regel 3: Erfolg braucht keine Meldung, alles andere schon.
        #expect(CatalogQueueButtons.text(for: .added, listName: "L") == nil)
        #expect(CatalogQueueButtons.text(for: .alreadyThere, listName: "L") != nil)
        #expect(CatalogQueueButtons.text(for: .limitReached(limit: 5000), listName: "L") != nil)
        #expect(CatalogQueueButtons.text(for: .notQueueable, listName: "L") != nil)
        // Die Grenz-Meldung nennt die ZAHL, sonst ist sie nicht handelbar.
        #expect(CatalogQueueButtons.text(for: .limitReached(limit: 5000), listName: "L")?
            .contains("5") == true)
    }

    @Test("das Umsortieren behält alle Einträge")
    func reorderKeepsEverything() {
        let store = fresh()
        let list = store.create(name: "Test", itemIds: ["a1", "b2", "c3", "d4"])
        store.move(playlistId: list.id, from: IndexSet(integer: 0), to: 3)
        let ids = store.playlist(id: list.id)?.itemIds ?? []
        #expect(ids.count == 4)
        #expect(Set(ids) == ["a1", "b2", "c3", "d4"])
        #expect(ids.first != "a1", "der bewegte Eintrag steht nicht mehr vorn")
        store.delete(playlistId: list.id)
    }
}
#endif
