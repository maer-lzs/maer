// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The measure lines before E1b carry no path, and the debug measure page
/// leaves nothing behind: no bookmark, no held access.
struct E1MeasureLineTests {
    @Test("E1MESS-Zeilen: Aufloesung und Wiedergabe, nie ein Pfad")
    func lines() {
        #expect(E1MeasureLine.resolution(place: .usb, resolved: true, stale: true, renewed: true,
                                         access: true, files: 3, reason: nil)
                == "E1MESS ort=usb aufgeloest=ja veraltet=ja erneuert=ja zugriff=ja dateien=3")
        #expect(E1MeasureLine.resolution(place: .icloud, resolved: false, stale: false, renewed: false,
                                         access: false, files: nil, reason: "nicht-erreichbar")
                == "E1MESS ort=icloud aufgeloest=nein veraltet=nein erneuert=nein zugriff=nein dateien=- fehler=nicht-erreichbar")
        #expect(E1MeasureLine.playback(minute: 7, playing: true, access: true)
                == "E1MESS wiedergabe minute=7 spielt=ja zugriff=ja")
        #expect(E1MeasureLine.playback(minute: 0, playing: false, access: true, reason: "keine-audiodatei")
                == "E1MESS wiedergabe minute=0 spielt=nein zugriff=ja fehler=keine-audiodatei")
        #expect(E1MeasureLine.Place.allCases.map(\.rawValue) == ["intern", "icloud", "anbieter", "usb"])
    }
}

#if DEBUG
@MainActor
struct BookmarkMeasureTests {
    /// Counts starts and stops, so a held access is visible.
    final class CountingAccess: BookmarkMeasure.Access {
        private(set) var started = 0
        private(set) var stopped = 0
        func start(_ url: URL) -> Bool { started += 1; return true }
        func stop(_ url: URL) { stopped += 1 }
    }

    @Test("E1-Messseite: nach Messung loeschen bleibt kein Lesezeichen und kein gehaltener Zugriff")
    func clearingLeavesNothing() throws {
        let suite = "e1mess-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.m4a"))

        let access = CountingAccess()
        let store = BookmarkMeasure.Store(defaults: defaults, access: access)
        store.keep(folder: folder, place: .usb)
        #expect(store.hasBookmark)
        #expect(store.place == .usb)
        #expect(store.lastLine?.hasPrefix("E1MESS ort=usb aufgeloest=ja") == true)
        #expect(store.lastLine?.contains(folder.lastPathComponent) == false, "no path, no name in the line")
        #expect(store.resolve() != nil)
        #expect(store.lastLine?.contains("dateien=1") == true)

        // The playback probe holds the access; the file is no real audio,
        // so the player gives up, and the hold must stand anyway.
        store.startPlayback()
        #expect(store.heldFolder != nil, "the probe holds the folder's access")
        #expect(access.started > access.stopped)
        #expect(store.lastLine?.hasPrefix("E1MESS wiedergabe minute=0 spielt=nein zugriff=ja fehler=") == true,
                "a start that fails says why")

        store.clear()
        #expect(!store.hasBookmark, "no bookmark after clearing")
        #expect(defaults.string(forKey: BookmarkMeasure.Store.placeKey) == nil)
        #expect(store.heldFolder == nil, "no held folder after clearing")
        #expect(access.started == access.stopped, "every access started is stopped")
    }

    @Test("E1-Messseite: ein unlesbarer Ordner zaehlt nicht als leerer")
    func unreadableIsNotEmpty() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("e1mess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let empty = BookmarkMeasure.Store.counted(in: base)
        #expect(empty.files == 0)
        #expect(empty.reason == nil)
        let missing = BookmarkMeasure.Store.counted(in: base.appendingPathComponent("fehlt", isDirectory: true))
        #expect(missing.files == nil, "an unreadable folder has no count")
        #expect(missing.reason != nil, "and says why")
    }
}
#endif
#endif
