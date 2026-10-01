// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The map's promise: three of five areas work without any account, and a
/// "connected with …" line never carries anything but a host.
struct SourceMapTests {
    @Test("without any server: two areas ask for one, three are ready")
    func emptyState() {
        let facts = SourceMapFacts()
        #expect(facts.state(of: .audiobooks) == .needsServer)
        #expect(facts.state(of: .music) == .needsServer)
        #expect(facts.state(of: .podcasts) == .ready)
        #expect(facts.state(of: .radio) == .ready)
        #expect(facts.state(of: .freeCatalogs) == .ready)
        let serverless = SourceMapArea.allCases.filter { !$0.requiresServer }
        #expect(serverless.count == 3, "the serverless text names three areas — it must stay true")
    }

    @Test("a typed address alone is not a connection")
    func addressWithoutLoginStaysOpen() {
        var facts = SourceMapFacts()
        facts.absServer = "https://audio.example.com"
        #expect(facts.state(of: .audiobooks) == .needsServer)
        facts.absConnected = true
        #expect(facts.state(of: .audiobooks) == .connected(host: "audio.example.com"))
    }

    @Test("music names the server that actually answers — Subsonic first")
    func musicFollowsTheProviderOrder() {
        var facts = SourceMapFacts()
        facts.jellyfinConfigured = true
        facts.jellyfinServer = "http://jelly.local:8096"
        #expect(facts.state(of: .music) == .connected(host: "jelly.local:8096"))
        facts.subsonicConfigured = true
        facts.subsonicServer = "https://nav.example.com"
        #expect(facts.state(of: .music) == .connected(host: "nav.example.com"),
                "with both set the Subsonic side is used — the line must not claim the other one")
    }

    @Test("podcasts stay ready with or without sync")
    func podcastsAreNeverBlocked() {
        var facts = SourceMapFacts()
        #expect(facts.state(of: .podcasts) == .ready)
        facts.gpodderConfigured = true
        facts.gpodderServer = "https://sync.example.com/"
        #expect(facts.state(of: .podcasts) == .readySynced(host: "sync.example.com"))
    }

    @Test("the host line never carries credentials")
    func hostDropsCredentials() {
        #expect(SourceMap.host(from: "https://user:secret@audio.example.com/abs") == "audio.example.com")
        #expect(SourceMap.host(from: "audio.example.com") == "audio.example.com")
        #expect(SourceMap.host(from: "  https://audio.example.com:13378/  ") == "audio.example.com:13378")
        #expect(SourceMap.host(from: "") == "")
    }
}
#endif
