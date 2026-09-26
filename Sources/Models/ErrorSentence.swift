// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The sentence a person reads about a failure. The ONE place for it.
///
/// `error.localizedDescription` was the fallback at eleven places. For an
/// error without a sentence of its own the system builds "The operation
/// couldn't be completed. (Swift.CancellationError error 1.)" from the type
/// and a number, and that is what reached the screen ("RSSProvider error
/// 404"). Here an error with a sentence keeps it, a platform error keeps the
/// sentence the platform wrote, and everything else is named by its kind in
/// words. Never a type name, never a code. The log line has its own rule:
/// `FailureReason`.
nonisolated enum ErrorSentence {
    static func of(_ error: Error) -> String {
        if let own = (error as? LocalizedError)?.errorDescription, !own.isEmpty { return own }
        if error is CancellationError { return String(localized: "The action was cancelled.") }
        if error is DecodingError { return String(localized: "The server response could not be read.") }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorCancelled { return String(localized: "The action was cancelled.") }
            if NetworkReach.isOffline(ns) {
                return String(localized: "No internet connection. Please check your network and try again.")
            }
        }
        // A platform error (network, AVFoundation, the file system) carries
        // the sentence its framework wrote; a Swift error without one does
        // not, and the bridge would invent the type-and-number text.
        if let written = ns.userInfo[NSLocalizedDescriptionKey] as? String, !written.isEmpty { return written }
        return String(localized: "Something went wrong. Please try again.")
    }
}

/// The network codes that mean "no way to the server" (no net, timeout, DNS
/// failure), as opposed to real errors like 401 or a broken server format.
/// Here in Models so the sentence above can ask it; `NetworkStatus` asks the
/// same set, so player, library and sentence share one definition.
nonisolated enum NetworkReach {
    static let offlineCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff,
    ]

    static func isOffline(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && offlineCodes.contains(error.code)
    }
}
