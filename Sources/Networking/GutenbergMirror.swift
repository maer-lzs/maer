// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

enum GutenbergMirror {
    nonisolated static func address(for url: URL, rests: (URL) -> Bool = { HostCourtesy.shared.rests($0) }) -> URL { url }

    static func fetch(_ request: URLRequest, rests: (URL) -> Bool = { HostCourtesy.shared.rests($0) },
                      ask: (URLRequest) async throws -> (Data, HTTPURLResponse?)) async throws -> (Data, HTTPURLResponse?) {
        try await ask(request)
    }

    static func probe(_ url: URL) async -> Bool { false }
}
