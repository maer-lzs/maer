// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Y33: the per-attempt request policy — a 401 gets exactly one probe retry
/// before it counts, transients back off twice, everything else fails fast.
struct RequestRetryPolicyTests {
    @Test("401 probes once, then fails (logout only after the probe)")
    func unauthorizedProbe() {
        #expect(RequestRetryPolicy.decide(status: 401, urlErrorCode: nil, attempt: 0)
                == .retry(afterMs: 500))
        #expect(RequestRetryPolicy.decide(status: 401, urlErrorCode: nil, attempt: 1) == .fail)
    }

    @Test("transient statuses and URL errors back off twice, then fail")
    func transientBackoff() {
        for status in [429, 500, 502, 503] {
            #expect(RequestRetryPolicy.decide(status: status, urlErrorCode: nil, attempt: 0)
                    == .retry(afterMs: 400))
            #expect(RequestRetryPolicy.decide(status: status, urlErrorCode: nil, attempt: 1)
                    == .retry(afterMs: 1200))
            #expect(RequestRetryPolicy.decide(status: status, urlErrorCode: nil, attempt: 2) == .fail)
        }
        for code in [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost] {
            #expect(RequestRetryPolicy.decide(status: nil, urlErrorCode: code, attempt: 0)
                    == .retry(afterMs: 400))
        }
    }

    @Test("permanent failures never retry")
    func permanentFails() {
        #expect(RequestRetryPolicy.decide(status: 404, urlErrorCode: nil, attempt: 0) == .fail)
        #expect(RequestRetryPolicy.decide(status: 403, urlErrorCode: nil, attempt: 0) == .fail)
        // Real offline (no internet/DNS) is final — the cache fallback is right.
        #expect(RequestRetryPolicy.decide(status: nil, urlErrorCode: NSURLErrorNotConnectedToInternet,
                                          attempt: 0) == .fail)
    }

    /// Y39: Subsonic auth codes (200-envelope) ride the SAME 401 probe; every
    /// other API code is final on the spot.
    @Test("subsonic envelope auth codes probe once, other codes fail")
    func subsonicEnvelopeMapping() {
        #expect(RequestRetryPolicy.subsonicDecision(apiCode: 40, attempt: 0) == .retry(afterMs: 500))
        #expect(RequestRetryPolicy.subsonicDecision(apiCode: 40, attempt: 1) == .fail)
        #expect(RequestRetryPolicy.subsonicDecision(apiCode: 41, attempt: 0) == .retry(afterMs: 500))
        #expect(RequestRetryPolicy.subsonicDecision(apiCode: 41, attempt: 1) == .fail)
        // 50 = "not authorized for this operation" (permissions, not
        // credentials), 70 = not found — both final, no probe.
        #expect(RequestRetryPolicy.subsonicDecision(apiCode: 50, attempt: 0) == .fail)
        #expect(RequestRetryPolicy.subsonicDecision(apiCode: 70, attempt: 0) == .fail)
        #expect(RequestRetryPolicy.subsonicDecision(apiCode: 0, attempt: 0) == .fail)
    }
}
#endif
