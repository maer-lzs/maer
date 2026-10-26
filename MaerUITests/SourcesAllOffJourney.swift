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
///
/// The same way first walks the music source's own switches: the SOURCE
/// switch no longer touches the tab bar (a tab is the person's master
/// decision, a source only fills or empties its section), the MASTER switch
/// (settings, Libraries) removes and restores the tab, live.
nonisolated final class SourcesAllOffJourney: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Two sources that always carry a switch, one per group, so the case
    /// reads the page and not a single row's luck.
    private let watched = ["source-toggle-lrclib", "source-toggle-appleCatalog"]

    /// When the way started and its last mark, for the seconds each part
    /// takes (`JOURNEYTIME` in the log).
    private var started = Date()
    private var lastMark = Date()

    private func phase(_ name: String) {
        let now = Date()
        print("JOURNEYTIME part=\(name) s=\(Int(now.timeIntervalSince(lastMark))) total=\(Int(now.timeIntervalSince(started)))")
        lastMark = now
    }

    func testTheSourceSwitchesActOnTheTabsAndOnTheSamePage() throws {
        started = Date()
        lastMark = started
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-harness", "-uitest", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app did not come up")
        phase("start")

        let music = app.buttons["tab-music"].firstMatch
        XCTAssertTrue(music.waitForExistence(timeout: 15), "seeded music source must surface the tab")
        setMusicSource(app)   // SOURCE off
        XCTAssertTrue(music.waitForExistence(timeout: 10),
                      "the source toggle must NOT remove the tab; sections empty, tabs stay")
        setMusicSource(app)   // source on again
        setMusicMaster(app)   // MASTER off
        XCTAssertTrue(music.waitForNonExistence(timeout: 10), "the master toggle removes the tab live")
        setMusicMaster(app)   // master on again
        XCTAssertTrue(music.waitForExistence(timeout: 10), "the master toggle restores the tab live")
        phase("music")

        try openSourcesPage(app)
        phase("page")

        // The precondition, assured instead of assumed: a case that starts
        // with everything already off would measure nothing at all.
        // One switch at a time, read while it is on screen: on iOS 18.6 the
        // two watched rows are never in the hierarchy together, and a value
        // read after scrolling to the other one fails the case ("failed to
        // get matching snapshot", measured 01.10.2026 in the result bundle).
        for id in watched {
            let element = app.switches[id].firstMatch
            XCTAssertTrue(scrollTo(app, element), "the page must carry \(id)")
            let value = element.value as? String
            try XCTSkipIf(value == nil, "\(id) reports no state")
            if value != "1" {
                flip(element)
                XCTAssertEqual(element.value as? String, "1", "\(id) must start ON for this measurement")
            }
        }
        phase("precondition")

        // The action, with its second step.
        let allOff = app.buttons["sources-all-off"].firstMatch
        XCTAssertTrue(scrollTo(app, allOff, hittable: true), "the page must carry the collective action")
        allOff.tap()
        let confirm = app.buttons["sources-all-off-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "the collective switch-off must ask before it writes")
        confirm.tap()

        // NO navigation in between: this is the whole point of the case.
        // Scrolling within the page is not navigation, and it is needed: the
        // rows are tall enough that the upper ones leave the hierarchy while
        // the collective action is on screen.
        for id in watched {
            let element = app.switches[id].firstMatch
            XCTAssertTrue(reveal(app, element), "\(id) must still be on this page")
            XCTAssertEqual(element.value as? String, "0",
                           "\(id) still shows ON after the collective switch-off: the page did not re-read its keys")
        }

        phase("switch-off")

        // Put the bench back: EVERY source, not just the two this case
        // watches. The switches live in the simulator's real defaults, so a
        // half-healed page leaves the unit suite running against dead
        // sources afterwards (measured: two catalog fences fell over it).
        // Through a start that writes every source on, because the cleanup
        // is not what this case measures; the page then shows it.
        app.terminate()
        app.launchArguments += ["-uitest-sources-on"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app did not come back up")
        try openSourcesPage(app)
        for id in watched {
            let element = app.switches[id].firstMatch
            XCTAssertTrue(reveal(app, element), "\(id) must be reachable again")
            XCTAssertEqual(element.value as? String, "1", "\(id) must be back ON for the cases after this one")
        }
        phase("cleanup")
        app.terminate()
    }

    // MARK: - The music source's switches

    /// Flips the music source's switch on its page behind the map's music
    /// area and comes back out to the start page.
    private func setMusicSource(_ app: XCUIApplication) {
        let gear = app.buttons["open-settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.tap()
        // The source row lives behind its area on the map (General pill,
        // the settings' landing tab).
        let area = app.buttons["source-map-music"].firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 10))
        area.tap()
        let row = app.buttons["settings-music-source"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        flipAndWait(app.switches["music-tab-toggle"].firstMatch, "the toggle must flip")
        // Back to the settings root (Done lives on ITS toolbar), then out.
        backFromPage(app)   // source page to area page
        backFromPage(app)   // area page to the map
        closeSettings(app)
    }

    /// Closes the settings by Done on their toolbar, or, with the sections
    /// at the side, by the close button at the column's top.
    private func closeSettings(_ app: XCUIApplication) {
        let done = app.buttons["settings-done"].firstMatch
        let close = app.buttons["settings-close"].firstMatch
        let either = NSPredicate { _, _ in done.exists || close.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: either, object: nil)],
                                      timeout: 5), .completed, "the settings must offer a way out")
        (done.exists ? done : close).tap()
    }

    /// Flips the music tab's master switch in the settings.
    private func setMusicMaster(_ app: XCUIApplication) {
        let gear = app.buttons["open-settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.tap()
        let toggle = app.switches["tab-master-music"].firstMatch
        XCTAssertTrue(scrollTo(app, toggle, hittable: true))
        flipAndWait(toggle, "the master toggle must flip")
        closeSettings(app)
    }

    /// The identifier sits on the row-wide element: a center tap hits the
    /// label, which does NOT flip a Form toggle. The trailing knob does, and
    /// the value is waited for.
    private func flipAndWait(_ toggle: XCUIElement, _ message: String) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let before = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let flipped = NSPredicate(format: "value != %@", before ?? "")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: flipped, object: toggle)],
                                      timeout: 5), .completed, message)
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
        // The page itself is the proof that the tap opened it, not the tap.
        // Measured on iOS 18.6 in the run of all ten (29.09.2026): the entry
        // sat at the very bottom of the screen after the swipes, the tap
        // landed there and opened nothing, and the case then looked for a
        // switch on the wrong page for seventy seconds. One more tap after
        // the nudge above is cheap; a case on the wrong page is not.
        let firstSwitch = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'source-toggle-'")).firstMatch
        if !firstSwitch.waitForExistence(timeout: 5), sources.exists, sources.isHittable {
            sources.tap()
            XCTAssertTrue(firstSwitch.waitForExistence(timeout: 10), "the sources page did not open on the second tap either")
        }
    }

    /// Brings an element of this page into view, below or above. A row the
    /// page scrolled past leaves the hierarchy, so its absence says nothing
    /// about whether the page still carries it.
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        if element.waitForExistence(timeout: 5), element.isHittable { return true }
        for _ in 0..<8 {
            app.swipeUp()
            if element.exists, element.isHittable { return true }
        }
        for _ in 0..<8 {
            app.swipeDown()
            if element.exists, element.isHittable { return true }
        }
        return false
    }

    /// Flips one of these switches. Measured in this project's own journey
    /// (`MaerUITests.swift`, the lyrics row): a plain `tap()` on the element
    /// does not move them, the hit has to land on the control at the row's
    /// trailing edge. A tap that moves nothing fails here, where it happens.
    private func flip(_ element: XCUIElement) {
        let before = element.value as? String
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertNotEqual(element.value as? String, before, "\(element.identifier) did not flip")
    }

    @discardableResult
    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement,
                          hittable: Bool = false, swipes: Int = 8) -> Bool {
        let reached = { hittable ? element.isHittable : element.exists }
        if element.waitForExistence(timeout: 10), reached() { return nudgedIntoView(app, element) }
        for _ in 0..<swipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 2), reached() { return nudgedIntoView(app, element) }
        }
        // Back up as well: a row the page scrolled past has left the
        // hierarchy. Measured on iOS 18.6 (30.09.2026): after reaching the
        // lyrics row near the page's end, the directories row above it was
        // gone, and eight more swipes up could never bring it back.
        for _ in 0..<swipes {
            app.swipeDown()
            if element.waitForExistence(timeout: 2), reached() { return nudgedIntoView(app, element) }
        }
        return false
    }

    /// A row that ends at the screen's bottom edge counts as hittable and is
    /// not: measured on iOS 18.6 (29.09.2026), the sources entry stood at
    /// 821 of 852 points after the swipes, and the tap on it opened nothing.
    /// A short drag brings such a row a third of the screen up; a full
    /// swipe would carry it off the top.
    private func nudgedIntoView(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        let screen = app.frame
        guard element.frame.maxY > screen.maxY - 80 else { return true }
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        from.press(forDuration: 0.1, thenDragTo: to)
        return element.exists && element.isHittable
    }
}
