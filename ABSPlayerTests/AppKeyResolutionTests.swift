// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// Z1: the ONE app-key resolution rule (Jamendo + PodcastIndex) — a
/// user-entered value always beats the build-injected one; an absent
/// injection (nil or empty Info.plist substitution) resolves to "".
struct AppKeyResolutionTests {
    @Test func userValueBeatsInjected() {
        #expect(AppStorageKeys.resolvedAppKey(user: "mine", injected: "app") == "mine")
    }

    @Test func injectedFillsEmptyUser() {
        #expect(AppStorageKeys.resolvedAppKey(user: "", injected: "app") == "app")
    }

    @Test func absentInjectionResolvesEmpty() {
        #expect(AppStorageKeys.resolvedAppKey(user: "", injected: nil).isEmpty)
        // An empty $(VAR) substitution arrives as "" — same as not injected.
        #expect(AppStorageKeys.resolvedAppKey(user: "", injected: "").isEmpty)
    }
}
#endif
