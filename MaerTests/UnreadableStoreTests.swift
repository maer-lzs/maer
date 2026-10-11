// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A store that stands and does not decode is read as none, and the next
/// write does not replace it: favorites, own stations, the last heard, the
/// play counts and the known servers stay as they were.
struct UnreadableStoreTests {
    private static let unreadable = Data("{\"not\": \"a list\"}".utf8)

    private func fresh() throws -> UserDefaults {
        let suite = "unreadable-store-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let station = RadioStation(id: "radio:manual:probe", name: "Probe",
                                       streamURL: "https://probe.example/stream")

    @Test("die Schreibregel: frei ohne Wert, frei bei lesbarem Wert, gesperrt bei unlesbarem Wert oder anderem Typ")
    func theWriteRule() throws {
        let defaults = try fresh()
        let key = "probe"
        let free = CorruptStore.mayReplace([String].self, defaultsKey: key, defaults: defaults, label: "test")
        #expect(free, "an empty key is a fresh start")
        defaults.set(try JSONEncoder().encode(["a"]), forKey: key)
        let readable = CorruptStore.mayReplace([String].self, defaultsKey: key, defaults: defaults, label: "test")
        #expect(readable, "a readable value may be replaced")
        defaults.set(Self.unreadable, forKey: key)
        let blocked = CorruptStore.mayReplace([String].self, defaultsKey: key, defaults: defaults, label: "test")
        #expect(!blocked, "an unreadable value would be written over")
        defaults.set(42, forKey: key)
        let other = CorruptStore.mayReplace([String].self, defaultsKey: key, defaults: defaults, label: "test")
        #expect(!other, "a value of another kind would be written over")
    }

    @Test("unlesbare Radio-Listen und Zaehler bleiben stehen, wenn ein Sender dazukommt", .needsTheSources)
    func radioListsAreNotWrittenOver() throws {
        let defaults = try fresh()
        for key in [RadioStore.favoritesKey, RadioStore.manualKey, RadioStore.recentsKey,
                    RadioStore.mostPlayedKey, RadioStore.playCountsKey] {
            defaults.set(Self.unreadable, forKey: key)
        }
        RadioStore.replaceFavorites([station], defaults: defaults)
        RadioStore.addManual(station, defaults: defaults)
        RadioStore.recordRecent(station, defaults: defaults)
        RadioStore.recordPlay(station, defaults: defaults)
        for key in [RadioStore.favoritesKey, RadioStore.manualKey, RadioStore.recentsKey,
                    RadioStore.mostPlayedKey, RadioStore.playCountsKey] {
            let kept = defaults.data(forKey: key)
            #expect(kept == Self.unreadable, "\(key) was written over")
        }
        // Readable lists take the write as before.
        let open = try fresh()
        RadioStore.replaceFavorites([station], defaults: open)
        RadioStore.addManual(station, defaults: open)
        RadioStore.recordPlay(station, defaults: open)
        let favorites = RadioStore.favorites(defaults: open).map(\.id)
        let manual = RadioStore.manualStations(defaults: open).map(\.id)
        let counts = RadioStore.playCounts(defaults: open)
        #expect(favorites == [station.id] && manual == [station.id] && counts[station.id] == 1)
    }

    @Test("eine unlesbare Server-Liste bleibt stehen, wenn eine Verbindung gelingt")
    func knownServersAreNotWrittenOver() throws {
        let defaults = try fresh()
        defaults.set(Self.unreadable, forKey: KnownServers.storeKey)
        KnownServers.remember("https://abs.example", service: .audiobookshelf, defaults: defaults)
        let kept = defaults.data(forKey: KnownServers.storeKey)
        #expect(kept == Self.unreadable, "the server list was written over")
        let open = try fresh()
        KnownServers.remember("https://abs.example", service: .audiobookshelf, defaults: open)
        let remembered = KnownServers.all(defaults: open).map(\.url)
        #expect(remembered == ["https://abs.example"])
    }

    /// Where a stored value is decoded and an unreadable one becomes the
    /// empty value, per file; the stock is the count. Each one either has
    /// its write behind `CorruptStore.mayReplace` (`guardedWriters`) or
    /// stands for a reason:
    /// * `Artwork+Memo.swift`, `ResolutionCacheStore.swift` (2): caches,
    ///   rebuilt from the network.
    /// * `BookmarkQueue.swift`: the offline copy of the server's bookmarks,
    ///   replaced whole by the next answer (the queue itself reads through
    ///   `CorruptStore.load`).
    /// * the three cloud carriers and `StandCarrier.swift` (2): mirrors of
    ///   the other side, an unreadable one costs a full pull.
    /// * `PodcastTranscript.swift`: parses a downloaded document, writes
    ///   nothing back.
    static let decodeToEmptyStock = [
        "Artwork+Memo.swift": 1,
        "BookmarkQueue.swift": 1,
        "CloudKitChoiceCarrier.swift": 1,
        "CloudKitPlaylistCarrier.swift": 1,
        "CloudKitStatsCarrier.swift": 1,
        "KnownServers.swift": 1,
        "PodcastTranscript.swift": 1,
        "RadioModels.swift": 2,
        "ResolutionCacheStore.swift": 2,
        "StandCarrier.swift": 2,
    ]

    /// The stores above that hold what a person made; their writes ask.
    static let guardedWriters = ["KnownServers.swift": 1, "RadioModels.swift": 2, "BrowsedEpisodes.swift": 1]

    nonisolated static func decodesToEmpty(_ line: String) -> Bool {
        let tight = StockDriftTests.squeezed(line)
        return tight.contains("try?JSONDecoder().decode(")
            && ["return[]", "return[:]", "??[]", "??[:]"].contains { tight.contains($0) }
    }

    @Test("jede Stelle, die Unlesbares als leer liest, ist gezaehlt; die Speicher einer Person schreiben nur ueber die Schreibregel", .needsTheSources)
    func everyEmptyReadIsCounted() throws {
        var counts: [String: Int] = [:]
        var asks: [String: Int] = [:]
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = SyncContractFenceTests.stripped(text)
            let found = code.split(separator: "\n").filter { Self.decodesToEmpty(String($0)) }.count
            if found > 0 { counts[name] = found }
            let guarded = code.components(separatedBy: "CorruptStore.mayReplace(").count - 1
            if guarded > 0 { asks[name] = guarded }
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.decodeToEmptyStock)
        #expect(drift.isEmpty, "a stored value is read as empty unseen, or the stock stands above the count: \(drift)")
        #expect(asks == Self.guardedWriters, "a write of a person's store does not ask the rule: \(asks)")
        #expect(Self.decodesToEmpty("let x = (try? JSONDecoder().decode([A].self, from: d)) ?? []"))
        #expect(Self.decodesToEmpty("let x = try?  JSONDecoder().decode([A].self, from: d) else { return [:] }"))
        #expect(!Self.decodesToEmpty("return try? JSONDecoder().decode(A.self, from: d)"))
    }
}
#endif
