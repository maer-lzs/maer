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
    /// network on every appearance (15 network fetches of one cover after a scroll),
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

    /// The key sign-in (Nextcloud Music, any server after error 41) puts the
    /// key in the query; it is no part of a name, like `token` and `api_key`.
    @Test("im Schluessel-Modus steht der Schluessel nicht im Namen eines Covers")
    func subsonicApiKeyIsNotPartOfTheKey() {
        let a = key("https://nc.example.lan/rest/getCoverArt.view?apiKey=SECRETKEY1&id=al-1&size=600&c=Maer&v=1.16.1&f=json")
        let b = key("https://nc.example.lan/rest/getCoverArt.view?apiKey=OTHERKEY2&id=al-1&size=600&c=Maer&v=1.16.1&f=json")
        let bare = key("https://nc.example.lan/rest/getCoverArt.view?id=al-1&size=600")
        #expect(a == b && a == bare)
        #expect(!a.contains("SECRETKEY1"))
    }

    /// The class, asked of the code that writes the names: every query name a
    /// sign-in form or a client writes into an image address stays out of a
    /// cover's name. Measured at the built addresses, not at a list.
    @Test("jedes Anmeldeteil, das eine Bild-Adresse traegt, bleibt aus dem Namen")
    func everySignInPartStaysOutOfTheName() throws {
        for mode in [SubsonicSignIn.Mode.token, .apiKey] {
            let names = Set(SubsonicSignIn.items(mode, username: "u1", secret: "k1", token: "t1", salt: "s1").map(\.name))
            #expect(names.isSubset(of: SubsonicSignIn.queryNames), "\(mode): a name the sign-in writes is not declared")
            #expect(names.isSubset(of: ImageCache.signInQueryNames), "\(mode): a sign-in name enters a cover name")
        }
        let subsonic = try #require(SubsonicClient(serverURL: "https://music.example.lan/sub", username: "hoerer", password: "geheim-42"))
        let cover = try #require(subsonic.mediaURL("getCoverArt", ["id": "al-1", "size": "600"]))
        let subsonicNames = Set(try #require(URLComponents(url: cover, resolvingAgainstBaseURL: false)?.queryItems).map(\.name))
        #expect(subsonicNames.subtracting(["id", "size"]).isSubset(of: ImageCache.signInQueryNames),
                "the Subsonic client writes a name beside the sign-in that enters a cover name: \(subsonicNames)")
        let abs = APIClient(baseURL: URL(string: "https://abs.example.lan")!, token: "jwt-1")
        for url in [abs.coverURL(forItemId: "li_1"), abs.authorImageURL(authorId: "aut_1")] {
            let built = try #require(url)
            let absNames = Set(try #require(URLComponents(url: built, resolvingAgainstBaseURL: false)?.queryItems).map(\.name))
            #expect(!absNames.isEmpty && absNames.isSubset(of: ImageCache.signInQueryNames), "ABS: \(absNames)")
        }
        #expect(ImageCache.signInQueryNames.contains(JellyfinClient.mediaAuthQueryItem(token: "j1").name))
    }

    /// A name an older build wrote with the key in it becomes exactly the
    /// name the rule gives today.
    @Test("ein alter Name mit Schluessel wird genau der heutige Name")
    func anOldNameWithTheKeyBecomesTodaysName() {
        let today = key("https://nc.example.lan/rest/getCoverArt.view?apiKey=SECRETKEY1&id=al-1&size=600")
        let old = "nc.example.lan__rest_getCoverArt.view_apiKey=SECRETKEY1_id=al-1_size=600"
        #expect(ImageCache.nameWithoutSignIn(old) == today)
        #expect(ImageCache.nameWithoutSignIn(today) == nil, "a name without a sign-in part stays")
    }

    @Test func absPathBasedCoversUnaffected() {
        let a = key("https://abs.maer.fm/api/items/book-1/cover")
        let b = key("https://abs.maer.fm/api/items/book-2/cover")
        #expect(a != b)
        #expect(a == key("https://abs.maer.fm/api/items/book-1/cover"))
    }
}
#endif
