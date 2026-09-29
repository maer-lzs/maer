// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import OSLog

/// Signposts for scroll profiling in Instruments (Points of Interest +
/// a dedicated cover-decode signposter). Effectively zero-cost when the app is
/// not being traced. `nonisolated` so the off-main image pipeline can signal.
///
/// In Instruments: os_signpost / Points of Interest instrument, subsystem
/// the app's bundle id. Intervals: `thumbnail` (whole cache lookup, hit or
/// decode) and `decode` (the actual off-main pixel decode + display prep).
nonisolated enum PerfSignpost {
    static let cover = OSSignposter(subsystem: AppLogSubsystem.value, category: "cover")
    /// Derived-list recomputations that used to run in the scroll path
    /// (e.g. the Downloaded section's full-library filter+sort).
    static let library = OSSignposter(subsystem: AppLogSubsystem.value, category: "library")
}
