// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// The form of an archive.org item. Read from its collections instead of from
/// the route that opened it.
///
/// The collection lists below are VERBATIM from the five queries the app runs,
/// sampled at the source: 250 of 250 items answered with a `collection` field,
/// and every one of them contained the collection that had been queried.
struct ArchiveItemFormTests {
    @Test("Measured collections decide the form")
    func measuredCollections() {
        // Radio-play bundle, top of the queried collection.
        #expect(ArchiveItemForm.of(collections:
            ["oldtimeradio", "radioprograms", "lumedwards", "fav-hans1959"]) == .work)
        // A reading is in its own collection AND in the audiobook collection.
        #expect(ArchiveItemForm.of(collections: ["librivoxaudio", "audio_bookspoetry"]) == .work)
        // Audiobooks outside LibriVox.
        #expect(ArchiveItemForm.of(collections:
            ["audio_bookspoetry", "AuFilDesLectures", "audiolibrary"]) == .work)
        // Netlabel release: the label's own collection rides along.
        #expect(ArchiveItemForm.of(collections: ["bad-panda", "netlabels"]) == .album)
        // Shellac single from the digitisation project.
        #expect(ArchiveItemForm.of(collections:
            ["78rpm", "archiveofcontemporarymusic", "georgeblood", "audio_music"]) == .album)
    }

    @Test("Unknown collections decide nothing")
    func unknownStaysNil() {
        #expect(ArchiveItemForm.of(collections: []) == nil)
        // Broad umbrellas the app never queries say nothing about the form.
        #expect(ArchiveItemForm.of(collections: ["audio_music", "78rpm"]) == nil)
        #expect(ArchiveItemForm.of(collections: ["opensource_audio", "folksoundomy"]) == nil)
    }

    /// A work rendered as an album splits its one position into a mark per
    /// track. Where the listener was is then gone. The other way round only
    /// costs granularity, so the work side wins.
    @Test("Work wins when both apply")
    func workWinsConflict() {
        #expect(ArchiveItemForm.of(collections: ["netlabels", "librivoxaudio"]) == .work)
        #expect(ArchiveItemForm.of(collections: ["georgeblood", "oldtimeradio"]) == .work)
    }

    /// Aus EINEM Namen sind ZWEI Fragen geworden, weil es zwei waren.
    @Test("kuratierte Seriensammlung: nur dort ist das Buendel die Einheit")
    func curatedSeriesCollection() {
        #expect(ArchiveItemForm.isCuratedSeriesCollection(collections: ["oldtimeradio", "radioprograms"]))
        // The sibling collection alone is not the curated one we query.
        #expect(!ArchiveItemForm.isCuratedSeriesCollection(collections: ["radioprograms"]))
        #expect(!ArchiveItemForm.isCuratedSeriesCollection(collections: ["librivoxaudio"]))
        #expect(!ArchiveItemForm.isCuratedSeriesCollection(collections: []))
    }

    /// Ein Archive-Hoerbuch mit acht benannten Dateien hatte keine
    /// auswaehlbare Teileliste: die Liste haengt an der FORM, nicht an der
    /// Sammlung. Vorher fielen die Archive-Hoerbuecher durch beide
    /// Raster. Keine LibriVox-Kapitel, keine OTR-Folgenseite.
    @Test("ein Werk hat Teile, gleich in welcher der drei Sammlungen es liegt")
    func everyWorkHasParts() {
        #expect(ArchiveItemForm.hasParts(collections: ["oldtimeradio"]))
        #expect(ArchiveItemForm.hasParts(collections: ["librivoxaudio"]))
        // Der gemessene Fall. Vorher fiel er durch.
        #expect(ArchiveItemForm.hasParts(collections: ["audio_bookspoetry"]),
                "das Archive-Hoerbuch bekommt wieder keine Teileliste")
        // Ein ALBUM hat keine Teile. Seine Stuecke sind eigene Eintraege.
        #expect(!ArchiveItemForm.hasParts(collections: ["netlabels"]))
        #expect(!ArchiveItemForm.hasParts(collections: ["georgeblood"]))
        // Und ohne Aussage der Quelle wird nichts geraten.
        #expect(!ArchiveItemForm.hasParts(collections: []))
        #expect(!ArchiveItemForm.hasParts(collections: ["radioprograms"]))
    }

    /// Both lists hold only collections the app itself queries. A name nobody
    /// queries cannot identify an item that got in.
    @Test("Both lists stay disjoint")
    func listsDisjoint() {
        #expect(ArchiveItemForm.workCollections
            .isDisjoint(with: ArchiveItemForm.albumCollections))
    }

    @Test("The search index carries the collections through")
    func searchDocDecodesCollections() throws {
        let json = """
        {"response":{"docs":[
          {"identifier":"a","collection":["oldtimeradio","radioprograms"]},
          {"identifier":"b","collection":"netlabels"},
          {"identifier":"c"}
        ]}}
        """
        let docs = try ArchiveOrgClient.decodePopular(Data(json.utf8))
        #expect(docs[0].collection?.values == ["oldtimeradio", "radioprograms"])
        // Single-entry fields arrive as a bare string, like title and creator.
        #expect(docs[1].collection?.values == ["netlabels"])
        // Absent stays absent. No form, and the caller keeps its default.
        #expect(docs[2].collection == nil)
    }

    @Test("The metadata endpoint carries the collections through")
    func metadataDecodesCollections() throws {
        let json = """
        {"metadata":{"title":"T","collection":["librivoxaudio","audio_bookspoetry"]},
         "files":[{"name":"a.mp3","length":"60"}]}
        """
        let meta = try JSONDecoder().decode(ArchiveOrgClient.MetadataResponse.self,
                                            from: Data(json.utf8))
        #expect(ArchiveItemForm.of(collections: meta.metadata?.collection?.values ?? []) == .work)
    }

    /// The form must survive the intake. This is where it used to be lost:
    /// only the radio-play row remembered what an item was, so the same item
    /// was a bundle from that row and an ordinary item from search.
    @MainActor
    @Test("The provider answers the form after any intake")
    func providerRemembersForm() throws {
        let provider = FreeCatalogProvider.shared
        let doc = ArchivePopularDoc(
            identifier: "formtest-otr", title: ArchiveStringList(["T"]),
            creator: nil, downloads: 1, runtime: nil, licenseurl: nil,
            year: nil, subject: nil,
            collection: ArchiveStringList(["oldtimeradio", "radioprograms"]))
        let item = try #require(provider.remember(popular: doc))
        #expect(provider.archiveForm(itemId: item.id) == .work)
        #expect(provider.hasPartsList(itemId: item.id))

        let album = ArchivePopularDoc(
            identifier: "formtest-net", title: ArchiveStringList(["A"]),
            creator: nil, downloads: 1, runtime: nil, licenseurl: nil,
            year: nil, subject: nil,
            collection: ArchiveStringList(["bad-panda", "netlabels"]))
        let albumItem = try #require(provider.remember(popular: album))
        #expect(provider.archiveForm(itemId: albumItem.id) == .album)
        #expect(!provider.hasPartsList(itemId: albumItem.id))

        // Nothing known yet: no form, no claim.
        #expect(provider.archiveForm(itemId: FreeCatalog.archivePrefix + "never-seen") == nil)
        #expect(!provider.hasPartsList(itemId: FreeCatalog.archivePrefix + "never-seen"))
    }
}
