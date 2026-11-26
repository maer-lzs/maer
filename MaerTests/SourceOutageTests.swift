// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A source that stops answering: Gutenberg's main server answers 5xx and
/// its mirror pglaf has the same files (the record and covers at the same
/// path, the sound files under the number's digits); Radio Browser is one
/// machine, and its failure is said as the source's, not as the network's.
@MainActor
struct SourceOutageTests {
    static let www = "https://www.gutenberg.org"
    static let pglaf = "https://gutenberg.pglaf.org"

    static func answer(_ url: URL, _ status: Int) -> (Data, HTTPURLResponse?) {
        (Data("x".utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    }

    /// The ask of a witness: answers by host, records every request.
    /// Unchecked because one test owns it and asks it in sequence.
    final class Asked: @unchecked Sendable {
        var urls: [URL] = []
        var headers: [[String: String]] = []
        var timeouts: [TimeInterval] = []
        var byHost: [String: Int] = [:]
        func ask(_ request: URLRequest) async throws -> (Data, HTTPURLResponse?) {
            let url = try #require(request.url)
            urls.append(url)
            headers.append(request.allHTTPHeaderFields ?? [:])
            timeouts.append(request.timeoutInterval)
            return SourceOutageTests.answer(url, byHost[url.host() ?? ""] ?? 200)
        }
    }

    // MARK: Gutenberg, the address on pglaf

    @Test("pglaf: the record, the covers and the dump at the same path, a sound file under every digit but the last, a single digit under 0")
    func mirrorTable() {
        func mirror(_ path: String) -> String? { GutenbergRoute.mirror(of: URL(string: Self.www + path)!)?.absoluteString }
        #expect(mirror("/cache/epub/9272/pg9272.rdf") == Self.pglaf + "/cache/epub/9272/pg9272.rdf")
        #expect(mirror("/cache/epub/1342/pg1342.cover.medium.jpg") == Self.pglaf + "/cache/epub/1342/pg1342.cover.medium.jpg")
        #expect(mirror("/cache/epub/feeds/pg_catalog.csv") == Self.pglaf + "/cache/epub/feeds/pg_catalog.csv")
        #expect(mirror("/files/9272/mp3/9272-000.mp3") == Self.pglaf + "/9/2/7/9272/mp3/9272-000.mp3")
        #expect(mirror("/files/1/mp3/1-01.mp3") == Self.pglaf + "/0/1/mp3/1-01.mp3")
        #expect(mirror("/files/9/a.mp3") == Self.pglaf + "/0/9/a.mp3")
        #expect(mirror("/files/10/a.mp3") == Self.pglaf + "/1/10/a.mp3")
        #expect(mirror("/files/12/a.mp3") == Self.pglaf + "/1/12/a.mp3")
        #expect(mirror("/files/123/a.mp3") == Self.pglaf + "/1/2/123/a.mp3")
        #expect(mirror("/files/10001/a.mp3") == Self.pglaf + "/1/0/0/0/10001/a.mp3")
        #expect(mirror("/ebooks/9272") == nil, "a page is no file")
        #expect(mirror("/files/abc/a.mp3") == nil)
        #expect(GutenbergRoute.mirror(of: URL(string: "http://www.gutenberg.org/cache/epub/1/pg1.rdf")!) == nil, "only https")
        #expect(GutenbergRoute.mirror(of: URL(string: "https://gutendex.com/books/")!) == nil)
    }

    @Test("pglaf is asked after a 5xx or while www rests, never after a 404 or a 429")
    func whenTheMirror() {
        #expect(GutenbergRoute.asksMirror(status: 503, resting: false))
        #expect(GutenbergRoute.asksMirror(status: 500, resting: false))
        #expect(GutenbergRoute.asksMirror(status: nil, resting: true))
        #expect(!GutenbergRoute.asksMirror(status: 404, resting: false), "an absence is a finding")
        #expect(!GutenbergRoute.asksMirror(status: 200, resting: false))
        #expect(!GutenbergRoute.asksMirror(status: nil, resting: false))
    }

    // MARK: Gutenberg, the ways through the door

    @Test("www answers 503: one request to pglaf, with the same headers, and its answer stands")
    func fetchFallsBack() async throws {
        let asked = Asked()
        asked.byHost = ["www.gutenberg.org": 503]
        var request = URLRequest(url: URL(string: Self.www + "/cache/epub/feeds/pg_catalog.csv")!)
        request.setValue("bytes=0-99", forHTTPHeaderField: "Range")
        let (_, response) = try await GutenbergMirror.fetch(request, rests: { _ in false }, ask: asked.ask)
        #expect(asked.urls.map { $0.host() ?? "" } == ["www.gutenberg.org", "gutenberg.pglaf.org"])
        #expect(asked.headers.last?["Range"] == "bytes=0-99")
        #expect(response?.statusCode == 200)
    }

    @Test("pglaf answers large records slowly: its request waits at least a minute, a longer wait of the caller stays")
    func mirrorWaitsLonger() async throws {
        let asked = Asked()
        asked.byHost = ["www.gutenberg.org": 503]
        var request = URLRequest(url: URL(string: Self.www + "/cache/epub/26471/pg26471.rdf")!)
        request.timeoutInterval = 20
        _ = try await GutenbergMirror.fetch(request, rests: { _ in false }, ask: asked.ask)
        #expect(asked.timeouts == [20, 60])
        request.timeoutInterval = 120
        let again = Asked()
        _ = try await GutenbergMirror.fetch(request, rests: { _ in true }, ask: again.ask)
        #expect(again.timeouts == [120])
    }

    @Test("www rests: pglaf at once, www is not asked")
    func restingGoesStraight() async throws {
        let asked = Asked()
        _ = try await GutenbergMirror.fetch(URLRequest(url: URL(string: Self.www + "/cache/epub/1/pg1.rdf")!),
                                            rests: { $0.host() == "www.gutenberg.org" }, ask: asked.ask)
        #expect(asked.urls.map { $0.host() ?? "" } == ["gutenberg.pglaf.org"])
    }

    @Test("both answer 503: one request each, no second round, the answer of www stands")
    func bothFail() async throws {
        let asked = Asked()
        asked.byHost = ["www.gutenberg.org": 503, "gutenberg.pglaf.org": 503]
        let (_, response) = try await GutenbergMirror.fetch(URLRequest(url: URL(string: Self.www + "/cache/epub/1/pg1.rdf")!),
                                                            rests: { _ in false }, ask: asked.ask)
        #expect(asked.urls.count == 2)
        #expect(response?.statusCode == 503)
    }

    @Test("a 404 of www does not go to pglaf; another host never does")
    func noMirrorForAbsence() async throws {
        let asked = Asked()
        asked.byHost = ["www.gutenberg.org": 404, "gutendex.com": 503]
        _ = try await GutenbergMirror.fetch(URLRequest(url: URL(string: Self.www + "/cache/epub/1/pg1.rdf")!),
                                            rests: { _ in false }, ask: asked.ask)
        _ = try await GutenbergMirror.fetch(URLRequest(url: URL(string: "https://gutendex.com/books/")!),
                                            rests: { _ in true }, ask: asked.ask)
        #expect(asked.urls.map { $0.host() ?? "" } == ["www.gutenberg.org", "gutendex.com"])
    }

    @Test("the record: a server error keeps nothing and is the case of its own, said today with the old sentence")
    func recordUnavailable() async throws {
        let works = GutenbergWorks(wire: GutenbergWorks.Wire(record: { _ in (Data(), 503) }, duration: { _ in .unreadable }),
                                   suiteName: "outage-\(UUID().uuidString)")
        await #expect(throws: GutenbergUnavailable.self) { _ = try await works.work(number: 9272) }
        #expect(ErrorSentence.of(GutenbergUnavailable()) == String(localized: "Something went wrong. Please try again."))
    }

    // MARK: Gutenberg, the ways past the door

    @Test("a stream, a download and a duration read: pglaf while www rests, www otherwise; the next track asks pglaf too")
    func addressPastTheDoor() {
        let first = URL(string: Self.www + "/files/9272/mp3/9272-000.mp3")!
        let second = URL(string: Self.www + "/files/9272/mp3/9272-001.mp3")!
        let resting: (URL) -> Bool = { $0.host() == "www.gutenberg.org" }
        #expect(GutenbergMirror.address(for: first, rests: resting).host() == "gutenberg.pglaf.org")
        #expect(GutenbergMirror.address(for: second, rests: resting).host() == "gutenberg.pglaf.org", "the next track asks www again")
        #expect(GutenbergMirror.address(for: first, rests: { _ in false }) == first)
        let other = URL(string: "https://ia800.us.archive.org/1/a.mp3")!
        #expect(GutenbergMirror.address(for: other, rests: { _ in true }) == other)
    }

    @Test("Fence: every way to Gutenberg passes the mirror rule; pglaf is named only by the rule; what is kept carries www", .needsTheSources)
    func everyWay() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        // The door: covers (`Artwork`), the dump (`CatalogStockFetch`) and
        // every other data request pass `HTTP.data`.
        #expect(try code("Sources/Networking/HTTP.swift").contains("GutenbergMirror.fetch("))
        let works = try code("Sources/Networking/GutenbergWorks.swift")
        #expect(works.contains("GutenbergMirror.fetch("), "the record")
        #expect(works.contains("GutenbergMirror.address(for: url)"), "the duration read")
        #expect(try code("Sources/ViewModels/PlayerViewModel.swift").contains("AVURLAsset(url: target.url.viaGutenbergMirror"), "the stream")
        #expect(try code("Sources/Networking/FileDownloader.swift").contains("GutenbergMirror."), "the download")
        for file in ProjectFileIntegrityTests.sourceFiles() where !file.path.hasSuffix("GutenbergRoute.swift") {
            #expect(!SyncContractFenceTests.stripped(try SourceTree.text(file)).contains("pglaf"), "\(file.lastPathComponent) names pglaf")
        }
        #expect(!works.contains("GutenbergRoute.mirror("), "a kept part carries the address of www")
    }

    @Test("Fence: a Gutenberg track that failed for the server asks www once, then rebuilds at the held place through pglaf", .needsTheSources)
    func trackFailure() throws {
        let player = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8))
        #expect(player.contains("await GutenbergMirror.probe("))
        #expect(player.contains("rebuildAtHeldPosition(reason: \"gutenberg mirror\")"))
    }

    @Test("after the wait for www: the same title and queue rebuild through pglaf or go the usual way; another title, a stop or a new queue do nothing")
    func afterTheWait() {
        let asked = GutenbergMirrorStep.Moment(itemId: "gut:9272", queueBuild: 3, stopped: false)
        #expect(GutenbergMirrorStep.next(asked: asked, now: asked, down: true) == .rebuild)
        #expect(GutenbergMirrorStep.next(asked: asked, now: asked, down: false) == .usual)
        var other = asked; other.itemId = "gut:1342"
        #expect(GutenbergMirrorStep.next(asked: asked, now: other, down: true) == .nothing, "another title in the window")
        var stopped = asked; stopped.stopped = true
        #expect(GutenbergMirrorStep.next(asked: asked, now: stopped, down: true) == .nothing, "a stop or a sign out in the window")
        #expect(GutenbergMirrorStep.next(asked: asked, now: stopped, down: false) == .nothing)
        var rebuilt = asked; rebuilt.queueBuild = 4
        #expect(GutenbergMirrorStep.next(asked: asked, now: rebuilt, down: true) == .nothing, "the queue that failed is gone")
    }

    @Test("Fence: the step takes its moment before the wait and asks the rule after it", .needsTheSources)
    func stepAsksAfterTheWait() throws {
        let player = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8))
        let step = try #require(player.range(of: "private func gutenbergMirrorStep("))
        let body = String(player[step.lowerBound...].prefix(2_000))
        let moment = try #require(body.range(of: "let asked = mirrorMoment()"))
        let wait = try #require(body.range(of: "await GutenbergMirror.probe("))
        let rule = try #require(body.range(of: "GutenbergMirrorStep.next(asked: asked, now: self.mirrorMoment(), down: down)"))
        #expect(moment.lowerBound < wait.lowerBound && wait.lowerBound < rule.lowerBound)
        #expect(player.contains("queueBuilds += 1"), "a built queue counts")
    }

    // MARK: Radio Browser

    @Test("the list is de1, then all; the source's hosts are the same")
    func radioList() {
        #expect(RadioBrowserClient.mirrors == ["https://de1.api.radio-browser.info", "https://all.api.radio-browser.info"])
        #expect(ExternalSources.radioBrowser.hosts == ["de1.api.radio-browser.info", "all.api.radio-browser.info"])
    }

    @Test("the error that counts: an answer over a timeout over a host not found; on a tie the first of the list")
    func weightiest() {
        let answer = URLError(.badServerResponse)
        let timeout = URLError(.timedOut)
        let notFound = URLError(.cannotFindHost)
        #expect((RadioBrowserClient.weightiest([answer, notFound]) as? URLError)?.code == .badServerResponse)
        #expect((RadioBrowserClient.weightiest([notFound, timeout]) as? URLError)?.code == .timedOut)
        #expect((RadioBrowserClient.weightiest([timeout, answer]) as? URLError)?.code == .badServerResponse)
        let firstNotFound = URLError(.cannotFindHost, userInfo: ["n": 1])
        #expect((RadioBrowserClient.weightiest([firstNotFound, notFound]) as? URLError)?.userInfo["n"] as? Int == 1)
    }

    @Test("every server failed: online the source's sentence, offline the network's")
    func radioSentence() {
        #expect(RadioFailureLine.sentence(online: true) == String(localized: "The source did not answer."))
        #expect(RadioFailureLine.sentence(online: false) == nil, "offline the failed view keeps its own sentence")
    }

    @Test("rows that stand after a failed run get a line; it goes when a run answers; an answered run never shows it")
    func staleLine() {
        #expect(RadioStore.showsStaleLine(after: .keep))
        #expect(!RadioStore.showsStaleLine(after: .replace), "an answer takes the line away, also when only a fallback server failed")
        #expect(!RadioStore.showsStaleLine(after: .failed), "nothing stands: the page says it")
    }

    @Test("Fence: the tab says the line over standing rows and its failed view takes the source's sentence", .needsTheSources)
    func radioSurfaces() throws {
        let view = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Views/Radio/RadioView.swift"), encoding: .utf8))
        #expect(view.contains("RadioStore.showsStaleLine(after:"))
        #expect(view.contains("RadioFailureLine.sentence(online:"))
    }

    // MARK: Removals of a stand

    @Test("Fence: a removal is queued only by the cleanup of a carrier with a room limit, and no Mär Sync carrier has one; otherwise the removal needs its moment", .needsTheSources)
    func removalsOnlyFromTheCleanup() throws {
        var nonEmpty: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = SyncContractFenceTests.stripped(try SourceTree.text(file))
            for line in text.components(separatedBy: "\n") where line.contains(".write(upserts:") && !line.contains("removing: [],") {
                nonEmpty.append("\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(nonEmpty.count == 2 && nonEmpty.allSatisfy { $0.hasPrefix("PodcastCloudSync.swift") || $0.hasPrefix("CloudKitStandCarrier.swift") },
                "a second way queues removals; then a removal must carry the moment it saw: \(nonEmpty)")
        let carriers = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Networking/MaerSyncCarriers.swift"), encoding: .utf8))
        #expect(carriers.components(separatedBy: "var hasRoomLimit: Bool { false }").count - 1 == 2,
                "a Mär Sync carrier with a room limit queues removals without a moment")
    }
}
#endif
