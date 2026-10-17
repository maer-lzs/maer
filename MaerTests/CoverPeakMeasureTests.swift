// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import UIKit
import os
@testable import Maer

/// A measurement, not a change: the memory peak of a first scroll through
/// a large library, as the cells ask for it. Forty covers of 3000 px that
/// no cache knows come from a loopback server, eight at a time or one after
/// the other, as JPEG (most covers) or PNG, each asked at the size of a
/// grid cell; the process footprint is sampled every two milliseconds.
/// The numbers stand in the test log (`COVERPEAK`); the case holds only
/// that the measure ran.
@MainActor
@Suite(.serialized)
struct CoverPeakMeasureTests {
    /// The process footprint the system counts against the app, in bytes.
    private nonisolated static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// A cover of `side` pixels with a gradient and stripes, so a JPEG
    /// carries real detail; `jpeg` false gives a PNG, which ImageIO can not
    /// subsample while it reduces.
    private static func cover(_ side: Int, jpeg: Bool) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let draw: (UIGraphicsImageRendererContext) -> Void = { context in
            for row in stride(from: 0, to: side, by: 6) {
                UIColor(hue: CGFloat(row) / CGFloat(side), saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: row, width: side, height: 6))
            }
        }
        return jpeg ? renderer.jpegData(withCompressionQuality: 0.85, actions: draw) : renderer.pngData(actions: draw)
    }

    /// Each case runs alone in its own process (`-only-testing`), so no case
    /// starts with the caches of another.
    @Test("Messung: Speicherspitze, 40 JPEG-Cover, acht zugleich")
    func jpegEight() async throws { try await measure(jpeg: true, together: 8) }

    @Test("Messung: Speicherspitze, 40 JPEG-Cover, eines nach dem anderen")
    func jpegOne() async throws { try await measure(jpeg: true, together: 1) }

    @Test("Messung: Speicherspitze, 40 PNG-Cover, acht zugleich")
    func pngEight() async throws { try await measure(jpeg: false, together: 8) }

    private func measure(jpeg: Bool, together: Int) async throws {
        let covers = 40, side = 3000, cell: CGFloat = 400
        let body = Self.cover(side, jpeg: jpeg)
        let served = try await BulkImportTests.Stand.start(.answer(status: 200, body: body))
        defer { served.stop() }
        let ending = jpeg ? "jpg" : "png"
        let urls = (0..<covers).map { URL(string: "http://127.0.0.1:\(served.port)/peak-\($0)-\(UUID().uuidString).\(ending)")! }

        let peak = OSAllocatedUnfairLock(initialState: (peak: UInt64(0), stop: false))
        let baseline = Self.footprint()
        let sampler = Thread {
            while !peak.withLock({ $0.stop }) {
                let now = Self.footprint()
                peak.withLock { $0.peak = max($0.peak, now) }
                usleep(2_000)
            }
        }
        sampler.start()
        let started = Date()
        var answered = 0
        for batch in stride(from: 0, to: covers, by: together) {
            let cells = urls[batch..<min(batch + together, covers)].map { url in
                Task { @MainActor in await Artwork.image(for: url, thumbnail: cell) == nil ? 0 : 1 }
            }
            for asked in cells { answered += await asked.value }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        peak.withLock { $0.stop = true }
        let top = peak.withLock { $0.peak }
        let settled = Self.footprint()
        let mb = { (bytes: UInt64) in String(format: "%.1f", Double(bytes) / 1_048_576) }
        print("COVERPEAK format=\(ending) bytes=\(body.count) together=\(together) covers=\(covers) side=\(side) cell=\(Int(cell)) answered=\(answered) baseline_mb=\(mb(baseline)) peak_mb=\(mb(top)) rise_mb=\(mb(top > baseline ? top - baseline : 0)) after_mb=\(mb(settled)) ms=\(ms)")
        #expect(top > 0, "the footprint could not be read")
    }
}
#endif
