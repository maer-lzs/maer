import OSLog

/// Central loggers — one category per subsystem area. Use these instead of
/// print so incidents are visible in Console/sysdiagnose on device.
extension Logger {
    nonisolated static let gpodder = Logger(subsystem: "de.lzs.ABSPlayer", category: "gpodder")
    nonisolated static let music = Logger(subsystem: "de.lzs.ABSPlayer", category: "music")
    nonisolated static let library = Logger(subsystem: "de.lzs.ABSPlayer", category: "library")
}
