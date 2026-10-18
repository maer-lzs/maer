// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A measurement for the move of the remaining blocks out of the defaults,
/// not a change: at 22,000 titles, the bytes and the keys of every family
/// that grows with the library, how long one write of a block that is
/// written whole takes, and what the whole domain costs to read. The
/// numbers stand in the test log (`E4MESS`); the case holds only that the
/// measure ran.
///
/// The library is synthetic and an upper bound where a family is per
/// title: every title carries its key. 500 shows, 2,000 books with five
/// bookmarks each, 30,000 imported and 30,000 archived marks.
@MainActor
@Suite(.serialized)
struct DefaultsBlockMeasureTests {
    static let titles = 22_000
    static let shows = 500

    static func titleId(_ index: Int) -> String { "rss:feed-\(index / 40):episode-\(UUID().uuidString)" }

    /// The bytes of a set of keys as the binary property list the domain is
    /// stored in.
    static func bytes(_ entries: [String: Any]) -> Int {
        (try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0))?.count ?? 0
    }

    /// The median and the longest of five calls, in milliseconds.
    static func timed(_ body: (Int) -> Void) -> (median: Double, max: Double) {
        var durations: [Double] = []
        for round in 0..<5 {
            let started = Date()
            body(round)
            durations.append(Date().timeIntervalSince(started) * 1000)
        }
        let sorted = durations.sorted()
        return (sorted[sorted.count / 2], sorted.last ?? 0)
    }

    static func timedThrowing(_ body: (Int) throws -> Void) throws -> (median: Double, max: Double) {
        var failure: Error?
        let result = timed { round in
            do { try body(round) } catch { failure = error }
        }
        if let failure { throw failure }
        return result
    }

    static func line(_ family: String, keys: Int, bytes: Int, write: (median: Double, max: Double)? = nil) {
        var text = "E4MESS family=\(family) keys=\(keys) bytes=\(bytes)"
        if let write { text += String(format: " write_ms_median=%.1f write_ms_max=%.1f", write.median, write.max) }
        print(text)
    }

    @Test("Messung: die Bloecke der Voreinstellungen bei 22.000 Titeln, Groesse, Schluessel, Schreibdauer")
    func theBlocksAt22000Titles() throws {
        let suite = "e4mess-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ids = (0..<Self.titles).map(Self.titleId)
        let showIds = (0..<Self.shows).map { _ in "rss:\(UUID().uuidString)" }

        // The mirrors of the carriers, written whole on every persist, in
        // the form the stands had before they moved into rows.
        var stands: [String: [Double]] = [:]
        for (index, id) in ids.enumerated() { stands[id] = [Double(index % 3600), 1_760_000_000_000 + Double(index), 3600] }
        let standWrite = try Self.timedThrowing { round in
            stands["rss:feed-0:round"] = [Double(round), 1_760_000_000_000, 3600]
            defaults.set(try JSONEncoder().encode(stands), forKey: CloudKitStandCarrier.mirrorKey)
        }
        Self.line("standMirror", keys: 1, bytes: defaults.data(forKey: CloudKitStandCarrier.mirrorKey)?.count ?? 0, write: standWrite)

        // The travelling choices: a rate and a played tail per title, eight per show.
        var choices: [String: UserChoiceValue] = [:]
        for id in ids {
            choices[AppStorageKeys.playbackRate(id)] = .double(1.25)
            choices[PlayedTail.key(id)] = .double(30)
        }
        for show in showIds {
            for key in PodcastShowPreferences.travellingKeys(showId: show) { choices[key] = .string("newestFirst") }
        }
        var records: [String: CloudChoiceRecord] = [:]
        for (key, value) in choices {
            records[key] = CloudChoiceRecord(key: key, payload: CloudChoicePayload.encode(value), t: 1_760_000_000_000, tombstone: false)
        }
        let choiceWrite = Self.timed { round in
            records["round"] = CloudChoiceRecord(key: "round", payload: CloudChoicePayload.encode(.int(round)), t: 1, tombstone: false)
            StandMirrorStore.saveRows(CloudKitChoiceCarrier.rows(of: records), key: CloudKitChoiceCarrier.mirrorKey, defaults: defaults)
        }
        Self.line("choiceMirror", keys: 1, bytes: Self.bytes([CloudKitChoiceCarrier.mirrorKey: defaults.object(forKey: CloudKitChoiceCarrier.mirrorKey) ?? Data()]), write: choiceWrite)

        // One stamp per travelling choice, written whole on every note.
        var stamps: [String: Double] = [:]
        for key in choices.keys { stamps[key] = 1_760_000_000_000 }
        let stampWrite = Self.timed { round in
            stamps["round"] = Double(round)
            defaults.set(stamps, forKey: UserChoiceCloudSync.stampsKey)
        }
        Self.line("userChoiceStamps", keys: 1, bytes: Self.bytes([UserChoiceCloudSync.stampsKey: stamps]), write: stampWrite)

        // The keys per title and per show, one defaults key each.
        var rates: [String: Any] = [:], tails: [String: Any] = [:], rings: [String: Any] = [:]
        for (index, id) in ids.enumerated() {
            rates[AppStorageKeys.playbackRate(id)] = Float(1.25)
            tails[PlayedTail.key(id)] = Double(30)
            rings[AppStorageKeys.jumpRing(id)] = (0..<5).map { [Double(index + $0 * 60), 1_760_000_000_000 + Double($0)] }
        }
        var bookmarks: [String: Any] = [:]
        for book in ids.prefix(2_000) {
            let marks = (0..<5).map { ABSBookmark(libraryItemId: book, title: "Lesezeichen \($0)", time: Double($0 * 600), createdAt: 1_760_000_000_000) }
            bookmarks["bookmarkCache." + book] = try JSONEncoder().encode(marks)
        }
        var showTravelling: [String: Any] = [:], showLocal: [String: Any] = [:]
        for show in showIds {
            for key in PodcastShowPreferences.travellingKeys(showId: show) { showTravelling[key] = "newestFirst" }
            for prefix in ["podcastAutoDownload.", "podcastAutoDownloadSince.", "podcastAutoDownloadKeep.", "podcastAutoDownloadError."] {
                showLocal[prefix + show] = Double(1_760_000_000_000)
            }
        }
        for (family, entries) in [("playbackRate", rates), ("playedTail", tails), ("jumpRing", rings),
                                  ("bookmarkCache", bookmarks), ("showTravelling", showTravelling), ("showLocal", showLocal)] {
            for (key, value) in entries { defaults.set(value, forKey: key) }
            Self.line(family, keys: entries.count, bytes: Self.bytes(entries))
        }

        // Outside the move, for the list of 3.5: the marks of a large import.
        let imported = (0..<30_000).map { _ in "rss:\(UUID().uuidString)" }
        let markWrite = Self.timed { round in
            defaults.set(imported + ["round-\(round)"], forKey: ForeignMarks.importedKey)
        }
        defaults.set(Array(imported.reversed()), forKey: ForeignMarks.archivedKey)
        Self.line("foreignMarks", keys: 2, bytes: Self.bytes([ForeignMarks.importedKey: imported, ForeignMarks.archivedKey: imported]), write: markWrite)

        // The whole domain: its bytes, a small write into it, and the walk
        // the cleanup of the per-book keys takes over all of it.
        let domain = try #require(defaults.persistentDomain(forName: suite))
        let small = Self.timed { round in defaults.set(round % 2 == 0, forKey: "e4mess.small") }
        var walk = 0
        let walkTime = Self.timed { _ in walk = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("jumpRing.") }.count }
        Self.line("domain", keys: domain.count, bytes: Self.bytes(domain), write: small)
        print(String(format: "E4MESS family=dictionaryRepresentation keys=%d ms_median=%.1f ms_max=%.1f", walk, walkTime.median, walkTime.max))

        #expect(domain.count > 3 * Self.titles, "the precondition: the measure wrote the per-title keys into the domain")
        #expect(walk == Self.titles)
    }

    /// The same mirror in rows: what one changed stand costs on the main
    /// thread, and until its row landed.
    @Test("Messung: ein Abbild mit 22.000 Staenden in Zeilen, ein geaenderter Stand auf dem Hauptthread und bis er liegt")
    func theMirrorInRowsAt22000Stands() async throws {
        let suite = "e4mess-rows-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rows = CarrierStandRows.matching(defaults)
        var stands: [String: [Double]] = [:]
        for index in 0..<Self.titles { stands[Self.titleId(index)] = [Double(index % 3600), 1_760_000_000_000 + Double(index), 3600] }
        rows.set(CloudKitStandCarrier.mirrorKey, stands)
        await rows.awaitPendingWrites()
        var main: [Double] = [], landed: [Double] = []
        for round in 0..<5 {
            stands["rss:feed-0:round"] = [Double(round), 1_760_000_000_000, 3600]
            let started = Date()
            rows.set(CloudKitStandCarrier.mirrorKey, stands)
            main.append(Date().timeIntervalSince(started) * 1000)
            await rows.awaitPendingWrites()
            landed.append(Date().timeIntervalSince(started) * 1000)
        }
        main.sort()
        landed.sort()
        print(String(format: "E4MESS family=standRows keys=%d main_ms_median=%.1f main_ms_max=%.1f landed_ms_median=%.1f landed_ms_max=%.1f",
                     stands.count, main[2], main[4], landed[2], landed[4]))
        #expect(rows.rows(CloudKitStandCarrier.mirrorKey).count == Self.titles + 1, "the precondition: the rows hold the whole mirror")
    }
}
#endif
