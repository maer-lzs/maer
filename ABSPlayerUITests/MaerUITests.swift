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

    /// F3: the author portrait is SUCCESS-ONLY. The seed injects content into
    /// the view models and serves no author image, so the author line must stay
    /// plain text and NO "All books by …" tap surface may appear — the G8 rule
    /// (no image → no placeholder, no false affordance). The positive path
    /// (image present + ≥2 works → tap filters the library) is device-validated:
    /// the seed has no HTTP layer to vend an author image, and the tap gate
    /// itself is covered by `authorFilterEnabled` unit tests.
    func testAuthorPortraitAbsentWithoutServerImage() {
        let app = launchSeeded()
        let books = app.buttons["tab-audiobooks"].firstMatch
        XCTAssertTrue(books.waitForExistence(timeout: 20))
        books.tap()
        // The TabView keeps Home mounted behind the audiobooks tab, so several
        // buttons carry "Seed Book One" — pick the on-screen (hittable) grid
        // tile, not the occluded Home row.
        let matches = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Seed Book One"))
        XCTAssertTrue(matches.element(boundBy: 0).waitForExistence(timeout: 15),
                      "seeded book cell must exist")
        let bookCell = matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch
        bookCell.tap()
        // Detail page: the author renders as plain text …
        XCTAssertTrue(app.staticTexts["Ada Author"].waitForExistence(timeout: 15),
                      "author line must render on the detail page")
        // … and no author-portrait filter tap surface exists (no server image).
        XCTAssertFalse(app.buttons["All books by Ada Author"].exists,
                       "no server image → no portrait, no filter tap surface")
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
        // Neuordnung 30.07: the tab shows the library list, not the album grid.
        _ = app.buttons["music-route-albums"].firstMatch.waitForExistence(timeout: 10)
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

    /// Up-Next home at the player, entry 1: the mini-player long-press menu
    /// opens the queue sheet; the podcast tab carries no queue section anymore
    /// (its "Up Next" header came only from the removed section). All queries
    /// via locale-independent a11y ids — the sim runs localized.
    func testPlayerQueueEntryMiniPlayer() {
        let app = launchSeeded(withActivePlayer: true)
        // Podcast tab: no queue section despite the seeded, non-empty queue.
        let podcasts = app.buttons["tab-podcasts"].firstMatch
        XCTAssertTrue(podcasts.waitForExistence(timeout: 20))
        podcasts.tap()
        // "Seed Show" is the established tab anchor (testHomeAndTabSwitching).
        XCTAssertTrue(app.staticTexts["Seed Show"].firstMatch.waitForExistence(timeout: 15),
                      "podcast tab content must be up before asserting absence")
        XCTAssertFalse(app.staticTexts["Up Next"].firstMatch.exists,
                       "the podcast tab must not render the queue section anymore")
        // Long-press on the mini player → context menu → queue sheet.
        let miniPlayer = app.buttons["Now Playing Book"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.press(forDuration: 1.6)
        let menuEntry = app.buttons["mini-queue-entry"].firstMatch
        XCTAssertTrue(menuEntry.waitForExistence(timeout: 10),
                      "mini-player long-press must offer the queue entry")
        menuEntry.tap()
        let queueList = app.descendants(matching: .any)["play-queue-list"].firstMatch
        XCTAssertTrue(queueList.waitForExistence(timeout: 10),
                      "queue sheet must open from the mini player")
        snap(app, "player-queue-sheet")
        app.terminate()
    }

    /// Up-Next home at the player, entry 2: the full player's queue control
    /// opens the same queue sheet.
    func testPlayerQueueEntryFullPlayer() {
        let app = launchSeeded(withActivePlayer: true)
        let miniPlayer = app.buttons["Now Playing Book"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 20))
        miniPlayer.tap()
        let queueControl = app.buttons["player-queue"].firstMatch
        XCTAssertTrue(queueControl.waitForExistence(timeout: 15),
                      "full player must carry the queue control")
        queueControl.tap()
        XCTAssertTrue(app.descendants(matching: .any)["play-queue-list"].firstMatch.waitForExistence(timeout: 10),
                      "queue sheet must open from the full player")
        app.terminate()
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
        // Neuordnung 30.07: albums live on their own page behind the list entry.
        let albumsRow = app.buttons["music-route-albums"].firstMatch
        XCTAssertTrue(albumsRow.waitForExistence(timeout: 15))
        albumsRow.tap()
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
        // Fillers don't match "Seed", so the capped sections stay canonical;
        // dismiss the keyboard before scrolling on (swipes over the keyboard
        // don't scroll the list), then reach the album section.
        field.typeText("\n")
        let album = app.staticTexts["Seed Album"].firstMatch
        var albumSwipes = 0
        while !album.exists && albumSwipes < 4 {
            app.swipeUp()
            albumSwipes += 1
        }
        XCTAssertTrue(album.exists, "search must find the seeded album")
        snap(app, "global-search-library")
        // Y15: the catalog sits behind the explicit catalog row — scroll it
        // into reach (keyboard already dismissed above); on the full page it
        // trails ALL own sections.
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

    /// F5: the music tab shows the playlist card row on top (seeded playlists)
    /// with the "New Playlist" card, and that card opens the create flow.
    func testMusicPlaylistCards() {
        let app = launchSeeded()
        let music = app.buttons["tab-music"].firstMatch
        XCTAssertTrue(music.waitForExistence(timeout: 15))
        music.tap()
        // A seeded playlist card is present in the row.
        XCTAssertTrue(app.staticTexts["Seed Playlist"].firstMatch.waitForExistence(timeout: 15),
                      "the playlist card row must list the seeded playlist")
        // The "New Playlist" card opens the create alert.
        let newCard = app.buttons["new-playlist-card"].firstMatch
        XCTAssertTrue(newCard.waitForExistence(timeout: 10), "the New Playlist card must be present")
        // Scroll the row until the card is reachable (it sits after the seed
        // cards, off-screen right). The create-flow ALERT presentation is
        // verified on device (the owner'ss design loop) — presenting a text-field
        // alert from a mounted-but-tab-switched view is unreliable in XCUITest.
        // Korrektur 01.08: with full-size cards the New card starts far
        // off-screen — `isHittable` THROWS there ("activation point invalid"),
        // so reachability is judged by frame containment instead.
        func newCardOnScreen() -> Bool {
            let f = newCard.frame
            return !f.isEmpty && f.minX >= 0 && f.maxX <= app.frame.maxX + 1
        }
        var tries = 0
        while !newCardOnScreen() && tries < 8 {
            let a = app.staticTexts["Seed Playlist Two"].firstMatch
            let b = app.staticTexts["Seed Playlist"].firstMatch
            (a.exists ? a : b).swipeLeft()
            tries += 1
        }
        XCTAssertTrue(newCardOnScreen(), "the New Playlist card must scroll into reach")
        snap(app, "music-playlist-cards")
        app.terminate()
    }

    /// Music tab (seeded albums) — for the S17b bottom-bar background comparison.
    func testMusicTab() {
        let app = launchSeeded()
        let music = app.buttons["tab-music"].firstMatch
        XCTAssertTrue(music.waitForExistence(timeout: 15))
        music.tap()
        // Neuordnung 30.07: the tab's anchor is the library list.
        XCTAssertTrue(app.buttons["music-route-albums"].firstMatch.waitForExistence(timeout: 15))
        snap(app, "music-tab")
        // Reference: the audiobook tab bottom bar.
        let books = app.buttons["tab-audiobooks"].firstMatch
        if books.waitForExistence(timeout: 10) { books.tap() }
        snap(app, "audiobooks-tab")
    }


    // df69f6b regression: the large title must survive BOTH known killer
    // cycles — search open/close and fast tab switches while scrolled (the
    // dynamic ternary title on the live bar used to drop it, leaving its
    // reserved gap; pinned by navigationBarTitleDisplayMode(.large)).
    func testLargeTitleSurvivesCycles() {
        let app = launchSeeded()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        let titleBefore = app.navigationBars.staticTexts.firstMatch.label
        // Cycle 1: open search, close it.
        app.buttons["global-search"].firstMatch.tap()
        XCTAssertTrue(app.buttons["search-close"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["search-close"].firstMatch.tap()
        sleep(1)
        let existsAfterSearch = app.navigationBars.staticTexts.firstMatch.exists
        let labelAfterSearch = existsAfterSearch ? app.navigationBars.staticTexts.firstMatch.label : "<GONE>"
        // Cycle 2: fast tab switches (also scrolled).
        app.swipeUp()
        app.buttons["tab-podcasts"].firstMatch.tap()
        app.buttons["tab-audiobooks"].firstMatch.tap()
        sleep(1)
        // The DEVICE bug is the PERSISTENT loss (title gone, gap stays,
        // until restart). A transient drop during the tab transition exists
        // in suite context (order/timing) and is reported as its own finding
        // — here we assert the title RECOVERS: scroll to top + settle, up to
        // three attempts. A permanent gap still fails all three.
        var recovered = app.navigationBars.staticTexts.firstMatch.exists
        var attempts = 0
        while !recovered && attempts < 3 {
            app.swipeDown()
            sleep(1)
            recovered = app.navigationBars.staticTexts.firstMatch.exists
            attempts += 1
        }
        let labelAfterTabs = recovered ? app.navigationBars.staticTexts.firstMatch.label : "<GONE>"
        print("TITLEPROBE before=\(titleBefore) afterSearch=\(labelAfterSearch) afterTabs=\(labelAfterTabs) recoveryAttempts=\(attempts)")
        XCTAssertTrue(existsAfterSearch, "title gone after search cycle")
        // df69f6b: guarded by the tick-decoupled bar title in LibraryView
        // (FB18304716 family damping) — the title transition no longer lands
        // inside the bar's tab transition.
        XCTAssertTrue(recovered, "title PERMANENTLY gone after tab cycle (the device bug)")
    }


    // Fixlet 4575a76 regression: a returner with a persisted region taps
    // "Change region" — the picker must appear IMMEDIATELY (the section used
    // to go dead until restart because the states list never refilled).
    func testRadioRegionChangeShowsPicker() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "-radioEnabled", "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        let radio = app.buttons["tab-radio"].firstMatch
        XCTAssertTrue(radio.waitForExistence(timeout: 10))
        radio.tap()
        XCTAssertTrue(app.staticTexts["Seed Radio One"].firstMatch.waitForExistence(timeout: 10))
        let change = app.buttons["radio-region-change"].firstMatch
        var swipes = 0
        while !change.isHittable && swipes < 6 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(change.waitForExistence(timeout: 10), "the chosen-region section must offer Change region")
        change.tap()
        XCTAssertTrue(app.buttons["radio-region-picker"].firstMatch.waitForExistence(timeout: 10),
                      "after Change region the picker must appear immediately (no dead section)")
    }

    /// Y37 hardening (01.08): a sources-changed bump with TRANSIENT podcast
    /// unavailability must not throw the user off the podcast tab. The journey
    /// flips the RSS source OFF and back ON while standing on Podcasts — the
    /// old availability-based fallback jumped to Home on the first bump; the
    /// hardened policy keeps the selection (only the tab MASTER toggle moves it).
    func testPodcastTabSurvivesTransientSourceLoss() {
        let app = launchSeeded()
        let podcasts = app.buttons["tab-podcasts"].firstMatch
        XCTAssertTrue(podcasts.waitForExistence(timeout: 15))
        podcasts.tap()
        XCTAssertTrue(app.staticTexts["Seed Show"].firstMatch.waitForExistence(timeout: 15))

        let settings = app.buttons["open-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let rss = app.switches["settings-source-rss"].firstMatch
        XCTAssertTrue(rss.waitForExistence(timeout: 10), "RSS source toggle must exist")
        rss.tap()   // off → sources bump with podcasts transiently unavailable
        rss.tap()   // back on → second bump, state restored
        let done = app.buttons["settings-done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()

        // The podcast tab must still be the active one (the old code showed
        // Home here — "Seed Book One" — after the first bump).
        XCTAssertTrue(app.staticTexts["Seed Show"].firstMatch.waitForExistence(timeout: 10),
                      "tab selection must survive transient source loss (Y37 hardening)")
    }

    /// Such-Freeze diagnosis (01.08): measured FIRST search open + first query
    /// with the FrameProbe running — the long-frame counters around the open/
    /// type moments are the before/after evidence. Gated like the hitch probes.
    func testSearchFreezeProbe() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HITCH_PROBE"] == "1",
                          "measurement probe; set HITCH_PROBE=1 to run")
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "-uitest-huge", "-uitest-frameprobe"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let books = app.buttons["tab-audiobooks"].firstMatch
        XCTAssertTrue(books.waitForExistence(timeout: 15))
        books.tap()
        XCTAssertTrue(app.staticTexts["Seed Book One"].firstMatch.waitForExistence(timeout: 15))
        // Resolve all tap targets BEFORE the measured window — every XCUI
        // element query snapshots the (huge) a11y tree and would dominate the
        // measurement (sample-proven: ~50% XCTElementSnapshotRequest). The
        // probe window uses raw coordinate taps + app-level typing only.
        let search = app.buttons["global-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let searchPoint = CGPoint(x: search.frame.midX, y: search.frame.midY)
        let appOrigin = app.coordinate(withNormalizedOffset: .zero)
        sleep(4)   // settle past the tab-entry spike → clean probe window
        appOrigin.withOffset(CGVector(dx: searchPoint.x, dy: searchPoint.y)).tap()   // ← frozen moment
        sleep(4)
        // Focus the search field by position (bottom bar, Y17) — still no
        // element query inside the window — then type the first query.
        let frame = app.frame
        appOrigin.withOffset(CGVector(dx: frame.midX, dy: frame.maxY - 40)).tap()
        sleep(1)
        app.typeText("a")   // ← first query
        sleep(4)
        app.terminate()
    }

    // MARK: - iPad hitch probes (28.07 diagnosis package — measurement, no assert on values)

    /// Measured collapse-scroll probe: repeated fast scroll cycles across the
    /// collapse threshold on the audiobook grid; the scroll signpost metric
    /// reports hitch-time ratios per iteration. Run on iPhone AND iPad
    /// simulators, portrait and landscape — the numbers land in the log/
    /// xcresult (log-first: measure BEFORE any fix attempt).
    private func runHitchProbe(landscape: Bool) throws {
        // Measurement tool, not a regression assert — runs only in explicit
        // probe sessions (HITCH_PROBE=1), never in the routine suites.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HITCH_PROBE"] == "1",
                          "measurement probe; set HITCH_PROBE=1 to run")
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "-uitest-bulk", "-uitest-frameprobe"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let books = app.buttons["tab-audiobooks"].firstMatch
        XCTAssertTrue(books.waitForExistence(timeout: 15))
        books.tap()
        XCTAssertTrue(app.staticTexts["Seed Book One"].firstMatch.waitForExistence(timeout: 15))
        // Suspect line (a): how much cell/image work sits in one viewport.
        print("HITCHPROBE landscape=\(landscape) visibleImages=\(app.images.count) visibleTexts=\(app.staticTexts.count)")
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric]) {
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
            app.swipeDown(velocity: .fast)
            app.swipeDown(velocity: .fast)
        }
    }

    func testHitchProbePortrait() throws { try runHitchProbe(landscape: false) }

    func testHitchProbeLandscape() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        try runHitchProbe(landscape: true)
    }
}
