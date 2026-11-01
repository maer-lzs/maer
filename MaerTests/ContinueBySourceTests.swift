// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The rows of the large and medium "Continue": the source of a title, the
/// rows the app keeps (`ContinueBySource`) and the rows a widget shows
/// (`WidgetRows`).
struct ContinueBySourceTests {
    private func row(_ id: String, _ source: WidgetSource, at playedAt: Double) -> WidgetSourceRow {
        WidgetSourceRow(source: source, itemId: id, title: id, subtitle: nil, fraction: 0.5, remainingText: nil,
                        isLive: false, kindSymbol: "waveform", cover: nil, playedAt: playedAt)
    }

    @Test("die Quelle einer Zeile ist der Reiter der App, je Praefix und Form")
    func theSourceIsTheTab() {
        let lvaAlbum = FreeCatalog.archivePrefix + "concert"
        let table: [(String, ProgressMark.StartedForm?, WidgetSource?)] = [
            ("li_book-1", nil, .audiobooks),
            ("local:file-1", nil, .audiobooks),
            ("jf:book:1", nil, .audiobooks),
            ("rss:feed#ep-1", nil, .podcasts),
            ("abspod:show:ep-1", nil, .podcasts),
            ("sub:song:1", nil, .music),
            ("sub:album:1", nil, .music),
            ("jf:song:1", nil, .music),
            ("radio:station-1", nil, .radio),
            (FreeCatalog.librivoxPrefix + "1", nil, .audiobooks),
            (FreeCatalog.gutenbergPrefix + "1", nil, .audiobooks),
            (FreeCatalog.jamendoPrefix + "1", nil, .music),
            (lvaAlbum, nil, .audiobooks),
            (lvaAlbum, .album, .music),
            (CatalogSongID.make(album: lvaAlbum, index: 2), nil, .music),
            ("other:1", nil, nil),
        ]
        for (id, form, expected) in table {
            #expect(ContinueBySource.source(for: id, markedForm: form) == expected, "\(id) \(String(describing: form))")
            let tab = MediaFamily.kind(for: id, markedForm: form)
            #expect(ContinueBySource.source(for: id, markedForm: form)?.rawValue == tab?.rawValue,
                    "\(id) has another source than its tab \(String(describing: tab))")
        }
    }

    @Test("jede Quelle ist ein Reiter der App und jeder Reiter ausser Start eine Quelle")
    func everySourceIsATab() {
        #expect(Set(WidgetSource.allCases.map(\.rawValue)) == Set(MediaType.allCases.filter { $0 != .home }.map(\.rawValue)))
    }

    @Test("ein neuer Titel: einmal in den Zeilen, je Quelle der neueste und die zwei zuletzt gehoerten bleiben")
    func aNewTitleReplacesWhatNoWidgetShows() {
        var rows: [WidgetSourceRow] = []
        rows = WidgetRows.merged(row("book-a", .audiobooks, at: 1), into: rows)
        rows = WidgetRows.merged(row("book-b", .audiobooks, at: 2), into: rows)
        #expect(rows.map(\.itemId) == ["book-b", "book-a"], "two titles heard last stay, even of one source")
        rows = WidgetRows.merged(row("ep", .podcasts, at: 3), into: rows)
        #expect(rows.map(\.itemId) == ["ep", "book-b"], "the older book is neither the newest of its source nor among the two last")
        rows = WidgetRows.merged(row("song", .music, at: 4), into: rows)
        rows = WidgetRows.merged(row("station", .radio, at: 5), into: rows)
        #expect(rows.map(\.itemId) == ["station", "song", "ep", "book-b"], "the newest of every source stays")
        rows = WidgetRows.merged(row("book-b", .audiobooks, at: 6), into: rows)
        #expect(rows.map(\.itemId) == ["book-b", "station", "song", "ep"], "a title heard again stands once, with its new moment")
    }

    private func progress(_ fraction: Double, at ms: Double, time: Double? = nil) -> BookProgress {
        BookProgress(fraction: fraction, isFinished: false, lastUpdate: ms, currentTime: time)
    }

    @Test("ein Durchgang der Startseite wird zu Zeilen, je Art aus dem, was die Startseite liest")
    func theHomePassBecomesRows() {
        let song = CatalogSongID.make(album: FreeCatalog.archivePrefix + "album", index: 1)
        let cards: [String: ContinueBySource.Card] = [
            "li_book": .init(title: "Buch", subtitle: "Autorin", kindSymbol: "book.closed", markedForm: nil, isLive: false,
                             local: progress(0.1, at: 1_000), server: progress(0.5, at: 2_000, time: 1_800), duration: 3_600),
            "rss:feed#ep": .init(title: "Folge", subtitle: "Sendung", kindSymbol: "mic", markedForm: nil, isLive: false,
                                 local: progress(0.75, at: 9_000, time: 900), server: progress(0.2, at: 3_000), duration: 1_200),
            "sub:album:1": .init(title: "Album", subtitle: "Band", kindSymbol: "music.note", markedForm: nil, isLive: false),
            "radio:station": .init(title: "Sender", subtitle: nil, kindSymbol: "antenna.radiowaves.left.and.right",
                                   markedForm: nil, isLive: true, local: progress(0.9, at: 9_999)),
            song: .init(title: "Spur", subtitle: nil, kindSymbol: "music.note", markedForm: nil, isLive: false),
        ]
        let moments: [(id: String, ms: Double)] = [("li_book", 5), ("rss:feed#ep", 4), ("sub:album:1", 3),
                                                   ("radio:station", 2), (song, 1), ("unknown:x", 9)]
        let rows = ContinueBySource.rows(of: moments) { cards[$0] }
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.itemId, $0) })
        #expect(byId["li_book"]?.source == .audiobooks && byId["li_book"]?.fraction == 0.5,
                "the book shows the newer progress, the server's")
        #expect(byId["li_book"]?.remainingText == DurationText.remaining(seconds: 1_800))
        #expect(byId["rss:feed#ep"]?.source == .podcasts && byId["rss:feed#ep"]?.fraction == 0.75,
                "the episode shows the newer progress, this device's")
        #expect(byId["sub:album:1"]?.source == .music && byId["sub:album:1"]?.fraction == nil
                    && byId["sub:album:1"]?.remainingText == nil, "an album without a position has no bar")
        #expect(byId["radio:station"]?.isLive == true && byId["radio:station"]?.fraction == nil)
        #expect(byId[song] == nil || byId[song]?.source == .music, "a catalogue track is music")
        #expect(byId["unknown:x"] == nil, "a title without a card has no row")
        #expect(rows.allSatisfy { $0.cover == WidgetCoverStore.continueRows.name(for: $0.itemId) })
        #expect(rows.map(\.playedAt) == rows.map(\.playedAt).sorted(by: >), "heard last first")
    }

    @Test("ein Album ohne begonnenen Fortschritt zeigt keinen Balken und keine Restzeit, ohne Stand wie mit 0 vom Server")
    func anAlbumNobodyStartedShowsNoProgress() {
        let cards: [String: ContinueBySource.Card] = [
            "sub:album:none": .init(title: "Album", subtitle: "Band", kindSymbol: "music.note", markedForm: nil, isLive: false,
                                    duration: 2_400),
            "sub:album:zero": .init(title: "Album", subtitle: "Band", kindSymbol: "music.note", markedForm: nil, isLive: false,
                                    server: progress(0, at: 2_000), duration: 2_400),
            "sub:album:begun": .init(title: "Album", subtitle: "Band", kindSymbol: "music.note", markedForm: nil, isLive: false,
                                     server: progress(0.25, at: 2_000), duration: 2_400),
            "radio:station": .init(title: "Sender", subtitle: nil, kindSymbol: "antenna.radiowaves.left.and.right",
                                   markedForm: nil, isLive: true),
        ]
        // One source keeps one row, so every case gets its own pass.
        let rows = cards.keys.compactMap { id in ContinueBySource.rows(of: [(id, 1)]) { cards[$0] }.first }
        let shows = Dictionary(uniqueKeysWithValues: rows.map { ($0.itemId, $0.showsProgress) })
        #expect(shows == ["sub:album:none": false, "sub:album:zero": false, "sub:album:begun": true, "radio:station": false],
                "only a started title shows a bar and its time")
        #expect(rows.first { $0.itemId == "sub:album:zero" }?.subtitle == "Band", "the row keeps who made it")
    }

    @Test("die Karte des Schreibers: ein Sender ist live, ein Buch traegt Titel, Autorin, Laenge und den Stand des Servers")
    @MainActor
    func theWritersCard() throws {
        let stationId = "radio:rb:card-\(UUID().uuidString)"
        let station = RadioStation(id: stationId, name: "Sender", streamURL: "https://stream.example/live")
        let live = try #require(ContinueRowsWriter.card(for: stationId, entry: nil, item: nil, station: station, serverProgress: nil))
        #expect(live.isLive && live.title == "Sender" && live.local == nil && live.server == nil)
        let bookId = "li_card-\(UUID().uuidString)"
        let metadata = try JSONDecoder().decode(LibraryItemMetadata.self,
                                                from: Data(#"{"title":"Buch","authorName":"Autorin"}"#.utf8))
        let item = LibraryItem(id: bookId, media: LibraryItemMedia(metadata: metadata, duration: 3_600, chapters: nil, tracks: nil),
                               addedAt: nil)
        let server = progress(0.5, at: 2_000, time: 1_800)
        let book = try #require(ContinueRowsWriter.card(for: bookId, entry: LibraryEntry(item: item, progress: server),
                                                        item: nil, station: nil, serverProgress: nil))
        #expect(!book.isLive && book.title == "Buch" && book.subtitle == "Autorin" && book.duration == 3_600)
        #expect(book.server == server && book.local == nil, "the book's progress is the library entry's")
        #expect(ContinueRowsWriter.card(for: "li_none-\(UUID().uuidString)", entry: nil, item: nil, station: nil,
                                        serverProgress: nil) == nil, "a title nothing resolves has no card")
    }

    @Test("nichts eines frueheren Durchgangs bleibt: ein Titel, den die Startseite nicht mehr zeigt, geht")
    func aTitleTheHomeNoLongerShowsLeaves() {
        let card = ContinueBySource.Card(title: "t", subtitle: nil, kindSymbol: "book.closed", markedForm: nil, isLive: false)
        let first = ContinueBySource.rows(of: [("li_a", 2), ("li_gone", 1)]) { _ in card }
        #expect(first.map(\.itemId) == ["li_a", "li_gone"])
        let second = ContinueBySource.rows(of: [("li_a", 3)]) { _ in card }
        #expect(second.map(\.itemId) == ["li_a"], "a title of a removed server or another account stayed")
    }

    @Test("die Startseite ruft den einen Schreiber mit dem, was ihre Zeilen zeigen; nur er schreibt die Zeilen", .needsTheSources)
    func theHomePassCallsTheOneWriter() throws {
        let home = try FetchAnswerTests.squeezedSource("Sources/Views/HomeView.swift")
        #expect(home.contains("writeWidgetRows(continueMoments: books + episodesShown, episodeProgress: episodeProgress)"),
                "the home pass no longer hands the writer what its Continue row shows")
        #expect(home.contains("let entries = listenAgain(limit: RowPreview.limit).entries"),
                "the Listen Again row reads its entries another way than the widget's rows")
        #expect(home.contains("Task { await ContinueRowsWriter.write(rows, passAtMs: passAtMs) }"))
        let writer = try FetchAnswerTests.squeezedSource("Sources/Providers/ContinueRowsWriter.swift")
        #expect(writer.contains("if WidgetRows.passMovesTitle(oldPassAtMs: previous?.passAtMs, newPassAtMs: passAtMs, snapshot: WidgetSnapshot.load()) { reload() }"),
                "a pass with the same rows that leaves the snapshot's title out no longer reloads the widget")
        var writers: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
            if text.contains("ContinueRows(rows:") { writers.append(file.lastPathComponent) }
        }
        #expect(writers == ["ContinueRowsWriter.swift"], "the rows have another writer: \(writers)")
    }

    @Test("gross: je eingeschaltete Quelle der neueste Titel in der Reihenfolge der Reiter, in Bedienungshilfen-Groessen zwei")
    func theLargeWidget() {
        let rows = [row("station", .radio, at: 9), row("book-b", .audiobooks, at: 8), row("book-a", .audiobooks, at: 7),
                    row("song", .music, at: 6), row("ep", .podcasts, at: 5)]
        let all = Set(WidgetSource.allCases)
        #expect(WidgetRows.shown(rows, layout: .large(all), accessibilitySize: false).map(\.itemId)
                == ["book-b", "ep", "song", "station"])
        #expect(WidgetRows.shown(rows, layout: .large(all.subtracting([.radio])), accessibilitySize: false).map(\.itemId)
                == ["book-b", "ep", "song"], "a source switched off has no row")
        #expect(WidgetRows.shown(rows.filter { $0.source != .music }, layout: .large(all), accessibilitySize: false).map(\.itemId)
                == ["book-b", "ep", "station"], "a source without a title has no row")
        #expect(WidgetRows.shown(rows, layout: .large(all), accessibilitySize: true).map(\.itemId) == ["book-b", "ep"])
    }

    @Test("mittel: die zwei zuletzt gehoerten Titel oder je eine von zwei Quellen, in Bedienungshilfen-Groessen eine Zeile")
    func theMediumWidget() {
        let rows = [row("book-a", .audiobooks, at: 7), row("station", .radio, at: 5), row("book-b", .audiobooks, at: 8),
                    row("ep", .podcasts, at: 6)]
        #expect(WidgetRows.shown(rows, layout: .mediumRecent, accessibilitySize: false).map(\.itemId) == ["book-b", "book-a"])
        #expect(WidgetRows.shown(rows, layout: .mediumRecent, accessibilitySize: true).map(\.itemId) == ["book-b"])
        #expect(WidgetRows.shown(rows, layout: .mediumSources(.radio, .podcasts), accessibilitySize: false).map(\.itemId)
                == ["station", "ep"], "in the order chosen")
        #expect(WidgetRows.shown(rows, layout: .mediumSources(.audiobooks, .audiobooks), accessibilitySize: false).map(\.itemId)
                == ["book-b"], "one source chosen twice is one row")
        #expect(WidgetRows.shown(rows, layout: .mediumSources(.music, .podcasts), accessibilitySize: false).map(\.itemId)
                == ["ep"], "a source without a title has no row")
    }

    @Test("die Einstellung je Groesse: gross die eingeschalteten Quellen, mittel zuletzt gehoert oder zwei Quellen")
    @MainActor
    func theSettingsAskForTheirRows() {
        var settings = ContinueWidgetSettings()
        #expect(settings.layout(large: true) == .large(Set(WidgetSource.allCases)), "a new large widget shows every source")
        #expect(settings.layout(large: false) == .mediumRecent, "a new medium widget shows the titles heard last")
        settings.music = false
        settings.radio = false
        #expect(settings.layout(large: true) == .large([.audiobooks, .podcasts]))
        settings.mediumContent = .twoSources
        settings.firstSource = .radio
        settings.secondSource = .audiobooks
        #expect(settings.layout(large: false) == .mediumSources(.radio, .audiobooks))
        #expect(settings.layout(large: true) == .large([.audiobooks, .podcasts]), "the medium choice leaves the large one alone")
    }

    @Test("jeder Text der Einstellung steht englisch und deutsch im Katalog", .needsTheSources)
    func theSettingsSpeakGerman() throws {
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let texts = ["Continue Listening", "Audiobooks", "Podcasts", "Music", "Radio", "Content", "Last Heard",
                     "Two Sources", "First Source", "Second Source", "Source"]
        for text in texts {
            let entry = strings[text] as? [String: Any]
            let german = ((entry?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect((german?["value"] as? String)?.isEmpty == false, "\(text) has no German text")
            #expect(german?["state"] as? String == "translated", "\(text) is not translated")
        }
        let shared = try FetchAnswerTests.squeezedSource("Sources/Models/WidgetShared.swift")
        for text in texts.dropFirst() {
            #expect(shared.contains("\"\(text)\""), "\(text) is no longer a text of the settings")
        }
    }

    @Test("der Schnappschuss traegt die Quelle seines Titels, keine Zeilen; ein Schnappschuss ohne Quelle liest sich wie vorher")
    func theSnapshotCarriesItsSource() throws {
        let old = Data(#"{"itemId":"li_1","title":"Buch","fraction":0.5,"isPlaying":false}"#.utf8)
        let read = try JSONDecoder().decode(WidgetSnapshot.self, from: old)
        #expect(read.title == "Buch" && read.source == nil)
        var snapshot = read
        snapshot.source = .audiobooks
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: encoded).source == .audiobooks)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let keys = try #require(object as? [String: Any]).keys
        #expect(!keys.contains("rows") && !keys.contains("bySource"), "the player's snapshot carries rows again: \(keys.sorted())")
        let rows = ContinueRows(rows: [row("ep", .podcasts, at: 2), row("station", .radio, at: 1)], passAtMs: 5)
        #expect(try JSONDecoder().decode(ContinueRows.self, from: JSONEncoder().encode(rows)) == rows)
    }

    @Test("eine Zeile anderer Form faellt heraus, die anderen lesen sich")
    func aRowOfAnotherFormIsLeftOut() throws {
        let file = Data("""
            {"rows":[
              {"source":"podcasts","itemId":"ep","title":"Folge","isLive":false,"kindSymbol":"mic","playedAt":2,"later":"field"},
              {"source":"audiobooks","itemId":"no-title","isLive":false,"kindSymbol":"book","playedAt":1},
              {"source":"television","itemId":"tv","title":"TV","isLive":false,"kindSymbol":"tv","playedAt":3}
            ]}
            """.utf8)
        let read = try JSONDecoder().decode(ContinueRows.self, from: file)
        #expect(read.rows.map(\.itemId) == ["ep"], "a row of another form took the others with it, or was read")
        #expect(try JSONDecoder().decode(ContinueRows.self, from: Data("{}".utf8)).rows.isEmpty)
    }

    private func snapshot(_ id: String, _ source: WidgetSource?, savedAt seconds: Double, heardAtMs: Double? = nil,
                          playing: Bool = false) -> WidgetSnapshot {
        WidgetSnapshot(itemId: id, title: id, author: nil, fraction: 0.4, remainingText: "x", isPlaying: playing,
                       steps: nil, savedAt: seconds, kindSymbol: "waveform", isLive: false, source: source,
                       heardAtMs: heardAtMs ?? seconds * 1000)
    }

    @Test("gehoert ist die letzte Position, nicht das Schreiben: ein Schnappschuss, neu geschrieben ohne Hoeren, bleibt draussen")
    func writtenIsNotHeard() {
        let pass = [row("book-before", .audiobooks, at: 4_000)]
        let restored = snapshot("hidden", .audiobooks, savedAt: 20, heardAtMs: 6_000)
        #expect(WidgetRows.withTitle(of: restored, at: Date(timeIntervalSince1970: 21), in: pass, passAtMs: 10_000) == pass,
                "a title written anew after the pass, but heard before it, came back")
        var station = snapshot("radio:x", .radio, savedAt: 12, playing: true)
        station.heardAtMs = nil
        #expect(station.heardMs == 12_000, "a playing station without a position is heard while it plays")
        station.isPlaying = false
        #expect(station.heardMs == nil)
        #expect(snapshot("again", .audiobooks, savedAt: 20, heardAtMs: 6_000, playing: true).heardMs == 20_000,
                "a title playing again counts from this write, not from its older position")
        #expect(WidgetRows.withTitle(of: station, at: Date(), in: pass, passAtMs: 10_000) == pass)
    }

    @Test("ueber den echten Player: ein Titel, den der Durchgang ausliess und der wieder laeuft, steht waehrend des Hoerens in seiner Zeile", .needsAudio)
    func aTitleHeardAgainStandsInItsRow() async throws {
        let ticks = TickWorkTests()
        let file = try ticks.tone(seconds: 12)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "widget-again-\(UUID().uuidString)"
        let heard = Date().timeIntervalSince1970 * 1000 - 3_600_000
        ListeningStore.record(id, position: 3, duration: 12, atMs: heard)
        ContinueHiddenStore.hide(id: id, lastUpdate: heard)
        defer { ContinueHiddenStore.show(id: id) }
        let pass = [row("book-before", .audiobooks, at: heard - 60_000)]
        let passAt = Date().timeIntervalSince1970 * 1000
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: false),
                                    localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: TrackFileSizeTests.book(id, path: file.path, size: 1, seconds: 12))
        model.play()
        let written = try #require(WidgetSnapshot.load(), "the precondition: the play wrote a snapshot")
        #expect(written.itemId == id && written.isPlaying, "the precondition: the snapshot of the play")
        let shown = WidgetRows.withTitle(of: written, at: Date(), in: pass, passAtMs: passAt)
        let large = WidgetRows.shown(shown, layout: .large(Set(WidgetSource.allCases)), accessibilitySize: false)
        #expect(large.first?.itemId == id, "the title playing again is missing from its row: \(large.map(\.itemId))")
        model.stop()
    }

    @Test("ueber den echten Player: ein Titel, den die Wiederherstellung ohne Hoeren laedt, legt sich nicht ueber den Durchgang zurueck", .needsAudio)
    func aRestoredTitleStaysOut() async throws {
        let ticks = TickWorkTests()
        let file = try ticks.tone(seconds: 12)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "widget-restore-\(UUID().uuidString)"
        let heard = Date().timeIntervalSince1970 * 1000 - 3_600_000
        ListeningStore.record(id, position: 3, duration: 12, atMs: heard)
        ContinueHiddenStore.hide(id: id, lastUpdate: heard)
        defer { ContinueHiddenStore.show(id: id) }
        let pass = [row("book-before", .audiobooks, at: heard - 60_000)]
        let passBefore = Date().timeIntervalSince1970 * 1000
        // The restore at start: the title opens without playing, and the load writes the snapshot.
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: false),
                                    localTracks: { _ in [:] }, isOnline: { true })
        await model.load(item: TrackFileSizeTests.book(id, path: file.path, size: 1, seconds: 12))
        let written = try #require(WidgetSnapshot.load(), "the precondition: the load wrote a snapshot")
        #expect(written.itemId == id && written.source != nil && !written.isPlaying)
        #expect(written.heardAtMs == heard, "the load counts as heard: \(String(describing: written.heardAtMs))")
        #expect(WidgetRows.withTitle(of: written, at: Date(), in: pass, passAtMs: passBefore) == pass,
                "pass before the restore: the hidden title came back")
        let passAfter = Date().timeIntervalSince1970 * 1000
        #expect(WidgetRows.withTitle(of: written, at: Date(), in: pass, passAtMs: passAfter) == pass,
                "pass after the restore: the hidden title came back")
        model.stop()
        let coordinator = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerCoordinator.swift")
        #expect(coordinator.contains("await open(item: item, autoplay: false, preservesContext: true, origin: .restore)"),
                "the restore at start plays, so this witness no longer stands for it")
    }

    @Test("gleiche Zeilen, aber der neue Durchgang laesst den Titel des Schnappschusses aus: das Widget laedt neu")
    func aPassThatLeavesTheTitleOutReloads() {
        let heard = snapshot("x", .audiobooks, savedAt: 30, heardAtMs: 15_000)
        #expect(WidgetRows.passMovesTitle(oldPassAtMs: 10_000, newPassAtMs: 20_000, snapshot: heard))
        #expect(!WidgetRows.passMovesTitle(oldPassAtMs: 16_000, newPassAtMs: 20_000, snapshot: heard), "already out before")
        #expect(!WidgetRows.passMovesTitle(oldPassAtMs: 10_000, newPassAtMs: 14_000, snapshot: heard), "still in after")
        #expect(WidgetRows.passMovesTitle(oldPassAtMs: nil, newPassAtMs: 20_000, snapshot: heard))
        #expect(!WidgetRows.passMovesTitle(oldPassAtMs: 10_000, newPassAtMs: 20_000, snapshot: nil))
    }

    @Test("eine geaenderte Quelle nimmt nur die Zeilen ihrer Titel, ohne auf einen Durchgang zu warten", .needsTheSources)
    func aSourceChangeKeepsWhatIsStillThere() throws {
        let track = FreeCatalog.jamendoPrefix + "t1"
        let freeBook = FreeCatalog.librivoxPrefix + "b1"
        // The session's answers with every source off but Subsonic: the
        // catalogue says false always, RSS without a subscription too.
        let onlySubsonic: (String) -> Bool = { ItemNamespace.isSubsonic($0) }
        let table: [(id: String, stands: Bool, what: String)] = [
            (track, true, "a catalogue track"),
            (freeBook, true, "a free audiobook"),
            ("rss:feed:ep", true, "an episode of a browsed show"),
            ("radio:rb:x", true, "a station with the radio off"),
            ("sub:album:1", true, "an album of a source still on"),
            ("li_book", false, "a book with the server signed out"),
            ("jf:album:2", false, "an album of a music server switched off"),
            ("abspod:ep", false, "an episode of the server's podcasts switched off"),
        ]
        for entry in table {
            #expect(ContinueBySource.standsAfterSwitch(entry.id, sourceRead: onlySubsonic) == entry.stands,
                    "\(entry.what)")
        }
        let stored = ContinueRows(rows: table.enumerated().map { row($1.id, .audiobooks, at: Double(8 - $0) * 1_000) },
                                  passAtMs: 9_000)
        let kept = ContinueBySource.keepingStanding(stored, snapshotItemId: track, nowMs: 20_000, sourceRead: onlySubsonic)
        #expect(kept.rows.map(\.itemId) == table.filter(\.stands).map(\.id), "a row that stands went, or one that went stayed")
        #expect(kept.passAtMs == 9_000, "a title heard after the last pass would no longer join")
        let gone = ContinueBySource.keepingStanding(stored, snapshotItemId: "li_book", nowMs: 20_000, sourceRead: onlySubsonic)
        #expect(gone.passAtMs == 20_000, "the snapshot's title lost its source and would join again")
        let none = ContinueBySource.keepingStanding(nil, snapshotItemId: nil, nowMs: 20_000, sourceRead: onlySubsonic)
        #expect(none.rows.isEmpty && none.passAtMs == 20_000)
        let session = try FetchAnswerTests.squeezedSource("Sources/AppSession.swift")
        #expect(session.contains("Task { await ContinueRowsWriter.keepStanding { self.provider(for: $0).isAvailable } }"),
                "a change of sources no longer cuts the rows by the session's one answer")
    }

    @Test("nach dem Abmelden vom Server stehen keine Zeilen mehr da, ueber den echten Weg der Person")
    @MainActor
    func aSignOutForgetsTheRows() async throws {
        let before = ContinueRows.load()
        let auth = AppSession.shared.authViewModel
        let wasSignedIn = auth.isLoggedIn
        let token = KeychainStore.load(forKey: KeychainKey.apiToken)
        defer {
            _ = before?.save()
            if let token { KeychainStore.save(token, forKey: KeychainKey.apiToken) }
            auth.isLoggedIn = wasSignedIn
        }
        await ContinueRowsWriter.write([row("li_old-server", .audiobooks, at: 1_000)], passAtMs: 1_000)
        #expect(ContinueRows.load()?.rows.isEmpty == false, "the precondition: rows of the server")
        let signedOutAt = Date().timeIntervalSince1970 * 1000
        auth.logout()
        for _ in 0..<50 where ContinueRows.load()?.rows.isEmpty == false {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let after = try #require(ContinueRows.load())
        #expect(after.rows.isEmpty, "the rows of the signed-out server stand: \(after.rows.map(\.itemId))")
        #expect((after.passAtMs ?? 0) >= signedOutAt, "the moment of the sign-out keeps an older snapshot out")
    }

    @Test("das Abmelden vergisst den Schnappschuss samt Cover nur bei einem Titel dieses Servers; ein Sender bleibt")
    @MainActor
    func aSignOutForgetsOnlyThisServersSnapshot() async throws {
        let ids: [(String, Bool)] = [("li_book", true), ("abspod:show#ep", true), ("radio:rb:x", false), ("rss:feed#ep", false),
                                     ("sub:album:1", false), ("jf:song:1", false), ("local:file", false)]
        for (id, want) in ids {
            #expect(ItemNamespace.isAudiobookshelf(id) == want, "\(id)")
        }
        let snapshotURL = try #require(WidgetSnapshot.snapshotURL)
        let coverURL = try #require(WidgetSnapshot.coverURL)
        let keptSnapshot = try? Data(contentsOf: snapshotURL)
        let keptCover = try? Data(contentsOf: coverURL)
        let rows = ContinueRows.load()
        let auth = AppSession.shared.authViewModel
        let wasSignedIn = auth.isLoggedIn
        let token = KeychainStore.load(forKey: KeychainKey.apiToken)
        defer {
            for (url, data) in [(snapshotURL, keptSnapshot), (coverURL, keptCover)] {
                if let data { try? data.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
            }
            _ = rows?.save()
            if let token { KeychainStore.save(token, forKey: KeychainKey.apiToken) }
            auth.isLoggedIn = wasSignedIn
        }
        for (id, gone) in [("li_old-server", true), ("radio:rb:station", false)] {
            WidgetSnapshot(itemId: id, title: "Titel", author: nil, fraction: 0.5, remainingText: nil, isPlaying: false).save()
            try Data([0x89]).write(to: coverURL)
            auth.logout()
            await ContinueRowsWriter.forget()
            #expect((WidgetSnapshot.load() == nil) == gone, "\(id): the snapshot")
            #expect(FileManager.default.fileExists(atPath: coverURL.path) == !gone, "\(id): its cover")
        }
    }

    @Test("zwei Schreiber, kein Verlust: was der Durchgang herausnahm, legt der Player nicht zurueck", .needsTheSources)
    func thePlayerNeverWritesTheRows() throws {
        let home = [row("book", .audiobooks, at: 1_000), row("ep", .podcasts, at: 900)]
        let shown = WidgetRows.withTitle(of: snapshot("song", .music, savedAt: 2), at: Date(timeIntervalSince1970: 3),
                                         in: home, passAtMs: 1_500)
        #expect(shown.map(\.itemId) == ["song", "book", "ep"], "the rows are the pass's rows and the playing title")
        let player = try FetchAnswerTests.squeezedSource("Sources/ViewModels/PlayerViewModel+Widget.swift")
        #expect(!player.contains("ContinueRows"), "the player writes the home pass's rows")
        #expect(player.contains("source: ContinueBySource.source(for: item.id, markedForm: markedForm),"),
                "the player's title carries no source, so it joins no row")
    }

    @Test("zwei Schreiber, kein Verlust: der laufende Titel steht in seiner Zeile, auch wenn der Durchgang ihn nicht kennt")
    func thePlayingTitleStandsInItsRow() {
        let home = [row("book-old", .audiobooks, at: 1_000), row("ep", .podcasts, at: 900)]
        let playing = snapshot("book-now", .audiobooks, savedAt: 5)
        let shown = WidgetRows.withTitle(of: playing, at: Date(timeIntervalSince1970: 6), in: home, passAtMs: 1_500)
        let large = WidgetRows.shown(shown, layout: .large(Set(WidgetSource.allCases)), accessibilitySize: false)
        #expect(large.map(\.itemId) == ["book-now", "ep"], "the playing book stands in the audiobooks row")
        #expect(large.first?.playedAt == 5_000 && large.first?.fraction == 0.4)
        #expect(WidgetRows.withTitle(of: snapshot("x", nil, savedAt: 9), at: Date(), in: home, passAtMs: 1_500) == home,
                "a snapshot without a source joins no row")
        #expect(WidgetRows.withTitle(of: nil, at: Date(), in: home, passAtMs: 1_500) == home)
        #expect(WidgetRows.withTitle(of: playing, at: Date(), in: home, passAtMs: nil).contains { $0.itemId == "book-now" },
                "a file without the moment of its pass takes the snapshot's title in")
    }

    @Test("ein Titel, den der juengste Durchgang ausliess (beendet, ausgeblendet, Konto weg), steht in keiner Zeile, auch wenn der Schnappschuss ihn traegt")
    func aTitleThePassLeftOutStaysOut() {
        let pass = [row("book-before", .audiobooks, at: 4_000), row("ep", .podcasts, at: 3_000)]
        // Finished, hidden or no longer this account's: the pass at 10 s left X out, the snapshot of X is older.
        for left in ["finished", "hidden", "other-account"] {
            let shown = WidgetRows.withTitle(of: snapshot(left, .audiobooks, savedAt: 6), at: Date(timeIntervalSince1970: 11),
                                             in: pass, passAtMs: 10_000)
            #expect(shown == pass, "\(left) came back into the rows: \(shown.map(\.itemId))")
            let large = WidgetRows.shown(shown, layout: .large(Set(WidgetSource.allCases)), accessibilitySize: false)
            #expect(large.first?.itemId == "book-before", "the audiobooks row shows \(left) instead of the book before")
        }
        // Heard after the pass: the pass could not know it yet.
        let after = WidgetRows.withTitle(of: snapshot("new", .audiobooks, savedAt: 12), at: Date(timeIntervalSince1970: 13),
                                         in: pass, passAtMs: 10_000)
        #expect(after.first?.itemId == "new")
        // The pass knows the title with a newer moment than the snapshot: its row stands.
        let newer = [row("book-before", .audiobooks, at: 14_000)]
        #expect(WidgetRows.withTitle(of: snapshot("book-before", .audiobooks, savedAt: 12), at: Date(timeIntervalSince1970: 15),
                                     in: newer, passAtMs: 14_500) == newer)
    }

    @Test("ohne Zeilen zeigt auch gross den einen Titel, „Noch nichts gehört“ nur ohne Schnappschuss")
    func theFaceWithoutRows() {
        typealias Row = (wide: Bool, rows: Bool, snapshot: Bool, want: ContinueFace)
        let table: [Row] = [
            (true, true, true, .rows),
            (true, false, true, .oneTitle),
            (true, false, false, .nothingYet),
            (true, true, false, .rows),
            (false, true, true, .oneTitle),
            (false, false, true, .oneTitle),
            (false, false, false, .nothingYet),
        ]
        for row in table {
            #expect(ContinueFace.of(showsRowsAtThisSize: row.wide, hasRows: row.rows, hasSnapshot: row.snapshot) == row.want,
                    "\(row)")
        }
    }

    @Test("gross und mittel zeigen die Zeilen der Regel, je Zeile ein Link und ein Knopf mit ihrem Titel", .needsTheSources)
    func theWidgetShowsTheRows() throws {
        let widget = try FetchAnswerTests.squeezedSource("LiveActivityWidget/ContinueListeningWidget.swift")
        #expect(widget.contains("WidgetRows.shown(WidgetRows.withTitle(of: entry.snapshot, at: entry.date, in: entry.homeRows, passAtMs: entry.passAtMs), layout: entry.layout, accessibilitySize: dynamicTypeSize.isAccessibilitySize)"),
                "the widget picks its rows past the rule, or without the type size")
        #expect(widget.contains("Link(destination: ResumeLink.url(itemId: row.itemId))"), "a row does not open its own title")
        #expect(widget.contains("Button(intent: ResumeListeningIntent(itemId: row.itemId))"), "a row's button does not continue its own title")
        #expect(widget.contains(".supportedFamilies([.systemSmall, .systemMedium, .systemLarge,"))
        #expect(widget.contains("ContinueFace.of(showsRowsAtThisSize: isWide, hasRows: !rows.isEmpty, hasSnapshot: entry.snapshot != nil)"),
                "the widget decides its face past the rule")
        #expect(widget.contains("case .systemMedium, .systemLarge: medium(snapshot, line)"),
                "the large widget without rows does not show the one title")
        #expect(widget.contains("WidgetCoverStore.continueRows.url(named: name)"), "the rows' covers come from another place")
        #expect(widget.contains(".fixedSize(horizontal: subtitle != nil, vertical: false)"),
                "beside a long name the time left is cut off again")
        #expect(widget.contains("Text(verbatim: \" · \") .fixedSize() .accessibilityHidden(true)"),
                "VoiceOver reads the separator between name and time")
        #expect(widget.contains("if row.showsProgress { ProgressView(value: row.fraction ?? 0)"),
                "a title nobody started draws an empty bar again")
        #expect(widget.contains("row.isLive ? String(localized: \"Live\") : row.showsProgress ? (row.remainingText ?? \"\") : \"\""),
                "a title nobody started shows its whole length as time left")
        #expect(widget.contains("rowDetail(row, compact: compact && started)"),
                "the medium rows hide who made a title nobody started")
    }

    @Test("das Widget liest seine Einstellung je Groesse und gibt jedem Eintrag seine Zeilen", .needsTheSources)
    func theWidgetReadsItsSettings() throws {
        let widget = try FetchAnswerTests.squeezedSource("LiveActivityWidget/ContinueListeningWidget.swift")
        #expect(widget.contains("AppIntentConfiguration( kind: \"ContinueListeningWidget\", intent: ContinueWidgetSettings.self,"),
                "the widget's kind or its settings changed; a placed widget keeps its kind")
        #expect(widget.contains("settings.layout(large: context.family == .systemLarge)"))
        let shared = try FetchAnswerTests.squeezedSource("Sources/Models/WidgetShared.swift")
        #expect(shared.contains("When(widgetFamily: .equalTo, .systemLarge)") && shared.contains("When(widgetFamily: .equalTo, .systemMedium)"),
                "the settings are no longer one per size")
    }
}
#endif
