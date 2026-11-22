// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Network
import Testing
@testable import Maer

/// Every loopback server of the witnesses binds 127.0.0.1 and nowhere
/// else, through one listener. Bound to every address, the port of one
/// witness can be the port of another listener on IPv4, and a request the
/// witness sends reaches that one instead.
struct LoopbackListenerFenceTests {
    @Test("the one listener binds 127.0.0.1 alone")
    func bindsTheLoopbackAddress() throws {
        let listener = try LoopbackListener.make()
        defer { listener.cancel() }
        guard case .hostPort(let host, _) = listener.parameters.requiredLocalEndpoint else {
            Issue.record("the listener binds every address")
            return
        }
        #expect(host == "127.0.0.1")
    }

    @Test("no witness opens a listener of its own", .needsTheSources)
    func noListenerOfItsOwn() throws {
        var offenders: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["MaerTests"])
        where !name.hasSuffix("LoopbackListener.swift") && !name.hasSuffix("LoopbackListenerFenceTests.swift") {
            if text.contains("NWListener(") { offenders.append(name) }
        }
        #expect(offenders.isEmpty, "a listener of its own in \(offenders.sorted())")
    }
}
#endif
