// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The decoders of the free catalogues are pure: `Data` in, entries out.
/// The file may name no stock, no store, no settings and no transport, so
/// the Linux probe of the pure layer compiles it with the models alone.
struct FreeCatalogDecodersFenceTests {
    nonisolated static let forbidden = ["CatalogStock", "AppStorageKeys", "ExternalSources", "UserDefaults",
                                        "URLSession", "HTTP.", "RequestRetryPolicy", "Logger", "@MainActor"]

    nonisolated static func offenders(in text: String) -> [String] {
        Self.forbidden.filter { text.contains($0) }
    }

    @Test("The decoders of the free catalogs know neither stock nor store nor transport", .needsTheSources)
    func decodersStayPure() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.path.hasSuffix("/Sources/Models/FreeCatalogDecoders.swift") })
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(Self.offenders(in: text).isEmpty, "the decoders reach past the pure layer: \(Self.offenders(in: text))")
        #expect(Self.offenders(in: "let stock = CatalogStockService.shared") == ["CatalogStock"])
        #expect(Self.offenders(in: "try JSONDecoder().decode(Response.self, from: data)").isEmpty)
    }

    @Test("The clients do not decode themselves", .needsTheSources)
    func clientsDoNotDecode() throws {
        let file = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.path.hasSuffix("/Sources/Networking/FreeCatalogClients.swift") })
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("JSONDecoder"), "a client decodes on its own; the decoders live in FreeCatalogDecoders")
    }
}
#endif
