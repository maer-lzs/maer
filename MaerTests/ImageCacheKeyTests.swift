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

    /// Without `raw` Audiobookshelf scales every cover to 400 pixels wide
    /// (`CacheManager`, `options.width || 400`): the client asks for the
    /// cover as the server keeps it, and a cover kept from the scaled
    /// address never answers the new one.
    @Test("ein Audiobookshelf-Cover kommt ungerechnet, und kein 400-Pixel-Cover antwortet seiner Adresse")
    func absCoverComesUnscaled() throws {
        let client = APIClient(baseURL: URL(string: "https://abs.example.lan")!, token: "T")
        let url = try #require(client.coverURL(forItemId: "li_1"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "raw", value: "1")))
        #expect(url.path == "/api/items/li_1/cover")
        #expect(APIClient.buildsImage(path: url.path))
        let scaled = key("https://abs.example.lan/api/items/li_1/cover?token=T")
        #expect(key(url.absoluteString) != scaled, "a cover kept at 400 pixels answers the unscaled address")
        #expect(key(url.absoluteString) == key("https://abs.example.lan/api/items/li_1/cover?raw=1&token=OTHER"))
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
            // `raw` names the picture (unscaled), as `id` and `size` do for Subsonic.
            let signIn = absNames.subtracting([APIClient.coverOriginalName])
            #expect(!signIn.isEmpty && signIn.isSubset(of: ImageCache.signInQueryNames), "ABS: \(absNames)")
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

    /// A key holding `_`, `/` or `:` was written with `_` in the old name;
    /// its pieces go with the sign-in part, no piece of the key stays.
    @Test("ein Schluessel mit Unterstrich, Schraegstrich oder Doppelpunkt verschwindet ganz aus dem alten Namen")
    func aKeyWithSeparatorsLeavesNoPiece() {
        let today = key("https://nc.example.lan/rest/getCoverArt.view?apiKey=ab_cd/e:f&id=al-1&size=600")
        let old = "nc.example.lan__rest_getCoverArt.view_apiKey=ab_cd_e_f_id=al-1_size=600"
        let renamed = ImageCache.nameWithoutSignIn(old)
        #expect(renamed == today)
        #expect(renamed.map { !$0.contains("cd") && !$0.contains("_e_") } == true, "a piece of the key stayed: \(renamed ?? "-")")
    }

    @Test func absPathBasedCoversUnaffected() {
        let a = key("https://abs.maer.fm/api/items/book-1/cover")
        let b = key("https://abs.maer.fm/api/items/book-2/cover")
        #expect(a != b)
        #expect(a == key("https://abs.maer.fm/api/items/book-1/cover"))
    }

    /// A foreign picture keeps every one-letter query part: there they name
    /// the picture (measured on feed and station images: a cache-buster `t`,
    /// a version `v`, NPR's size and crop `s`, `c`, `f`).
    @Test("eine fremde Bild-Adresse behaelt jeden Kurznamen, zwei Groessen geben zwei Namen")
    func aForeignPictureKeepsItsShortNames() {
        let npr = key("https://media.npr.org/assets/img/show.jpg?s=1400&c=66&f=jpg")
        #expect(npr.contains("s=1400") && npr.contains("c=66") && npr.contains("f=jpg"))
        #expect(key("https://media.npr.org/assets/img/show.jpg?s=600&c=66&f=jpg") != npr, "two sizes share a name")
        #expect(key("https://www.omnycontent.com/d/programs/x/image.jpg?t=1700000001")
                != key("https://www.omnycontent.com/d/programs/x/image.jpg?t=1700000002"),
                "a publisher's cache-buster does not reach the name")
        #expect(key("https://cdn.example.org/cover.png?v=3").contains("v=3"))
    }

    /// The unambiguous sign-in names stay out of every name, also at a
    /// foreign address, so a sign-in never reaches a file name there either.
    @Test("ein eindeutiger Zugangsname faellt auch an einer fremden Adresse")
    func anUnambiguousSignInNameDropsEverywhere() {
        for name in ["token", "apiKey", "api_key", "ApiKey"] {
            let carried = key("https://cdn.example.org/cover.png?\(name)=SECRET9&v=3")
            #expect(!carried.contains("SECRET9"), "\(name) entered a foreign name")
            #expect(carried == key("https://cdn.example.org/cover.png?v=3"))
        }
        #expect(ImageCache.unambiguousSignInNames == ["token", "apiKey", "api_key", "ApiKey"])
    }

    /// The image addresses our clients build are client images, measured at
    /// the built addresses; a foreign address is none.
    @Test("die gebauten Bild-Adressen der Klienten sind Klient-Formen, eine fremde nicht")
    func theClientsBuildClientImages() throws {
        let subsonic = try #require(SubsonicClient(serverURL: "https://music.example.lan/sub", username: "hoerer", password: "geheim-42"))
        #expect(ImageCache.isClientImage(try #require(subsonic.mediaURL("getCoverArt", ["id": "al-1", "size": "600"]))))
        #expect(!ImageCache.isClientImage(try #require(subsonic.mediaURL("stream", ["id": "so-1"]))), "a stream is no image")
        let abs = APIClient(baseURL: URL(string: "https://abs.example.lan")!, token: "jwt-1")
        #expect(ImageCache.isClientImage(try #require(abs.coverURL(forItemId: "li_1"))))
        #expect(ImageCache.isClientImage(try #require(abs.authorImageURL(authorId: "aut_1"))))
        let jellyfin = JellyfinClient(serverURL: "https://jf.example.lan", username: "u", password: "p",
                                      deviceId: "d", accessToken: "tok", userId: "user")
        #expect(ImageCache.isClientImage(try #require(jellyfin.imageURL(itemId: "it1", maxWidth: 600))))
        #expect(!ImageCache.isClientImage(URL(string: "https://media.npr.org/assets/img/show.jpg?s=1400")!))
        // At a client image the short names still carry the sign-in.
        let built = try #require(subsonic.mediaURL("getCoverArt", ["id": "al-1", "size": "600"]))
        let name = ImageCache.shared.testKey(for: built)
        #expect(!name.contains("t=") && !name.contains("s=") && !name.contains("u=hoerer"), "a sign-in part entered: \(name)")
    }
}
#endif
