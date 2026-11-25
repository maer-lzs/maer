// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The service key of Mär Sync is asked at the address the person typed
/// and held for it: a redirect to another host would hold that host's key
/// for this address, so the key's question follows no redirect off its
/// origin. A pin this device cannot read now is no pin: the sign-in stops
/// instead of holding the key on offer over it.
struct ServiceKeyOriginTests {
    @Test("a redirect of the key's question is followed only to the same scheme, host and port")
    func sameOrigin() throws {
        let base = try #require(URL(string: "https://sync.example:8443/maer"))
        #expect(RedirectGuard.isSameOrigin(try #require(URL(string: "https://sync.example:8443/maer/v2/key")), as: base))
        #expect(RedirectGuard.isSameOrigin(try #require(URL(string: "https://SYNC.example:8443/other")), as: base), "case of the host aside")
        #expect(!RedirectGuard.isSameOrigin(try #require(URL(string: "https://evil.example:8443/maer/v2/key")), as: base))
        #expect(!RedirectGuard.isSameOrigin(try #require(URL(string: "http://sync.example:8443/maer/v2/key")), as: base), "never from https to http")
        #expect(!RedirectGuard.isSameOrigin(try #require(URL(string: "https://sync.example/maer/v2/key")), as: base), "another port")
    }

    @Test("a pin read as unreadable stays unreadable; only a missing pin is no pin")
    func pinReading() {
        #expect(ServiceKeyPin.reading(.value("ab:cd")) == .held("ab:cd"))
        #expect(ServiceKeyPin.reading(.value("")) == ServiceKeyPin.PinRead.none)
        #expect(ServiceKeyPin.reading(.missing) == ServiceKeyPin.PinRead.none)
        #expect(ServiceKeyPin.reading(.unreadable) == .unreadable)
        #expect(ServiceKeyPin.reading(.undecodable) == .damaged, "there but not readable is not gone, and is told apart")
    }

    @Test("Fence: the key is asked without following a redirect off its origin, and an unreadable pin stops the sign-in", .needsTheSources)
    func wiring() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        // Every way to the service: requests, the tunnel and the socket.
        let client = try source("Sources/Networking/MaerSyncClient.swift")
        #expect(client.contains("redirects: .sameOrigin(as:"), "a request to the service follows a redirect to any host")
        #expect(!client.contains("{ try await HTTP.data(for: $0, retry: false) }"), "a way to the service keeps the guard that follows every host")
        #expect(client.contains("HTTP.webSocket(for: request, redirects: .sameOrigin(as:"), "the changes socket follows a redirect to any host")
        let tunnel = try source("Sources/Networking/MaerSyncTunnel.swift")
        #expect(!tunnel.contains("{ try await HTTP.data(for: $0, retry: false) }"))
        #expect(tunnel.contains("ServiceKeyPin.read(for: base)"), "the handshake reads an unreadable pin as none")
        let signIn = try source("Sources/Networking/MaerSyncSignIn.swift")
        #expect(signIn.contains("ServiceKeyPin.read(for: base)"))
        #expect(signIn.contains("return .keyPinUnreadable"))
        let page = try source("Sources/Views/MaerSyncSettingsView.swift")
        #expect(page.contains("case .keyPinUnreadable:"))
    }
}
#endif
