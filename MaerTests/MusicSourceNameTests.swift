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

    @Test("F5b-4b: nur eine Kennung eines Musikservers traegt die Kapsel, ein Katalog-Titel nie")
    func capsuleOnlyForServerIds() {
        #expect(MusicSourceName.capsule(forItemId: "jf:album:1", serving: .both, name: "Jellyfin") == "Jellyfin")
        #expect(MusicSourceName.capsule(forItemId: "sub:album:1", serving: .both, name: "Navidrome") == "Navidrome")
        #expect(MusicSourceName.capsule(forItemId: "jam:album-1", serving: .both, name: "Navidrome") == nil,
                "AlbumCell zeigt auch Katalog-Titel; ohne die Pruefung truegen sie den Namen des Geraete-Servers")
        #expect(MusicSourceName.capsule(forItemId: "abs-book", serving: .both, name: "Navidrome") == nil)
        #expect(MusicSourceName.capsule(forItemId: "sub:album:1", serving: .one(.subsonic), name: "Navidrome") == nil)
    }

    @Test("F5b-4b: Zelle, Weiterhoeren-Karte, Hoer-Kachel und Server-Playlist-Karte fragen die eine Kapsel-Frage", .needsTheSources)
    func surfacesAskTheOneQuestion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // Through the router's door, not the session: the growth fence
        // counts every `.shared` a view reaches for.
        // Per TYPE, not per file: MusicView.swift asks for the playlist row
        // too, so a file-wide look stayed green with the cell unwired.
        func text(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let cell = try #require(FinishedDownloadControlTests.body(
            of: "AlbumCell", in: try text("Sources/Views/Music/MusicView.swift")))
        #expect(cell.contains("router.sourceLabel(item.id)"), "die Albumzelle fragt die Kapsel nicht")
        let continueCard = try #require(FinishedDownloadControlTests.body(
            of: "MusicContinueCard", in: try text("Sources/Views/Music/MusicContinueCard.swift")))
        #expect(continueCard.contains("router.sourceLabel(item.id)"), "die Weiterhoeren-Karte fragt die Kapsel nicht")
        #expect(try text("Sources/Views/MixedMediaPage.swift").contains("badgeText: router.sourceLabel(id)"),
                "die Hoer-Kachel fragt die Kapsel nicht")
        #expect(try text("Sources/Views/Music/MusicView.swift")
                    .contains("PlaylistCardSource.server($0, sourceLabel: router.sourceLabel($0.itemId))"),
                "die Playlist-Reihe reicht den Namen nicht")
        let card = try String(contentsOf: root.appendingPathComponent("Sources/Views/Music/PlaylistCard.swift"),
                              encoding: .utf8)
        #expect(card.contains("placeCapsule: sourceLabel"), "die Server-Karte traegt den gereichten Namen nicht")
        #expect(ItemRouter.empty.sourceLabel("jf:album:1") == nil, "der leere Router antwortet nichts")
        // One capsule look: nobody draws the black cover capsule by hand.
        var own: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.lastPathComponent != "CoverCapsule.swift" {
            if try String(contentsOf: file, encoding: .utf8).contains(".background(.black.opacity(0.55), in: Capsule())") {
                own.append(file.lastPathComponent)
            }
        }
        #expect(own.isEmpty, "eine eigene Kopie der Cover-Kapsel: \(own)")
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
