// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The one way a catalog page turns a failure into what it shows: the
/// plain sentence for the page (`FreeCatalog.failureReason`) and, in the
/// same step, the measured reason in the log line (`FreeCatalog.logReason`),
/// so the code that no longer reaches the page is never lost. The device's
/// reach is asked here, once per failure, so every page words a timeout the
/// same way. Nil when nothing failed (a cancellation, a question never asked).
nonisolated enum CatalogPageFailure {
    static func sentence(for error: Error, at place: String) async -> String? {
        let online = await Reachability.isConnected()
        guard let sentence = FreeCatalog.failureReason(error, online: online) else { return nil }
        Logger.library.notice("FREECAT page \(place, privacy: .public) failed reason=\(FreeCatalog.logReason(error) ?? "-", privacy: .public) online=\(online, privacy: .public)")
        return sentence
    }
}
