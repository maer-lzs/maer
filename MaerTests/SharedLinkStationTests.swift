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

    private func opener(resolve: @escaping (String) async -> RadioStation?) -> SharedLinkOpener {
        SharedLinkOpener(staysHome: { _ in false }, knows: { _ in false },
                         browse: { _ in false }, resolveCatalog: { _ in false }, resolveStation: resolve)
    }

    @Test("ein Link mit echter Kennung und fremdem Strom oeffnet den Sender nie mit Namen oder Strom aus dem Link")
    func aStationFromALinkNeverCarriesTheLinksStream() async throws {
        let opener = opener { $0 == Self.uuid ? Self.catalog : nil }
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
        #expect(await opener { _ in nil }.outcome(for: url) == .refused(reason: "stationUnknown"))
        let other = RadioStation(id: "radio:rb:00000000-0000-0000-0000-000000000000", name: "Other", streamURL: "https://other.example/s")
        #expect(await opener { _ in other }.outcome(for: url) == .refused(reason: "stationUnknown"))
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
