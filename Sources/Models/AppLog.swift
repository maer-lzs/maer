// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import OSLog

/// Central loggers — one category per subsystem area. Use these instead of
/// print so incidents are visible in Console/sysdiagnose on device.
extension Logger {
    nonisolated static let gpodder = Logger(subsystem: "de.lzs.ABSPlayer", category: "gpodder")
    nonisolated static let rss = Logger(subsystem: "de.lzs.ABSPlayer", category: "rss")
    nonisolated static let music = Logger(subsystem: "de.lzs.ABSPlayer", category: "music")
    nonisolated static let library = Logger(subsystem: "de.lzs.ABSPlayer", category: "library")
    nonisolated static let player = Logger(subsystem: "de.lzs.ABSPlayer", category: "player")
}
