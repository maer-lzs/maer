// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The app used to introduce itself to foreign servers under SIX hand-kept
/// identifiers: four version values (`Maer/1.0` without any address, `2.1`,
/// `2.6`, `2.7`) across six strings. One of them named the private
/// development forge, which therefore travelled to foreign image services on
/// every artist-portrait fetch.
///
/// The same error class as the scattered activation defaults: the same value
/// in N places, and N−1 drift apart. The identifier therefore stands **once**
/// here and derives the version from the bundle, so the next version bump
/// carries it along instead of five of six being forgotten.
///
/// The address is `maer.fm` rather than the forge, because it stays valid
/// when the forge changes. MusicBrainz and Radio Browser explicitly require
/// an identifying agent with a contact path, and with six identities any
/// attribution on their side is worthless.
nonisolated enum AppUserAgent {
    /// The ONE way the app introduces itself to foreign servers.
    static let value: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Maer/\(version ?? "0") (+https://maer.fm)"
    }()

    /// Sets it on a request that does not name one yet. Called by the three
    /// ways out (`HTTP.prepare`, `RequestRetryPolicy.fetch`,
    /// `FileDownloader.download`) and nowhere else: before, each call site
    /// set it by hand, and four ways to feeds, transcripts and Pocket Casts
    /// went out without it.
    static func applyIfMissing(to request: inout URLRequest) {
        guard request.value(forHTTPHeaderField: header) == nil else { return }
        request.setValue(value, forHTTPHeaderField: header)
    }

    private static let header = "User-Agent"
}
