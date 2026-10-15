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

    @Test("ein zweites Speichern landet, auch wenn der Eintrag im iCloud-Schluesselbund liegt")
    func theSecondWriteLands() throws {
        let key = "test.bothworlds.\(UUID().uuidString)"
        defer { KeychainStore.delete(forKey: key) }

        KeychainStore.save("first", forKey: key, synchronizable: true)
        // Die Voraussetzung wird ZUGESICHERT, nicht angenommen: ohne einen
        // wirklich synchronisierbaren Eintrag misst dieser Fall die Sache
        // nicht, und ein gruener Lauf ohne Messung ist der teuerste Ausgang.
        let stored = attributes(forKey: key)
        try #require(stored.count == 1, "genau ein Eintrag steht da")
        try #require((stored[0][kSecAttrSynchronizable as String] as? Bool) == true,
                     "der Eintrag ist wirklich als reisend angelegt")

        KeychainStore.save("second", forKey: key, synchronizable: true)
        #expect(KeychainStore.load(forKey: key) == "second",
                "die zweite Aenderung ist angekommen")
        #expect(attributes(forKey: key).count == 1, "und sie hat keinen zweiten Eintrag daneben gelegt")
    }

    @Test("wer das Reisen abschaltet, laesst keinen Zwilling bei Apple stehen")
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

    @Test("die Tuer nennt an jeder adressierenden Abfrage die zwei Welten und liest jeden Status", .needsTheSources)
    func everyCallSaysWhichWorldsAndReadsItsStatus() throws {
        let door = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "KeychainStore.swift" })
        let text = try String(contentsOf: door, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Jeder SecItem-Aufruf gehoert einer Abfrage, die die Welten nennt.
        // Gezaehlt werden die AUFRUFE, nicht die Vorkommen des Wortes: ein
        // Kommentar ueber einen Aufruf ist kein Aufruf.
        let calls = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && trimmed.contains("SecItem")
        }
        #expect(calls.count >= 4, "der Sucher findet die Aufrufe noch: \(calls.count)")

        // Wer seinen Status verwerfen darf, steht hier MIT Grund. Ein
        // Aufruf, dessen Urteil niemand liest, ist sonst ein Schrieb ohne
        // Folge. Die Ausnahme still im Filter zu lassen waere dieselbe
        // Klasse, die dieser Zeuge bewacht: eine Ausnahme, die man nicht
        // nachgesehen hat, ist ein Loch mit Begruendung.
        let mayDropItsStatus: [String: String] = [
            "SecItemDelete": "ein Raeumen vor dem ersten Schreiben gibt errSecItemNotFound, und das ist kein Fehlschlag; die Loeschung, die etwas BEHAUPTET (delete), liest ihren Status trotzdem",
        ]
        let dropped = calls.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("SecItem") else { return false }   // Zuweisung liest ihn
            return !mayDropItsStatus.keys.contains { trimmed.hasPrefix($0) }
        }
        #expect(dropped.isEmpty, "hier wird ein Status verworfen: \(dropped)")
        // Und die Ausnahme deckt nur, was sie benennt: die andere Loeschung
        // liest ihren Status, also darf die Liste nicht wachsen, ohne dass
        // es auffaellt (die Bereinigung unter dem alten Dienstnamen fiel mit
        // ihrem Schritt).
        let readDeletes = lines.filter { $0.contains("= SecItemDelete(") }.count
        #expect(readDeletes == 1, "delete liest seinen Status, gezaehlt: \(readDeletes)")

        // Und die Zahl der Welten-Angaben deckt die adressierenden Abfragen.
        let worlds = lines.filter { $0.contains("kSecAttrSynchronizableAny") }.count
        #expect(worlds >= 4, "vier Abfragen nennen die zwei Welten, gezaehlt: \(worlds)")
    }
}
#endif
