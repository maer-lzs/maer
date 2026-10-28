// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A shuffle whose songs do not come (a music server that does not answer)
/// starts nothing and says so; the server's songs fail with a log line,
/// never a silent empty list.
@MainActor
struct ShuffleEmptyPoolTests {
    @Test("ein leerer Vorrat sagt den Satz der Albumseite, offline nach dem Netz des Geraets")
    func anEmptyPoolSaysWhyByTheDevicesNetwork() async {
        let cases: [(ShufflePool, Bool, String)] = [
            (.unavailable, true, String(localized: "Couldn't load tracks")),
            (.unavailable, false, String(localized: "Not available offline")),
            (.empty, true, String(localized: "No tracks")),
            (.empty, false, String(localized: "No tracks")),
        ]
        for (pool, online, sentence) in cases {
            let coordinator = PlayerCoordinator(provider: MockProvider())
            await ShufflePlayButton.start(pool: { pool }, isOnline: online, coordinator: coordinator)
            #expect(coordinator.loadError == sentence, "\(pool) online=\(online) said \(coordinator.loadError ?? "nothing")")
        }
        #expect(ShufflePlayButton.sentence(for: .unavailable, isOnline: false).1 == .network)
    }

    @Test("ein verschluckter Ausfall heisst nicht leer: Liste in der Hand leer, Abruf ohne Lieder nicht gekommen")
    func aSwallowedFailureIsNotEmpty() throws {
        if case .unavailable = ShufflePool.fetched([]) {} else { Issue.record("a fetch that gave nothing reads as empty") }
        if case .empty = ShufflePool.of([]) {} else { Issue.record("an empty list in hand is not empty") }
        if case .unavailable = ShufflePool.server([], failed: true) {} else { Issue.record("a failed server fetch is not unavailable") }
        if case .empty = ShufflePool.server([], failed: false) {} else { Issue.record("an empty server answer is not empty") }
        // A host the device cannot find while it has a network is a source
        // that did not answer, not offline: the device decides, not the code.
        MusicSongsFailure.log(itemId: "sub:al-witness", URLError(.cannotFindHost))
        #expect(MusicSongsFailure.take("sub:al-witness"))
        #expect(!MusicSongsFailure.take("sub:al-witness"), "the mark is taken once")
        #expect(ShufflePlayButton.sentence(for: .server([], failed: true), isOnline: true).0
                == String(localized: "Couldn't load tracks"))
    }

    /// Every shuffle entry in the views, per file and by the form its pool
    /// takes: `fetched` for a source that turns a failure into an empty
    /// list, `server` for a music server's songs with their failure mark,
    /// `of` for a list already in hand, `passed` for a menu item that hands
    /// on the pool its caller built. A list fetched in place (`of-await`)
    /// is its own form and stands in no entry: a fetch that swallowed its
    /// failure reads as empty there. A new entry, or one that changes its
    /// form, moves a count and is read here with its reason.
    nonisolated static let entryStock: [String: (count: Int, reason: String)] = [
        "CatalogSourcePage.swift:fetched": (1, "albumSongs turns a failed release fetch into no songs"),
        "MusicLibraryPages.swift:fetched": (1, "shuffleLibrarySongItems turns a failed library fetch into no songs"),
        "MusicLibraryPages.swift:of": (1, "the playable songs of the page, already in hand"),
        "MusicView.swift:fetched": (1, "CatalogShuffleSongs turns a failed catalogue fetch into no songs"),
        "MusicView.swift:server": (1, "a server collection's songs with their failure mark"),
        "MusicView.swift:passed": (1, "the menu item hands on the pool its caller built"),
        "MusicAlbumView.swift:server": (1, "the album or playlist page's songs with their failure mark"),
        "PlaylistCard.swift:server": (1, "a server playlist's songs with their failure mark"),
        "PlaylistCard.swift:of": (1, "a local playlist's entries, already in hand"),
    ]

    /// The form of each shuffle entry in a text: the entry's line and the
    /// two after it, up to the first closing brace.
    nonisolated static func entryForms(in text: String) -> [String] {
        let lines = SyncContractFenceTests.stripped(text)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var forms: [String] = []
        for (index, line) in lines.enumerated()
        where line.contains("ShufflePlayButton(") || line.contains("shuffleDraw: {") || line.contains("songs: {") {
            let window = lines[index..<min(index + 3, lines.count)].joined(separator: "\n")
            let body = window.range(of: "}").map { String(window[..<$0.upperBound]) } ?? window
            if body.contains(".fetched(") { forms.append("fetched") }
            else if body.contains("serverPool(") { forms.append("server") }
            else if body.contains(".of(await") { forms.append("of-await") }
            else if body.contains(".of(") { forms.append("of") }
            else if body.contains("pool: songs") { forms.append("passed") }
            else { forms.append("unknown") }
        }
        return forms
    }

    @Test("der Leser der Zufall-Einstiege erkennt jede Form, auch ueber zwei Zeilen und im Kommentar nicht")
    func theEntryReaderSeesEveryForm() {
        #expect(Self.entryForms(in: "ShufflePlayButton(playerCoordinator: c, style: .icon) { .fetched(await a()) }") == ["fetched"])
        #expect(Self.entryForms(in: "ShufflePlayButton(playerCoordinator: c, style: .icon) {\n    await CollectionSongs.serverPool(id)\n}") == ["server"])
        #expect(Self.entryForms(in: "shuffleDraw: { .of(items) },") == ["of"])
        #expect(Self.entryForms(in: "shuffleDraw: { .of(await load()) },") == ["of-await"],
                "a list fetched in place is no list in hand")
        #expect(Self.entryForms(in: "ShufflePlayButton(playerCoordinator: c, style: .menuItem, pool: songs)\n}") == ["passed"])
        #expect(Self.entryForms(in: "songs: { .songs(await load()) },") == ["unknown"])
        #expect(Self.entryForms(in: "// ShufflePlayButton(playerCoordinator: c) { .of(x) }").isEmpty)
    }

    @Test("jeder Zufall-Einstieg der Ansichten steht mit seiner Form im Bestand, in beide Richtungen", .needsTheSources)
    func everyShuffleEntryIsInTheStock() throws {
        var counts: [String: Int] = [:]
        let files = SourceTree.files(under: SourceTree.root.appendingPathComponent("Sources/Views"))
            .filter { $0.pathExtension == "swift" }
        for file in files {
            for form in Self.entryForms(in: try String(contentsOf: file, encoding: .utf8)) {
                counts["\(file.lastPathComponent):\(form)", default: 0] += 1
            }
        }
        #expect(counts.values.reduce(0, +) >= 9, "the precondition: the reader found the entries: \(counts)")
        let drift = StockDrift.findings(counts: counts, stock: Self.entryStock.mapValues(\.count))
        #expect(drift.isEmpty, "a shuffle entry is new, gone or changed its form: \(drift)")
        #expect(Self.entryStock.values.allSatisfy { !$0.reason.isEmpty })
        let button = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/ShufflePlayButton.swift"), encoding: .utf8))
        #expect(button.contains("@Environment(\\.isOnline) private var isOnline"))
    }

    /// The body of `songItems(forItemId:)` in a provider file.
    static func songItemsBody(_ path: String) throws -> String {
        let source = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        let start = try #require(source.range(of: "func songItems(forItemId itemId: String) async -> [LibraryItem] {"))
        let rest = source[start.upperBound...]
        // The function ends at the first brace on its own indentation.
        let end = try #require(rest.range(of: "\n    }\n")).lowerBound
        return String(rest[..<end])
    }

    @Test("die Lieder eines Musikservers fallen nie still aus", .needsTheSources)
    func serverSongsNeverFailSilently() throws {
        for path in ["Sources/Providers/SubsonicProvider.swift", "Sources/Providers/JellyfinProvider.swift"] {
            let body = try Self.songItemsBody(path)
            #expect(body.contains("MusicSongsFailure.log(itemId: itemId, error)"), "\(path): no log line")
            #expect(!body.contains("try?"), "\(path): a fetch fails silently again")
        }
        let button = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/Music/ShufflePlayButton.swift"), encoding: .utf8))
        #expect(button.contains("await Self.start(pool: pool, isOnline: isOnline, coordinator: playerCoordinator)"))
        // The reader finds the body and stops at its end.
        let subsonic = try Self.songItemsBody("Sources/Providers/SubsonicProvider.swift")
        #expect(subsonic.contains("learnCovers(songs)"))
        #expect(!subsonic.contains("func "), "the reader ran into the next function")
    }
}
#endif
