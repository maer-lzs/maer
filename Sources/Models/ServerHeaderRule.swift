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

    /// Why an entered header is not kept: a name the app sets itself, a
    /// name that is no HTTP token (a space, a colon), or a value with a line
    /// break or another control character, which could start a header of
    /// its own.
    enum Refusal: Equatable, Sendable {
        case reservedName, notAToken, unsafeValue
    }

    /// The entered row as it is kept: name and value without the spaces at
    /// either end (a value pasted from elsewhere often ends in one).
    static func cleaned(name: String, value: String) -> Header {
        Header(name: name.trimmingCharacters(in: .whitespaces),
               value: value.trimmingCharacters(in: .whitespaces))
    }

    /// The server address a sheet's field names, as the table keeps it:
    /// trimmed, `https://` when no scheme is typed (as the sheets complete
    /// it), nil while it is no address with a host.
    static func base(typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let full = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: full), let host = url.host, !host.isEmpty,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    /// The reason a cleaned row is not kept, nil when it is.
    static func refusal(of header: Header) -> Refusal? {
        if reservedNames.contains(header.name.lowercased()) { return .reservedName }
        if !isAllowed(name: header.name) { return .notAToken }
        if header.value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .unsafeValue
        }
        return nil
    }

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

    /// The one form of a server's address the table keeps its headers
    /// under, made like `origin`: scheme and host in small letters, the
    /// default port left out, the path without a trailing slash, no user and
    /// no password. Two spellings of one server are one entry. The key reads
    /// back as the same URL: an IPv6 host keeps its brackets and the path
    /// stays percent-encoded (`URL(string: key)` gives the key again).
    static func key(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : scheme == "http" ? 80 : nil
        let port = url.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        let shownHost = host.contains(":") ? "[\(host)]" : host
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(shownHost)\(port)\(path)"
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
