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
    @Test("an Audiobookshelf cover comes unscaled, and no 400-pixel cover answers its address")
    func absCoverComesUnscaled() throws {
        let client = APIClient(baseURL: URL(string: "https://abs.example.lan")!, token: "T")
        let url = try #require(client.largeCoverURL(forItemId: "li_1"))
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
    @Test("in key mode the key is not in the name of a cover")
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
    @Test("every sign-in part that an image address carries stays out of the name")
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
        for url in [abs.coverURL(forItemId: "li_1"), abs.largeCoverURL(forItemId: "li_1"), abs.authorImageURL(authorId: "aut_1")] {
            let built = try #require(url)
            let absNames = Set(try #require(URLComponents(url: built, resolvingAgainstBaseURL: false)?.queryItems).map(\.name))
            // `raw` and `width` name the picture (unscaled, grid width), as
            // `id` and `size` do for Subsonic.
            let signIn = absNames.subtracting([APIClient.coverOriginalName, APIClient.coverWidthName])
            #expect(!signIn.isEmpty && signIn.isSubset(of: ImageCache.signInQueryNames), "ABS: \(absNames)")
        }
        #expect(ImageCache.signInQueryNames.contains(JellyfinClient.mediaAuthQueryItem(token: "j1").name))
    }

    /// A name an older build wrote with the key in it becomes exactly the
    /// name by address without it, which the read and the sweep know as a
    /// former name (`formerNames`, `legacyMoves`).
    @Test("an old name with a key becomes exactly the name by address without it")
    func anOldNameWithTheKeyBecomesTodaysName() {
        let today = ImageCache.addressName(for: URL(string: "https://nc.example.lan/rest/getCoverArt.view?apiKey=SECRETKEY1&id=al-1&size=600")!)
        let old = "nc.example.lan__rest_getCoverArt.view_apiKey=SECRETKEY1_id=al-1_size=600"
        #expect(ImageCache.nameWithoutSignIn(old) == today)
        #expect(ImageCache.nameWithoutSignIn(today) == nil, "a name without a sign-in part stays")
    }

    /// A key holding `_`, `/` or `:` was written with `_` in the old name;
    /// its pieces go with the sign-in part, no piece of the key stays.
    @Test("a key with underscore, slash or colon vanishes entirely from the old name")
    func aKeyWithSeparatorsLeavesNoPiece() {
        let today = ImageCache.addressName(for: URL(string: "https://nc.example.lan/rest/getCoverArt.view?apiKey=ab_cd/e:f&id=al-1&size=600")!)
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
    @Test("a foreign image address keeps every short name, two sizes give two names")
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
    @Test("an unambiguous credential name drops out on a foreign address too")
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
    @Test("the image addresses built by the clients are client forms, a foreign one is not")
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

    @Test("an image of the own servers is named by kind, id and form, the same on every host and under every path")
    func aServerPictureIsNamedByItsId() throws {
        let table: [(String, String, String)] = [
            ("https://abs.example.lan/api/items/li_1/cover?width=400&token=A",
             "https://books.other.example/abs/api/items/li_1/cover?width=400&token=B", "abs_items_li_1_width=400"),
            ("https://abs.example.lan/api/items/li_1/cover?raw=1&token=A",
             "http://10.0.0.2:13378/api/items/li_1/cover?raw=1", "abs_items_li_1_raw=1"),
            ("https://abs.example.lan/api/authors/aut_1/image?token=A",
             "https://new.example/api/authors/aut_1/image", "abs_authors_aut_1"),
            ("https://music.example.lan/rest/getCoverArt.view?id=al-1&size=600&u=a&t=T1&s=S1&v=1&c=Maer&f=json",
             "https://nd.other.example/sub/rest/getCoverArt.view?id=al-1&size=600&apiKey=K&v=1&c=Maer&f=json",
             "sub_al-1_size=600"),
            ("https://jf.example.lan/Items/it1/Images/Primary?maxWidth=600&ApiKey=A",
             "https://media.other.example/jellyfin/Items/it1/Images/Primary?maxWidth=600&ApiKey=B",
             "jf_it1_Primary_maxWidth=600"),
            ("https://jf.example.lan/Items/it1/Images/Backdrop/0?ApiKey=A",
             "https://media.other.example/Items/it1/Images/Backdrop/0", "jf_it1_Backdrop_0"),
        ]
        for (first, moved, expected) in table {
            #expect(key(first) == expected, "\(first)")
            #expect(key(moved) == expected, "a move of the server renamed \(moved)")
        }
        let primary = key("https://jf.example.lan/Items/it1/Images/Primary?ApiKey=A")
        #expect(primary != key("https://jf.example.lan/Items/it1/Images/Backdrop/0?ApiKey=A"),
                "two types of one item share a name")
        #expect(key("https://music.example.lan/rest/getCoverArt.view?id=al-1&size=300")
                != key("https://music.example.lan/rest/getCoverArt.view?id=al-1&size=600"), "two sizes share a name")
        #expect(key("https://music.example.lan/rest/getCoverArt.view?id=al-1")
                != key("https://jf.example.lan/Items/al-1/Images/Primary"), "two kinds of server share a name")
    }

    @Test("a public address is still named by host, path and query")
    func aPublicAddressKeepsItsName() {
        let address = "https://archive.org/services/img/librivox_book"
        #expect(ImageCache.serverImageName(URL(string: address)!) == nil)
        #expect(key(address) == "archive.org__services_img_librivox_book")
        #expect(key("https://media.npr.org/assets/img/show.jpg?s=1400") == "media.npr.org__assets_img_show.jpg_s=1400")
    }

    @Test("every image address that a client builds is named without host")
    func everyBuiltServerPictureIsNamedWithoutItsHost() throws {
        let subsonic = try #require(SubsonicClient(serverURL: "https://music.example.lan/sub", username: "hoerer", password: "geheim-42"))
        let abs = APIClient(baseURL: URL(string: "https://abs.example.lan")!, token: "jwt-1")
        let jellyfin = JellyfinClient(serverURL: "https://jf.example.lan", username: "u", password: "p",
                                      deviceId: "d", accessToken: "tok", userId: "user")
        let built = [subsonic.mediaURL("getCoverArt", ["id": "al-1", "size": "600"]),
                     abs.coverURL(forItemId: "li_1"), abs.largeCoverURL(forItemId: "li_1"),
                     abs.authorImageURL(authorId: "aut_1"),
                     jellyfin.imageURL(itemId: "it1", maxWidth: 600)].compactMap { $0 }
        #expect(built.count == 5, "a client built no address")
        for url in built {
            let name = try #require(ImageCache.serverImageName(url), "\(url) is not read as a server picture")
            #expect(!name.contains("example") && name == key(url.absoluteString), "\(name)")
        }
    }

    /// A fetch that counts its runs and holds until it is opened.
    @MainActor
    private final class Runs {
        private(set) var count = 0
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        func run() async -> Artwork.Fetched {
            count += 1
            if !isOpen { await withCheckedContinuation { waiting.append($0) } }
            return .unanswered
        }
        func open() {
            isOpen = true
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    @Test("two addresses of the same cover with a different salt are the same name and one fetch")
    func oneCoverWithTwoSaltsIsOneFetch() async throws {
        let one = URL(string: "https://music.example.lan/rest/getCoverArt.view?id=al-9&size=600&t=T1&s=S1")!
        let two = URL(string: "https://music.example.lan/rest/getCoverArt.view?id=al-9&size=600&t=T2&s=S2")!
        #expect(ImageCache.fileKey(for: one) == ImageCache.fileKey(for: two))
        let runs = Runs()
        let first = Task { await CoverFetchCoalescer.fetch(one) { await runs.run() } }
        let second = Task { await CoverFetchCoalescer.fetch(two) { await runs.run() } }
        try await Task.sleep(nanoseconds: 50_000_000)
        runs.open()
        _ = await (first.value, second.value)
        #expect(runs.count == 1, "two salts fetched twice")
    }
}
#endif
