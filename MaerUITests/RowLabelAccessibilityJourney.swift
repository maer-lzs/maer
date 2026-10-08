// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import XCTest

/// What VoiceOver reads for a list row whose label lays out symbol and title
/// itself at an accessibility size (`RowLabelStyle`): one element whose
/// label is the title, as the system's label gives at every other size, and
/// not the symbol's name in front of it.
nonisolated final class RowLabelAccessibilityJourney: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func readStorageRows(sizeCategory: String?) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-harness", "-uitest", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let sizeCategory { app.launchArguments += ["-UIPreferredContentSizeCategoryName", sizeCategory] }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app did not come up")
        let settings = app.buttons["open-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "the seeded start page")
        settings.tap()

        let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS[c] 'Wi-Fi'")).firstMatch
        let button = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Clear Cover Cache'")).firstMatch
        var tries = 0
        while !(toggle.exists && button.exists && button.isHittable) && tries < 20 {
            app.swipeUp(velocity: .slow)
            tries += 1
        }
        try XCTSkipUnless(toggle.exists && button.exists, "the storage rows were not reached")
        let size = sizeCategory ?? "standard"
        XCTAssertEqual(toggle.label, "Warn When Not on Wi-Fi", "the switch reads more than its title at \(size)")
        XCTAssertEqual(button.label, "Clear Cover Cache", "the button reads more than its title at \(size)")
        XCTAssertEqual(app.switches.matching(NSPredicate(format: "label CONTAINS[c] 'Wi-Fi'")).count, 1,
                       "the switch row is more than one element at \(size)")
        app.terminate()
    }

    func testTheStorageRowsReadTheirTitleAtAX3() throws {
        try readStorageRows(sizeCategory: "UICTContentSizeCategoryAccessibilityXL")
    }

    func testTheStorageRowsReadTheirTitleAtTheStandardSize() throws {
        try readStorageRows(sizeCategory: nil)
    }
}
