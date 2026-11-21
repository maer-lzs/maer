// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

nonisolated enum LocalNetworkAccess {
    static func isLocal(host: String?) -> Bool { false }
    static func isDenied(host: String?, code: URLError.Code, deviceOnline: Bool) -> Bool { false }
    static var sentence: String { "" }
}
