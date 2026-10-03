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
        #expect(MusicPageState.of(serverMissing: true, isEmpty: true, isLoading: false, failure: nil) == .missing)
        #expect(MusicPageState.of(serverMissing: true, isEmpty: true, isLoading: true, failure: "x") == .missing)
        #expect(MusicPageState.of(serverMissing: true, isEmpty: false, isLoading: false, failure: nil) == .missing,
                "a server that went away replaces a full page with the way out")
        #expect(MusicPageState.of(serverMissing: false, isEmpty: false, isLoading: false, failure: "x") == .content,
                "stale beats empty: a later failure keeps the page")
        #expect(MusicPageState.of(serverMissing: false, isEmpty: true, isLoading: true, failure: nil) == .loading)
        #expect(MusicPageState.of(serverMissing: false, isEmpty: true, isLoading: false, failure: "x") == .failed("x"))
        #expect(MusicPageState.of(serverMissing: false, isEmpty: true, isLoading: false, failure: nil) == .empty)
    }

    @Test("eine Aenderung der Quellen fragt die Erreichbarkeit immer, laedt nur, wo vorher kein Server war")
    func theSourcesChange() {
        #expect(MusicPageState.onSourcesChange(reachableNow: false, wasMissing: false) == .showMissing)
        #expect(MusicPageState.onSourcesChange(reachableNow: false, wasMissing: true) == .keep)
        #expect(MusicPageState.onSourcesChange(reachableNow: true, wasMissing: true) == .reload)
        #expect(MusicPageState.onSourcesChange(reachableNow: true, wasMissing: false) == .keep,
                "a page with its server is not asked again")
    }

    @Test("der Ladeweg fragt zuerst den Server, ein Fehlschlag wird der Satz der Seite, ein Abbruch entscheidet nichts")
    func theLoad() async {
        var asked = 0
        let missing = await MusicPageLoad.run("probe", reachable: false) { asked += 1; return [1] }
        #expect(missing.isMissing && missing.value == nil && missing.failure == nil)
        #expect(asked == 0, "without a server nothing is asked")

        let loaded = await MusicPageLoad.run("probe", reachable: true) { asked += 1; return [1, 2] }
        #expect(loaded.value == [1, 2] && !loaded.isMissing && loaded.failure == nil)
        #expect(asked == 1)

        let failed = await MusicPageLoad.run("probe", reachable: true) { () async throws -> [Int] in throw Boom() }
        #expect(failed.failure == ErrorSentence.of(Boom()), "a failure is the page's sentence, never an empty list")
        #expect(failed.value == nil && !failed.isMissing && !failed.isCancelled)

        let cancelled = await MusicPageLoad.run("probe", reachable: true) { () async throws -> [Int] in throw CancellationError() }
        #expect(cancelled.isCancelled && cancelled.failure == nil && cancelled.value == nil)
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
        let code = SyncContractFenceTests.stripped(raw)
        let start = #/(?m)^(?:private |fileprivate )?struct (\w+)(?:<[^>\n]*>)?\s*:\s*View\b/#
        let next = #/(?m)^(?:private |fileprivate |final |@MainActor )*(?:struct|class|enum|extension|actor) /#
        let asks = #/(?:^|[^A-Za-z0-9_])musicProvider(?![A-Za-z0-9_(])/#
        var found: [(String, Bool, Bool)] = []
        var rest = code[...]
        while let head = rest.firstMatch(of: start) {
            let afterHead = rest[head.range.upperBound...]
            let end = afterHead.firstMatch(of: next)?.range.lowerBound ?? afterHead.endIndex
            let body = String(afterHead[..<end])
            if body.contains(asks) {
                found.append((String(head.1), body.contains("MusicPageBody("),
                              body.contains(".onMusicSourcesChange") || body.contains(".reasksOnSourcesChange(")))
            }
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
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
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
    /// point is about.
    @Test("jeder Ladeweg einer Musik-Seite fragt die Erreichbarkeit des Anbieters", .needsTheSources)
    func everyPageLoadAsksTheProvider() throws {
        let file = SourceTree.root.appendingPathComponent("Sources/Views/Music/MusicLibraryPages.swift")
        let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
        let calls = code.components(separatedBy: "MusicPageLoad.run(").dropFirst()
        #expect(calls.count == 5, "songs, genres, both halves of a genre, the shelf: \(calls.count)")
        let unasked = calls.filter { call in
            let head = call.prefix { $0 != "{" }
            return !head.contains("reachable: provider.isAvailable)")
        }
        #expect(unasked.isEmpty, "a page load that does not ask the provider: \(unasked.map { $0.prefix(80) })")
    }
}
#endif
