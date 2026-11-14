// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import Security
@testable import Maer

/// The keychain door addresses items in TWO worlds: the local one and the
/// iCloud keychain. Every query that names an item must say which worlds
/// it means, or it means "local only" by Apple's default.
///
/// Three of the four calls in the door said it and wrote down why. `save`
/// did not, and both halves of it went wrong: its clearing left a
/// synchronized twin standing, and its add then met that twin, answered
/// `errSecDuplicateItem` and wrote nothing, while the status was dropped.
/// A person changing a feed password changed nothing and was told nothing.
struct KeychainBothWorldsTests {
    private func attributes(forKey key: String) -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return (result as? [[String: Any]]) ?? []
    }

    @Test("a second save lands even if the entry is in the iCloud keychain")
    func theSecondWriteLands() throws {
        let key = "test.bothworlds.\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: key) }

        KeychainStore.save("first", forKey: key, synchronizable: true)
        // The precondition is ASSERTED, not assumed: without a
        // truly syncable entry this case does not measure the thing,
        // and a green run without a measurement is the most expensive outcome.
        let stored = attributes(forKey: key)
        try #require(stored.count == 1, "genau ein Eintrag steht da")
        try #require((stored[0][kSecAttrSynchronizable as String] as? Bool) == true,
                     "der Eintrag ist wirklich als reisend angelegt")

        KeychainStore.save("second", forKey: key, synchronizable: true)
        #expect(KeychainStore.load(forKey: key) == "second",
                "die zweite Aenderung ist angekommen")
        #expect(attributes(forKey: key).count == 1, "und sie hat keinen zweiten Eintrag daneben gelegt")
    }

    @Test("whoever turns off travelling leaves no twin standing at Apple")
    func turningTravelOffLeavesNoTwin() throws {
        let key = "test.bothworlds.off.\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: key) }

        KeychainStore.save("travelling", forKey: key, synchronizable: true)
        try #require((attributes(forKey: key).first?[kSecAttrSynchronizable as String] as? Bool) == true,
                     "der Eintrag reist, bevor die Probe ihn zurueckholt")

        KeychainStore.save("local", forKey: key, synchronizable: false)
        let after = attributes(forKey: key)
        #expect(after.count == 1, "genau EIN Eintrag, kein Zwilling: \(after.count)")
        #expect((after.first?[kSecAttrSynchronizable as String] as? Bool) == false,
                "und er reist nicht mehr")
        #expect(KeychainStore.load(forKey: key) == "local")
    }

    @Test("the door names the two worlds at every addressing query and reads every status", .needsTheSources)
    func everyCallSaysWhichWorldsAndReadsItsStatus() throws {
        let door = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "KeychainStore.swift" })
        let text = try String(contentsOf: door, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Every SecItem call belongs to a query that names the worlds.
        // The CALLS are counted, not the occurrences of the word: a
        // comment about a call is no call.
        let calls = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && trimmed.contains("SecItem")
        }
        #expect(calls.count >= 4, "der Sucher findet die Aufrufe noch: \(calls.count)")

        // Whoever may drop its status is listed here WITH a reason. A
        // call whose verdict nobody reads is otherwise a write without
        // consequence. Leaving the exception silently in the filter would be the same
        // class this witness guards: an exception nobody has
        // checked is a hole with a justification.
        let mayDropItsStatus: [String: String] = [
            "SecItemDelete": "ein Raeumen vor dem ersten Schreiben gibt errSecItemNotFound, und das ist kein Fehlschlag; die Loeschung, die etwas BEHAUPTET (delete), liest ihren Status trotzdem",
        ]
        let dropped = calls.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SecItem") else { return false }   // an assignment reads it
            return !mayDropItsStatus.keys.contains { trimmed.hasPrefix($0) }
        }
        #expect(dropped.isEmpty, "hier wird ein Status verworfen: \(dropped)")
        // And the exception covers only what it names: the other deletion
        // reads its status, so the list must not grow without it
        // being noticed (the cleanup under the old service name went away with
        // its step).
        let readDeletes = lines.filter { $0.contains("= SecItemDelete(") }.count
        #expect(readDeletes == 1, "delete liest seinen Status, gezaehlt: \(readDeletes)")

        // And the number of world statements covers the addressing queries.
        let worlds = lines.filter { $0.contains("kSecAttrSynchronizableAny") }.count
        #expect(worlds >= 4, "vier Abfragen nennen die zwei Welten, gezaehlt: \(worlds)")
    }
}
#endif
