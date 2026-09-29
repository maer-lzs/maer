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
            lang: "en", synced: true, offset: -1000, displayArtist: nil, displayTitle: nil,
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
            SubsonicStructuredLyrics(lang: "en", synced: false, offset: nil, displayArtist: nil,
                                     displayTitle: nil, line: [SubsonicLyricsLine(start: nil, value: "plain")]),
            SubsonicStructuredLyrics(lang: "en", synced: true, offset: nil, displayArtist: nil,
                                     displayTitle: nil, line: [SubsonicLyricsLine(start: 1000, value: "synced")]),
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
        // MusicBrainz policy: an identifying User-Agent is mandatory.
        #expect(CoverArtArchive.userAgent.contains("Maer/"))
        #expect(CoverArtArchive.userAgent.contains("http"))
    }

    @Test("e3dabb3: fromWeb survives the cache roundtrip; old entries decode as server")
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

    // MARK: - Ein Nein wird nur aufgeschrieben, wenn jemand es gesagt hat

    @Test("eine Abweisung wird nicht als 'dieses Lied hat keinen Text' gebucht")
    func aRefusalIsNotAFinding() {
        // Der Negativ-Eintrag gilt sechzig Tage, auf Platte und im
        // Speicher. Vorher endete jeder Weg im selben nil: eine Quelle, die
        // antwortet, eine die abweist (LRCLIB drosselt Serienfragen mit
        // 429), und ein Geraet, das niemanden fragen konnte.
        #expect(LyricsCaching.mayRemember([.answered, .answered]))
        #expect(LyricsCaching.mayRemember([.answered, .notAsked]))
        #expect(!LyricsCaching.mayRemember([.answered, .failed]))
        #expect(!LyricsCaching.mayRemember([.failed, .failed]))
    }

    @Test("eine Runde, in der niemand gefragt wurde, schreibt nichts auf")
    func aRoundWithoutAQuestionWritesNothing() {
        // Sonst bucht ein einziger Blick auf ein Lied im Flugmodus zwei
        // Monate lang 'kein Text'.
        #expect(!LyricsCaching.mayRemember([.notAsked, .notAsked]))
        #expect(!LyricsCaching.mayRemember([]))
    }

    @Test("ein Nein von vor dem Einschalten ist keine Antwort auf die neue Frage")
    func aNoFromBeforeTheSwitchIsOvertaken() {
        // Mit ausgeschaltetem Abruf ist der Server die einzige Quelle, und
        // sein "es gibt keinen" ist eine wahre Antwort auf DIESE Frage.
        #expect(!LyricsCaching.negativeIsOvertaken(hasLyrics: false, webAsked: false, lookupEnabled: false))
        // Wird der Abruf eingeschaltet, ist die Frage eine andere, und der
        // offene Dienst wurde nie gefragt. Sonst wirkt der Schalter, den
        // jemand gerade umgelegt hat, fuer diese Lieder sechzig Tage nicht.
        #expect(LyricsCaching.negativeIsOvertaken(hasLyrics: false, webAsked: false, lookupEnabled: true))
        // Wer gefragt wurde, bleibt gefragt.
        #expect(!LyricsCaching.negativeIsOvertaken(hasLyrics: false, webAsked: true, lookupEnabled: true))
        // Ein gefundener Text wird von einem Schalter nie ueberholt.
        #expect(!LyricsCaching.negativeIsOvertaken(hasLyrics: true, webAsked: false, lookupEnabled: true))
        // Eintraege von vor diesem Feld: nichts ist ueber sie bekannt, also
        // bleiben sie stehen. Jedes alte Nein zu verwerfen naehme die
        // richtigen mit.
        #expect(!LyricsCaching.negativeIsOvertaken(hasLyrics: false, webAsked: nil, lookupEnabled: true))
    }
}
#endif
