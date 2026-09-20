// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a failed request is called in a log line: a code, never an address.
///
/// **Measured at a device, which is why this exists.** The socket line read
/// `reason=__NSCFError` five times in eleven minutes. That is the class name
/// of a bridged `NSError`, not a reason, and whoever read it could not tell a
/// timeout from a refusal. The reason was there the whole time: the same
/// error carried `NSURLErrorDomain` and `-1001`, and the line threw it away.
///
/// The order of the answers is the whole rule:
/// 1. `URLError` keeps the short form it has always had. Three witnesses and
///    every older log line rest on `urlError=<code>`, and a bridged
///    `NSError` would print the same fact in a different alphabet.
/// 2. An error that COMES from Objective-C says its domain and its code, and
///    its underlying error once, because that is where a socket timeout
///    names itself.
/// 3. Anything else stays its TYPE name. A Swift error's description would
///    print its associated values, and those carry addresses; the promise in
///    the first line of this comment is worth more than a case name.
nonisolated enum FailureReason {
    /// Taken from the error's `userInfo`, never from a free-text field: a
    /// domain and a number cannot carry a host or a token.
    static func of(_ error: Error) -> String {
        if let urlError = error as? URLError { return "urlError=\(urlError.code.rawValue)" }
        guard type(of: error) is NSError.Type else { return String(describing: type(of: error)) }
        let ns = error as NSError
        guard let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return "\(ns.domain)=\(ns.code)"
        }
        // One level, not a chain: the first cause is the one that names the
        // mechanism, and a chain would grow a log line without bound.
        return "\(ns.domain)=\(ns.code) under=\(under.domain)=\(under.code)"
    }
}
