// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Which request carries the headers a person entered for a server, pure.
///
/// A server is its address: scheme, host, port and the path it lives
/// under. A request carries the headers of the server whose address it
/// lies under; with two servers on one host the longer path wins, and
/// another port or host gets nothing. A redirect takes the headers of the
/// server it leaves and adds those of the server it reaches.
nonisolated enum ServerHeaderRule {
    struct Header: Codable, Equatable, Sendable {
        let name: String
        let value: String
    }

    struct Entry: Equatable, Sendable {
        let base: URL
        let headers: [Header]
    }

    /// Headers the app sets itself. One entered under such a name would be
    /// sent twice or replace the app's own, so it is refused.
    static let reservedNames: Set<String> = [
        "authorization", "user-agent", "content-type", "content-length", "cookie", "host",
    ]

    /// A name a request can carry: an HTTP token, not one the app sets.
    static func isAllowed(name: String) -> Bool {
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
            .union(CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"))
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(token.contains) else { return false }
        return !reservedNames.contains(name.lowercased())
    }

    /// Scheme, host and port, with the default port written out, so
    /// `https://a` and `https://a:443` are one server.
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(port)"
    }

    /// The path a server lives under, without a trailing slash.
    static func basePath(_ url: URL) -> String {
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The entry whose server the address lies under; the longest path wins.
    static func entry(for url: URL, in entries: [Entry]) -> Entry? {
        guard let origin = origin(url) else { return nil }
        let path = url.path
        return entries
            .filter { entry in
                guard Self.origin(entry.base) == origin else { return false }
                let base = basePath(entry.base)
                return base.isEmpty || path == base || path.hasPrefix(base + "/")
            }
            .max { basePath($0.base).count < basePath($1.base).count }
    }

    /// The request with the headers of its server set, each once.
    static func applied(_ request: URLRequest, entries: [Entry]) -> URLRequest {
        guard let url = request.url, let entry = entry(for: url, in: entries) else { return request }
        var out = request
        for header in entry.headers { out.setValue(header.value, forHTTPHeaderField: header.name) }
        return out
    }

    /// The next request of a redirect from `previous`: without the headers
    /// of the server it leaves, with those of the server it reaches.
    static func redirected(_ request: URLRequest, from previous: URL?, entries: [Entry]) -> URLRequest {
        guard let target = request.url else { return request }
        let left = previous.flatMap { entry(for: $0, in: entries) }
        let reached = entry(for: target, in: entries)
        guard left != reached else { return request }
        var out = request
        for header in left?.headers ?? [] { out.setValue(nil, forHTTPHeaderField: header.name) }
        return applied(out, entries: entries)
    }
}
