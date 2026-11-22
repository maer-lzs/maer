// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Network

/// The one listener every loopback server of the witnesses opens: bound to
/// the address the witnesses ask (127.0.0.1) and nowhere else. Bound to
/// every address, the port of one witness could be the port of another
/// listener on IPv4, and a request reached that one (a sign-in answered
/// 401 from 127.0.0.1 while its own server saw no request). A witness that
/// asks `localhost` as a second host reaches it over IPv4 as well.
nonisolated enum LoopbackListener {
    static func make() throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        return try NWListener(using: parameters)
    }
}
#endif
