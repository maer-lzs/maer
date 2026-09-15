// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import XCTest

/// The collective switch-off, end to end and ON THE PAGE.
///
/// The model side is fenced by `ExternalSourcesTests`; what no unit case can
/// see is that the page SHOWS the result afterwards. That hangs on a
/// hand-built crutch (`@State refresh` plus `.id(...)`), because the rows read
/// their key through `@AppStorage`, which does not see a write that bypasses
/// it. If the crutch falls in a rebuild, the button writes eleven keys and the
/// page keeps saying "on": the class "switch says A, state is B".
///
/// Therefore this journey never navigates away in between. A fresh page would
/// read the keys again and look right even with the crutch gone, which is
/// exactly the failure it is here to catch.
nonisolated final class SourcesAllOffJourney: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Two sources that always carry a switch, one per group, so the case
    /// reads the page and not a single row's luck.
    private let watched = ["source-toggle-lrclib", "source-toggle-appleCatalog"]

    func testTurningEverySourceOffShowsOnTheSamePage() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-harness", "-uitest", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app did not come up")

        try openSourcesPage(app)

        // The precondition, assured instead of assumed: a case that starts
        // with everything already off would measure nothing at all.
        var switches: [String: XCUIElement] = [:]
        for id in watched {
            let element = app.switches[id].firstMatch
            XCTAssertTrue(scrollTo(app, element), "the page must carry \(id)")
            switches[id] = element
        }
        let before = switches.mapValues { $0.value as? String }
        for (id, value) in before {
            try XCTSkipIf(value == nil, "\(id) reports no state")
            if value != "1" {
                switches[id].map(flip)
                XCTAssertEqual(switches[id]?.value as? String, "1", "\(id) must start ON for this measurement")
            }
        }

        // The action, with its second step.
        let allOff = app.buttons["sources-all-off"].firstMatch
        XCTAssertTrue(scrollTo(app, allOff, hittable: true), "the page must carry the collective action")
        allOff.tap()
        let confirm = app.buttons["sources-all-off-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "the collective switch-off must ask before it writes")
        confirm.tap()

        // NO navigation in between: this is the whole point of the case.
        for id in watched {
            let element = app.switches[id].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 10), "\(id) must still be on screen")
            XCTAssertEqual(element.value as? String, "0",
                           "\(id) still shows ON after the collective switch-off: the page did not re-read its keys")
        }

        // Put the bench back: EVERY source, not just the two this case
        // watches. The switches live in the simulator's real defaults, so a
        // half-healed page leaves the unit suite running against dead
        // sources afterwards (measured: two catalog fences fell over it).
        // Through a restart, because after the alert the rows sit elsewhere
        // and the cleanup is not what this case measures.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app did not come back up")
        try openSourcesPage(app)
        turnEverySourceBackOn(app)
        for id in watched {
            let element = app.switches[id].firstMatch
            XCTAssertTrue(scrollTo(app, element, hittable: true), "\(id) must be reachable again")
            XCTAssertEqual(element.value as? String, "1", "\(id) must be back ON for the cases after this one")
        }
        app.terminate()
    }

    /// The cancel half of the same promise: a collective destruction that is
    /// waved away writes nothing.
    func testCancellingTheCollectiveSwitchOffWritesNothing() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-harness", "-uitest", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app did not come up")

        try openSourcesPage(app)
        let lrclib = app.switches[watched[0]].firstMatch
        XCTAssertTrue(scrollTo(app, lrclib), "the page must carry \(watched[0])")
        if lrclib.value as? String != "1" { flip(lrclib) }
        try XCTSkipUnless(lrclib.value as? String == "1", "the row must start ON for this measurement")

        let allOff = app.buttons["sources-all-off"].firstMatch
        XCTAssertTrue(scrollTo(app, allOff, hittable: true))
        allOff.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "the dialog must offer a way out")
        cancel.tap()

        XCTAssertEqual(lrclib.value as? String, "1",
                       "a cancelled collective switch-off must leave every switch alone")
        app.terminate()
    }

    // MARK: - Getting there

    private func openSourcesPage(_ app: XCUIApplication) throws {
        let gear = app.buttons["open-settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 20), "the library must carry the settings gear")
        gear.tap()
        let general = app.buttons["settings-tab-general"].firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 15), "the settings must carry the general pill")
        general.tap()
        let sources = app.buttons["settings-external-sources"].firstMatch
        XCTAssertTrue(scrollTo(app, sources, hittable: true), "the general pill must carry the sources entry")
        sources.tap()
    }

    /// Walks the page and flips every switch that stands OFF. There is no
    /// collective way back by design, so the cleanup does what a person
    /// would do: one after the other, scrolling down as it goes.
    private func turnEverySourceBackOn(_ app: XCUIApplication) {
        for _ in 0..<4 { app.swipeDown() }
        for _ in 0..<10 {
            var flipped = false
            for element in app.switches.allElementsBoundByIndex
            where element.exists && element.isHittable && element.value as? String == "0" {
                flip(element)
                flipped = true
            }
            if !flipped { app.swipeUp() }
            if !app.buttons["sources-all-off"].firstMatch.exists { continue }
        }
        for _ in 0..<4 { app.swipeDown() }
    }

    /// Flips one of these switches. Measured in this project's own journey
    /// (`MaerUITests.swift`, the lyrics row): a plain `tap()` on the element
    /// does not move them, the hit has to land on the control at the row's
    /// trailing edge.
    private func flip(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    @discardableResult
    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement,
                          hittable: Bool = false, swipes: Int = 8) -> Bool {
        let reached = { hittable ? element.isHittable : element.exists }
        if element.waitForExistence(timeout: 10), reached() { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 2), reached() { return true }
        }
        return false
    }
}
