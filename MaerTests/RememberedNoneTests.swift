// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// What a foreign service does not have is remembered like a
/// hit: „keine Dauer“ and „kein Cover“ ask at most once, also
/// across a restart. A failure is no answer, but counts as asked for
/// the rest of the session.
struct RememberedNoneTests {
    /// Counts every question to archive.org; answers per id from the table.
    /// Unchecked because one lock guards the asks; the replies are set once.
    nonisolated final class Wire: @unchecked Sendable {
        /// `heldFirst`: the first question meets a holdback, later ones the files.
        /// `restingFor`: the first n questions meet a resting host.
        enum Reply { case files([(format: String?, length: String?)]), failure,
                     heldFirst([(format: String?, length: String?)]),
                     restingFor(Int, [(format: String?, length: String?)]) }
        private let lock = NSLock()
        private var _asks: [String: Int] = [:]
        let replies: [String: Reply]

        init(_ replies: [String: Reply]) { self.replies = replies }

        func asks(_ identifier: String) -> Int { lock.withLock { _asks[identifier, default: 0] } }

        var wire: ArchiveRuntimeService.Wire {
            ArchiveRuntimeService.Wire(files: { identifier in
                let asked = self.lock.withLock {
                    self._asks[identifier, default: 0] += 1
                    return self._asks[identifier, default: 0]
                }
                switch self.replies[identifier] {
                case .files(let files): return files
                case .heldFirst(let files):
                    if asked == 1 { throw FetchHeldBack() }
                    return files
                case .restingFor(let count, let files):
                    if asked <= count { throw HostCourtesy.Resting(host: "archive.org", remaining: .seconds(60)) }
                    return files
                case .failure, nil: throw URLError(.timedOut)
                }
            })
        }
    }

    private static func suite() -> String { "remembered-none-\(UUID().uuidString)" }

    @Test("Duration: ten appearances of a tile without a duration ask once, and after the restart not at all")
    func aMissingRuntimeIsAskedOnce() async {
        let suite = Self.suite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let wire = Wire(["none": .files([(format: "PNG", length: nil)]),
                         "found": .files([(format: "VBR MP3", length: "600")])])
        let first = ArchiveRuntimeService(wire: wire.wire, suiteName: suite)
        for _ in 0..<10 {
            #expect(await first.runtimeSeconds(identifier: "none") == nil)
            #expect(await first.runtimeSeconds(identifier: "found") == 600)
        }
        #expect(wire.asks("none") == 1, "ein Nein wird nicht wieder gefragt")
        #expect(wire.asks("found") == 1)
        // Restart: a new service on the same defaults.
        let second = ArchiveRuntimeService(wire: wire.wire, suiteName: suite)
        #expect(await second.runtimeSeconds(identifier: "none") == nil)
        #expect(await second.runtimeSeconds(identifier: "found") == 600)
        #expect(wire.asks("none") == 1 && wire.asks("found") == 1, "das Gemerkte ueberlebt die Sitzung")
    }

