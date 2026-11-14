// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A station from a link: the link names a real station's id, so its name
/// and stream must come from the catalog, never from the link. A link built
/// by hand with a real id and a foreign stream would otherwise put that
/// stream under the real station, and it would travel with the recent
/// stations and the choices to every device.
@MainActor
struct SharedLinkStationTests {
    static let uuid = "9617a958-0601-11e8-ae97-52543be04c81"
    static let foreign = "https://foreign.example/stream.mp3"
    static let catalog = RadioStation(id: "radio:rb:\(uuid)", name: "Deutschlandfunk", streamURL: "https://st01.dlf.de/dlf/01/128/mp3/stream.mp3")

    private func opener(resolve: @escaping (String) async -> SharedLinkOpener.StationLookup) -> SharedLinkOpener {
        SharedLinkOpener(staysHome: { _ in false }, knows: { _ in false },
                         browse: { _ in false }, resolveCatalog: { _ in false }, resolveStation: resolve)
    }

    @Test("a link with a real id and a foreign stream never opens the station with a name or stream from the link")
    func aStationFromALinkNeverCarriesTheLinksStream() async throws {
        let opener = opener { $0 == Self.uuid ? .found(Self.catalog) : .unknown }
        let url = try #require(SharedLink.url(for: .station(uuid: Self.uuid, .init(title: "Fremd", audioURL: Self.foreign))))
        let outcome = await opener.outcome(for: url)
        guard case .station(let station) = outcome else {
            Issue.record("the precondition: the link opens the station: \(outcome)"); return
        }
        #expect(station.streamURL != Self.foreign, "the station plays the link's stream")
        #expect(station.name != "Fremd", "the station carries the link's name")
        #expect(station == Self.catalog, "the station is not the catalog's")
    }

    @Test("if the catalog does not find the id, or names another station, the link opens nothing")
    func aStationTheCatalogDoesNotConfirmOpensNothing() async throws {
        let url = try #require(SharedLink.url(for: .station(uuid: Self.uuid, .init(title: "Fremd", audioURL: Self.foreign))))
        #expect(await opener { _ in .unknown }.outcome(for: url) == .refused(reason: "stationUnknown"))
        let other = RadioStation(id: "radio:rb:00000000-0000-0000-0000-000000000000", name: "Other", streamURL: "https://other.example/s")
        #expect(await opener { _ in .found(other) }.outcome(for: url) == .refused(reason: "stationUnknown"))
    }

    @Test("a station the catalog gave no answer for opens its page with Retry, and a switched off source opens it without")
    func aStationWithoutAnAnswerOpensItsPage() async throws {
        let url = try #require(SharedLink.url(for: .station(uuid: Self.uuid, .init(title: "Fremd", audioURL: Self.foreign))))
        let notLoaded = await opener { _ in .notLoaded }.outcome(for: url)
        #expect(notLoaded == .stationPage(uuid: Self.uuid, .notLoaded), "a catalog without an answer reads as a station it does not know")
        guard case .radioStationLink(let uuid, let gap) = SharedLinkOpener.target(of: notLoaded) else {
            Issue.record("a station that did not load opens no page"); return
        }
        #expect(uuid == Self.uuid && gap == .notLoaded)
        #expect(SharedLinkOpener.sentence(for: notLoaded) == nil, "a station that did not load still says a sentence instead of its page")
        let off = await opener { _ in .sourceOff }.outcome(for: url)
        #expect(off == .stationPage(uuid: Self.uuid, .sourceOff), "a switched off source reads as a catalog without an answer")
        #expect(SharedLinkOpener.target(of: off) != nil, "a switched off source opens no page")
    }

    @Test("the page opens in the state of its gap, and Retry turns it into the station, the refusal or the gap again")
    func thePageStateFollowsTheCatalogsAnswer() {
        #expect(SharedStationLinkPage.state(of: .notLoaded) == .notLoaded)
        #expect(SharedStationLinkPage.state(of: .sourceOff) == .sourceOff)
        #expect(SharedLinkOpener.pageState(uuid: Self.uuid, lookup: .found(Self.catalog)) == .station(Self.catalog))
        let other = RadioStation(id: "radio:rb:00000000-0000-0000-0000-000000000000", name: "Other", streamURL: "https://other.example/s")
        #expect(SharedLinkOpener.pageState(uuid: Self.uuid, lookup: .found(other)) == .unknown, "another station stands for the id")
        #expect(SharedLinkOpener.pageState(uuid: Self.uuid, lookup: .unknown) == .unknown)
        #expect(SharedLinkOpener.pageState(uuid: Self.uuid, lookup: .notLoaded) == .notLoaded)
        #expect(SharedLinkOpener.pageState(uuid: Self.uuid, lookup: .sourceOff) == .sourceOff)
    }

