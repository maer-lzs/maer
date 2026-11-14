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

    @Test("a server with a books library serves both types without anyone assigning anything")
    func aServerWithABooksLibraryServesBoth() {
        let withBooks = SourceModes.fromServerNamedLibraries(hasBooksLibrary: true)
        #expect(withBooks.serves(.music))
        #expect(withBooks.serves(.audiobooks))
        #expect(withBooks.types == [.music, .audiobooks])
    }

    @Test("without a books library the source stays music, and the audiobook tab does not see it")
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
    @Test("the source names audiobooks as soon as the library is known")
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

    @Test("the books library is fetched under its own id, not under the source abbreviation")
    func booksAreFetchedUnderTheirOwnLibraryId() {
        let libraryId = JellyfinProvider.libraryId(booksViewId: "v-books")
        #expect(libraryId == "jf:books:v-books")
        #expect(JellyfinProvider.booksViewId(fromLibraryId: libraryId) == "v-books")
        // The provider slug is the MUSIC answer. A books fetch that fell back
        // to it would silently list albums in the audiobook shelf.
        #expect(JellyfinProvider.booksViewId(fromLibraryId: "jf") == nil)
    }

    // MARK: - What the shelf shows as progress

    @Test("the shelf progress comes from the listing itself, at the furthest point")
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

    @Test("a book without any position reports no progress")
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

    @Test("a book listened through reports finished")
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

    @Test("the server's answer carries the date of the last playback")
    func theWirePayloadCarriesTheLastPlayedDate() throws {
        let file = try #require(try files().first)
        #expect(file.userData?.lastPlayedDate == "2026-09-15T06:00:00.0000000Z")
        #expect(JellyfinProvider.epochMs(fromJFDate: file.userData?.lastPlayedDate) != nil)
    }

    // MARK: - The shelf notices a source that starts serving books

    @Test("the signature of the secondary sources changes only when the SET changes")
    func theSignatureFollowsTheSetAndNothingElse() {
        let none = LibraryViewModel.secondarySignature(of: [
            ("jf", false, true, ""), ("local", true, false, "")])
        #expect(none.isEmpty, "keine Quelle bedient Buecher, also steht nichts in der Kennung")

        let withJellyfin = LibraryViewModel.secondarySignature(of: [
            ("jf", true, true, ""), ("local", true, false, "")])
        #expect(withJellyfin == "jf|")
        #expect(withJellyfin != none, "eine Quelle faengt an, Buecher zu bedienen: das Regal muss nachziehen")

        // A plain announcement (a client rebuilt with the same answer) leaves
        // the set alone, and then the shelf must NOT ask the servers again.
        let announcedAgain = LibraryViewModel.secondarySignature(of: [
            ("local", true, false, ""), ("jf", true, true, "")])
        #expect(announcedAgain == withJellyfin, "dieselbe Menge in anderer Reihenfolge ist dieselbe Kennung")

        let alsoLocal = LibraryViewModel.secondarySignature(of: [
            ("jf", true, true, ""), ("local", true, true, "")])
        #expect(alsoLocal == "jf|,local|")
        #expect(alsoLocal != withJellyfin)
    }

    /// The signature alone does NOT stop a second announcement, and that
    /// was the finding: `secondarySignature` is written only at the END of
    /// `reloadLocalCache`, so every announcement that arrives
    /// during the two `await`s still sees the old value and gets
    /// through. One switch produces three of them, and then three runs ask
    /// every secondary source over the network at the same time.
    ///
    /// Discarding would be the opposite error: the announcement during the run
    /// can be exactly the one that matters.
    @Test("a second announcement is remembered, not discarded and not run twice")
    func aSecondAnnouncementIsRememberedNotRun() {
        typealias Step = LibraryViewModel.SecondaryRefreshStep
        #expect(LibraryViewModel.secondaryRefreshStep(signatureChanged: false, running: false) == Step.skip,
                "nichts hat sich geaendert, also kostet es keine Anfrage")
        #expect(LibraryViewModel.secondaryRefreshStep(signatureChanged: false, running: true) == Step.skip,
                "auch waehrend eines Laufs bleibt eine unveraenderte Menge folgenlos")
        #expect(LibraryViewModel.secondaryRefreshStep(signatureChanged: true, running: false) == Step.run)
        #expect(LibraryViewModel.secondaryRefreshStep(signatureChanged: true, running: true) == Step.queue,
                "die zweite Ankuendigung wird gemerkt, damit sie nicht verlorengeht")
    }

    /// The fence beside it reads the source text, and it must not trip on the sentence
    /// that EXPLAINS why the old grip is gone. Both directions,
    /// otherwise it is a claim about the fence instead of a measurement.
    @Test("a comment ABOUT the grip is no grip")
    func aCommentAboutTheGripIsNotAGrip() {
        let stripped = { (raw: String) in
            raw.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        let comment = "        /// `PlayerCoordinator.provider` ist ein `let` aus dem `init`.\n        let p = router.provider(id)"
        #expect(!stripped(comment).lowercased().contains("coordinator.provider"),
                "der Satz ueber den Griff darf den Zaun nicht ausloesen")
        let grip = "        let p = coordinator.provider"
        #expect(stripped(grip).lowercased().contains("coordinator.provider"),
                "der Griff selbst muss ihn ausloesen, sonst bewacht der Zaun nichts")
    }

    // MARK: - And from what it serves, not only THAT it serves

    /// The case that fails today. The books library on the server becomes
    /// another one: the same source, still reachable, keeps serving
    /// books. Only the ids on the shelf now belong to a library
    /// that nobody asks any more, and a tap on one lands at a source
    /// that does not know it.
    ///
    /// The wake-up call arrives correctly (`refreshKnownLibraries` calls it), it
    /// is discarded at the gate because the signature does not see it.
    @Test("the same source with a DIFFERENT library is a different signature")
    func aLibraryThatBecomesAnotherOneMovesTheSignature() {
        let libraryA = LibraryViewModel.secondarySignature(of: [("jf", true, true, "A")])
        let libraryB = LibraryViewModel.secondarySignature(of: [("jf", true, true, "B")])
        #expect(libraryA != libraryB,
                "Buecher-Bibliothek A wird B: das Regal traegt sonst Kennungen, die niemand mehr bedient")
    }

    /// The opposite direction, and without it the gate would merely be unhinged. The
    /// network price is the reason it stands at all: one switch
    /// produces three announcements, and three runs ask every secondary source
    /// at the same time over the network.
    @Test("the same library announced twice costs no request")
    func thesameLibraryAnnouncedTwiceCostsNothing() {
        let once = LibraryViewModel.secondarySignature(of: [("jf", true, true, "A")])
        let again = LibraryViewModel.secondarySignature(of: [("jf", true, true, "A")])
        #expect(once == again)
    }

    /// And the half that carries the objection: `serving` is in the
    /// mapped value, NOT in the filter. If it could decide WHICH
    /// sources count, a music library would make the book shelf shuffle
    /// anew, exactly the price the gate stands against.
    /// That is why `servingSignature` answers per KIND, and here stands the
    /// answer for books.
    @Test("a source without books is not in it, whatever it serves from")
    func whatAMusicOnlySourceServesCannotReachTheBookShelf() {
        let musicMoved = LibraryViewModel.secondarySignature(of: [("jf", false, true, "andere-musik")])
        #expect(musicMoved.isEmpty,
                "eine Quelle, die keine Buecher bedient, bewegt das Buch-Regal nicht")
    }

    /// The stock of the overriders, in BOTH directions.
    ///
    /// Exactly the sources that can be pointed at a DIFFERENT library of the same
    /// type answer more than the default. If one drops
    /// out, it drops out silently, and exactly this silence is the
    /// class the finding comes from.
    @Test("exactly the sources with several libraries say what they serve from",
          .needsTheSources)
    func exactlyTheSourcesWithSeveralLibrariesAnswer() throws {
        let folder = SourceTree.root.appendingPathComponent("Sources/Providers")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(names.count > 0, "ohne Dateien misst dieser Fall nichts")
        let declaring = names.filter { name in
            let text = (try? String(contentsOf: folder.appendingPathComponent(name),
                                    encoding: .utf8)) ?? ""
            return text.contains("func servingSignature(for type: MediaType) -> String {")
        }.sorted()
        #expect(declaring == ["AudioProvider.swift",
                              "JellyfinProvider.swift",
                              "SubsonicProvider.swift"],
                "AudioProvider.swift traegt die Vorgabe und gehoert dazu, die anderen zwei sind genau die Quellen, die auf eine andere Bibliothek desselben Typs zeigen koennen. Kommt eine dazu oder faellt eine weg, ist das ein Entscheid und kein Zufall")
    }

    /// The class, not the place it was found: the requirement must be in the PROTOCOL.
    /// If it is only in the extension, a call on
    /// `any AudioProvider` binds statically to the default, Jellyfin's answer is
    /// silently discarded, and the fence would stay green while the defect
    /// stands unchanged. That is exactly how `isAvailable` once
    /// slipped through (the always visible music tab).
    ///
    /// That is why this witness asks the source as an EXISTENTIAL, not as a
    /// concrete type: only then does it measure the binding instead of the implementation.
    @Test("the answer of the source survives the way through the existential")
    @MainActor
    func theAnswerSurvivesTheExistential() {
        let previous = AppStorageKeys.jellyfinBooksViewIdValue
        defer { AppStorageKeys.jellyfinBooksViewIdValue = previous }
        AppStorageKeys.jellyfinBooksViewIdValue = "eine-buecher-bibliothek"

        let asItself = JellyfinProvider.shared
        let throughTheBox: any AudioProvider = JellyfinProvider.shared
        #expect(asItself.servingSignature(for: .audiobooks) == "eine-buecher-bibliothek")
        #expect(throughTheBox.servingSignature(for: .audiobooks) == "eine-buecher-bibliothek",
                "ueber `any AudioProvider` kommt die Vorgabe zurueck, wenn die Anforderung nur in der Erweiterung steht, und dann misst der ganze Zaun nichts")
    }

    @Test("a source that does not serve the type or is not ready is not in it")
    func onlyServingAndAvailableSourcesCount() {
        #expect(LibraryViewModel.secondarySignature(of: [("jf", true, false, "")]).isEmpty,
                "nicht bereit heisst nicht im Regal")
        #expect(LibraryViewModel.secondarySignature(of: [("jf", false, true, "")]).isEmpty,
                "bedient keine Buecher heisst nicht im Regal")
    }

    // MARK: - Source fence

    /// A statement about the code, measured like a number: the shelf's merge
    /// asks `mediaTypes`, so this source may never answer with a fixed set
    /// again. Written as a fence because the merge itself needs a live client
    /// and a server, which no unit case has.
    @Test("the source derives its types from the gate, not from a fixed list", .needsTheSources)
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
    /// source into the audiobook tab asks exactly this question, as a rule
    /// with its cases, and the shelf asks the rule.
    @Test("the shelf mixes in every secondary source that serves audiobooks", .needsTheSources)
    func theShelfMergesEverySourceThatServesAudiobooks() throws {
        #expect(LibraryViewModel.mixesIn(isMain: false, servesBooks: true, available: true), "a books source is mixed in")
        #expect(!LibraryViewModel.mixesIn(isMain: true, servesBooks: true, available: true), "the main source never twice")
        #expect(!LibraryViewModel.mixesIn(isMain: false, servesBooks: false, available: true), "a music-only source stays out")
        #expect(!LibraryViewModel.mixesIn(isMain: false, servesBooks: true, available: false), "an unavailable source stays out")
        let source = SyncContractFenceTests.stripped(try String(contentsOfFile: Self.shelfPath, encoding: .utf8))
        #expect(source.contains("Self.mixesIn(isMain: provider === session.provider"),
                "the shelf no longer asks the rule for its secondary sources")
        #expect(source.contains("servesBooks: provider.mediaTypes.contains(.audiobooks)"),
                "the rule is no longer fed the source's own types")
    }

    /// The other half of the same seam: the signature only helps if someone
    /// asks it after a source announced a change. Measured live at the bench,
    /// and the reason this fence exists: the books library answers a second
    /// after the start, and without this the shelf kept the mix it had made
    /// before that answer, so the book appeared only at the next launch.
    @Test("the shelf is woken when a source changes its types", .needsTheSources)
    func theShelfIsWokenWhenASourceChangesWhatItServes() throws {
        let source = try String(contentsOfFile: Self.shelfViewPath, encoding: .utf8)
        #expect(source.contains("onChange(of: session.sourcesVersion)"),
                "die Ankuendigung der Quellen erreicht die Bibliotheks-Ansicht nicht mehr")
        #expect(source.contains("viewModel.refreshSecondarySources(from: session.allProviders)"),
                "die Ansicht weckt das Regal nicht mehr, eine spaet gemeldete Bibliothek bliebe unsichtbar")
    }

    /// The CLASS, not the find: a surface that acts on a TITLE must resolve
    /// its provider from that title's id. The coordinator's provider is not
    /// what plays: it is a `let` from its `init`, built with the MAIN library
    /// provider, so it answered for a Jellyfin book with a request to the
    /// library server (measured live at the bench: the book page stayed
    /// without parts, the player without chapters).
    @Test("surfaces that act on a title get the provider from its id", .needsTheSources)
    func aSurfaceActingOnATitleRoutesByItsId() throws {
        for path in [Self.bookPagePath, Self.bookGridPath] {
            let raw = try String(contentsOfFile: path, encoding: .utf8)
            // Comment lines out first. The fence used to read the raw file
            // and then tore on the sentence EXPLAINING why the old grip is
            // gone: naming `PlayerCoordinator.provider` in a comment is not
            // using it. Same rule as the other source fences here, and it is
            // the one this repository already wrote down after a fence tore
            // on a comment about `async let`.
            let source = raw.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let file = (path as NSString).lastPathComponent
            // The grip itself, in ANY form. An earlier version of this fence
            // listed the shapes it had seen (an assignment, a call) and stayed
            // green when the probe put the old TERNARY back; a fence that
            // names forms instead of the thing guards only what it has met.
            #expect(!source.lowercased().contains("coordinator.provider"),
                    "\(file) fragt wieder den Haupt-Anbieter nach einem Titel")
            #expect(source.contains("router.provider("),
                    "\(file) leitet keinen Titel mehr ueber den Router")
        }
    }

    private static let shelfViewPath =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Views/LibraryView.swift").path
    private static let bookPagePath =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Views/BookDetailScreen.swift").path
    private static let bookGridPath =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Views/BookGridComponents.swift").path
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
