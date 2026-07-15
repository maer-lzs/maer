import OSLog

/// S16: signposts for scroll profiling in Instruments (Points of Interest +
/// a dedicated cover-decode signposter). Effectively zero-cost when the app is
/// not being traced. `nonisolated` so the off-main image pipeline can signal.
///
/// In Instruments: os_signpost / Points of Interest instrument, subsystem
/// `de.lzs.ABSPlayer`. Intervals: `thumbnail` (whole cache lookup, hit or
/// decode) and `decode` (the actual off-main pixel decode + display prep).
nonisolated enum PerfSignpost {
    static let cover = OSSignposter(subsystem: "de.lzs.ABSPlayer", category: "cover")
}
