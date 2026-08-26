// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if DEBUG
import UIKit
import OSLog

/// iPad hitch diagnosis (28.07 package): the simulator does not deliver the
/// hitch-time sub-metrics of `XCTOSSignpostMetric`, so this DEBUG-only
/// `CADisplayLink` probe counts long frames itself. Active only under the
/// `-uitest-frameprobe` launch argument; numbers go to the unified log as
/// `FRAMEPROBE …` lines (log-first. Measure before any fix attempt).
/// Simulator numbers are RELATIVE comparison values (CPU-side layout/render
/// cost), not device-true hitch durations.
final class FrameProbe {
    static let shared = FrameProbe()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var longFrames = 0
    private var longFrameMs = 0.0
    private var worstMs = 0.0

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-uitest-frameprobe") }

    func startIfRequested() {
        guard Self.isActive, link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
        Logger.library.notice("FRAMEPROBE armed")
    }

    @objc private func tick(_ l: CADisplayLink) {
        defer { last = l.timestamp }
        guard last > 0 else { return }
        let dt = l.timestamp - last
        let expected = l.duration > 0 ? l.duration : 1.0 / 60.0
        frames += 1
        // A "long frame": more than 1.75× the vsync budget late.
        if dt > expected * 1.75 {
            longFrames += 1
            longFrameMs += (dt - expected) * 1000
            worstMs = max(worstMs, dt * 1000)
        }
        // Periodic flush. The UI-test host collects these via log stream.
        if frames % 300 == 0 {
            Logger.library.notice("FRAMEPROBE frames=\(self.frames) long=\(self.longFrames) longMs=\(Int(self.longFrameMs)) worstMs=\(Int(self.worstMs))")
        }
    }
}
#endif
