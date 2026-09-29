// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Hoeflichkeit gegenueber fremden Diensten: hoechstens vier Anfragen
/// gleichzeitig je Host, MusicBrainz und das Cover Art Archive gemeinsam
/// hoechstens eine je Sekunde, und nach 429 oder 503 ruht der ganze Host so
/// lange, wie er verlangt, auch ein eigener Server.
struct HostCourtesyTests {
    // MARK: - Die Regel, rein

    @Test("Regel: MusicBrainz und das Cover Art Archive sind eine Gruppe, jeder andere Host seine eigene")
    func groups() {
        #expect(HostCourtesyRule.group(of: "musicbrainz.org") == "musicbrainz")
        #expect(HostCourtesyRule.group(of: "coverartarchive.org") == "musicbrainz")
        #expect(HostCourtesyRule.group(of: "beta.MusicBrainz.org") == "musicbrainz")
        #expect(HostCourtesyRule.group(of: "notmusicbrainz.org") == "notmusicbrainz.org", "a suffix is a domain, not a string")
        #expect(HostCourtesyRule.group(of: "archive.org") == "archive.org")
    }

    @Test("Regel: fremd vier gleichzeitig, MusicBrainz eine je Sekunde, eigene Server ohne Deckel")
    func allowances() {
        #expect(HostCourtesyRule.allowance(group: "archive.org", isOwnServer: false)
                == .init(concurrent: 4, spacing: nil))
        #expect(HostCourtesyRule.allowance(group: "musicbrainz", isOwnServer: false)
                == .init(concurrent: 1, spacing: .seconds(1)))
        #expect(HostCourtesyRule.allowance(group: "abs.home", isOwnServer: true)
                == .init(concurrent: nil, spacing: nil))
        #expect(HostCourtesyRule.asksToRest(status: 429) && HostCourtesyRule.asksToRest(status: 503))
        #expect(!HostCourtesyRule.asksToRest(status: 500) && !HostCourtesyRule.asksToRest(status: 404))
    }

    @Test("Regel: Retry-After in Sekunden oder als Datum, sonst 2, 4, 8 bis 60 Sekunden, hoechstens eine Stunde")
    func rests() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(HostCourtesyRule.rest(retryAfter: "120", restsInARow: 0, now: now) == .seconds(120))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let inThirty = formatter.string(from: now.addingTimeInterval(30))
        #expect(HostCourtesyRule.rest(retryAfter: inThirty, restsInARow: 0, now: now) == .seconds(30))
        #expect(HostCourtesyRule.rest(retryAfter: "999999", restsInARow: 0, now: now) == .seconds(3600))
        #expect(HostCourtesyRule.rest(retryAfter: nil, restsInARow: 0, now: now) == .seconds(2))
        #expect(HostCourtesyRule.rest(retryAfter: nil, restsInARow: 1, now: now) == .seconds(4))
        #expect(HostCourtesyRule.rest(retryAfter: "soon", restsInARow: 2, now: now) == .seconds(8))
        #expect(HostCourtesyRule.rest(retryAfter: nil, restsInARow: 9, now: now) == .seconds(60))
    }

    // MARK: - Der Aktor, eigene Instanz

    /// Zaehlt, wie viele `enter` schon zurueckkamen.
    actor Passed {
        var count = 0
        func add() { count += 1 }
    }

    private static func url(_ host: String) -> URL { URL(string: "https://\(host)/x")! }

    @Test("Aktor: nie mehr als vier gleichzeitig an einen fremden Host, der fuenfte wartet auf einen Platz")
    func capOfFour() async throws {
        let courtesy = HostCourtesy(ownHosts: { [] })
        var passes: [HostCourtesy.Pass] = []
        for _ in 0..<4 { passes.append(try await courtesy.enter(Self.url("a.example"))) }
        let passed = Passed()
        let fifth = Task {
            let pass = try await courtesy.enter(Self.url("a.example"))
            await passed.add()
            return pass
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await passed.count == 0, "the fifth request went out beside four")
        #expect(await courtesy.counts(group: "a.example").inFlight == 4)
        await courtesy.leave(passes[0], status: 200, retryAfter: nil)
        let fifthPass = try await fifth.value
        #expect(await passed.count == 1, "a slot that frees goes to the one waiting")
        #expect(await courtesy.counts(group: "a.example").inFlight == 4)
        #expect(await courtesy.counts(group: "a.example").held == 1)
        for pass in passes.dropFirst() + [fifthPass] { await courtesy.leave(pass, status: 200, retryAfter: nil) }
        #expect(await courtesy.counts(group: "a.example").inFlight == 0)
    }

    @Test("Aktor: ein eigener Server hat keinen Deckel, das Geraet selbst geht nicht durch die Regel")
    func ownServerAndLoopback() async throws {
        let courtesy = HostCourtesy(ownHosts: { ["abs.home.example"] })
        for _ in 0..<10 { _ = try await courtesy.enter(Self.url("abs.home.example")) }
        #expect(await courtesy.counts(group: "abs.home.example").inFlight == 10)
        let loop = try await courtesy.enter(URL(string: "http://127.0.0.1:8811/v1")!)
        #expect(!loop.counted)
    }

    @Test("Aktor: MusicBrainz und das Cover Art Archive teilen die eine Sekunde")
    func musicBrainzSpacing() async throws {
        let courtesy = HostCourtesy(ownHosts: { [] })
        let clock = ContinuousClock()
        let started = clock.now
        let first = try await courtesy.enter(Self.url("musicbrainz.org"))
        await courtesy.leave(first, status: 200, retryAfter: nil)
        let second = try await courtesy.enter(Self.url("coverartarchive.org"))
        await courtesy.leave(second, status: 200, retryAfter: nil)
        let spent = started.duration(to: clock.now)
        #expect(spent >= .milliseconds(950), "two starts in the group less than a second apart: \(spent)")
        #expect(await courtesy.counts(group: "musicbrainz").asked == 2)
    }

    @Test("Aktor: ein 429 mit Retry-After haelt ALLE Anfragen an den Host so lange an, auch an einen eigenen Server")
    func retryAfterHoldsTheWholeHost() async throws {
        let courtesy = HostCourtesy(ownHosts: { ["own.example"] })
        let clock = ContinuousClock()
        for host in ["far.example", "own.example"] {
            let pass = try await courtesy.enter(Self.url(host))
            let refused = clock.now
            await courtesy.leave(pass, status: host == "own.example" ? 503 : 429, retryAfter: "1")
            async let a = courtesy.enter(Self.url(host))
            async let b = courtesy.enter(Self.url(host))
            let (passA, passB) = try await (a, b)
            #expect(refused.duration(to: clock.now) >= .milliseconds(950), "\(host) was asked during its rest")
            await courtesy.leave(passA, status: 200, retryAfter: nil)
            await courtesy.leave(passB, status: 200, retryAfter: nil)
            #expect(await courtesy.counts(group: host).refused == 1)
        }
    }

    @Test("Aktor: eine lange Ruhe schickt nichts, die Anfrage endet ungefragt")
    func aLongRestSendsNothing() async throws {
        let courtesy = HostCourtesy(ownHosts: { [] })
        let pass = try await courtesy.enter(Self.url("busy.example"))
        await courtesy.leave(pass, status: 429, retryAfter: "120")
        await #expect(throws: HostCourtesy.Resting.self) {
            _ = try await courtesy.enter(Self.url("busy.example"))
        }
        #expect(await courtesy.counts(group: "busy.example").asked == 1, "the resting host was asked again")
    }

    // MARK: - Der Zaun ueber die Wege nach aussen

    private static func code(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return SyncContractFenceTests.stripped(try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("Zaun: jede Frage an eine Sitzung geht durch das Hoeflichkeits-Tor, die Ausnahmen sind benannt", .needsTheSources)
    func everyWayPassesTheGate() throws {
        let retry = try Self.code("Sources/Networking/Retry.swift")
        #expect(retry.contains("try await courteously(request) {\n                    try await session.data(for: request, delegate: redirects)"),
                "fetch asks its session inside the gate, per attempt")
        #expect(retry.components(separatedBy: "session.data(").count - 1 == 1)
        let http = try Self.code("Sources/Networking/HTTP.swift")
        for ask in ["session(lane).data(for: prepared)", "session(.stream).bytes(for: prepared)",
                    "session(lane).download(for: prepared)", "session(lane).upload(for: prepared, fromFile: file)"] {
            #expect(http.contains("courteously(prepared) {") && http.contains(ask), "\(ask)")
            let site = try #require(http.range(of: ask))
            let before = http[..<site.lowerBound].suffix(80)
            #expect(before.contains("courteously(prepared)"), "\(ask) asks past the gate")
        }
        // Named exceptions: the socket lane talks to the person's own sync
        // service and holds one standing connection; the background session
        // is scheduled by the system and runs what the person asked for.
        #expect(http.components(separatedBy: "webSocketTask(with:").count - 1 == 1)
        let downloader = try Self.code("Sources/Networking/FileDownloader.swift")
        #expect(downloader.components(separatedBy: "downloadTask(with: ").count - 1 == 1)
        #expect(downloader.components(separatedBy: "downloadTask(withResumeData: ").count - 1 == 1)
    }

    @Test("Zaun: niemand ausser dem Tor fuehrt einen eigenen MusicBrainz-Abstand", .needsTheSources)
    func noOwnMusicBrainzPace() throws {
        for path in ["Sources/Networking/CoverArtArchive.swift", "Sources/Networking/RadioArtworkService.swift",
                     "Sources/Networking/ArtistPortraitService.swift"] {
            let text = try Self.code(path)
            #expect(!text.contains("Task.sleep") && !text.contains("lastRequest"), "\(path) keeps its own pace")
        }
    }
}
#endif
