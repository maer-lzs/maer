// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// #51/W1 (class B): change detection via content identity, never via count.
struct ContentTokenTests {
    @Test("Same content, any order: same token")
    func orderInsensitive() {
        #expect(ContentToken.of(["a", "b", "c"]) == ContentToken.of(["c", "a", "b"]))
        #expect(ContentToken.of(Set(["a", "b"])) == ContentToken.of(["b", "a"]))
    }

    @Test("Swapped element at equal count: different token (the class-B failure)")
    func swappedContentChangesToken() {
        #expect(ContentToken.of(["feedA", "feedB"]) != ContentToken.of(["feedA", "feedC"]))
    }

    @Test("Empty and growth")
    func emptyAndGrowth() {
        #expect(ContentToken.of([String]()) == 0)
        #expect(ContentToken.of(["a"]) != ContentToken.of([String]()))
        #expect(ContentToken.of(["a", "b"]) != ContentToken.of(["a"]))
    }
}

/// Drive mode: the one-button sleep cycle off→15→30→60→off.
struct DriveModeSleepTests {
    @Test("Sleep cycle steps")
    func cycle() {
        #expect(DriveModeView.nextSleepStep(active: false, current: nil) == 15)
        #expect(DriveModeView.nextSleepStep(active: true, current: 15 * 60) == 30)
        #expect(DriveModeView.nextSleepStep(active: true, current: 29 * 60) == 60)
        #expect(DriveModeView.nextSleepStep(active: true, current: 60 * 60) == nil)
    }
}
#endif
