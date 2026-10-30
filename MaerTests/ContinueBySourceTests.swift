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
        rows = ContinueBySource.merged(row("book-a", .audiobooks, at: 1), into: rows)
        rows = ContinueBySource.merged(row("book-b", .audiobooks, at: 2), into: rows)
        #expect(rows.map(\.itemId) == ["book-b", "book-a"], "two titles heard last stay, even of one source")
        rows = ContinueBySource.merged(row("ep", .podcasts, at: 3), into: rows)
        #expect(rows.map(\.itemId) == ["ep", "book-b"], "the older book is neither the newest of its source nor among the two last")
        rows = ContinueBySource.merged(row("song", .music, at: 4), into: rows)
        rows = ContinueBySource.merged(row("station", .radio, at: 5), into: rows)
        #expect(rows.map(\.itemId) == ["station", "song", "ep", "book-b"], "the newest of every source stays")
        rows = ContinueBySource.merged(row("book-b", .audiobooks, at: 6), into: rows)
        #expect(rows.map(\.itemId) == ["book-b", "station", "song", "ep"], "a title heard again stands once, with its new moment")
    }

    @Test("eine Zeile geht, wenn die App den Titel nicht mehr zeigt: beendet, ausgeblendet, Server oder Konto weg")
    func aRowGoesWithItsTitle() {
        let heard = 1_800_000_000_000.0
        let rows = [row("done", .audiobooks, at: heard), row("hidden", .podcasts, at: heard),
                    row("hidden-then-heard", .podcasts, at: heard + 60_000), row("gone", .music, at: heard),
                    row("stays", .radio, at: heard)]
        let markers = ["hidden": heard / 1000, "hidden-then-heard": heard / 1000]
        let kept = ContinueBySource.kept(rows, finished: ["done"], hiddenMarkers: markers, owned: { $0 != "gone" })
        #expect(kept.map(\.itemId) == ["hidden-then-heard", "stays"])
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
