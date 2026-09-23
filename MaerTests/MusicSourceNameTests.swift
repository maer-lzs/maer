// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A music server is named by what it reports about itself, and the capsule
/// shows that name only while two music servers are active.
struct MusicSourceNameTests {
    @Test("der Name ist der gemeldete Typ; Jellyfin heisst Jellyfin; ohne Angabe Subsonic")
    func names() {
        #expect(MusicSourceName.name(providerId: "sub", reportedType: "navidrome") == "Navidrome")
        #expect(MusicSourceName.name(providerId: "sub", reportedType: "nextcloud music") == "Nextcloud Music")
        #expect(MusicSourceName.name(providerId: "sub", reportedType: " funkwhale ") == "Funkwhale")
        #expect(MusicSourceName.name(providerId: "sub", reportedType: nil) == "Subsonic")
        #expect(MusicSourceName.name(providerId: "sub", reportedType: "  ") == "Subsonic")
        #expect(MusicSourceName.name(providerId: "jf", reportedType: "navidrome") == "Jellyfin",
                "Jellyfin meldet keinen Subsonic-Typ; ein fremder Wert aendert den Namen nicht")
    }

    @Test("die Kapsel nur bei zwei Musikservern")
    func capsuleOnlyWithTwo() {
        #expect(MusicSourceName.capsule(serving: .both, name: "Navidrome") == "Navidrome")
        #expect(MusicSourceName.capsule(serving: .one(.subsonic), name: "Navidrome") == nil)
        #expect(MusicSourceName.capsule(serving: .one(.jellyfin), name: "Jellyfin") == nil)
    }

    @Test("der Ausfall-Satz nimmt dieselben Namen wie die Kapsel")
    func failureSentenceUsesTheNames() {
        let names = ["sub": "Navidrome", "jf": "Jellyfin"]
        let sentence = MusicSourceFailure.sentence(failed: ["sub"], all: ["sub", "jf"], names: names)
        #expect(sentence?.contains("Navidrome") == true)
        #expect(sentence?.contains("Subsonic") == false)
    }

    @Test("der Typ aus der Antwort wird gelesen, gespeichert und nur bei Aenderung ueberschrieben")
    func reportedTypeIsReadAndKept() throws {
        let navidrome = #"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","openSubsonic":true}}"#
        let body = try JSONDecoder().decode(SubsonicEnvelope.self, from: Data(navidrome.utf8)).subsonicResponse
        #expect(body.type == "navidrome")
        let plain = #"{"subsonic-response":{"status":"ok","version":"1.15.0"}}"#
        #expect(try JSONDecoder().decode(SubsonicEnvelope.self, from: Data(plain.utf8)).subsonicResponse.type == nil)

        let server = "typtest.invalid/\(UUID().uuidString)"
        defer { AppStorageKeys.set(nil, for: "subsonicType.\(server)") }
        #expect(SubsonicClient.reportedType(server: server) == nil)
        SubsonicClient.persistReportedType("navidrome", server: server)
        #expect(SubsonicClient.reportedType(server: server) == "navidrome")
        SubsonicClient.persistReportedType(nil, server: server)
        #expect(SubsonicClient.reportedType(server: server) == "navidrome", "eine Antwort ohne Typ loescht den bekannten nicht")
    }
}
#endif
