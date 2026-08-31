// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// The `.corrupt` pattern. The danger is not the decode failure. It
/// is that the NEXT save writes the emptiness back over recoverable data.
@Suite struct CorruptStoreTests {

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(name)-\(UUID().uuidString).json")
    }

    private struct Item: Codable, Equatable { let id: String }

    /// Missing and unreadable must not look the same. That sameness IS the
    /// defect.
    @Test func aMissingFileIsFreshNotCorrupt() {
        let outcome = CorruptStore.load([Item].self, from: tempURL("missing"), label: "test")
        #expect(!outcome.blocksEmptySave)
        #expect(outcome.value == nil)
    }

    @Test func aReadableFileLoads() throws {
        let url = tempURL("good")
        try JSONEncoder().encode([Item(id: "a")]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let outcome = CorruptStore.load([Item].self, from: url, label: "test")
        #expect(outcome.value == [Item(id: "a")])
        #expect(!outcome.blocksEmptySave)
    }

    /// A REAL corrupt file. Truncated bytes, not a fabricated structure.
    @Test func aCorruptFileIsPreservedAndBlocksTheEmptySave() throws {
        let url = tempURL("broken")
        let good = try JSONEncoder().encode([Item(id: "important")])
        try good.prefix(good.count / 2).write(to: url)      // abgeschnitten
        let backup = url.appendingPathExtension("corrupt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: backup)
        }
        let outcome = CorruptStore.load([Item].self, from: url, label: "test")
        #expect(outcome.value == nil)
        #expect(outcome.blocksEmptySave)
        // The original is kept. And it is the ORIGINAL, byte for byte.
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: backup) == good.prefix(good.count / 2))
    }

    /// The rule that makes preserving worth anything. Forensics alone does not
    /// help the person whose library vanished.
    @Test func anEmptyStateMayNotOverwriteAnUnreadableStore() {
        #expect(!CorruptStore.maySave(isEmpty: true, afterCorruptRead: true))
        #expect(CorruptStore.maySave(isEmpty: false, afterCorruptRead: true))
        #expect(CorruptStore.maySave(isEmpty: true, afterCorruptRead: false))
    }

    /// …and the block must not be permanent: a real, non-empty state written
    /// afterwards is the user building something new, and refusing it forever
    /// would be its own defect.
    @Test func arealStateAfterCorruptionIsAllowedThrough() {
        #expect(CorruptStore.maySave(isEmpty: false, afterCorruptRead: true))
    }

    /// The defaults variant keeps the raw bytes under a sibling key. There is
    /// no file to move aside, and throwing them away would end the recovery.
    @Test func aCorruptDefaultsStoreKeepsItsBytes() {
        let key = "corrupt-test-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defaults.set(Data("nicht mal ansatzweise JSON".utf8), forKey: key)
        defer {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: key + ".corrupt")
        }
        let outcome = CorruptStore.load([Item].self, defaultsKey: key, label: "test")
        #expect(outcome.blocksEmptySave)
        #expect(defaults.data(forKey: key + ".corrupt") != nil)
    }

    /// The last failure is the interesting one. Two backups nobody can tell
    /// apart help no one.
    @Test func asecondCorruptionReplacesTheOlderBackup() throws {
        let url = tempURL("twice")
        let backup = url.appendingPathExtension("corrupt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: backup)
        }
        try Data("erste".utf8).write(to: url)
        _ = CorruptStore.load([Item].self, from: url, label: "test")
        try Data("zweite".utf8).write(to: url)
        _ = CorruptStore.load([Item].self, from: url, label: "test")
        #expect(try String(data: Data(contentsOf: backup), encoding: .utf8) == "zweite")
    }
}
