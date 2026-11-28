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
/// words. Never a type name. A technical cause ends the sentence with the
/// number the system or the server reported, in brackets behind its full
/// stop, the same form on every platform (`with`, the shared vectors);
/// without such a number there is no bracket. The log line has its own
/// rule: `FailureReason`.
///
/// An error that carries the number its server reported says so here.
nonisolated protocol ReportedCode {
    var reportedCode: Int? { get }
}

nonisolated enum ErrorSentence {
    /// A sentence and the number the system or the server reported:
    /// `"<sentence> (<code>)"`; without a number, the sentence alone.
    static func with(_ sentence: String, code: Int?) -> String {
        guard let code else { return sentence }
        return "\(sentence) (\(code))"
    }

    /// The number the system or the server reported for `error`, of the
    /// classes the form names; nil for every other. A Swift error carries
    /// none unless it says what its server reported; a cancel is no cause;
    /// the code of a title without a playable file is the app's own.
    static func code(of error: Error) -> Int? {
        if let reported = error as? ReportedCode { return reported.reportedCode }
        // The system's errors: an NSError, or one of its Swift faces
        // (`URLError`, `CocoaError`, `AVError`, `POSIXError`), which are
        // `CustomNSError`; no type of the app is.
        guard type(of: error) is NSError.Type || error is CustomNSError else { return nil }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled || ns.code == NSURLErrorResourceUnavailable {
            return nil
        }
        return ns.code
    }

    static func of(_ error: Error) -> String {
        with(sentence(of: error), code: code(of: error))
    }

    private static func sentence(of error: Error) -> String {
        if let own = (error as? LocalizedError)?.errorDescription, !own.isEmpty { return own }
        if error is CancellationError { return String(localized: "The action was cancelled.") }
        if error is DecodingError { return String(localized: "The server response could not be read.") }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            if ns.code == NSURLErrorCancelled { return String(localized: "The action was cancelled.") }
            if NetworkReach.isOffline(ns) {
                return String(localized: "No internet connection. Please check your network and try again.")
            }
            // A source that finds no playable file in a title says so with
            // this code, built without a sentence of its own.
            if ns.code == NSURLErrorResourceUnavailable {
                return String(localized: "This title has no file that can be played.")
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
