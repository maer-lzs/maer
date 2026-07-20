// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Permanent UI-test harness (Stage 2). Read-only journeys only — never mutate a
/// live server (mirrors the audit harness discipline). Data-dependent journeys
/// launch with `-uitest`, which activates the DEBUG-only seeding hook
/// (UITestSeed): the login gate is bypassed and deterministic fake content is
/// injected, so no live server/account is touched.
///
/// `nonisolated`: the target inherits SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
/// from the app, but XCTestCase's lifecycle (init/setUp) is nonisolated — opt out.
nonisolated final class MaerUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchSeeded(withActivePlayer: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest"]
        // Opt-in: only the full-player journey wants an active player; other
        // journeys stay free of the ever-present, tappable mini player.
        if withActivePlayer { app.launchArguments += ["-uitest-player"] }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        return app
    }

    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        // On a clean simulator the app opens on its login/setup gate; on a seeded
        // one, the library. Either way the process must come up and render.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        XCTAssertGreaterThan(app.windows.count, 0)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// T3/T5 proof + Home: the app opens on the Home tab, whose "Up Next" section
    /// renders the global queue with ALL media types together — a book, a music
    /// album and a podcast episode. Before the fix the book + album were dropped.
    func testMixedQueueRendersAllTypes() {
        let app = launchSeeded()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20),
                      "queued audiobook must render (T3/T5)")
        XCTAssertTrue(app.staticTexts["Seed Album"].firstMatch.exists,
                      "queued music album must render (T3/T5)")
        XCTAssertTrue(app.staticTexts["Seed Episode One"].firstMatch.exists,
                      "queued podcast episode must render")
        snap(app, "mixed-queue-all-types")
    }

    /// Home journey: the Home tab is the start tab and aggregates sections; a
    /// jump/tab switch reaches the podcast library and back.
    func testHomeAndTabSwitching() {
        let app = launchSeeded()
        // Home is the start tab — its Up Next section shows the seeded queue.
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        snap(app, "home")

        // Switch to the Podcasts tab → seeded show.
        let podcasts = app.buttons["tab-podcasts"].firstMatch
        XCTAssertTrue(podcasts.waitForExistence(timeout: 10))
        podcasts.tap()
        XCTAssertTrue(app.staticTexts["Seed Show"].waitForExistence(timeout: 15)
                      || app.staticTexts["Seed Episode One"].firstMatch.waitForExistence(timeout: 5))
        snap(app, "podcast-tab")

        // Back to Home.
        let home = app.buttons["tab-home"].firstMatch
        if home.waitForExistence(timeout: 10) { home.tap() }
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 10))
    }

    /// Etappe 6 matrix: the changed surfaces at an ACCESSIBILITY text size (AX3)
    /// — Home (mixed queue, 128pt covers, sections) and the Music tab (badges,
    /// CoverGrid). Screenshots for the size matrix.
    func testAccessibilitySizeAX3() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest",
                                "-UIPreferredContentSizeCategoryName",
                                "UICTContentSizeCategoryAccessibilityExtraLarge"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        snap(app, "home-ax3")
        let music = app.buttons["tab-music"].firstMatch
        if music.waitForExistence(timeout: 10) { music.tap() }
        _ = app.staticTexts["Seed Album"].firstMatch.waitForExistence(timeout: 10)
        snap(app, "music-ax3")
    }

    /// X14: the full player must show the WORK title as the largest text, with
    /// the chapter/part line below it — the reported bug showed only the cleaned
    /// chapter ("Teil 12"). The seed installs a presentation-only book with
    /// fallback chapters; opening the full player must surface both.
    func testFullPlayerShowsWorkTitle() {
        let app = launchSeeded(withActivePlayer: true)
        // The seeded active player shows in the mini bar (label = work title).
        let miniPlayer = app.buttons["Now Playing Book"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 20), "mini player must show the active work")
        miniPlayer.tap()
        // Full player: the work is the large title; the fallback part marker below.
        XCTAssertTrue(app.staticTexts["Now Playing Book"].waitForExistence(timeout: 15),
                      "full player must show the work title (X14)")
        XCTAssertTrue(app.staticTexts["Teil 2 von 3"].firstMatch.exists,
                      "the chapter/part line sits below the work title")
        snap(app, "full-player-book")
    }

    /// X15: from a music SUB-page (album detail, artist detail) the media tab bar
    /// must switch library — music pushes used plain destination links that stayed
    /// on the stack, so the tab tap looked dead. Both entry points are covered.
    func testMusicSubpagesTabBarSwitchesLibrary() {
        let app = launchSeeded()
        let music = app.buttons["tab-music"].firstMatch
        XCTAssertTrue(music.waitForExistence(timeout: 15))
        music.tap()

        // Album detail → switch to the audiobook library via the tab.
        let album = app.staticTexts["Seed Album"].firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 15))
        album.tap()
        // Y63: the settings cog stays on the album page (outermost) alongside
        // the album's own trailing actions — it doesn't vanish behind them.
        let albumCog = app.buttons["open-settings"].firstMatch
        XCTAssertTrue(albumCog.waitForExistence(timeout: 10) && albumCog.isHittable,
                      "the settings cog must remain visible on the album page (Y63)")
        let books = app.buttons["tab-audiobooks"].firstMatch
        XCTAssertTrue(books.waitForExistence(timeout: 10))
        books.tap()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 10),
                      "tab bar must switch to the audiobook library from the album page (X15)")
        snap(app, "x15-from-album")

        // Artist detail → switch to the podcast library via the tab. The browse
        // row label is localized ("Künstler") — use its locale-independent id.
        music.tap()
        let artistsRow = app.buttons["music-route-artists"].firstMatch
        XCTAssertTrue(artistsRow.waitForExistence(timeout: 10))
        artistsRow.tap()
        let artist = app.staticTexts["Seed Artist"].firstMatch
        XCTAssertTrue(artist.waitForExistence(timeout: 10))
        artist.tap()
        let podcasts = app.buttons["tab-podcasts"].firstMatch
        XCTAssertTrue(podcasts.waitForExistence(timeout: 10))
        podcasts.tap()
        XCTAssertTrue(app.staticTexts["Seed Show"].waitForExistence(timeout: 10)
                      || app.staticTexts["Seed Episode One"].firstMatch.waitForExistence(timeout: 5),
                      "tab bar must switch to the podcast library from the artist page (X15)")
        snap(app, "x15-from-artist")
    }

    /// N1d: the active tab pill sits concentric to the bar capsule — screenshots
    /// of the states the gap/rounding relation must hold in: at rest and right
    /// after a tab tap (mid-glide, best effort — the snap races the 0.3 s
    /// animation). The seeded lists are too short to scroll past the collapse
    /// threshold, so the collapse morph itself stays a device check; the swipes
    /// still exercise the scroll-reporting path under the new pill.
    func testTabPillConcentricStates() {
        let app = launchSeeded()
        let books = app.buttons["tab-audiobooks"].firstMatch
        XCTAssertTrue(books.waitForExistence(timeout: 15))
        books.tap()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 15))
        snap(app, "pill-at-rest")
        // Mid-glide: snap immediately after the tap, no waits in between.
        app.buttons["tab-podcasts"].firstMatch.tap()
        snap(app, "pill-glide")
        _ = app.staticTexts["Seed Show"].waitForExistence(timeout: 15)
        app.swipeUp(velocity: .fast)
        snap(app, "post-scroll")
    }

    /// Teil 7 (brand-accent trial, decision prep): Start / audiobook library /
    /// full player per candidate — 0 orange (today), 1 Mär blue, 2 anthracite.
    /// A4: gray-shade decision screenshots — every candidate in light AND
    /// dark (the shades are adaptive, both sides matter for the pick).
    func testBrandAccentTrialScreenshots() {
        for (tag, name) in [(0, "anthrazit"), (1, "schiefer"), (2, "graphit")] {
            for mode in ["light", "dark"] {
                let app = XCUIApplication()
                app.launchArguments += ["-uitest", "-uitest-player",
                                        "-brandAccentTrial", "\(tag)", "-appearance", mode]
                app.launch()
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
                XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
                snap(app, "gray-\(name)-\(mode)-home")
                let books = app.buttons["tab-audiobooks"].firstMatch
                if books.waitForExistence(timeout: 10) { books.tap() }
                _ = app.staticTexts["Seed Book One"].waitForExistence(timeout: 10)
                snap(app, "gray-\(name)-\(mode)-library")
                let mini = app.buttons["Now Playing Book"].firstMatch
                if mini.waitForExistence(timeout: 10) {
                    mini.tap()
                    _ = app.staticTexts["Now Playing Book"].waitForExistence(timeout: 10)
                    snap(app, "gray-\(name)-\(mode)-player")
                }
                app.terminate()
            }
        }
    }

    /// F6/Y23: ONE query on the search PAGE finds the seeded book, episode and
    /// album, the "New Shows" catalog sits behind the explicit row (seeded
    /// directory — no real catalog request leaves the harness), the Y20 scope
    /// bar narrows single-select, and the Y19/Y24 X button clears then closes
    /// (with the Y30 recents chip on the deck in between).
    func testGlobalSearchFindsAllTypes() {
        let app = launchSeeded()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        let search = app.buttons["global-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        // Y20: the standing scope bar tops the page; Home opens at "Library".
        XCTAssertTrue(app.buttons["scope-library"].firstMatch.waitForExistence(timeout: 10),
                      "the scope bar must stand on the search page")
        // Y17: the field sits in the bottom bar.
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Seed")
        // Library scope: own hits of every type.
        XCTAssertTrue(app.staticTexts["Seed Episode One"].firstMatch.waitForExistence(timeout: 10),
                      "search must find the seeded episode")
        XCTAssertTrue(app.staticTexts["Seed Album"].firstMatch.exists,
                      "search must find the seeded album")
        snap(app, "global-search-library")
        // Y15: the catalog sits behind the explicit catalog row — dismiss the
        // keyboard (submit) and scroll it into reach first; on the full page
        // it trails ALL own sections.
        field.typeText("\n")
        let catalogRow = app.buttons["search-catalog-row"].firstMatch
        XCTAssertTrue(catalogRow.waitForExistence(timeout: 5), "catalog row must close the library results")
        var swipes = 0
        while !catalogRow.isHittable && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        catalogRow.tap()
        XCTAssertTrue(app.staticTexts["Seed Catalog Show"].firstMatch.waitForExistence(timeout: 10),
                      "the catalog view must show the seeded catalog show")
        snap(app, "global-search-catalog")
        // Y20: single-select — the music scope narrows to the album hit.
        app.buttons["scope-music"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Seed Album"].firstMatch.waitForExistence(timeout: 5),
                      "music scope must keep the album hit")
        XCTAssertFalse(app.staticTexts["Seed Episode One"].firstMatch.exists,
                       "music scope must drop the episode hit")
        snap(app, "global-search-scope-music")
        // Y19/Y24: first X clears the query → the browse deck appears with the
        // just-run query as a Y30 recents chip.
        let close = app.buttons["search-close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the round X must sit next to the field")
        close.tap()
        let recentChip = app.buttons["Seed"].firstMatch
        XCTAssertTrue(recentChip.waitForExistence(timeout: 5),
                      "the deck must offer the recent search")
        snap(app, "global-search-deck")
        // Tapping the chip re-runs the search (results view returns).
        recentChip.tap()
        XCTAssertTrue(app.buttons["search-catalog-row"].firstMatch.waitForExistence(timeout: 10),
                      "the recents chip must re-run the query")
        // Second X pair: clear, then close — the magnifier button returns.
        close.tap()
        close.tap()
        XCTAssertTrue(app.buttons["global-search"].firstMatch.waitForExistence(timeout: 5),
                      "the X on an empty field must close the search")
    }

    /// F10: the serverless path — the setup offers the equal "start without a
    /// server" button; tapping it lands in the app (settings reachable, no
    /// audiobooks tab without a book source).
    func testServerlessOnboarding() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-setup"]
        app.launch()
        let start = app.buttons["start-serverless"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15), "setup must offer the serverless path")
        start.tap()
        XCTAssertTrue(app.buttons["open-settings"].firstMatch.waitForExistence(timeout: 15),
                      "serverless start must land in the app")
        XCTAssertFalse(app.buttons["tab-audiobooks"].firstMatch.exists,
                       "no book source → no audiobooks tab")
        app.terminate()
    }

    /// Y37: the source toggle drives the tab bar LIVE in both directions —
    /// switching the music source off removes the Music tab without a restart,
    /// switching it back on restores it.
    func testMusicSourceToggleUpdatesTabs() {
        let app = launchSeeded()
        let music = app.buttons["tab-music"].firstMatch
        XCTAssertTrue(music.waitForExistence(timeout: 15), "seeded music source must surface the tab")

        func setMusicToggle() {
            let gear = app.buttons["open-settings"].firstMatch
            XCTAssertTrue(gear.waitForExistence(timeout: 10))
            gear.tap()
            // Etappe E: the source row lives in the tab-independent Sources
            // section on the General pill (the settings' landing tab).
            let row = app.buttons["settings-music-source"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            let toggle = app.switches["music-tab-toggle"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10))
            // The identifier sits on the row-wide element — a center tap hits
            // the label, which does NOT flip a Form toggle. Tap the trailing
            // knob and verify the value actually changed.
            let before = toggle.value as? String
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let flipped = NSPredicate(format: "value != %@", before ?? "")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: flipped, object: toggle)],
                                          timeout: 5), .completed, "the toggle must flip")
            // Back to the settings root (Done lives on ITS toolbar), then out.
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let done = app.buttons["settings-done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
        }

        setMusicToggle()   // off
        XCTAssertTrue(music.waitForNonExistence(timeout: 10),
                      "switching the source off must remove the tab live")
        setMusicToggle()   // on again
        XCTAssertTrue(music.waitForExistence(timeout: 10),
                      "switching the source on must restore the tab live")
    }

    /// F4/F5: the radio tab appears with the source switched on (seeded
    /// favorites), lists the stations, and the live search finds them under
    /// the radio scope. No real catalog/stream leaves the harness.
    func testRadioTabAndSearch() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "-radioEnabled", "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        let radio = app.buttons["tab-radio"].firstMatch
        XCTAssertTrue(radio.waitForExistence(timeout: 10), "enabled radio source must surface the tab")
        radio.tap()
        XCTAssertTrue(app.staticTexts["Seed Radio One"].firstMatch.waitForExistence(timeout: 10),
                      "favorites must list the seeded station")
        // F4-discovery: the browse sections show the seeded catalog stand-in
        // (net-gated in production; the harness never hits the real catalog).
        XCTAssertTrue(app.staticTexts["Seed Popular Station"].firstMatch.waitForExistence(timeout: 10),
                      "the Popular browse row must list the seeded catalog station")
        // A curated genre tile pushes its station list (byTag drilldown).
        let newsGenre = app.buttons["radio-genre-news"].firstMatch
        var genreSwipes = 0
        while !newsGenre.isHittable && genreSwipes < 6 { app.swipeUp(); genreSwipes += 1 }
        XCTAssertTrue(newsGenre.waitForExistence(timeout: 10), "the curated genre tiles must appear")
        newsGenre.tap()
        XCTAssertTrue(app.staticTexts["Seed Catalog Two"].firstMatch.waitForExistence(timeout: 10),
                      "tapping a genre must push its station list")
        app.navigationBars.buttons.element(boundBy: 0).tap()   // back to the radio tab
        // Radio scope in the global search (only visible with the source on).
        app.buttons["global-search"].firstMatch.tap()
        XCTAssertTrue(app.buttons["scope-radio"].firstMatch.waitForExistence(timeout: 10),
                      "the radio scope must appear while the source is active")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Seed Radio")
        XCTAssertTrue(app.staticTexts["Seed Radio Two"].firstMatch.waitForExistence(timeout: 10),
                      "search must find the seeded stations")
        app.terminate()
    }

    /// Music tab (seeded albums) — for the S17b bottom-bar background comparison.
    func testMusicTab() {
        let app = launchSeeded()
        let music = app.buttons["tab-music"].firstMatch
        XCTAssertTrue(music.waitForExistence(timeout: 15))
        music.tap()
        XCTAssertTrue(app.staticTexts["Seed Album"].firstMatch.waitForExistence(timeout: 15))
        snap(app, "music-tab")
        // Reference: the audiobook tab bottom bar.
        let books = app.buttons["tab-audiobooks"].firstMatch
        if books.waitForExistence(timeout: 10) { books.tap() }
        snap(app, "audiobooks-tab")
    }
}
