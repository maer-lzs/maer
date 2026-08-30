// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// `podcast:transcript` parsing. Content-sniffed SRT/VTT/JSON onto the
/// shared SongLyrics shape; garbage yields nil (the player entry stays away).
struct PodcastTranscriptTests {

    @Test("SRT: cues with comma timestamps, multi-line bodies join")
    func srt() throws {
        let srt = """
        1
        00:00:01,500 --> 00:00:04,000
        Hello and welcome
        to the show.

        2
        00:01:02,000 --> 00:01:05,000
        Second segment.
        """
        let parsed = try #require(PodcastTranscript.parse(Data(srt.utf8)))
        #expect(parsed.synced)
        #expect(parsed.lines.count == 2)
        #expect(parsed.lines[0].start == 1.5)
        #expect(parsed.lines[0].text == "Hello and welcome to the show.")
        #expect(parsed.lines[1].start == 62)
    }

    @Test("VTT: header skipped, voice tags stripped, dot timestamps")
    func vtt() throws {
        let vtt = """
        WEBVTT

        00:00.000 --> 00:03.000
        <v Anna>Guten Morgen!</v>

        NOTE internal comment

        01:00:00.500 --> 01:00:02.000
        One hour in.
        """
        let parsed = try #require(PodcastTranscript.parse(Data(vtt.utf8)))
        #expect(parsed.synced)
        #expect(parsed.lines.first?.text == "Guten Morgen!")
        #expect(parsed.lines.first?.start == 0)
        #expect(parsed.lines.last?.start == 3600.5)
    }

    @Test("Podcasting-2.0 JSON: segments map, empty bodies drop")
    func json() throws {
        let json = """
        {"version":"1.0.0","segments":[
          {"startTime":0.5,"endTime":3.2,"body":"First words"},
          {"startTime":4.0,"body":"  "},
          {"startTime":6.1,"body":"More words"}
        ]}
        """
        let parsed = try #require(PodcastTranscript.parse(Data(json.utf8)))
        #expect(parsed.lines.map(\.text) == ["First words", "More words"])
        #expect(parsed.lines.first?.start == 0.5)
    }

    @Test("Garbage/empty/foreign shapes yield nil — the entry stays away")
    func garbage() {
        #expect(PodcastTranscript.parse(Data()) == nil)
        #expect(PodcastTranscript.parse(Data("just some prose without cues".utf8)) == nil)
        #expect(PodcastTranscript.parse(Data("{\"hello\":1}".utf8)) == nil)
        #expect(PodcastTranscript.parse(Data("<html><body>portal</body></html>".utf8)) == nil)
    }

    @Test("Timestamp forms: SRT comma, VTT dot, with/without hours")
    func timestamps() {
        #expect(PodcastTranscript.timestamp("00:00:01,500") == 1.5)
        #expect(PodcastTranscript.timestamp("02:03.250") == 123.25)
        #expect(PodcastTranscript.timestamp("01:00:00.000") == 3600)
        #expect(PodcastTranscript.timestamp("nonsense") == nil)
    }
}
#endif
