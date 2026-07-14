import Testing
@testable import ABSPlayer

/// D3/N1 — show-id derivation for the session-restore fallback: a vanished
/// episode ("rss:<feedKey>:<guid>") must map to its subscriptions-store show
/// ("feed:<feedKey>") even when the original guid contains colons (URLs).
struct RestoreFallbackTests {

    @Test func mapsEpisodeIdToShowId() {
        #expect(PlayerCoordinator.showId(forEpisodeId: "rss:b06a1e49813e58a2:some-guid")
            == "feed:b06a1e49813e58a2")
    }

    @Test func keepsColonsInOriginalGuid() {
        let id = "rss:b06a1e49813e58a2:https://podcast-mp3.dradio.de/2026/07/13/x.mp3?refId=nachrichten-108"
        #expect(PlayerCoordinator.showId(forEpisodeId: id) == "feed:b06a1e49813e58a2")
    }

    @Test func rejectsForeignAndMalformedIds() {
        #expect(PlayerCoordinator.showId(forEpisodeId: "abspod:xyz:guid") == nil)
        #expect(PlayerCoordinator.showId(forEpisodeId: "sub:album:123") == nil)
        #expect(PlayerCoordinator.showId(forEpisodeId: "rss:") == nil)
        #expect(PlayerCoordinator.showId(forEpisodeId: "rss::guid") == nil)
        #expect(PlayerCoordinator.showId(forEpisodeId: "rss:key:") == nil)
        #expect(PlayerCoordinator.showId(forEpisodeId: "93717f06-plain-book-id") == nil)
    }
}
