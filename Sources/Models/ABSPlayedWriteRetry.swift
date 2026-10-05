// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether a played mark that the server did not take stays queued for the
/// next try. No answer (offline, a dropped connection), a pause (429), a
/// server error (5xx) and a sign-in problem (401, 403) can pass: the entry
/// stays. Any other refusal (the episode is gone, the write is rejected)
/// answers the same every time: the entry goes, said in the log. The mark
/// itself stands on the device either way, and the push of the local
/// history carries a newer one to the server later.
nonisolated enum ABSPlayedWriteRetry {
    /// `status` is the HTTP status of the refusal, nil without an answer.
    static func keeps(status: Int?) -> Bool {
        guard let status else { return true }
        return status == 401 || status == 403 || status == 429 || status >= 500
    }
}
