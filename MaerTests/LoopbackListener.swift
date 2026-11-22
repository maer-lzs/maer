// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Network

/// The one listener every loopback server of the witnesses opens.
enum LoopbackListener {
    static func make() throws -> NWListener {
        try NWListener(using: .tcp, on: .any)
    }
}
#endif
