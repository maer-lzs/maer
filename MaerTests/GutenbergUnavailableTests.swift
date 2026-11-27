// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// When gutendex does not answer, every catalogue surface says that
/// Gutenberg is not answering, not that an answer could not be read.
struct GutenbergUnavailableTests {
    @Test("a 5xx of gutendex is Gutenberg not answering; a 2xx and a 4xx are not")
    func status() {
        #expect(throws: GutenbergUnavailable.self) { try GutenbergClient.answered(status: 503) }
        #expect(throws: GutenbergUnavailable.self) { try GutenbergClient.answered(status: 500) }
        #expect(throws: Never.self) { try GutenbergClient.answered(status: 200) }
        #expect(throws: Never.self) { try GutenbergClient.answered(status: 404) }
    }

    @Test("a timeout or a refused connection is Gutenberg not answering; no network stays no network")
    func transport() {
        #expect(GutenbergClient.unavailable(URLError(.timedOut)) is GutenbergUnavailable)
        #expect(GutenbergClient.unavailable(URLError(.cannotConnectToHost)) is GutenbergUnavailable)
        #expect(GutenbergClient.unavailable(URLError(.notConnectedToInternet)) is URLError)
    }

    @Test("the page says the sentence of Gutenberg for it")
    @MainActor func sentence() {
        #expect(FreeCatalog.failureReason(GutenbergUnavailable(), online: true)
                == String(localized: "Gutenberg is not answering right now."))
    }

    @Test("Fence: the read of gutendex asks the status before it decodes", .needsTheSources)
    func readAsks() throws {
        let clients = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/FreeCatalogClients.swift"), encoding: .utf8))
        #expect(clients.contains("try answered(status: response?.statusCode)\n        return try decodeWithCount(data)"))
    }
}
#endif
