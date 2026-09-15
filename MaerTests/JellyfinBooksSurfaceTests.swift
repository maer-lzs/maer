// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The surface the folded Jellyfin book reaches the audiobook shelf through.
/// The fold itself was built and witnessed before this, but nothing asked it:
/// the shelf merges every secondary source that serves audiobooks, and this
/// source served music only. These cases hold the seam that changed.
@Suite struct JellyfinBooksSurfaceTests {

    /// The listing of one folder, as the test bench answers it: three files of
    /// one book, the first played through, the second half way in.
    private let booksWire = """
    {"Items":[
      {"Id":"f1","Name":"Teil 1","Type":"AudioBook","ParentId":"folder","Album":"Probebuch",
       "IndexNumber":1,"RunTimeTicks":6000000000,
       "UserData":{"Played":true,"PlaybackPositionTicks":0,"LastPlayedDate":"2026-09-15T06:00:00.0000000Z"}},
      {"Id":"f2","Name":"Teil 2","Type":"AudioBook","ParentId":"folder","Album":"Probebuch",
       "IndexNumber":2,"RunTimeTicks":6000000000,
       "UserData":{"Played":false,"PlaybackPositionTicks":3000000000,"LastPlayedDate":"2026-09-15T07:00:00.0000000Z"}},
      {"Id":"f3","Name":"Teil 3","Type":"AudioBook","ParentId":"folder","Album":"Probebuch",
       "IndexNumber":3,"RunTimeTicks":6000000000,"UserData":{"Played":false}}
    ]}
    """

    private func files() throws -> [JFItem] {
        try JSONDecoder().decode(JFItemsResult.self, from: Data(booksWire.utf8)).items ?? []
    }

    // MARK: - What the source serves

    @Test("ein Server mit Buecher-Bibliothek bedient beide Typen, ohne dass jemand etwas zuordnet")
    func aServerWithABooksLibraryServesBoth() {
        let withBooks = SourceModes.fromServerNamedLibraries(hasBooksLibrary: true)
        #expect(withBooks.serves(.music))
        #expect(withBooks.serves(.audiobooks))
        #expect(withBooks.types == [.music, .audiobooks])
    }

    @Test("ohne Buecher-Bibliothek bleibt die Quelle Musik, und der Hoerbuch-Tab sieht sie nicht")
    func aServerWithoutABooksLibraryStaysMusic() {
        let musicOnly = SourceModes.fromServerNamedLibraries(hasBooksLibrary: false)
        #expect(musicOnly.serves(.music))
        #expect(!musicOnly.serves(.audiobooks))
        // The pair cannot claim a third type, whatever the server reports.
        #expect(!musicOnly.serves(.podcasts))
        #expect(!SourceModes.fromServerNamedLibraries(hasBooksLibrary: true).serves(.radio))
    }

    /// The gate the shelf asks is `mediaTypes`, and it must be able to say
    /// audiobooks at all. This is the line that kept the fold unreachable.
    @Test("die Quelle nennt Hoerbuecher, sobald die Bibliothek bekannt ist")
    func theSourceCanNameAudiobooks() {
        let stored = AppStorageKeys.jellyfinBooksViewIdValue
        defer { AppStorageKeys.jellyfinBooksViewIdValue = stored }

        AppStorageKeys.jellyfinBooksViewIdValue = ""
        #expect(!AppStorageKeys.jellyfinActive(for: .audiobooks),
                "ohne bekannte Buecher-Bibliothek darf der Hoerbuch-Tab die Quelle nicht sehen")

