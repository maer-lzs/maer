// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import XCTest

/// f01d6d3 probe (temporary scaffolding, not part of the routine suites):
/// measures the SEAM on a rendered featured card — the pixel column at the
/// card's horizontal center, across the artwork→text-zone boundary. With the
/// edge-colour ground the column must be near-constant; the old whole-image
/// mean showed a visible break there. Run gated so routine suites skip it.
nonisolated final class EdgeJoinProbe: XCTestCase {

    func testFeaturedCardJoinColumn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["EDGE_PROBE"] == "1",
                          "probe only — set EDGE_PROBE=1")
        let app = XCUIApplication()
        app.launch()
        let serverless = app.buttons["start-serverless"].firstMatch
        if serverless.waitForExistence(timeout: 20) { serverless.tap() }
        XCTAssertTrue(app.buttons["tab-radio"].firstMatch.waitForExistence(timeout: 25))
        app.buttons["tab-radio"].firstMatch.tap()

        // Star ONE station so a featured card appears in "My Stations".
        let tiles = app.buttons.matching(identifier: "radio-tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 60), "keine Kacheln")
        var starred = false
        for index in 0..<3 where !starred {
            let tile = tiles.element(boundBy: index)
            guard tile.exists else { continue }
            tile.press(forDuration: 1.1)
            let favorite = app.buttons["radio-favorite-toggle"].firstMatch
            if favorite.waitForExistence(timeout: 6) { favorite.tap(); starred = true }
            else { app.tap() }
        }
        try XCTSkipUnless(starred, "konnte keinen Favoriten setzen")

        let card = app.buttons.matching(identifier: "radio-card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "keine Karte")
        // Let logo, accent and edge measurement land.
        Thread.sleep(forTimeInterval: 8)

        let frame = card.frame
        let shot = XCUIScreen.main.screenshot()
        guard let cg = shot.image.cgImage else { return XCTFail("kein CGImage") }
        let scale = CGFloat(cg.width) / shot.image.size.width

        // The join: card width == artwork height, so the artwork/text boundary
        // sits at frame.minY + frame.width. Sample the center column ±14 pt.
        let x = Int((frame.midX) * scale)
        let boundary = (frame.minY + frame.width) * scale
        var samples: [(Int, Int, Int, Int)] = []
        guard let data = cg.dataProvider?.data as Data? else { return XCTFail("keine Daten") }
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        for dy in stride(from: -14.0, through: 14.0, by: 2.0) {
            let y = Int(boundary + dy * scale)
            guard y >= 0, y < cg.height else { continue }
            let i = y * bpr + x * bpp
            samples.append((Int(dy), Int(data[i]), Int(data[i + 1]), Int(data[i + 2])))
        }
        // Max channel delta between neighbouring samples INSIDE the band —
        // the number the report needs.
        var maxDelta = 0
        for pair in zip(samples, samples.dropFirst()) {
            maxDelta = max(maxDelta,
                           abs(pair.0.1 - pair.1.1),
                           abs(pair.0.2 - pair.1.2),
                           abs(pair.0.3 - pair.1.3))
        }
        let lines = samples.map { "dy=\($0.0): RGB(\($0.1),\($0.2),\($0.3))" }
        NSLog("EDGEPROBE column=\(x) boundary=\(Int(boundary)) maxDelta=\(maxDelta)\n"
              + lines.joined(separator: "\n"))

        let shotAttachment = XCTAttachment(screenshot: shot)
        shotAttachment.name = "edge-join"
        shotAttachment.lifetime = .keepAlways
        add(shotAttachment)
        app.terminate()
    }
}
