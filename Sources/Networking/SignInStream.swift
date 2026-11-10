// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import os

/// How the stream of a track is asked when its source attaches a sign-in.
///
/// A stream asset follows a redirect itself and asks the end of the
/// redirect again, straight and with every header it was given (measured):
/// a sign-in handed to it for the source's address reaches whatever host
/// the source redirects to. So the end of the redirects is asked first, and
/// the asset gets that address with the sign-in the source answers for it:
/// its own host with it, any other host without.
nonisolated enum SignInStream {
    /// The plan of one track. `signIn` is the source's answer for an
    /// address (`AudioProvider.streamAuthHeaders(forItemId:to:)`): the
    /// headers it attaches there, none for a host that is not its own, nil
    /// while they cannot be read. `end` asks the end of the redirects.
    ///
    /// An end that cannot be asked leaves the track where it is today: the
    /// address the app knows, with the sign-in the source answers for it.
    static func plan(for url: URL, sourceHeaders: [String: String],
                     signIn: @Sendable (URL) async -> [String: String]?,
                     end: @Sendable (URLRequest) async -> URL? = { await ServerHeaders.endAddress(of: $0) }
    ) async -> ServerHeaders.Stream {
        var request = URLRequest(url: url)
        for (name, value) in sourceHeaders { request.setValue(value, forHTTPHeaderField: name) }
        guard let end = await end(request) else {
            Logger.player.notice("SIGNIN stream end unknown, asked at its own address: host=\(url.host ?? "-", privacy: .public)")
            return .plain
        }
        guard let headers = await signIn(end) else { return .waiting }
        if end.host?.lowercased() != url.host?.lowercased() {
            Logger.player.notice("SIGNIN stream ends at another host: from=\(url.host ?? "-", privacy: .public) to=\(end.host ?? "-", privacy: .public) signIn=\(!headers.isEmpty, privacy: .public)")
        }
        return .resolved(end, headers: headers)
    }
}
