// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The one way to Gutenberg's mirror (`GutenbergRoute`): a request through
/// the door goes there once when www answers a server error or rests, the
/// ways past the door (a stream, a download, a duration read) take its
/// address while www rests. What is kept carries the address of www; the
/// mirror is only the way of this request.
enum GutenbergMirror {
    /// The gate's rest of www, the one reach of this way to the gate.
    nonisolated static func wwwRests(_ url: URL) -> Bool { HostCourtesy.shared.rests(url) }

    /// The address to ask now: the mirror's while www rests, else the same.
    nonisolated static func address(for url: URL, rests: (URL) -> Bool = wwwRests) -> URL {
        guard let mirror = GutenbergRoute.mirror(of: url), GutenbergRoute.asksMirror(status: nil, resting: rests(url)) else {
            return url
        }
        return mirror
    }

    /// One request through `ask`; a server error or a rest of www asks the
    /// mirror once with the same headers. When the mirror fails too, the
    /// answer of www stands (or its error), never a second round.
    static func fetch(_ request: URLRequest, rests: (URL) -> Bool = wwwRests,
                      ask: (URLRequest) async throws -> (Data, HTTPURLResponse?)) async throws -> (Data, HTTPURLResponse?) {
        guard let url = request.url, let mirror = GutenbergRoute.mirror(of: url) else {
            return try await ask(request)
        }
        var onMirror = request
        onMirror.url = mirror
        onMirror.timeoutInterval = max(request.timeoutInterval, GutenbergRoute.mirrorTimeout)
        if GutenbergRoute.asksMirror(status: nil, resting: rests(url)) {
            Logger.library.notice("GUTENBERG www rests, asking the mirror")
            return try await ask(onMirror)
        }
        let first: (Data, HTTPURLResponse?)
        do {
            first = try await ask(request)
        } catch is HostCourtesy.Resting {
            Logger.library.notice("GUTENBERG www rests, asking the mirror")
            return try await ask(onMirror)
        }
        guard GutenbergRoute.asksMirror(status: first.1?.statusCode, resting: false) else { return first }
        Logger.library.notice("GUTENBERG www status=\(first.1?.statusCode ?? 0), asking the mirror")
        do {
            let second = try await ask(onMirror)
            if let status = second.1?.statusCode, (200...299).contains(status) { return second }
            Logger.library.notice("GUTENBERG mirror status=\(second.1?.statusCode ?? 0) too")
        } catch {
            Logger.library.notice("GUTENBERG mirror failed too: \(FailureReason.of(error), privacy: .public)")
        }
        return first
    }

    /// Whether the address is a file of www that pglaf also holds.
    nonisolated static func isMainFile(_ url: URL) -> Bool { GutenbergRoute.mirror(of: url) != nil }

    /// The mirror's address after a way past the door failed on a file of
    /// www for a server error or a rest; nil for an absence or another host.
    static func mirrorIfDown(_ url: URL) async -> URL? {
        await probe(url) ? GutenbergRoute.mirror(of: url) : nil
    }

    /// After a way past the door failed on a file of www: asks www once
    /// through the door (the gate learns a rest from it) and says whether
    /// the mirror is the way now. An absence is not.
    static func probe(_ url: URL) async -> Bool {
        guard GutenbergRoute.mirror(of: url) != nil else { return false }
        if wwwRests(url) { return true }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            // Straight to www, once: through the door it would go on to the
            // mirror and answer for it.
            let (_, response) = try await RequestRetryPolicy.fetch(request, once: true)
            return GutenbergRoute.asksMirror(status: response?.statusCode, resting: wwwRests(url))
        } catch is HostCourtesy.Resting {
            return true
        } catch {
            return false
        }
    }
}

extension URL {
    /// The address a way past the door asks now (`GutenbergMirror.address`).
    nonisolated var viaGutenbergMirror: URL { GutenbergMirror.address(for: self) }
}
