// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The player's one place for the form of the playing title
/// (`PlayerViewModel.playingForm`): a netlabel album started by shuffle is
/// music before its start writes the mark.
@MainActor
struct PlayingFormTests {
    private func netlabelAlbum(_ identifier: String) throws -> String {
        let doc = ArchivePopularDoc(identifier: identifier, title: ArchiveStringList(["Clips and Soundboards 2"]),
                                    creator: ArchiveStringList(["Ayato"]), downloads: nil, runtime: nil,
                                    licenseurl: nil, year: nil, subject: nil,
                                    collection: ArchiveStringList(["netlabels"]))
        return try #require(FreeCatalogProvider.shared.remember(popular: doc)).id
    }

    @Test("Ein Netlabel-Album aus dem Zufall gilt im Player als Musik, bevor die Marke geschrieben ist")
    func aShuffledNetlabelAlbumIsMusic() throws {
        let id = try netlabelAlbum("maer-witness-playing-form-\(UUID().uuidString)")
        #expect(ListeningStore.startedForm(id) == nil, "the witness starts without a mark")
        #expect(!MediaFamily.isMusicByForm(id), "by the id alone the album reads as a book")
        let model = PlayerViewModel(provider: FreeCatalogProvider.shared, localTracks: { _ in [:] }, isOnline: { true })
        model.item = LibraryItemDetail(
            id: id,
            media: LibraryItemMedia(
                metadata: LibraryItemMetadata(title: "Clips and Soundboards 2", authorName: "Ayato", narratorName: nil,
                                              seriesName: nil, genres: nil, publishedYear: nil, description: nil),
                duration: 120, chapters: nil, tracks: nil),
            userMediaProgress: nil)
        #expect(model.playingForm == .album)
        #expect(model.isMusicItem, "no parts, no book end")
        #expect(model.skipContent == .music, "the skip of a song, not thirty seconds")
        #expect(RemoteCommandRule.kind(forItem: id, markedForm: model.playingForm) == .songs, "the title keys move songs")
    }

    @Test("Die Regeln fuer Sprung und Titeltasten nehmen die Form mit, ohne Form bleibt es beim Bisherigen")
    func theRulesTakeTheForm() {
        let id = FreeCatalog.archivePrefix + "maer-witness-rules"
        #expect(PlaybackSkip.content(forItemId: id, markedForm: .album) == .music)
        #expect(PlaybackSkip.content(forItemId: id) == .spokenWord)
        #expect(PlaybackSkip.content(forItemId: id, markedForm: .work) == .spokenWord)
        #expect(RemoteCommandRule.kind(forItem: id, markedForm: .album) == .songs)
        #expect(RemoteCommandRule.kind(forItem: id) == .spoken)
    }

    /// Every form question of the player reads the one place, and the
    /// release page pauses what plays from it.
    @Test("Jede Formfrage des Players liest die eine Stelle, die Katalog-Albumseite pausiert", .needsTheSources)
    func everyQuestionReadsThePlace() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path),
                                                       encoding: .utf8))
        }
        for path in ["Sources/ViewModels/PlayerViewModel.swift", "Sources/ViewModels/PlayerViewModel+NowPlaying.swift",
                     "Sources/Views/PlayerView.swift"] {
            let text = try code(path)
            #expect(!text.contains("isMusicByForm($0.id)") && !text.contains("isMusicByForm(id)"),
                    "\(path) asks the form by the id alone")
            for line in text.split(separator: "\n")
            where line.contains("RemoteCommandRule.kind(forItem:") || line.contains("PlaybackSkip.content(forItemId:") {
                #expect(line.contains("markedForm:"), "\(path): \(line)")
            }
        }
        let page = try code("Sources/Views/CatalogSourcePage.swift")
        #expect(page.contains("playerCoordinator.activeItem.map({ CatalogSongID.album(of: $0.id) }) == itemId"))
        #expect(page.contains("ActiveAlbumPlayButton(viewModel: vm)"))
    }
}
#endif
