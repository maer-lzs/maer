// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// No music surface says "none" without a server having been asked. One
/// decision (`MusicPageState`), one way to load (`MusicPageLoad`), one body
/// (`MusicPageBody`), and a fence over every view that asks the device's
/// music server.
@MainActor
struct MusicPageStateTests {
    private struct Boom: Error {}

    @Test("ohne Server nie leer und nie Fehler, ein Fehlschlag auf leerer Seite ist der Fehler, eine volle Seite bleibt")
    func theDecision() {
        #expect(MusicPageState.of(serverMissing: true, asked: true, isEmpty: true, isLoading: false, failure: nil) == .missing)
        #expect(MusicPageState.of(serverMissing: true, asked: true, isEmpty: true, isLoading: true, failure: "x") == .missing)
        #expect(MusicPageState.of(serverMissing: true, asked: true, isEmpty: false, isLoading: false, failure: nil) == .missing,
                "a server that went away replaces a full page with the way out")
        #expect(MusicPageState.of(serverMissing: false, asked: true, isEmpty: false, isLoading: false, failure: "x") == .content,
                "stale beats empty: a later failure keeps the page")
        #expect(MusicPageState.of(serverMissing: false, asked: true, isEmpty: true, isLoading: true, failure: nil) == .loading)
        #expect(MusicPageState.of(serverMissing: false, asked: true, isEmpty: true, isLoading: false, failure: "x") == .failed("x"))
        #expect(MusicPageState.of(serverMissing: false, asked: true, isEmpty: true, isLoading: false, failure: nil) == .empty)
    }

    @Test("eine Aenderung der Quellen fragt die Erreichbarkeit immer, laedt nur, wo vorher kein Server war")
    func theSourcesChange() {
        #expect(MusicPageState.onSourcesChange(reachableNow: false, wasMissing: false, asked: true) == .showMissing)
        #expect(MusicPageState.onSourcesChange(reachableNow: false, wasMissing: true, asked: true) == .keep)
        #expect(MusicPageState.onSourcesChange(reachableNow: true, wasMissing: true, asked: true) == .reload)
        #expect(MusicPageState.onSourcesChange(reachableNow: true, wasMissing: false, asked: true) == .keep,
                "a page with its server is not asked again")
        #expect(MusicPageState.onSourcesChange(reachableNow: true, wasMissing: false, asked: false) == .reload,
                "a page that never asked and whose server came loads")
        #expect(MusicPageState.onSourcesChange(reachableNow: false, wasMissing: false, asked: false) == .showMissing)
        // Another account answers: a full page starts over.
        #expect(MusicPageState.onSourcesChange(reachableNow: true, wasMissing: false, asked: true, accountChanged: true) == .startOver)
        #expect(MusicPageState.onSourcesChange(reachableNow: false, wasMissing: false, asked: true, accountChanged: true) == .showMissing)
    }

    @Test("nach einem Kontowechsel verwirft die Musikseite die Listen des frueheren Kontos, auch wenn das Laden des neuen scheitert")
    @MainActor
    func anAccountSwitchDropsTheFormerLists() async throws {
        @MainActor final class Server { var account = "a"; var fails = false }
        let server = Server()
        let source = MusicSource(
            albumsPage: { _, _, _ in [] },
            shelf: { _, _ in [] },
            artists: { [] },
            playlists: {
                if server.fails { throw Boom() }
                return [MusicPlaylist(id: server.account, itemId: server.account, name: server.account,
                                      songCount: 1, duration: nil, changedAt: nil)]
            })
        let model = MusicViewModel(source: source)
        await model.loadIfNeeded()
        #expect(model.playlists.map(\.id) == ["a"])
        // Another user at the same server; the new account's lists fail.
        server.account = "b"
        server.fails = true
        MusicAccountSwitch.generation += 1
        await model.sourcesChanged()
        #expect(model.playlists.isEmpty, "the former account's playlists stayed: \(model.playlists.map(\.id))")
        // The next change loads the new account's.
        server.fails = false
        MusicAccountSwitch.generation += 1
        await model.sourcesChanged()
        #expect(model.playlists.map(\.id) == ["b"])
    }

    @Test("der Ladeweg fragt zuerst den Server, ein Fehlschlag wird der Satz der Seite, ein Abbruch entscheidet nichts")
    func theLoad() async {
        var asked = 0
        let current = { true }
        let missing = await MusicPageLoad.run("probe", reachable: false, isCurrent: current) { asked += 1; return [1] }
        #expect(missing.isMissing && missing.value == nil && missing.failure == nil)
        #expect(asked == 0, "without a server nothing is asked")

        let loaded = await MusicPageLoad.run("probe", reachable: true, isCurrent: current) { asked += 1; return [1, 2] }
        #expect(loaded.value == [1, 2] && !loaded.isMissing && loaded.failure == nil)
        #expect(asked == 1)

        let failed = await MusicPageLoad.run("probe", reachable: true, isCurrent: current) { () async throws -> [Int] in
            throw Boom()
        }
        #expect(failed.failure == ErrorSentence.of(Boom()), "a failure is the page's sentence, never an empty list")
        #expect(failed.value == nil && !failed.isMissing && !failed.isCancelled)

        let cancelled = await MusicPageLoad.run("probe", reachable: true, isCurrent: current) { () async throws -> [Int] in
            throw CancellationError()
        }
        #expect(cancelled.isCancelled && cancelled.failure == nil && cancelled.value == nil)
    }

    // MARK: - Superseded runs

    @Test("ein Zuruecksetzen waehrend eines Laufs: der alte Lauf ist ueberholt, ein neuer beginnt, das spaete Ende des alten gibt den neuen nicht frei")
    func thePageRuns() throws {
        var runs = PageRuns()
        let begun = runs.begin()
        let first = try #require(begun)
        #expect(runs.isRunning && runs.begin() == nil, "one page at a time within a generation")
        runs.reset()
        #expect(!runs.isCurrent(first) && !runs.isRunning, "the old run is past its page")
        let begunAgain = runs.begin()
        let second = try #require(begunAgain, "the new generation loads right away")
        runs.end(first)
        #expect(runs.isRunning && runs.begin() == nil, "the late end of the old run leaves the new one running")
        runs.end(second)
        #expect(!runs.isRunning && runs.isCurrent(second))
        let whole = runs.reset()
        let newer = runs.reset()
        #expect(!runs.isCurrent(whole) && runs.isCurrent(newer), "a whole load is a new generation each time, the newest wins")
    }

    /// The fetch answers only after the page was reset: the answer, value
    /// or failure, decides nothing.
    @Test("ein Holer, der nach dem Zuruecksetzen antwortet, entscheidet nichts")
    func aSupersededRunDecidesNothing() async {
        final class Page { var runs = PageRuns() }
        let page = Page()
        let run = page.runs.reset()
        let late = await MusicPageLoad.run("probe", reachable: true, isCurrent: { page.runs.isCurrent(run) }) {
            // The reload happens while this answer is on its way.
            page.runs.reset()
            return [7, 8]
        }
        #expect(late.isCancelled && late.value == nil, "the old answer does not land on the new list")

        let run2 = page.runs.reset()
        let lateFailure = await MusicPageLoad.run("probe", reachable: true, isCurrent: { page.runs.isCurrent(run2) }) {
            () async throws -> [Int] in
            page.runs.reset()
            throw Boom()
        }
        #expect(lateFailure.isCancelled && lateFailure.failure == nil,
                "nor does its failure become the new page's sentence")

        let run3 = page.runs.reset()
        let onTime = await MusicPageLoad.run("probe", reachable: true, isCurrent: { page.runs.isCurrent(run3) }) { [9] }
        #expect(onTime.value == [9], "the precondition: an answer of the current run lands")
    }

    // MARK: - Fence

    /// Every view that asks the device's music server (`musicProvider`
    /// without `(for:` or `(serving:`, which name another source) draws
    /// `MusicPageBody` and listens to the sources, or stands in the stock
    /// with its reason.
    nonisolated static let stock: [String: String] = [
        "HomeView": "its music rows hide themselves when empty and never say none; the rows are their own point",
    ]

    /// The views in one file that ask the device's music server, each with
    /// whether it draws the body and listens to the sources.
    nonisolated static func surfaces(in raw: String) -> [(name: String, drawsBody: Bool, listens: Bool)] {
        musicViews(in: raw).map { view in
            (view.name, view.body.contains("MusicPageBody("),
             view.body.contains(".onMusicSourcesChange") || view.body.contains(".reasksOnSourcesChange("))
        }
    }

    /// The views in one file that ask the device's music server, with the
    /// code of each, found by structure (the view declaration up to the next
    /// type), not by how a call is wrapped.
    nonisolated static func musicViews(in raw: String) -> [(name: String, body: String)] {
        let code = SyncContractFenceTests.stripped(raw)
        let start = #/(?m)^(?:private |fileprivate )?struct (\w+)(?:<[^>\n]*>)?\s*:\s*View\b/#
        let next = #/(?m)^(?:private |fileprivate |final |@MainActor )*(?:struct|class|enum|extension|actor) /#
        let asks = #/(?:^|[^A-Za-z0-9_])musicProvider(?![A-Za-z0-9_(])/#
        var found: [(String, String)] = []
        var rest = code[...]
        while let head = rest.firstMatch(of: start) {
            let afterHead = rest[head.range.upperBound...]
            let end = afterHead.firstMatch(of: next)?.range.lowerBound ?? afterHead.endIndex
            let body = String(afterHead[..<end])
            if body.contains(asks) { found.append((String(head.1), body)) }
            rest = afterHead[end...]
        }
        return found
    }

    @Test("der Zaun erkennt eine Flaeche ohne Huelle und uebersieht einen anderen Server")
    func theFenceSeesTheClass() {
        let bare = """
        struct Bare: View {
            var body: some View { Text("x") }
            func load() async { _ = try? await AppSession.shared.musicProvider.genres() }
        }
        struct Named: View {
            func load() async { _ = AppSession.shared.musicProvider(for: id) }
        }
        struct Good: View {
            private var music: MusicProvider { AppSession.shared.musicProvider }
            var body: some View { MusicPageBody(state: .empty, emptyTitle: "x", retry: {}) { EmptyView() }
                .reasksOnSourcesChange(serverMissing: $m, reachable: { true }, reload: {}) }
        }
        """
        let found = Self.surfaces(in: bare)
        #expect(found.map(\.name) == ["Bare", "Good"], "the receiver form is seen, a named source is not")
        #expect(found.first { $0.name == "Bare" }.map { !$0.drawsBody && !$0.listens } == true)
        #expect(found.first { $0.name == "Good" }.map { $0.drawsBody && $0.listens } == true)
    }

    @Test("jede Flaeche, die den Musik-Server des Geraets fragt, zeichnet die Huelle und hoert auf die Quellen", .needsTheSources)
    func everyMusicSurfaceAsksBeforeItSaysNone() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = SourceTree.files(under: sources)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 100, "the fence read the sources")
        var all: [String] = []
        var offenders: [String] = []
        for file in files {
            for surface in Self.surfaces(in: try String(contentsOf: file, encoding: .utf8)) {
                all.append(surface.name)
                if Self.stock[surface.name] == nil, !(surface.drawsBody && surface.listens) {
                    offenders.append("\(file.lastPathComponent) \(surface.name) body=\(surface.drawsBody) listens=\(surface.listens)")
                }
            }
        }
        #expect(offenders.isEmpty, "a music surface says none without asking: \(offenders)")
        #expect(Set(all).isSuperset(of: ["MusicView", "MusicAlbumsPage", "MusicSongsPage", "MusicGenresPage",
                                          "MusicGenreDetailPage", "MusicShelfPage"]),
                "the fence found the surfaces it guards: \(all.sorted())")
        let unused = Set(Self.stock.keys).subtracting(all)
        #expect(unused.isEmpty, "a stock entry without its surface goes: \(unused)")
    }

    /// Every load of a page hands in the provider's own answer whether a
    /// server is there; a fixed value would skip the question the whole
    /// point is about. And every load names the run it belongs to
    /// (`isCurrent:` from the page's `PageRuns`), so a superseded answer is
    /// dropped in the one place.
    @Test("jeder Ladeweg einer Musik-Seite fragt die Erreichbarkeit des Anbieters und nennt seinen Lauf", .needsTheSources)
    func everyPageLoadAsksTheProvider() throws {
        let file = SourceTree.root.appendingPathComponent("Sources/Views/Music/MusicLibraryPages.swift")
        let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
        let calls = code.components(separatedBy: "MusicPageLoad.run(").dropFirst()
        #expect(calls.count == 5, "songs, genres, both halves of a genre, the shelf: \(calls.count)")
        let unasked = calls.filter { call in
            let head = call.prefix { $0 != "{" }
            return !head.contains("reachable: provider.isAvailable,")
        }
        #expect(unasked.isEmpty, "a page load that does not ask the provider: \(unasked.map { $0.prefix(80) })")
        let unnamed = calls.filter { call in
            // The run is the closure right after `isCurrent:`, before the fetch.
            guard let range = call.range(of: "isCurrent: {") else { return true }
            return !call[range.upperBound...].prefix { $0 != "}" }.contains("uns.isCurrent(run)")
        }
        #expect(unnamed.isEmpty, "a page load without its run: \(unnamed.map { $0.prefix(80) })")
        #expect(code.contains("MusicPageLoad.superseded(\"jamendo shelf\", runs.isCurrent(run))"),
                "the page with its own loader asks the same rule")
    }

    /// Before its first run a page has asked nothing: an empty page loads,
    /// it says neither "none" nor an error.
    @Test("vor dem ersten Lauf sagt keine Seite leer, sie laedt")
    func beforeTheFirstRunThePageLoads() {
        #expect(MusicPageState.of(serverMissing: false, asked: false, isEmpty: true, isLoading: false, failure: nil) == .loading,
                "the first frame said none before the server was asked")
        #expect(MusicPageState.of(serverMissing: false, asked: false, isEmpty: true, isLoading: false, failure: "x") == .loading)
        #expect(MusicPageState.of(serverMissing: true, asked: false, isEmpty: true, isLoading: false, failure: nil) == .missing)
        var runs = PageRuns()
        #expect(!runs.hasStarted)
        runs.reset()
        #expect(runs.hasStarted, "a whole load counts as asked")
        var paged = PageRuns()
        _ = paged.begin()
        #expect(paged.hasStarted, "a paged load counts as asked")
    }

    /// The surfaces that draw `MusicPageBody`, found by structure. Held in
    /// both directions: a new surface is a finding, so is one that left.
    nonisolated static let bodySurfaces: Set<String> =
        ["MusicView", "MusicAlbumsPage", "MusicSongsPage", "MusicGenresPage", "MusicGenreDetailPage", "MusicShelfPage"]

    /// Every surface that draws `MusicPageBody` passes whether it has asked,
    /// from its runs, never a fixed answer, both to the body and to the
    /// change of the sources.
    @Test("jede Seite mit dem Musik-Koerper sagt, ob sie schon gefragt hat, aus ihren Laeufen", .needsTheSources)
    func everyPageSaysWhetherItAsked() throws {
        let views = SourceTree.root.appendingPathComponent("Sources/Views")
        let files = SourceTree.files(under: views).filter { $0.pathExtension == "swift" }
        var drawing: Set<String> = []
        for file in files {
            for view in Self.musicViews(in: try String(contentsOf: file, encoding: .utf8))
            where view.body.contains("MusicPageBody(") {
                drawing.insert(view.name)
                let flat = view.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                #expect(flat.contains("asked: vm.hasAsked,") || flat.contains("asked: runs.hasStarted,"),
                        "\(view.name) does not answer asked from its runs")
                #expect(!flat.contains("asked: true") && !flat.contains("asked: false"),
                        "\(view.name) answers asked with a fixed value")
                if flat.contains(".reasksOnSourcesChange(") {
                    #expect(flat.contains("asked: { runs.hasStarted }"), "\(view.name) listens without saying whether it asked")
                }
            }
        }
        #expect(drawing == Self.bodySurfaces, "the surfaces that draw the music body changed: \(drawing.sorted())")
    }
}
#endif
