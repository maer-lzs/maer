// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The one seam for sync behaviour per source: what travels, and what the
/// other device makes of it. One row per source, like the matrix.
struct SyncCarriedTests {
    private func item(_ id: String, title: String? = "A Title", author: String? = "Someone",
                      duration: Double? = 120) -> LibraryItem {
        LibraryItem(id: id, media: LibraryItemMedia(
            metadata: LibraryItemMetadata(title: title, authorName: author, narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: duration, chapters: nil, tracks: nil), addedAt: nil)
    }

    @Test("Der Schnappschuss traegt Titel, Untertitel, Dauer und Quelle; ein Platzhalter reist nie; ein Server-Cover reist nie")
    func snapshotCarriesWhatNamesTheItem() {
        let cover = URL(string: "https://archive.org/services/img/x")!
        let catalog = SyncCarried.snapshot(forId: "lva:x#3", known: item("lva:x#3"), coverURL: cover)
        #expect(catalog == CarriedItem(id: "lva:x#3", title: "A Title", subtitle: "Someone", duration: 120,
                                       coverURL: cover.absoluteString, source: "lva:"))
        let server = SyncCarried.snapshot(forId: "sub:song:42", known: item("sub:song:42"),
                                          coverURL: URL(string: "https://music.example/cover?token=secret"))
        #expect(server?.coverURL == nil, "a server cover address carries a token and must not travel")
        #expect(server?.source == "sub:")
        #expect(SyncCarried.snapshot(forId: "lva:y", known: item("lva:y", title: "Unknown Title"), coverURL: nil) == nil)
        #expect(SyncCarried.snapshot(forId: "lva:y", known: item("lva:y", title: "lva:y"), coverURL: nil) == nil)
        #expect(SyncCarried.snapshot(forId: "lva:y", known: nil, coverURL: nil) == nil)
        #expect(SyncCarried.source(of: "abc123") == "library")
    }

    @Test("Aufloesung je Quelle: bekannt spielt; Katalog spielt aus sich selbst mit Namen; Server, Datei, Folge nennen ihren Grund")
    func resolutionPerSource() {
        let carried = CarriedItem(id: "lva:album#2", title: "Track Two", subtitle: "Netlabel", duration: 200)
        // Known anywhere: plays.
        #expect(SyncCarried.resolve(itemId: "sub:song:1", carried: nil, known: item("sub:song:1"),
                                    sourceConfigured: true).item?.id == "sub:song:1")
        // Catalogue without stock: a stub that names itself from the snapshot.
        let stub = SyncCarried.resolve(itemId: "lva:album#2", carried: carried, known: nil, sourceConfigured: false).item
        #expect(stub?.id == "lva:album#2")
        #expect(stub?.title == "Track Two" && stub?.author == "Netlabel" && stub?.media?.duration == 200)
        // Catalogue without stock and without snapshot: still playable, unnamed.
        #expect(SyncCarried.resolve(itemId: "lv:12", carried: nil, known: nil, sourceConfigured: false).item?.media == nil)
        // Server music without the server; with the server it plays from its
        // id, since the cache only knows what this run listed (GT-4).
        #expect(SyncCarried.resolve(itemId: "sub:song:9", carried: nil, known: nil, sourceConfigured: false).reason
                == .sourceNotConfigured(source: "sub:"))
        #expect(SyncCarried.resolve(itemId: "jf:9", carried: nil, known: nil, sourceConfigured: true).item?.id == "jf:9")
        // A bare audiobook id needs its library server.
        #expect(SyncCarried.resolve(itemId: "li_abc", carried: nil, known: nil, sourceConfigured: false).reason
                == .sourceNotConfigured(source: "library"))
        // Local file, podcast episode, unknown namespace.
        #expect(SyncCarried.resolve(itemId: "local:/x.mp3", carried: nil, known: nil, sourceConfigured: true).reason == .fileNotOnDevice)
        #expect(SyncCarried.resolve(itemId: "rss:feed:ep", carried: nil, known: nil, sourceConfigured: true).reason == .showNotFollowed)
        #expect(SyncCarried.resolve(itemId: "abspod:ep", carried: nil, known: nil, sourceConfigured: true).reason == .showNotFollowed)
        #expect(SyncCarried.resolve(itemId: "zz:1", carried: nil, known: nil, sourceConfigured: true).reason == .unknownSource)
    }
}
#endif
