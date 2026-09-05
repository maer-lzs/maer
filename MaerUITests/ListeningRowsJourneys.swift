// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import XCTest

/// The listening rows follow an entry that arrives from OUTSIDE (the shape
/// of a takeover or a pot adoption) without a restart, a tab switch or a
/// pull. The seed writes such an entry twenty seconds after launch
/// (`-uitest-late-entry`); the journeys only wait.
nonisolated final class ListeningRowsJourneys: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchWithLateEntry() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "-uitest-late-entry"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app did not come up")
        return app
    }

    /// The Continue card of the late episode, on whichever surface.
    private func lateCard(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["podcast-continue-rss:seed:ep-2"].firstMatch
    }

    /// Home: the Continue row shows the late episode by itself.
    func testHomeContinueFollowsALateEntry() {
        let app = launchWithLateEntry()
        XCTAssertTrue(app.buttons["tab-home"].firstMatch.waitForExistence(timeout: 15))
        // Rot-Probe: before the entry lands, the row does not carry it.
        XCTAssertFalse(lateCard(app).exists, "the late episode must not be in Continue before its entry exists")
        XCTAssertTrue(lateCard(app).waitForExistence(timeout: 35),
                      "Home must show the late entry without a tab switch or a pull")
    }

    /// Scroll the tab until the element is on screen (a lazy tile below
    /// the fold has no accessibility node until it is built).
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<8 {
            if element.exists { return true }
            app.swipeUp()
        }
        return element.exists
    }

    /// Podcasts tab, opened BEFORE the entries land: the show tile's
    /// unplayed count follows the late entries (22 seeded episodes, one
    /// finishes and one starts late) without leaving the tab. The Next Up row cannot be
    /// the witness here: it lists unplayed episodes with or without a state.
    /// Scrolling is allowed (the late Continue row pushes the grid below
    /// the fold); a tab switch or a pull is not.
    func testPodcastsTabFollowsALateEntry() {
        let app = launchWithLateEntry()
        let podcasts = app.buttons["tab-podcasts"].firstMatch
        XCTAssertTrue(podcasts.waitForExistence(timeout: 15))
        podcasts.tap()
        XCTAssertTrue(app.staticTexts["Seed Show"].firstMatch.waitForExistence(timeout: 15))
        let badge = app.staticTexts.matching(identifier: "show-tile-count").firstMatch
        XCTAssertTrue(scrollTo(badge, in: app), "the seed show tile carries a count")
        // Rot-Probe: before the entries land, every seeded episode is unplayed.
        XCTAssertEqual(badge.label, "22", "the count before the late entry")
        // The entries land twenty seconds after launch. Then find the tile again.
        var seen = ""
        for _ in 0..<16 {
            sleep(2)
            for _ in 0..<3 { app.swipeDown() }
            if scrollTo(badge, in: app) {
                seen = badge.label
                if seen == "20" { break }
            }
        }
        // 22 minus the finished one minus the started one: an episode in
        // progress counts as unplayed in neither mode.
        XCTAssertEqual(seen, "20", "the tile count must follow the late entries without leaving the tab")
    }
}
