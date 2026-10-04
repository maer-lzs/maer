// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a music page shows instead of, or as, its content. One answer for
/// every surface that asks the device's music server, so no page says
/// "none" without a server having been asked: without a server the page
/// says so and offers a way out, a failed load on an empty page is an
/// error with retry, and a page that has content keeps it when a later
/// load fails (stale beats empty).
nonisolated enum MusicPageState: Equatable, Sendable {
    case missing
    case content
    case loading
    case failed(String)
    case empty

    /// `asked` is whether the page has started its first run: before that
    /// an empty page knows nothing yet and loads, it never says "none".
    static func of(serverMissing: Bool, asked: Bool, isEmpty: Bool, isLoading: Bool,
                   failure: String?) -> MusicPageState {
        if serverMissing { return .missing }
        if !isEmpty { return .content }
        if !asked || isLoading { return .loading }
        if let failure { return .failed(failure) }
        return .empty
    }

    /// What a page does when the sources change (an address or account
    /// added or removed here).
    enum SourcesChange: Equatable, Sendable {
        /// The server is gone: the way out replaces whatever stood there.
        case showMissing
        /// The page said "no server here" and one is there now: load.
        case reload
        /// Nothing to do; a full page is not asked again.
        case keep
    }

    /// The reachability is asked on every change, also on a full page; a
    /// load follows only where the page had no server before.
    static func onSourcesChange(reachableNow: Bool, wasMissing: Bool) -> SourcesChange {
        if !reachableNow { return wasMissing ? .keep : .showMissing }
        return wasMissing ? .reload : .keep
    }
}
