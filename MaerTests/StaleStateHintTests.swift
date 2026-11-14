// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The hint above a tab with the last known stand says why:
/// without network „Offline“, with network and no answer from the server
/// „Server nicht erreichbar“. The one input is the app's network value.
struct StaleStateHintTests {
    @Test("Without network offline, with network server unreachable, each with its own symbol")
    func bothCases() {
        #expect(StaleStateHint.of(isOnline: false) == .offline)
        #expect(StaleStateHint.of(isOnline: true) == .serverUnreachable)
        #expect(StaleStateHint.offline.symbol == "wifi.slash")
        #expect(StaleStateHint.serverUnreachable.symbol == "server.rack")
        #expect(StaleStateHint.offline.text.key == "Offline: last known state")
        #expect(StaleStateHint.serverUnreachable.text.key == "Server unreachable: last known state")
    }

    @Test("Both sentences are in the catalog in German")
    func bothLanguages() {
        var offline = StaleStateHint.offline.text, server = StaleStateHint.serverUnreachable.text
        offline.locale = Locale(identifier: "de")
        server.locale = Locale(identifier: "de")
        #expect(String(localized: offline) == "Offline: zuletzt bekannter Stand")
        #expect(String(localized: server) == "Server nicht erreichbar: zuletzt bekannter Stand")
    }

    @Test("The hint of the tabs takes the rule and the network value, no sentence of its own", .needsTheSources)
    func theBannerTakesTheRule() throws {
        let view = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Views/LibraryView.swift"), encoding: .utf8))
            .components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(view.contains("lethint=StaleStateHint.of(isOnline:isOnline)"))
        #expect(view.contains("Image(systemName:hint.symbol)"))
        #expect(view.contains("Text(hint.text)"))
        #expect(!view.contains("\"Offline:lastknownstate\""))
    }
}
#endif
