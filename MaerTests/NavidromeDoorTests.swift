// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Die Tuer: jede gespeicherte `sub:`-Kennung erreicht den Server in der
/// Form, auf die er antwortet. Navidrome 0.64 hat Songs und Playlisten neue
/// Kennungen gegeben und beantwortet eine alte mit Fehler 70; was vor dem
/// Update gespeichert wurde, traegt die alte.
struct NavidromeDoorTests {
    /// A song id from before 0.64 that no longer fits 128 bits, and the id
    /// Navidrome gave it (both from the shared case file).
    static let old = "7N42dgm5tFLK9N8MT7fHC8"
    static let new = "4lNKf50OxNrXbwJuGRpSfD"

    @Test("die Tuer rechnet um, wenn die Regel gilt, und sonst nicht")
    func theDoorRewritesWhenTheRuleHolds() {
        #expect(SubsonicProvider.id("sub:song:\(Self.old)", kind: "song", canonical: true) == Self.new)
        #expect(SubsonicProvider.id("sub:playlist:\(Self.old)", kind: "playlist", canonical: true) == Self.new)
        #expect(SubsonicProvider.id("sub:song:\(Self.old)", kind: "song", canonical: false) == Self.old,
                "a server before 0.64 gets the id as it was stored")
        #expect(SubsonicProvider.id("sub:song:\(Self.new)", kind: "song", canonical: true) == Self.new,
                "a new id passes unchanged")
        #expect(SubsonicProvider.id("sub:album:\(Self.old)", kind: "song", canonical: true) == nil,
                "the kind still decides")
        #expect(SubsonicProvider.serverId(Self.old, canonical: true) == Self.new)
        #expect(SubsonicProvider.serverId(SubsonicProvider.serverId(Self.old, canonical: true), canonical: true) == Self.new,
                "twice through the door is once")
    }

    @Test("ob die Regel gilt, sagt der gemerkte Typ und die gemerkte Fassung des eingetragenen Servers")
    @MainActor
    func theRuleFollowsTheServerSetUpHere() throws {
        let address = "https://door-\(UUID().uuidString).example/music"
        let server = SubsonicClient.serverKey(for: try #require(URL(string: address)))
        let previous = AppStorageKeys.subsonicServerURLValue
        defer {
            AppStorageKeys.subsonicServerURLValue = previous
            AppStorageKeys.set(nil, for: "subsonicType.\(server)")
            AppStorageKeys.set(nil, for: "subsonicServerVersion.\(server)")
        }
        AppStorageKeys.subsonicServerURLValue = address
        #expect(!SubsonicProvider.idsAreCanonical, "nothing reported yet: no rewriting")
        SubsonicClient.persistReportedType("navidrome", server: server)
        SubsonicClient.persistReportedVersion("0.63.2 (abc)", server: server)
        #expect(!SubsonicProvider.idsAreCanonical, "Navidrome before 0.64 keeps the old ids")
        SubsonicClient.persistReportedVersion("0.64.2 (38dc2727)", server: server)
        #expect(SubsonicProvider.idsAreCanonical)
        #expect(SubsonicProvider.id("sub:song:\(Self.old)", kind: "song") == Self.new,
                "the default asks the server set up here")
    }

    /// The first answer after the update can be the refusal of an old id.
    /// OpenSubsonic names its server in that envelope too, and that is what
    /// turns the new ids on.
    @Test("auch ein Fehler-Umschlag lehrt Typ und Fassung")
    func anErrorEnvelopeTeachesTheVersion() throws {
        let server = "door-error-\(UUID().uuidString).example/rest"
        defer {
            AppStorageKeys.set(nil, for: "subsonicType.\(server)")
            AppStorageKeys.set(nil, for: "subsonicServerVersion.\(server)")
        }
        let json = """
        {"subsonic-response":{"status":"failed","version":"1.16.1","type":"navidrome",
         "serverVersion":"0.64.2 (38dc2727)","openSubsonic":true,
         "error":{"code":70,"message":"data not found"}}}
        """
        let body = try JSONDecoder().decode(SubsonicEnvelope.self, from: Data(json.utf8)).subsonicResponse
        #expect(body.error?.code == 70, "the precondition: an error envelope")
        SubsonicClient.learn(from: body, server: server)
        #expect(SubsonicClient.reportedType(server: server) == "navidrome")
        #expect(SubsonicClient.reportedVersion(server: server) == "0.64.2 (38dc2727)")
    }

    /// The order and the one door, held in the sources: the client learns
    /// before it looks at an error, and no stored id reaches the server past
    /// the door.
    @Test("die Naht: zuerst lernen, dann der Fehler; keine rohe Kennung an der Tuer vorbei", .needsTheSources)
    func theSeam() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let client = try code("Sources/Networking/SubsonicClient.swift")
        let learn = try #require(client.range(of: "Self.learn(from: body, server: signInServer)"))
        let error = try #require(client.range(of: "if let err = body.error {"))
        #expect(learn.lowerBound < error.lowerBound, "the version is learned only after the error was looked at")
        #expect(client.components(separatedBy: "persistReportedVersion(").count - 1 == 2,
                "the version is kept somewhere else than in learn")

        let provider = try code("Sources/Providers/SubsonicProvider.swift")
        #expect(provider.contains("return serverId(String(itemId.dropFirst(prefix.count)), canonical: canonical)"))
        #expect(provider.contains("return raw.isEmpty ? nil : serverId(raw, canonical: canonical)"))
        #expect(provider.contains("client?.mediaURL(\"stream\", [\"id\": Self.serverId(contentPath)])"),
                "the stream takes a stored song id past the door")
        #expect(try Self.rawIdTakers() == [], "a stored id is taken apart outside the door")
    }

    // MARK: - Bookmarks: an id compared, not sent

    @Test("die kanonische Item-Kennung: nur der rohe Teil einer sub:-Kennung, und nur wenn die Regel gilt")
    func theCanonicalItemId() {
        #expect(SubsonicProvider.canonicalItemId("sub:playlist:\(Self.old)", canonical: true) == "sub:playlist:\(Self.new)")
        #expect(SubsonicProvider.canonicalItemId("sub:playlist:\(Self.new)", canonical: true) == "sub:playlist:\(Self.new)")
        #expect(SubsonicProvider.canonicalItemId("sub:playlist:\(Self.old)", canonical: false) == "sub:playlist:\(Self.old)")
        #expect(SubsonicProvider.canonicalItemId("rss:feed:\(Self.old)", canonical: true) == "rss:feed:\(Self.old)")
        #expect(SubsonicProvider.canonicalItemId("sub:playlist:", canonical: true) == "sub:playlist:")
    }

    /// Bookmarks written before the update carry the playlist's old id in
    /// their comment, newer ones the new id. Both are this playlist.
    @Test("Lesezeichen: alter und neuer Kommentar sind dasselbe Item, der juengste gewinnt")
    func oldAndNewCommentsAreOneItem() throws {
        func bookmark(_ song: String, _ ms: Int, _ changed: String, comment: String) throws -> SubsonicBookmark {
            try JSONDecoder().decode(SubsonicBookmark.self, from: Data(
                "{\"position\":\(ms),\"comment\":\"\(comment)\",\"changed\":\"\(changed)\",\"entry\":{\"id\":\"\(song)\"}}".utf8))
        }
        let stamp: (SubsonicBookmark) -> Double = {
            ISO8601DateFormatter().date(from: $0.changed ?? "")!.timeIntervalSince1970 * 1000
        }
        let songs: [(id: String, start: Double)] = [("A", 0), ("B", 180)]
        let bookmarks = [
            try bookmark("A", 10_000, "2026-10-02T10:00:00Z", comment: "sub:playlist:\(Self.new)"),
            try bookmark("B", 20_000, "2026-10-02T11:00:00Z", comment: "sub:playlist:\(Self.old)"),
        ]
        let key: (String) -> String = { SubsonicProvider.canonicalItemId($0, canonical: true) }
        let pick = try #require(BookmarkProgressMath.resume(bookmarks: bookmarks, itemId: "sub:playlist:\(Self.new)",
                                                           songs: songs, stamp: stamp, key: key))
        #expect(pick.time == 200, "the newer bookmark under the old comment counts for the playlist")
        let fromOld = try #require(BookmarkProgressMath.resume(bookmarks: bookmarks, itemId: "sub:playlist:\(Self.old)",
                                                              songs: songs, stamp: stamp, key: key))
        #expect(fromOld.time == 200, "asked by the old id, the same answer")
        let plain = try #require(BookmarkProgressMath.resume(bookmarks: bookmarks, itemId: "sub:playlist:\(Self.new)",
                                                            songs: songs, stamp: stamp))
        #expect(plain.time == 10, "the precondition: without the key only the exact comment counts")
    }

    @Test("Lesezeichen in der Naht: zusammengefasst, verglichen und geschrieben in der kanonischen Form", .needsTheSources)
    func bookmarksGoThroughTheCanonicalForm() throws {
        let provider = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/SubsonicProvider.swift"), encoding: .utf8))
        #expect(provider.contains("byItem[Self.canonicalItemId(comment), default: []].append(bm)"),
                "the library read keeps old and new comments apart")
        #expect(provider.components(separatedBy: "key: { Self.canonicalItemId($0) }").count - 1 == 2,
                "a resume compares comments in their stored form")
        #expect(provider.contains("comment: Self.canonicalItemId(itemId))"), "a bookmark is written with an old id")
    }

    /// Lines under `Sources` outside the provider that take a `sub:` id
    /// apart into its raw server id.
    static func rawIdTakers() throws -> [String] {
        let root = SourceTree.root
        let files = try #require(FileManager.default.enumerator(at: root.appendingPathComponent("Sources"),
                                                                includingPropertiesForKeys: nil))
        let patterns = ["dropFirst(\"sub:", "\"sub:song:\".count", "\"sub:album:\".count", "\"sub:playlist:\".count",
                        "replacingOccurrences(of: \"sub:"]
        var found: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "SubsonicProvider.swift" {
            let text = SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8))
            for line in text.split(separator: "\n") where patterns.contains(where: { line.contains($0) }) {
                found.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return found
    }
}
#endif
