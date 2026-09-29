// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Was es bei einem fremden Dienst nicht gibt, wird gemerkt wie ein
/// Treffer: „keine Dauer“ und „kein Cover“ fragen hoechstens einmal, auch
/// ueber einen Neustart. Ein Fehlschlag ist keine Antwort, zaehlt aber fuer
/// den Rest der Sitzung als gefragt.
struct RememberedNoneTests {
    /// Zaehlt jede Frage an archive.org; antwortet je Kennung aus der Tabelle.
    nonisolated final class Wire: @unchecked Sendable {
        enum Reply { case files([(format: String?, length: String?)]), failure }
        private let lock = NSLock()
        private var _asks: [String: Int] = [:]
        let replies: [String: Reply]

        init(_ replies: [String: Reply]) { self.replies = replies }

        func asks(_ identifier: String) -> Int { lock.withLock { _asks[identifier, default: 0] } }

        var wire: ArchiveRuntimeService.Wire {
            ArchiveRuntimeService.Wire(files: { identifier in
                self.lock.withLock { self._asks[identifier, default: 0] += 1 }
                switch self.replies[identifier] {
                case .files(let files): return files
                case .failure, nil: throw URLError(.timedOut)
                }
            })
        }
    }

    private static func suite() -> String { "remembered-none-\(UUID().uuidString)" }

    @Test("Dauer: zehn Erscheinungen einer Kachel ohne Dauer fragen einmal, und nach dem Neustart gar nicht")
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
        // Neustart: ein neuer Dienst auf denselben Defaults.
        let second = ArchiveRuntimeService(wire: wire.wire, suiteName: suite)
        #expect(await second.runtimeSeconds(identifier: "none") == nil)
        #expect(await second.runtimeSeconds(identifier: "found") == 600)
        #expect(wire.asks("none") == 1 && wire.asks("found") == 1, "das Gemerkte ueberlebt die Sitzung")
    }

    @Test("Dauer: ein Fehlschlag gilt fuer die Sitzung als gefragt, wird aber nicht gemerkt")
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

    @Test("Dauer: gemerkt wird fuer zehn Jahre, ein Nein so lange wie ein Treffer")
    func keptForGood() {
        #expect(ArchiveRuntimeService.keptFor >= 10 * 365 * 24 * 3600)
    }

    @Test("Cover: ein Platzhalter ueberlebt die Sitzung, faellt mit einer neuen Regel und mit dem Leeren des Caches")
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
        ServicePlaceholderCovers.dropSessionCopy()
        #expect(ServicePlaceholderCovers.contains(url, defaults: defaults), "gemerkt ueber den Neustart")
        // Unter einer anderen Regel ist das alte Nein nicht mehr findbar.
        let key = ServicePlaceholderCovers.prefix + url.absoluteString
        #expect(Artwork.Memo.remembered(key, under: ArchiveServicePlaceholder.rule, defaults: defaults) == .missing)
        #expect(Artwork.Memo.remembered(key, under: "another-rule", defaults: defaults) == nil)
        ServicePlaceholderCovers.forgetAll(defaults: defaults)
        ServicePlaceholderCovers.dropSessionCopy()
        #expect(!ServicePlaceholderCovers.contains(url, defaults: defaults), "das Leeren des Caches fragt neu")
    }

    @Test("Cover: die Tuer fragt das Gemerkte vor jedem Netzweg und merkt jeden erkannten Platzhalter", .needsTheSources)
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
    }
}
#endif
