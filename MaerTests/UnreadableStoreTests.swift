// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A store that stands and does not decode is read as none; the next write
/// sets it aside under `CorruptStore.asideKey` and writes the new state: favorites, own
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

    @Test("the write rule: nothing aside without a value and with a readable value; an unreadable value or one of another kind lies aside afterwards, a later one replaces the aside copy")
    func theWriteRule() throws {
        let defaults = try fresh()
        let key = "probe"
        let aside = CorruptStore.asideKey(key)
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

    /// The aside copy must never travel: the sync takes a key by family
    /// prefix (`hasPrefix`), and a store key one letter short of a family
    /// (`radioFavorites`, `recentSearches`, `knownServers`) with `.corrupt`
    /// behind it stood one letter away. The hardest key is the family stem
    /// itself; its aside copy begins no family either.
    @Test("no aside key falls into a travelling family, not even that of the family stem; no family and no travelling value begins with the aside prefix")
    func noAsideKeyTravels() {
        let families = UserChoiceCatalog.travelingPrefixes + UserChoiceCatalog.familyPrefixes
        let asidePrefix = CorruptStore.asideKey("")
        for family in families {
            for key in [String(family.dropLast()), family + "probe"] {
                let aside = CorruptStore.asideKey(key)
                let travels = families.filter { aside.hasPrefix($0) }
                #expect(travels.isEmpty, "the aside key \(aside) falls into \(travels)")
            }
            #expect(!family.hasPrefix(asidePrefix), "the family \(family) begins with the aside prefix")
        }
        let scalars = UserChoiceCatalog.travelingScalars.filter { $0.hasPrefix(asidePrefix) }
        #expect(scalars.isEmpty, "a traveling value begins with the aside prefix: \(scalars)")
    }

    /// A literal that ends in `.corrupt` or begins (or goes on after an
    /// interpolation) with `corrupt.`: every spelling of an aside key,
    /// glued (`key + ".corrupt"`) or interpolated (`"\(key).corrupt"`).
    nonisolated static func buildsAsideKey(_ code: String) -> Bool {
        code.contains(".corrupt\"") || code.contains("\"corrupt.") || code.contains(")corrupt.")
    }

    @Test("an aside key arises only in CorruptStore, not even through interpolation", .needsTheSources)
    func onlyTheStoreNamesAsideKeys() throws {
        var builders: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) where name != "CorruptStore.swift" {
            if Self.buildsAsideKey(SyncContractFenceTests.stripped(text)) { builders.append(name) }
        }
        #expect(builders.isEmpty, "a file builds an aside key past CorruptStore.asideKey: \(builders)")
    }

    @Test("the reader of the aside keys sees every spelling, not the file extension")
    func theAsideKeyReaderReads() {
        #expect(Self.buildsAsideKey(#"let k = key + ".corrupt""#))
        #expect(Self.buildsAsideKey(#"let k = "\(key).corrupt""#))
        #expect(Self.buildsAsideKey(#"let k = "corrupt.\(key)""#))
        #expect(Self.buildsAsideKey(#"let k = "\(prefix)corrupt.\(key)""#))
        #expect(!Self.buildsAsideKey(#"url.appendingPathExtension("corrupt")"#), "the file aside is no key")
    }

    @Test("unreadable radio lists and counters lie aside, the new station stands", .needsTheSources)
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
            let aside = defaults.data(forKey: CorruptStore.asideKey(key))
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
        let stillAside = defaults.data(forKey: CorruptStore.asideKey(RadioStore.favoritesKey))
        #expect(stillAside == Self.unreadable, "a second write replaced the aside copy")
    }

    @Test("an unreadable server list lies aside, the successful login stands")
    func knownServersAreSetAside() throws {
        let defaults = try fresh()
        defaults.set(Self.unreadable, forKey: KnownServers.storeKey)
        KnownServers.remember("https://abs.example", service: .audiobookshelf, defaults: defaults)
        let aside = defaults.data(forKey: CorruptStore.asideKey(KnownServers.storeKey))
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
    /// * `StandCarrier.swift` (1, `StandMirrorStore`: the list of removals)
    ///   and `CarrierRows.swift` (1, the blobs of the mirrors, read once at
    ///   the move): mirrors of the other side, an unreadable one costs a
    ///   full pull.
    /// * `PodcastTranscript.swift`: parses a downloaded document, writes
    ///   nothing back.
    static let decodeToEmptyStock = [
        "Artwork+Memo.swift": 1,
        "CarrierRows.swift": 1,
        "KnownServers.swift": 1,
        "PodcastTranscript.swift": 1,
        "RadioModels.swift": 2,
        "ResolutionCacheStore.swift": 2,
        "StandCarrier.swift": 1,
    ]

    /// The stores above that hold what a person made; their writes ask.
    static let guardedWriters = ["KnownServers.swift": 1, "RadioModels.swift": 2, "BrowsedEpisodes.swift": 1]

    nonisolated static func decodesToEmpty(_ line: String) -> Bool {
        let tight = StockDriftTests.squeezed(line)
        return tight.contains("try?JSONDecoder().decode(")
            && ["return[]", "return[:]", "??[]", "??[:]"].contains { tight.contains($0) }
    }

    @Test("every place that reads the unreadable as empty is counted; the stores of a person write only through the write rule", .needsTheSources)
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