    @Test("only a station the catalog does not know says a sentence instead of a page")
    func onlyAnUnknownStationSaysASentence() {
        #expect(SharedLinkOpener.sentence(for: .refused(reason: "stationUnknown")) == SharedLinkOpener.refusal)
        #expect(SharedLinkOpener.sentence(for: .station(Self.catalog)) == nil, "a page that opens says a sentence")
        #expect(SharedLinkOpener.stationSourceOff != SharedLinkOpener.refusal, "a switched off source says the refusal")
    }

    @Test("Fence: the page offers Retry only when the catalog did not answer", .needsTheSources)
    func thePageOffersRetryOnlyWithoutAnAnswer() throws {
        let file = SourceTree.root.appendingPathComponent("Sources/Views/Radio/SharedStationLinkPage.swift")
        let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
        let body = try #require(code.components(separatedBy: "var body: some View {").dropFirst().first?
            .components(separatedBy: "private func askAgain").first, "the precondition: the page has a body")
        let branches = body.components(separatedBy: "case .")
        let notLoaded = try #require(branches.first { $0.hasPrefix("notLoaded:") })
        #expect(notLoaded.contains("LoadFailedView(") && notLoaded.contains("askAgain()"), "a page without an answer offers no Retry")
        for state in ["sourceOff:", "unknown:", "station("] {
            let branch = try #require(branches.first { $0.hasPrefix(state) }, "the page has no branch \(state)")
            #expect(!branch.contains("LoadFailedView(") && !branch.contains("RetryPill(") && !branch.contains("askAgain"),
                    "the branch \(state) offers Retry")
        }
    }

    @Test("Fence: the app asks the Radio Browser switch before it asks the catalog", .needsTheSources)
    func theOpenerAsksTheSwitchBeforeTheCatalog() throws {
        let file = SourceTree.root.appendingPathComponent("Sources/ViewModels/SharedLinkOpener.swift")
        let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
        let live = try #require(code.components(separatedBy: "static func lookUpStation(").dropFirst().first,
                                "the precondition: the app looks up stations in one place")
        let gate = try #require(live.range(of: "guard ExternalSources.isAllowed(ExternalSources.radioBrowser) else { return .sourceOff }"),
                                "the lookup does not ask the switch")
        let ask = try #require(live.range(of: "RadioBrowserClient.station(uuid:"), "the lookup does not ask the catalog")
        #expect(gate.lowerBound < ask.lowerBound, "the catalog is asked before the switch")
        #expect(code.contains("resolveStation: { await lookUpStation($0) }"), "the opener of the app asks another lookup")
        let page = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Views/Radio/SharedStationLinkPage.swift"), encoding: .utf8))
        #expect(page.contains("SharedLinkOpener.lookUpStation("), "Retry asks another lookup")
    }

    @Test("the catalog's query asks the one id")
    func theCatalogIsAskedForTheOneId() {
        let query = RadioBrowserClient.Query.byUUID(uuid: Self.uuid)
        #expect(query.path == "/json/stations/byuuid/\(Self.uuid)")
        #expect(query.queryItems.isEmpty)
    }

    @Test("Fence: the station from a link reads neither name nor stream from the link", .needsTheSources)
    func theStationNeverReadsTheLinksFacts() throws {
        let file = SourceTree.root.appendingPathComponent("Sources/ViewModels/SharedLinkOpener.swift")
        let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
        let station = try #require(code.components(separatedBy: "case .station(let uuid, _):").dropFirst().first,
                                   "the precondition: the station case ignores the link's facts")
        let body = try #require(station.components(separatedBy: "case .book(").first)
        #expect(!body.contains("facts") && !body.contains("RadioStation("), "the station is built from the link")
        #expect(body.contains("resolveStation("), "the station is not asked of the catalog")
    }
}
#endif