        AppStorageKeys.jellyfinBooksViewIdValue = "v-books"
        // The tab masters and the source toggle decide the rest; the point
        // here is that the books half is no longer answered with a flat no.
        let servedWithLibrary = AppStorageKeys.jellyfinActive(for: .audiobooks)
        let tabsAndToggle = SourceActivation.effective(
            tabEnabled: AppStorageKeys.audiobooksTabEnabledValue,
            sourceEnabled: AppStorageKeys.jellyfinEnabledValue)
        #expect(servedWithLibrary == tabsAndToggle,
                "mit bekannter Bibliothek entscheiden nur noch Tab-Schalter und Quellen-Schalter")
    }

    @Test("die Buecher-Bibliothek wird unter ihrer eigenen Kennung geholt, nicht unter dem Quellen-Kuerzel")
    func booksAreFetchedUnderTheirOwnLibraryId() {
        let libraryId = JellyfinProvider.libraryId(booksViewId: "v-books")
        #expect(libraryId == "jf:books:v-books")
        #expect(JellyfinProvider.booksViewId(fromLibraryId: libraryId) == "v-books")
        // The provider slug is the MUSIC answer. A books fetch that fell back
        // to it would silently list albums in the audiobook shelf.
        #expect(JellyfinProvider.booksViewId(fromLibraryId: "jf") == nil)
    }

    // MARK: - What the shelf shows as progress

    @Test("der Regal-Fortschritt kommt aus der Listung selbst, am weitesten Punkt")
    func theShelfReadsItsProgressFromTheListing() throws {
        let groups = JellyfinBookFold.fold(try files())
        let group = try #require(groups.first)
        #expect(group.isFolded)
        let progress = try #require(JellyfinProvider.bookProgress(for: group))
        // Track 1 played (600 s) plus 300 s into track 2, of 1800 s total.
        #expect(abs((progress.currentTime ?? 0) - 900) < 0.5)
        #expect(abs(progress.fraction - 0.5) < 0.01)
        #expect(!progress.isFinished, "ein Buch mit einer ungehoerten Spur ist nicht fertig")
        // The newest LastPlayedDate of the files is what the row sorts by.
        #expect(progress.lastUpdate == JellyfinProvider.epochMs(fromJFDate: "2026-09-15T07:00:00.0000000Z"))
    }

    @Test("ein Buch ohne jede Position meldet keinen Fortschritt")
    func anUntouchedBookReportsNothing() throws {
        let wire = """
        {"Items":[
          {"Id":"g1","Name":"Teil 1","Type":"AudioBook","ParentId":"folder","Album":"Neu",
           "IndexNumber":1,"RunTimeTicks":6000000000},
          {"Id":"g2","Name":"Teil 2","Type":"AudioBook","ParentId":"folder","Album":"Neu",
           "IndexNumber":2,"RunTimeTicks":6000000000}
        ]}
        """
        let items = try JSONDecoder().decode(JFItemsResult.self, from: Data(wire.utf8)).items ?? []
        let group = try #require(JellyfinBookFold.fold(items).first)
        #expect(JellyfinProvider.bookProgress(for: group) == nil,
                "ohne Position darf kein Balken entstehen, sonst steht jedes Buch bei null Prozent im Regal")
    }

    @Test("ein durchgehoertes Buch meldet fertig")
    func aBookPlayedThroughReportsFinished() throws {
        let wire = """
        {"Items":[
          {"Id":"h1","Name":"Teil 1","Type":"AudioBook","ParentId":"folder","Album":"Fertig",
           "IndexNumber":1,"RunTimeTicks":6000000000,"UserData":{"Played":true}},
          {"Id":"h2","Name":"Teil 2","Type":"AudioBook","ParentId":"folder","Album":"Fertig",
           "IndexNumber":2,"RunTimeTicks":6000000000,"UserData":{"Played":true}}
        ]}
        """
        let items = try JSONDecoder().decode(JFItemsResult.self, from: Data(wire.utf8)).items ?? []
        let group = try #require(JellyfinBookFold.fold(items).first)
        let progress = try #require(JellyfinProvider.bookProgress(for: group))
        #expect(progress.isFinished)
        #expect(progress.fraction == 1)
    }

    @Test("die Antwort des Servers traegt das Datum der letzten Wiedergabe")
    func theWirePayloadCarriesTheLastPlayedDate() throws {
        let file = try #require(try files().first)
        #expect(file.userData?.lastPlayedDate == "2026-09-15T06:00:00.0000000Z")
        #expect(JellyfinProvider.epochMs(fromJFDate: file.userData?.lastPlayedDate) != nil)
    }

    // MARK: - Source fence

    /// A statement about the code, measured like a number: the shelf's merge
    /// asks `mediaTypes`, so this source may never answer with a fixed set
    /// again. Written as a fence because the merge itself needs a live client
    /// and a server, which no unit case has.
    @Test("die Quelle leitet ihre Typen aus dem Tor ab, nicht aus einer festen Liste")
    func theSourceDerivesItsTypesFromTheGate() throws {
        let source = try String(contentsOfFile: Self.providerPath, encoding: .utf8)
        #expect(!source.contains("var mediaTypes: Set<MediaType> { [.music] }"),
                "die feste Musik-Liste ist zurueck, damit faellt die Quelle wieder aus dem Hoerbuch-Regal")
        #expect(source.contains("AppStorageKeys.jellyfinActive(for: $0) }"),
                "mediaTypes fragt das Aktivierungstor nicht mehr")
        #expect(source.contains("func fetchLibraryItems(for type: MediaType)"),
                "ohne eigenen Griff fuer den Typ holt die Vorgabe die Musik-Bibliothek in den Hoerbuch-Tab")
    }

    /// The shelf's own half of the same seam: the merge that lets a second
    /// source into the audiobook tab asks exactly this question.
    @Test("das Regal mischt jede Zweitquelle ein, die Hoerbuecher bedient")
    func theShelfMergesEverySourceThatServesAudiobooks() throws {
        let source = try String(contentsOfFile: Self.shelfPath, encoding: .utf8)
        #expect(source.contains("provider.mediaTypes.contains(.audiobooks)"),
                "die Misch-Bedingung des Regals hat ihre Form geaendert, der Zeuge oben prueft dann nichts mehr")
    }

    private static let providerPath =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Providers/JellyfinProvider.swift").path
    private static let shelfPath =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ViewModels/LibraryViewModel.swift").path
}
#endif
