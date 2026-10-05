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

    @Test("ein Ausfall ist kein Befund: gemerkt wird nur ein Dokument oder ein klares Nein")
    func onlyAnAnswerIsRemembered() {
        #expect(PodcastTranscript.remembers(status: 200))
        #expect(PodcastTranscript.remembers(status: 404) && PodcastTranscript.remembers(status: 410))
        #expect(!PodcastTranscript.remembers(status: nil), "a transport failure is no answer")
        #expect(!PodcastTranscript.remembers(status: 500) && !PodcastTranscript.remembers(status: 503))
        #expect(!PodcastTranscript.remembers(status: 429) && !PodcastTranscript.remembers(status: 401))
    }

    /// The session cache of the service: a failed fetch is asked again at
    /// the next look and the transcript arrives; a document that does not
    /// parse and a 404 stand for the session.
    @Test("der Dienst fragt nach einem Ausfall neu und merkt nur Antworten")
    @MainActor
    func theServiceAsksAgainAfterAFailure() async throws {
        let url = "https://feeds.example/transcript-\(UUID().uuidString).vtt"
        let remote = try #require(URL(string: url))
        let vtt = Data("WEBVTT\n\n00:00.000 --> 00:03.000\nGuten Morgen!\n".utf8)
        final class Script { var answers: [Result<(Data, Int), URLError>] = []; var asked = 0 }
        let script = Script()
        let service = PodcastTranscriptService()
        service.fetch = { _ in
            script.asked += 1
            let next = script.answers.removeFirst()
            let (data, status) = try next.get()
            return (data, HTTPURLResponse(url: remote, statusCode: status, httpVersion: nil, headerFields: nil))
        }

        script.answers = [.failure(URLError(.notConnectedToInternet)), .success((vtt, 200))]
        #expect(await service.transcript(for: url) == nil, "the precondition: the first fetch failed")
        #expect(await service.transcript(for: url)?.lines.first?.text == "Guten Morgen!",
                "a transport failure stood as no transcript for the session")
        #expect(script.asked == 2)
        _ = await service.transcript(for: url)
        #expect(script.asked == 2, "a read transcript is asked again")

        let broken = "https://feeds.example/broken-\(UUID().uuidString).vtt"
        script.answers = [.success((Data("<html>portal</html>".utf8), 503)), .success((Data("not a transcript".utf8), 200))]
        #expect(await service.transcript(for: broken) == nil)
        #expect(await service.transcript(for: broken) == nil)
        #expect(script.asked == 4, "a server error stood as no transcript")
        _ = await service.transcript(for: broken)
        #expect(script.asked == 4, "a document that does not parse is an answer and stands")

        let gone = "https://feeds.example/gone-\(UUID().uuidString).vtt"
        script.answers = [.success((Data(), 404))]
        #expect(await service.transcript(for: gone) == nil)
        _ = await service.transcript(for: gone)
        #expect(script.asked == 5, "a clean 404 is an answer and stands")
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
