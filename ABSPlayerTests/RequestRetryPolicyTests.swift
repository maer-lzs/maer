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
}
#endif
