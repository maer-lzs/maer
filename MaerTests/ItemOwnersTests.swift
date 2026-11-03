// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The register of which server a library id belongs to, and its file.
struct ItemOwnersTests {
    @Test("das Register: eine volle Ladung macht ihre Kennungen zu ihren, die letzte gewinnt, Namensraeume bleiben draussen")
    func aFullLoadOwnsItsIds() {
        var owners = ItemOwners()
        let first = owners.noteFullLoad(ids: ["a", "both", "jf:book:1"], server: "https://A.example:443/")
        #expect(first)
        #expect(owners.owner(of: "a") == "https://a.example", "the owner is the server's one name")
        #expect(owners.owner(of: "jf:book:1") == nil, "an id with a namespace names its source itself")
        let again = owners.noteFullLoad(ids: ["a"], server: "https://a.example")
        #expect(!again, "the same load again changes nothing")
        owners.noteFullLoad(ids: ["both", "b"], server: "https://b.example")
        #expect(owners.owner(of: "both") == "https://b.example", "the last full load to name an id owns it")
        #expect(owners.owner(of: "never") == nil)
    }

    @Test("das Register: geraeumt wird nur, was dem geladenen Server gehoert und seine Liste nicht mehr nennt")
    func aServerCleansOnlyItsOwn() {
        let owners = ItemOwners(owners: ["a-left": "https://a.example", "a-here": "https://a.example",
                                         "b-left": "https://b.example"])
        #expect(owners.cleanable(absentFrom: ["a-here"], server: "https://a.example") == ["a-left"])
        #expect(owners.cleanable(absentFrom: [], server: "https://B.example/") == ["b-left"])
        #expect(owners.cleanable(absentFrom: [], server: "https://c.example").isEmpty, "a server without books cleans nothing")
        #expect(owners.cleanable(absentFrom: ["a-here"], server: "https://a.example").contains("unowned") == false)
        var dropped = owners
        let removed = dropped.drop(where: { $0 == "a-left" })
        #expect(removed)
        #expect(dropped.owner(of: "a-left") == nil, "a cleaned id stays in the register")
        let none = dropped.drop(where: { $0 == "gone already" })
        #expect(!none)
    }

    @Test("die Datei des Registers: gelesen wie geschrieben, eine unlesbare wird nicht durch ein leeres ersetzt")
    func theShelfKeepsAnUnreadableRegister() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("owners-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shelf = ItemOwnerShelf(file: folder.appendingPathComponent("item-owners.json"))
        guard case .fresh = shelf.read() else { Issue.record("no file reads as fresh"); return }
        let owners = ItemOwners(owners: ["a": "https://a.example"])
        shelf.write(owners, afterCorruptRead: false)
        #expect(shelf.read().value == owners)

        try Data("not a register".utf8).write(to: shelf.file)
        let read = shelf.read()
        #expect(read.value == nil && read.blocksEmptySave, "an unreadable register reads as unknown")
        shelf.write(ItemOwners(), afterCorruptRead: read.blocksEmptySave)
        #expect(!FileManager.default.fileExists(atPath: shelf.file.path), "an empty register replaced the unreadable one")
        #expect(FileManager.default.fileExists(atPath: shelf.file.appendingPathExtension("corrupt").path),
                "the unreadable register was not set aside")
    }

    /// The register stays on this device: no catalog of synced choices and
    /// no carrier names it, only the load that writes it, the queue that
    /// reads it and the outward tag that hashes its names.
    @Test("das Register reist nicht: nur der Ladeweg, die Warteschlange und das Etikett nach aussen nennen es",
          .needsTheSources)
    func theRegisterNeverTravels() throws {
        var namers: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let code = try String(contentsOf: file, encoding: .utf8)
            if code.contains("ItemOwner") || code.contains("item-owners") { namers.append(file.lastPathComponent) }
        }
        #expect(namers.sorted() == ["ABSServerScope.swift", "ItemOwnerShelf.swift", "ItemOwners.swift",
                                    "LibraryViewModel.swift", "OutwardServerTag.swift", "SyncQueue.swift"],
                "the register is named outside the load, the queue and the outward tag: \(namers.sorted())")
    }
}
#endif
