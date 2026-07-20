// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

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

    @Test func absPathBasedCoversUnaffected() {
        let a = key("https://abs.maer.fm/api/items/book-1/cover")
        let b = key("https://abs.maer.fm/api/items/book-2/cover")
        #expect(a != b)
        #expect(a == key("https://abs.maer.fm/api/items/book-1/cover"))
    }
}
#endif