    @Test("Duration: a failure counts as asked for the session, but is not remembered")
    func aFailureCountsForTheSessionOnly() async {
        let suite = Self.suite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let wire = Wire(["down": .failure])
        let first = ArchiveRuntimeService(wire: wire.wire, suiteName: suite)
        for _ in 0..<10 { #expect(await first.runtimeSeconds(identifier: "down") == nil) }
        #expect(wire.asks("down") == 1, "eine Anfrage je Eintrag und Sitzung, auch beim Fehlschlag")
        let second = ArchiveRuntimeService(wire: wire.wire, suiteName: suite)
        _ = await second.runtimeSeconds(identifier: "down")
        #expect(wire.asks("down") == 2, "ein Fehlschlag ist keine Antwort: die naechste Sitzung fragt wieder")
    }

    @Test("Duration: a block books no question, the tile asks once afterwards")
    func aHoldbackIsNotAQuestion() async {
        let suite = Self.suite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let wire = Wire(["held": .heldFirst([(format: "VBR MP3", length: "300")])])
        let service = ArchiveRuntimeService(wire: wire.wire, suiteName: suite)
        #expect(await service.runtimeSeconds(identifier: "held") == nil, "waehrend der Sperre keine Dauer")
        #expect(await service.runtimeSeconds(identifier: "held") == 300, "nach der Sperre fragt die Kachel")
        #expect(wire.asks("held") == 2)
    }

    @Test("Duration: a resting host books no question, after the rest the tile asks once")
    func aRestingHostIsNotAQuestion() async {
        let suite = Self.suite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let wire = Wire(["rest": .restingFor(10, [(format: "VBR MP3", length: "420")])])
        let service = ArchiveRuntimeService(wire: wire.wire, suiteName: suite)
        for _ in 0..<10 {
            #expect(await service.runtimeSeconds(identifier: "rest") == nil, "while the host rests, no runtime")
        }
        #expect(await service.runtimeSeconds(identifier: "rest") == 420, "after the rest the tile asks")
        #expect(await service.runtimeSeconds(identifier: "rest") == 420)
        #expect(wire.asks("rest") == 11, "ten ends without a question, then one real one")
    }

    @Test("Duration: remembered for ten years, a no as long as a hit")
    func keptForGood() {
        #expect(ArchiveRuntimeService.keptFor >= 10 * 365 * 24 * 3600)
    }

    @Test("Cover: a placeholder survives the session, does not write at once and drops with the emptying of the cache")
    @MainActor
    func aPlaceholderIsRememberedForGood() throws {
        let suite = Self.suite()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            ServicePlaceholderCovers.dropSessionCopy()
        }
        ServicePlaceholderCovers.dropSessionCopy()
        let url = try #require(URL(string: "https://archive.org/services/img/GUNSMOKE05"))
        #expect(!ServicePlaceholderCovers.contains(url, defaults: defaults))
        ServicePlaceholderCovers.insert(url, defaults: defaults)
        #expect(defaults.data(forKey: ServicePlaceholderCovers.storeKey) == nil,
                "ein Eintrag schreibt nicht, erst der Fegelauf")
        ServicePlaceholderCovers.flush(defaults: defaults)
        ServicePlaceholderCovers.dropSessionCopy()
        #expect(ServicePlaceholderCovers.contains(url, defaults: defaults), "gemerkt ueber den Neustart")
        ServicePlaceholderCovers.forgetAll(defaults: defaults)
        ServicePlaceholderCovers.dropSessionCopy()
        #expect(!ServicePlaceholderCovers.contains(url, defaults: defaults), "das Leeren des Caches fragt neu")
    }

    @Test("Cover: a list under a foreign stamp is not read and drops at the next write")
    @MainActor
    func aListUnderAnotherRuleFalls() throws {
        let suite = Self.suite()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            ServicePlaceholderCovers.dropSessionCopy()
        }
        ServicePlaceholderCovers.dropSessionCopy()
        let old = "https://archive.org/services/img/OLD"
        let written = try JSONSerialization.data(withJSONObject: ["rule": "another-rule", "urls": [old]])
        defaults.set(written, forKey: ServicePlaceholderCovers.storeKey)
        let oldURL = try #require(URL(string: old))
        #expect(!ServicePlaceholderCovers.contains(oldURL, defaults: defaults), "fremder Stempel, nicht gelesen")
        let fresh = try #require(URL(string: "https://archive.org/services/img/NEW"))
        ServicePlaceholderCovers.insert(fresh, defaults: defaults)
        ServicePlaceholderCovers.flush(defaults: defaults)
        let data = try #require(defaults.data(forKey: ServicePlaceholderCovers.storeKey))
        let stored = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(stored["rule"] as? String == ArchiveServicePlaceholder.rule)
        #expect(stored["urls"] as? [String] == [fresh.absoluteString], "die alte Liste ist mit dem Schreiben gefallen")
    }

    @Test("Cover: at the cap the oldest drops, the count stays at the cap, and an entry costs no write")
    @MainActor
    func theListHasACap() throws {
        let suite = Self.suite()
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
            ServicePlaceholderCovers.dropSessionCopy()
        }
        ServicePlaceholderCovers.dropSessionCopy()
        let cap = ServicePlaceholderCovers.cap
        func address(_ n: Int) throws -> URL {
            try #require(URL(string: "https://archive.org/services/img/OTRR_Item_\(n)"))
        }
        for n in 0..<cap { ServicePlaceholderCovers.insert(try address(n), defaults: defaults) }
        #expect(ServicePlaceholderCovers.count(defaults: defaults) == cap)
        let clock = ContinuousClock()
        let extra = 3 * cap
        let spent = try clock.measure {
            for n in cap..<(cap + extra) { ServicePlaceholderCovers.insert(try address(n), defaults: defaults) }
        }
        print("PLACEHOLDER insert at cap \(cap): \(extra) inserts in \(spent)")
        #expect(defaults.data(forKey: ServicePlaceholderCovers.storeKey) == nil,
                "kein Eintrag hat geschrieben, auch nicht am Deckel")
        #expect(ServicePlaceholderCovers.count(defaults: defaults) == cap, "die Zahl bleibt beim Deckel")
        #expect(!ServicePlaceholderCovers.contains(try address(0), defaults: defaults), "der aelteste ist weg")
        #expect(!ServicePlaceholderCovers.contains(try address(extra - 1), defaults: defaults))
        #expect(ServicePlaceholderCovers.contains(try address(extra), defaults: defaults), "der aelteste lebende")
        #expect(ServicePlaceholderCovers.contains(try address(cap + extra - 1), defaults: defaults))
        // And after the restart the same list.
        ServicePlaceholderCovers.flush(defaults: defaults)
        ServicePlaceholderCovers.dropSessionCopy()
        #expect(ServicePlaceholderCovers.count(defaults: defaults) == cap)
        #expect(ServicePlaceholderCovers.contains(try address(extra), defaults: defaults))
    }

    @Test("Cover: the stamp arises from the constants of the detection")
    func theStampIsBuiltFromTheJudgement() {
        #expect(ArchiveServicePlaceholder.rule.contains("2212"))
        #expect(ArchiveServicePlaceholder.rule.contains("b5ef1d4b"))
        #expect(ArchiveServicePlaceholder.rule.hasSuffix("strip-3"))
    }

    @Test("Cover: the door asks the remembered before every network path and remembers every detected placeholder", .needsTheSources)
    func theDoorAsksTheMemoryFirst() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Networking/Artwork.swift"), encoding: .utf8)
        let asked = try #require(text.range(of: "if ServicePlaceholderCovers.contains(url) {"))
        let network = try #require(text.range(of: "await CoverFetchCoalescer.fetch(url"))
        #expect(asked.lowerBound < network.lowerBound, "the memory is asked before the network")
        let judged = try #require(text.range(of: "if ArchiveServicePlaceholder.isPlaceholder(data: data, url: url) {"))
        let booked = try #require(text.range(of: "ServicePlaceholderCovers.insert(url)"))
        #expect(judged.upperBound < booked.lowerBound)
        #expect(text.contains("ServicePlaceholderCovers.forgetAll()"), "clearing the cover cache re-asks")
        #expect(!text.contains("static var seen"), "the session-only set is gone")
        let sweep = try #require(text.range(of: "static func sweep() {"))
        let written = try #require(text.range(of: "ServicePlaceholderCovers.flush()"))
        let nextFunction = try #require(text.range(of: "static func sweepIfOverCap("))
        #expect(sweep.upperBound < written.lowerBound && written.upperBound < nextFunction.lowerBound,
                "the sweep at start and on going to the background writes the list")
    }
}
#endif
