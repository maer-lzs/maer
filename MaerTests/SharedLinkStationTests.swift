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

    @Test("ein Link mit echter Kennung und fremdem Strom oeffnet den Sender nie mit Namen oder Strom aus dem Link")
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

    @Test("findet der Katalog die Kennung nicht, oder nennt er einen anderen Sender, oeffnet der Link nichts")
    func aStationTheCatalogDoesNotConfirmOpensNothing() async throws {
        let url = try #require(SharedLink.url(for: .station(uuid: Self.uuid, .init(title: "Fremd", audioURL: Self.foreign))))
        #expect(await opener { _ in .unknown }.outcome(for: url) == .refused(reason: "stationUnknown"))
        let other = RadioStation(id: "radio:rb:00000000-0000-0000-0000-000000000000", name: "Other", streamURL: "https://other.example/s")
        #expect(await opener { _ in .found(other) }.outcome(for: url) == .refused(reason: "stationUnknown"))
    }

    @Test("antwortet der Katalog nicht, ist der Sender nicht geladen und nicht unbekannt")
    func aStationTheCatalogDidNotAnswerForIsNotLoaded() async throws {
        let url = try #require(SharedLink.url(for: .station(uuid: Self.uuid, .init(title: "Fremd", audioURL: Self.foreign))))
        #expect(await opener { _ in .notLoaded }.outcome(for: url) == .notLoaded(reason: "stationNotLoaded"),
                "a catalog without an answer reads as a station it does not know")
        #expect(SharedLinkOpener.target(of: .notLoaded(reason: "stationNotLoaded")) == nil, "a station that did not load opens a page")
        #expect(await opener { _ in .sourceOff }.outcome(for: url) == .sourceOff(reason: "stationSourceOff"),
                "a switched off source reads as a catalog without an answer")
    }

    @Test("jeder Ausgang ohne Seite sagt seinen eigenen Satz: unbekannt, nicht geladen, Quelle aus")
    func eachOutcomeWithoutAPageSaysItsOwnSentence() {
        let unknown = SharedLinkOpener.sentence(for: .refused(reason: "stationUnknown"))
        let notLoaded = SharedLinkOpener.sentence(for: .notLoaded(reason: "stationNotLoaded"))
        let off = SharedLinkOpener.sentence(for: .sourceOff(reason: "stationSourceOff"))
        #expect(unknown == SharedLinkOpener.refusal, "an unknown station says another sentence than every other refusal")
        #expect(notLoaded == SharedLinkOpener.stationNotLoaded, "a station that did not load says the refusal")
        #expect(off == SharedLinkOpener.stationSourceOff, "a switched off source says the refusal")
        #expect(Set([unknown, notLoaded, off]).count == 3, "two outcomes share one sentence")
        #expect(SharedLinkOpener.sentence(for: .station(Self.catalog)) == nil, "a page that opens says a sentence")
    }

    @Test("Zaun: der Oeffner der App fragt den Schalter von Radio Browser, bevor er den Katalog fragt", .needsTheSources)
    func theOpenerAsksTheSwitchBeforeTheCatalog() throws {
        let file = SourceTree.root.appendingPathComponent("Sources/ViewModels/SharedLinkOpener.swift")
        let code = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
        let live = try #require(code.components(separatedBy: "resolveStation: { uuid in").dropFirst().first,
                                "the precondition: the opener of the app resolves stations")
        let gate = try #require(live.range(of: "guard ExternalSources.isAllowed(ExternalSources.radioBrowser) else { return .sourceOff }"),
                                "the opener does not ask the switch")
        let ask = try #require(live.range(of: "RadioBrowserClient.station(uuid:"), "the opener does not ask the catalog")
        #expect(gate.lowerBound < ask.lowerBound, "the catalog is asked before the switch")
    }

    @Test("die Abfrage des Katalogs fragt die eine Kennung")
    func theCatalogIsAskedForTheOneId() {
        let query = RadioBrowserClient.Query.byUUID(uuid: Self.uuid)
        #expect(query.path == "/json/stations/byuuid/\(Self.uuid)")
        #expect(query.queryItems.isEmpty)
    }

    @Test("Zaun: der Sender aus einem Link liest weder Namen noch Strom aus dem Link", .needsTheSources)
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
