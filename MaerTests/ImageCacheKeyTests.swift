// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Cover cache key must distinguish Subsonic covers by their stable id and
/// stay stable across the per-request auth salt/token.
@MainActor
struct ImageCacheKeyTests {
    // Exercise the key indirectly through invalidate/hit behavior would need a
    // running cache; instead assert the pure keying via the exposed helper.
    private func key(_ s: String) -> String { ImageCache.shared.testKey(for: URL(string: s)!) }

    @Test func distinctSubsonicIdsGetDistinctKeys() {
        let a = key("https://music.maer.fm/rest/getCoverArt.view?id=al-1&size=600&u=x&t=aaa&s=111&c=maer&v=1.16&f=json")
        let b = key("https://music.maer.fm/rest/getCoverArt.view?id=al-2&size=600&u=x&t=bbb&s=222&c=maer&v=1.16&f=json")
        #expect(a != b)
    }

    @Test func sameIdStableAcrossRotatingSalt() {
        let a = key("https://music.maer.fm/rest/getCoverArt.view?id=al-1&size=600&u=x&t=aaa&s=111")
        let b = key("https://music.maer.fm/rest/getCoverArt.view?id=al-1&size=600&u=x&t=zzz&s=999")
        #expect(a == b)
    }

    /// The measured defect: Audiobookshelf puts the session token in the
    /// cover query, every tile in the audiobook tab fetched from the
    /// network on every appearance (#15 net on one cover after a scroll),
    /// while podcasts and music hit the thumbnail cache. Two causes in
    /// one: the token changed the key per login, and a JWT-length key
    /// exceeded the 255-byte file name limit, so nothing was ever written.
    @Test func absTokenIsNotPartOfTheKey() {
        let jwt = String(repeating: "x", count: 220)
        let a = key("https://abs.example.lan/api/items/li_1/cover?token=\(jwt)")
        let b = key("https://abs.example.lan/api/items/li_1/cover?token=OTHER")
        let bare = key("https://abs.example.lan/api/items/li_1/cover")
        #expect(a == b)
        #expect(a == bare)
        #expect(a.utf8.count <= 255)
    }

    @Test func jellyfinApiKeyIsNotPartOfTheKeyEither() {
        let a = key("https://jf.example.lan/Items/9/Images/Primary?api_key=AAA")
        let b = key("https://jf.example.lan/Items/9/Images/Primary?api_key=BBB")
        #expect(a == b)
    }

    /// The belt under the fix: any key beyond the ceiling becomes a
    /// stable digest instead of a file name the system refuses.
    @Test func overlongKeysBecomeAStableDigest() {
        let long = "https://h.example/x?" + (1...40).map { "k\($0)=v\($0)" }.joined(separator: "&")
        let a = key(long), b = key(long)
        #expect(a == b)
        #expect(a.utf8.count == 64)
        // Red probe: a different overlong query is a different digest.
        #expect(key(long + "&z=1") != a)
    }

    @Test func absPathBasedCoversUnaffected() {
        let a = key("https://abs.maer.fm/api/items/book-1/cover")
        let b = key("https://abs.maer.fm/api/items/book-2/cover")
        #expect(a != b)
        #expect(a == key("https://abs.maer.fm/api/items/book-1/cover"))
    }
}
#endif
