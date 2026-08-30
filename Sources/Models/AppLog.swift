// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import OSLog

/// Central loggers. One category per subsystem area. Use these instead of
/// print so incidents are visible in Console/sysdiagnose on device.
/// The subsystem is DERIVED from the bundle id (the id flip must never
/// depend on someone remembering a string here; extensions derive their
/// own and stay distinguishable).
nonisolated enum AppLogSubsystem {
    static let value = Bundle.main.bundleIdentifier ?? "fm.maer.app"
}

extension Logger {
    nonisolated static let gpodder = Logger(subsystem: AppLogSubsystem.value, category: "gpodder")
    nonisolated static let rss = Logger(subsystem: AppLogSubsystem.value, category: "rss")
    nonisolated static let music = Logger(subsystem: AppLogSubsystem.value, category: "music")
    nonisolated static let library = Logger(subsystem: AppLogSubsystem.value, category: "library")
    nonisolated static let player = Logger(subsystem: AppLogSubsystem.value, category: "player")
}
