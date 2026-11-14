// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A write the server applies each time it arrives goes out once after an
/// answer that leaves open whether it landed; the one probe after a 401
/// stays. And a removal by position goes only while the position still
/// holds the song the row showed.
struct RepeatableWritesTests {
    @Test("the retry: a non-repeatable write is not sent again after 5xx, 429 or a timeout, after 401 once")
    func aNonRepeatableWriteGoesOnce() {
        typealias Policy = RequestRetryPolicy
        for status in [500, 502, 503, 429] {
            #expect(Policy.decide(status: status, urlErrorCode: nil, attempt: 0, repeatable: false) == .fail, "\(status)")
            #expect(Policy.decide(status: status, urlErrorCode: nil, attempt: 0) != .fail, "a read lost its retry at \(status)")
        }
        #expect(Policy.decide(status: nil, urlErrorCode: NSURLErrorTimedOut, attempt: 0, repeatable: false) == .fail)
        #expect(Policy.decide(status: nil, urlErrorCode: NSURLErrorNetworkConnectionLost, attempt: 0, repeatable: false) == .fail)
        #expect(Policy.decide(status: 401, urlErrorCode: nil, attempt: 0, repeatable: false) != .fail,
                "the one probe after a 401 is gone, nothing was applied there")
    }

    @Test("Subsonic names its non-repeatable calls: create, append, remove by position, reported playback")
    func subsonicNamesItsWrites() {
        let add = SubsonicClient.addSongItems(["s1"])
        let remove = SubsonicClient.removeIndexItems([3])
        #expect(!SubsonicClient.isRepeatable("createPlaylist", ["name": "x"], extraItems: []))
        #expect(!SubsonicClient.isRepeatable("updatePlaylist", ["playlistId": "p"], extraItems: add))
        #expect(!SubsonicClient.isRepeatable("updatePlaylist", ["playlistId": "p"], extraItems: remove))
        #expect(!SubsonicClient.isRepeatable("scrobble", ["id": "s", "submission": "true"], extraItems: []))
        #expect(SubsonicClient.isRepeatable("updatePlaylist", ["playlistId": "p", "name": "neu"], extraItems: []), "a rename may go again")
        #expect(SubsonicClient.isRepeatable("scrobble", ["id": "s", "submission": "false"], extraItems: []))
        #expect(SubsonicClient.isRepeatable("getPlaylist", ["id": "p"], extraItems: []))
        #expect(SubsonicClient.isRepeatable("star", ["id": "s"], extraItems: []))
    }

    @Test("Jellyfin, Audiobookshelf and gpodder send their non-repeatable writes once", .needsTheSources)
    func theOtherClientsSendOnce() throws {
        let jellyfin = try FetchAnswerTests.squeezedSource("Sources/Networking/JellyfinClient.swift")
        #expect(jellyfin.contains(#"let data = try await post("Playlists", jsonBody: [ "Name": name, "UserId": uid, "MediaType": "Audio", ], repeatable: false)"#))
        #expect(jellyfin.contains(#"["Ids": songIds.joined(separator: ","), "UserId": uid], repeatable: false)"#))
        #expect(jellyfin.contains(#"_ = try await post("Users/\(uid)/PlayedItems/\(itemId)", repeatable: false)"#))
        let abs = try FetchAnswerTests.squeezedSource("Sources/Networking/APIClient.swift")
        #expect(abs.contains(#"_ = try await send(method: "POST", path: "api/podcasts", body: body, repeatable: false)"#))
        #expect(abs.contains(#"json: episodes, repeatable: false)"#))
        let gpodder = try FetchAnswerTests.squeezedSource("Sources/Networking/GPodderClient.swift")
        #expect(gpodder.contains(#"method: "POST", body: body), repeatable: false)"#))
        #expect(gpodder.contains("if repeatable, attempt < maxRetries, Self.isTransientURLError(error) {"))
    }

    @Test("Remove by position only while the shown song is at every spot")
    func aRemovalGoesOnlyWhereTheSongStillStands() {
        #expect(PlaylistRemoval.stillAt([1], drawn: ["b"], current: ["a", "b", "c"]))
        #expect(!PlaylistRemoval.stillAt([1], drawn: ["b"], current: ["a", "c", "b"]), "another song would fall")
        #expect(!PlaylistRemoval.stillAt([1], drawn: [nil], current: ["a", "b"]), "a row whose song is not known removed one")
        #expect(!PlaylistRemoval.stillAt([5], drawn: ["b"], current: ["a", "b"]))
        #expect(!PlaylistRemoval.stillAt([], drawn: [], current: ["a"]))
        #expect(PlaylistRemoval.stillAt([0, 2], drawn: ["a", "c"], current: ["a", "b", "c"]))
    }
}
#endif
