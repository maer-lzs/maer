// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Y37 hardening (01.08 diagnosis package): the tab selection may only be
/// moved off a tab by a REAL user deactivation — the tab's master toggle.
/// Transient availability states (server unreachable without VPN, the ABS
/// podcast probe not yet run, the async subscription load still decoding)
/// must NEVER change the selection: the availability race threw users off
/// the podcast tab on every start since servers became VPN-only reachable.
/// An unavailable-but-selected tab simply shows its offline/empty state.
nonisolated enum TabSelectionPolicy {
    /// Pure decision (tested): fall back to Home ONLY when the selected tab
    /// was deactivated by the user. Home itself never falls back.
    static func shouldFallBackToHome(selected: MediaType, masterEnabled: Bool) -> Bool {
        selected != .home && !masterEnabled
    }
}

extension MediaType {
    /// The tab's MASTER toggle — user intent, independent of reachability.
    /// Home is the aggregation tab and cannot be disabled.
    var userMasterEnabled: Bool {
        switch self {
        case .home: return true
        case .audiobooks: return AppStorageKeys.audiobooksTabEnabledValue
        case .podcasts: return AppStorageKeys.podcastsTabEnabledValue
        case .music: return AppStorageKeys.musicTabEnabledValue
        case .radio: return AppStorageKeys.radioTabEnabledValue
        }
    }
}
