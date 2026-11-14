// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Block C (music metadata): the pure lyric/metadata cores.
struct LyricsTests {

    // MARK: - LRC parsing

    @Test func parsesSyncedLRC() throws {
        let lrc = """
        [ar:Artist]
        [00:12.30] First line
        [00:15.00][01:20.50] Repeated line
        [00:13.10] Out of order line
        """
        let lyrics = try #require(LyricsParser.parseLRC(lrc))
        #expect(lyrics.synced)
        // Sorted by time, metadata tag skipped, repeated stamps expanded.
        #expect(lyrics.lines.map(\.text) == ["First line", "Out of order line", "Repeated line", "Repeated line"])
        #expect(lyrics.lines.first?.start == 12.3)
        #expect(lyrics.lines.last?.start == 80.5)
    }

    @Test func parsesUnsyncedText() throws {
        let plain = "Line one\nLine two\n\nLine three"
        let lyrics = try #require(LyricsParser.parseLRC(plain))
        #expect(!lyrics.synced)
        #expect(lyrics.lines.map(\.text) == ["Line one", "Line two", "Line three"])
        #expect(lyrics.lines.allSatisfy { $0.start == nil })
    }

    @Test("Garbage/empty input yields nil, not a crash or empty lyrics")
    func brokenInput() {
        #expect(LyricsParser.parseLRC("") == nil)
        #expect(LyricsParser.parseLRC("[ar:OnlyMeta]\n[ti:Title]") == nil)
        // Malformed stamp falls back to unsynced text.
        let odd = LyricsParser.parseLRC("[xx:yy] not a stamp")
        #expect(odd?.synced == false)
    }

    // MARK: - OpenSubsonic structured lyrics

    @Test func structuredSyncedWithOffset() throws {
        let structured = [SubsonicStructuredLyrics(
            lang: "en", synced: true, offset: -1000,
            line: [SubsonicLyricsLine(start: 5000, value: "Five seconds"),
                   SubsonicLyricsLine(start: 500, value: "Clamped to zero")]
        )]
        let lyrics = try #require(SubsonicProvider.songLyrics(fromStructured: structured))
        #expect(lyrics.synced)
        // 5000ms - 1000ms offset = 4s; 500ms - 1000ms clamps to 0.
        #expect(lyrics.lines.map(\.start) == [4.0, 0.0])
    }

    @Test func structuredPrefersSyncedVariant() throws {
        let structured = [
            SubsonicStructuredLyrics(lang: "en", synced: false, offset: nil, line: [SubsonicLyricsLine(start: nil, value: "plain")]),
            SubsonicStructuredLyrics(lang: "en", synced: true, offset: nil, line: [SubsonicLyricsLine(start: 1000, value: "synced")]),
        ]
        let lyrics = try #require(SubsonicProvider.songLyrics(fromStructured: structured))
        #expect(lyrics.synced)
        #expect(lyrics.lines.first?.text == "synced")
    }

    // MARK: - LRCLIB matching tolerance

    @Test func lrclibDurationTolerance() {
        // Both known and close → accept; clearly apart → reject.
        #expect(LyricsParser.lrclibDurationAcceptable(result: 221.6, song: 224))
        #expect(!LyricsParser.lrclibDurationAcceptable(result: 180, song: 224))
        // Unknown on either side → accept (LRCLIB matched artist+title).
        #expect(LyricsParser.lrclibDurationAcceptable(result: nil, song: 224))
        #expect(LyricsParser.lrclibDurationAcceptable(result: 200, song: 0))
    }

    // MARK: - Cover Art Archive request builder

    @Test func coverArtArchiveBuilder() {
        let url = CoverArtArchive.frontURL(mbid: "abc-123")
        #expect(url?.absoluteString == "https://coverartarchive.org/release/abc-123/front-1200")
        // MusicBrainz policy: an identifying User-Agent is mandatory. The
        // ways out set it (`UserAgentFenceTests`).
        #expect(AppUserAgent.value.contains("Maer/"))
        #expect(AppUserAgent.value.contains("http"))
    }

    @Test("fromWeb survives the cache roundtrip; old entries decode as server")
    func fromWebRoundtrip() throws {
        var lyrics = SongLyrics(synced: false, lines: [LyricsLine(start: nil, text: "x")])
        lyrics.fromWeb = true
        let data = try JSONEncoder().encode(lyrics)
        let back = try JSONDecoder().decode(SongLyrics.self, from: data)
        #expect(back.fromWeb == true)
        // Older disk entries carry no source → nil → treated as server
        // (never hidden by the LRCLIB opt-out; ages out via TTL).
        let legacy = Data("""
        {"synced":false,"lines":[{"text":"y"}]}
        """.utf8)
        let old = try JSONDecoder().decode(SongLyrics.self, from: legacy)
        #expect(old.fromWeb == nil)
    }

    // MARK: - A No is written down only if somebody has said it

    @Test("a refusal is not booked as 'dieses Lied hat keinen Text'")
    func aRefusalIsNotAFinding() {
        // The negative entry applies for sixty days, on disk and in
        // memory. Before, every way ended in the same nil: a source that
        // answers, one that refuses (LRCLIB throttles serial questions with
        // 429), and a device that could not ask anyone.
        #expect(LyricsCaching.mayRemember([.answered, .answered]))
        #expect(LyricsCaching.mayRemember([.answered, .notAsked]))
        #expect(!LyricsCaching.mayRemember([.answered, .failed]))
        #expect(!LyricsCaching.mayRemember([.failed, .failed]))
    }

    @Test("a round in which nobody was asked writes nothing down")
    func aRoundWithoutAQuestionWritesNothing() {
        // Otherwise a single look at a song in airplane mode books two
        // months of "kein Text".
        #expect(!LyricsCaching.mayRemember([.notAsked, .notAsked]))
        #expect(!LyricsCaching.mayRemember([]))
    }

    @Test("a No from before switching on is no answer to the new question")
    func aNoFromBeforeTheSwitchIsOvertaken() {
        // With the lookup switched off the server is the only source, and
        // its "es gibt keinen" is a true answer to THIS question.
        #expect(!LyricsCaching.negativeIsOvertaken(hasLyrics: false, webAsked: false, lookupEnabled: false))
        // If the lookup is switched on, the question is a different one, and the
        // open service was never asked. Otherwise the switch that
        // someone has just flipped has no effect for these songs for sixty days.
        #expect(LyricsCaching.negativeIsOvertaken(hasLyrics: false, webAsked: false, lookupEnabled: true))
        // Whoever was asked stays asked.
        #expect(!LyricsCaching.negativeIsOvertaken(hasLyrics: false, webAsked: true, lookupEnabled: true))
        // A found text is never overtaken by a switch.
        #expect(!LyricsCaching.negativeIsOvertaken(hasLyrics: true, webAsked: false, lookupEnabled: true))
        // Entries from before this field: nothing is known about them, so
        // they stay. Discarding every old No would take the
        // right ones along.
        #expect(!LyricsCaching.negativeIsOvertaken(hasLyrics: false, webAsked: nil, lookupEnabled: true))
    }
}
#endif
