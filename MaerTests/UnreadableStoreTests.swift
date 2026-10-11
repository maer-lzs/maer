// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A store that stands and does not decode is read as none; the next write
/// sets it aside under `.corrupt` and writes the new state: favorites, own
/// stations, the last heard, the play counts and the known servers take the
/// write, and the unreadable value stays recoverable.
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

    @Test("die Schreibregel: nichts beiseite ohne Wert und bei lesbarem Wert; ein unlesbarer Wert oder einer anderer Art liegt danach beiseite, ein spaeterer ersetzt die Beiseite-Kopie")
    func theWriteRule() throws {
        let defaults = try fresh()
        let key = "probe"
        let aside = key + ".corrupt"
        CorruptStore.setAsideUnreadable([String].self, defaultsKey: key, defaults: defaults, label: "test")
        #expect(defaults.object(forKey: aside) == nil, "an empty key set something aside")
        defaults.set(try JSONEncoder().encode(["a"]), forKey: key)
        CorruptStore.setAsideUnreadable([String].self, defaultsKey: key, defaults: defaults, label: "test")
        #expect(defaults.object(forKey: aside) == nil, "a readable value was set aside")
        defaults.set(Self.unreadable, forKey: key)
        CorruptStore.setAsideUnreadable([String].self, defaultsKey: key, defaults: defaults, label: "test")
        let first = defaults.data(forKey: aside)
        #expect(first == Self.unreadable, "the unreadable value was not set aside")
        defaults.set(42, forKey: key)
        CorruptStore.setAsideUnreadable([String].self, defaultsKey: key, defaults: defaults, label: "test")
        let later = defaults.integer(forKey: aside)
        #expect(later == 42, "a later unreadable value did not replace the aside copy (the last failure is kept)")
    }

    @Test("unlesbare Radio-Listen und Zaehler liegen beiseite, der neue Sender steht", .needsTheSources)
    func radioListsAreSetAside() throws {
        let defaults = try fresh()
        let keys = [RadioStore.favoritesKey, RadioStore.manualKey, RadioStore.recentsKey,
                    RadioStore.mostPlayedKey, RadioStore.playCountsKey]
        for key in keys { defaults.set(Self.unreadable, forKey: key) }
        RadioStore.replaceFavorites([station], defaults: defaults)
        RadioStore.addManual(station, defaults: defaults)
        RadioStore.recordRecent(station, defaults: defaults)
        RadioStore.recordPlay(station, defaults: defaults)
        for key in keys {
            let aside = defaults.data(forKey: key + ".corrupt")
            #expect(aside == Self.unreadable, "\(key) was not set aside")
        }
        let favorites = RadioStore.favorites(defaults: defaults).map(\.id)
        let manual = RadioStore.manualStations(defaults: defaults).map(\.id)
        let recents = RadioStore.recents(defaults: defaults).map(\.id)
        let counts = RadioStore.playCounts(defaults: defaults)
        #expect(favorites == [station.id] && manual == [station.id] && recents == [station.id] && counts[station.id] == 1,
                "the new state did not stand")
        // A second write finds a readable list and leaves the aside copy as it is.
        RadioStore.replaceFavorites([], defaults: defaults)
        let stillAside = defaults.data(forKey: RadioStore.favoritesKey + ".corrupt")
        #expect(stillAside == Self.unreadable, "a second write replaced the aside copy")
    }

    @Test("eine unlesbare Server-Liste liegt beiseite, der gelungene Login steht")
    func knownServersAreSetAside() throws {
        let defaults = try fresh()
        defaults.set(Self.unreadable, forKey: KnownServers.storeKey)
        KnownServers.remember("https://abs.example", service: .audiobookshelf, defaults: defaults)
        let aside = defaults.data(forKey: KnownServers.storeKey + ".corrupt")
        #expect(aside == Self.unreadable, "the server list was not set aside")
        let remembered = KnownServers.all(defaults: defaults).map(\.url)
        #expect(remembered == ["https://abs.example"], "the login did not stand")
    }

    /// Where a stored value is decoded and an unreadable one becomes the
    /// empty value, per file; the stock is the count. Each one either has
    /// its write behind `CorruptStore.setAsideUnreadable` (`guardedWriters`) or
    /// stands for a reason:
    /// * `Artwork+Memo.swift`, `ResolutionCacheStore.swift` (2): caches,
    ///   rebuilt from the network.
    /// * `BookmarkQueue.swift`: the offline copy of the server's bookmarks,
    ///   replaced whole by the next answer (the queue itself reads through
    ///   `CorruptStore.load`).
    /// * `StandCarrier.swift` (3, `StandMirrorStore` for every carrier):
    ///   mirrors of the other side, an unreadable one costs a full pull.
    /// * `PodcastTranscript.swift`: parses a downloaded document, writes
    ///   nothing back.
    static let decodeToEmptyStock = [
        "Artwork+Memo.swift": 1,
        "BookmarkQueue.swift": 1,
        "KnownServers.swift": 1,
        "PodcastTranscript.swift": 1,
        "RadioModels.swift": 2,
        "ResolutionCacheStore.swift": 2,
        "StandCarrier.swift": 3,
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
            let guarded = code.components(separatedBy: "CorruptStore.setAsideUnreadable(").count - 1
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
