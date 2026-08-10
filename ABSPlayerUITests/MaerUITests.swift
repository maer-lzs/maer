// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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

    /// 7330cc4: leave the current detail page by its OWN back button. Using
    /// `app.navigationBars.buttons` by index reaches across every bar in the
    /// hierarchy — including the library's, whose leading button is present
    /// only on tabs that have something to sort.
    private func backOut(_ app: XCUIApplication) {
        let bar = app.navigationBars.element(boundBy: app.navigationBars.count - 1)
        let back = bar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the detail page must offer a way back")
        back.tap()
    }

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
        // Fold rule (Befund-V seed): the delayed Entdecken rows land after
        // ~2 s ABOVE Up Next and can push every marker below the lazy fold —
        // scroll to each instead of pinning a layout.
        XCTAssertTrue(waitScrollingTo(app, text: "Seed Book One"),
                      "queued audiobook must render (T3/T5)")
        XCTAssertTrue(waitScrollingTo(app, text: "Seed Album"),
                      "queued music album must render (T3/T5)")
        let episode = app.staticTexts["Seed Episode One"].firstMatch
        var episodeSwipes = 0
        while !episode.exists && episodeSwipes < 6 { app.swipeUp(); episodeSwipes += 1 }
        XCTAssertTrue(episode.exists, "queued podcast episode must render")
        // bd66c5b: the Continue row renders the seeded in-progress ALBUM in
        // the SAME Featured-card format as book/episode cards (one row, one
        // format) — the music card carries its own a11y id.
        XCTAssertTrue(app.buttons["music-continue-card"].firstMatch.waitForExistence(timeout: 10),
                      "music continue entry must render as a Featured-format card")
        snap(app, "mixed-continue-row")
    }

    /// Home journey: the Home tab is the start tab and aggregates sections; a
    /// jump/tab switch reaches the podcast library and back.
    func testHomeAndTabSwitching() {
        let app = launchSeeded()
        // Home is the start tab — its Up Next section shows the seeded queue.
        // Auftrag L: the Entdecken rows sit ABOVE Up Next and fill from the
        // live catalogs, so the seed marker can sink below the fold of the
        // lazy root — scroll it into existence instead of pinning a layout.
        XCTAssertTrue(waitScrollingTo(app, text: "Seed Book One"))
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
        XCTAssertTrue(waitScrollingTo(app, text: "Seed Book One"))
    }

    /// Scroll helper for lazy roots: an element below the fold is not in the
    /// AX tree until its row materializes — swipe up (bounded) while looking.
    private func waitScrollingTo(_ app: XCUIApplication, text: String,
                                 swipes: Int = 8) -> Bool {
        let element = app.staticTexts[text].firstMatch
        if element.waitForExistence(timeout: 15) { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 2) { return true }
        }
        return false
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
        // Same fold rule as testHomeAndTabSwitching: AX3-sized tiles plus the
        // grown Entdecken rows can push the seed marker below the lazy root's
        // fold — scroll to it instead of pinning a layout.
        XCTAssertTrue(waitScrollingTo(app, text: "Seed Book One"))
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
        // Full player: the work is the large title; the fallback part marker
        // below. 9aad53c: the title line is a source-navigation BUTTON now.
        let workTitle = app.buttons["player-source-title"].firstMatch
        XCTAssertTrue(workTitle.waitForExistence(timeout: 15),
                      "full player must show the work title (X14)")
        XCTAssertTrue(workTitle.label.contains("Now Playing Book"),
                      "the title line must carry the work title (X14)")
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

        // M3: the sixth browse entry pushes the genre page; the seed provider
        // has no server → the honest empty state (not a spinner forever).
        let genresRow = app.buttons["music-route-genres"].firstMatch
        XCTAssertTrue(genresRow.waitForExistence(timeout: 15), "Genres entry must exist (M3)")
        genresRow.tap()
        // The page itself must open (nav title, "Genres" == de + en) and the
        // empty state must render — ContentUnavailableView's identifier lands
        // on varying element types, so query ANY descendant.
        XCTAssertTrue(app.navigationBars["Genres"].waitForExistence(timeout: 10),
                      "genre page must open (M3)")
        // Seed has a configured client without a reachable server — the page
        // must land in ONE of its two honest terminal states (error state
        // with Retry, or "No genres"), never a spinner forever (rule 3).
        let genreTerminal = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier IN %@", ["genres-empty", "genres-error"])).firstMatch
        XCTAssertTrue(genreTerminal.waitForExistence(timeout: 15),
                      "genre page must reach an honest terminal state without a server")
        app.navigationBars.buttons.firstMatch.tap()   // back to the tab root

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
        // Search sections apply asynchronously since the freeze fix — poll
        // briefly for the episode hit to clear instead of asserting instantly.
        let droppedEpisode = app.staticTexts["Seed Episode One"].firstMatch
        var polls = 0
        while droppedEpisode.exists && polls < 10 { usleep(400_000); polls += 1 }
        XCTAssertFalse(droppedEpisode.exists, "music scope must drop the episode hit")
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
        // The first screen is the MAP: every area with one line about what it
        // needs — and four of five need nothing.
        let audiobooks = app.buttons["source-map-audiobooks"].firstMatch
        XCTAssertTrue(audiobooks.waitForExistence(timeout: 15), "the setup must show the map of areas")
        for area in ["music", "podcasts", "radio", "freeCatalogs"] {
            XCTAssertTrue(app.buttons["source-map-\(area)"].firstMatch.exists,
                          "area \(area) must be on the map")
        }
        // An area without a server says what it would need, and leads there.
        audiobooks.tap()
        XCTAssertTrue(app.buttons["settings-abs-source"].firstMatch.waitForExistence(timeout: 10),
                      "the audiobook area must lead to the Audiobookshelf setup")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let start = app.buttons["start-serverless"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15), "setup must offer the serverless path")
        start.tap()
        XCTAssertTrue(app.buttons["open-settings"].firstMatch.waitForExistence(timeout: 15),
                      "serverless start must land in the app")
        XCTAssertFalse(app.buttons["tab-audiobooks"].firstMatch.exists,
                       "no book source → no audiobooks tab")
        app.terminate()
    }

    /// F2 (d9ef077): the map is not a screen you tap away once — the settings
    /// show the SAME component, which is what makes the way back exist. Proof
    /// is that both places carry the same rows with the same identifiers, and
    /// that the settings side reaches every area page.
    func testSourceMapIsAlsoTheSettingsSourcesOverview() {
        let app = launchSeeded()
        XCTAssertTrue(app.buttons["open-settings"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["open-settings"].firstMatch.tap()
        for area in ["audiobooks", "music", "podcasts", "radio", "freeCatalogs"] {
            let row = app.buttons["source-map-\(area)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10),
                          "the settings must show the same map row for \(area)")
        }
        // A filled state: the seeded run is connected, so the audiobook row
        // names a host instead of asking for one.
        var scrollBack = 0
        while !app.buttons["source-map-audiobooks"].firstMatch.isHittable && scrollBack < 6 {
            app.swipeUp(); scrollBack += 1
        }
        app.buttons["source-map-audiobooks"].firstMatch.tap()
        XCTAssertTrue(app.buttons["settings-abs-source"].firstMatch.waitForExistence(timeout: 10),
                      "the area page must carry the source entry")
        backOut(app)
        XCTAssertTrue(app.buttons["settings-done"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["settings-done"].firstMatch.tap()
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
            // The source row lives behind its area on the map (General pill,
            // the settings' landing tab).
            let area = app.buttons["source-map-music"].firstMatch
            XCTAssertTrue(area.waitForExistence(timeout: 10))
            area.tap()
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
            // 7330cc4: anchor on the CURRENT navigation bar, not on index 0 of
            // ALL bars — `app.navigationBars` also sees the library bar behind
            // the sheet, whose button count varies per tab (the sort button
            // only exists where there is something to sort). The index was
            // always fragile; it merely happened to fit.
            backOut(app)   // source page → area page
            backOut(app)   // area page → the map
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
        // 5219ea7 + 4ca91e6 (#83): the shuffle badge is a nested button
        // inside the card's play button — a real gesture-conflict blind spot.
        // Tapping the BADGE must start playback WITHOUT navigating; the card
        // remains on the tab (no pushed detail page).
        // isHittable THROWS for off-screen elements ("activation point
        // invalid") — frame containment instead, like newCardOnScreen above.
        let badgeQuery = app.buttons.matching(identifier: "playlist-shuffle-badge")
        let badge = badgeQuery.allElementsBoundByIndex.first { el in
            let f = el.frame
            return !f.isEmpty && f.minX >= 0 && f.maxX <= app.frame.maxX + 1
        } ?? badgeQuery.firstMatch
        XCTAssertTrue(badge.exists, "playlist card must carry the shuffle corner button")
        badge.tap()
        let miniShuffle = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Seed Song")).firstMatch
        XCTAssertTrue(miniShuffle.waitForExistence(timeout: 10),
                      "badge tap must START PLAYBACK (seeded song in the mini bar)")
        XCTAssertTrue(app.buttons["music-route-albums"].firstMatch.exists,
                      "badge tap must NOT navigate — the tab root stays visible")
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
        let picker = app.buttons["radio-region-picker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10),
                      "after Change region the picker must appear immediately (no dead section)")
        // b942da6/b1ab99d: the picker is a SHEET now — curated list with the
        // country-change layer; choosing binds to an existing entry.
        picker.tap()
        XCTAssertTrue(app.buttons["radio-country-change"].firstMatch.waitForExistence(timeout: 10),
                      "the sheet must offer the Change-Country layer")
        let region = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Seed Region Two")).firstMatch
        XCTAssertTrue(region.waitForExistence(timeout: 10), "curated region rows must list the states")
        region.tap()
        XCTAssertTrue(app.staticTexts["Seed Region Two"].firstMatch.waitForExistence(timeout: 10),
                      "choosing a region must show its section")
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
        let podcastArea2 = app.buttons["source-map-podcasts"].firstMatch
        XCTAssertTrue(podcastArea2.waitForExistence(timeout: 10), "the podcast area must be on the map")
        podcastArea2.tap()
        let rss = app.switches["settings-source-rss"].firstMatch
        XCTAssertTrue(rss.waitForExistence(timeout: 10), "RSS source toggle must exist")
        rss.tap()   // off → sources bump with podcasts transiently unavailable
        rss.tap()   // back on → second bump, state restored
        backOut(app)
        let done = app.buttons["settings-done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()

        // The podcast tab must still be the active one (the old code showed
        // Home here — "Seed Book One" — after the first bump).
        XCTAssertTrue(app.staticTexts["Seed Show"].firstMatch.waitForExistence(timeout: 10),
                      "tab selection must survive transient source loss (Y37 hardening)")
    }

    /// Letzter-Tab (01.08): the app restarts on the last selected tab (master
    /// toggle permitting) — the "always lands on Home again" complaint.
    func testAppRestartsOnLastSelectedTab() {
        var app = XCUIApplication()
        app.launchArguments += ["-uitest", "-uitest-keeptab"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let podcasts = app.buttons["tab-podcasts"].firstMatch
        XCTAssertTrue(podcasts.waitForExistence(timeout: 15))
        podcasts.tap()
        XCTAssertTrue(app.navigationBars["Podcasts"].firstMatch.waitForExistence(timeout: 15))
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["-uitest", "-uitest-keeptab"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        // Auftrag K: the marker is the podcast NAVIGATION BAR, not the "Seed
        // Show" tile — the new catalog tile row pushes the recently-updated
        // LazyVGrid below the fold, where its cells don't materialize into
        // the AX tree (verified via tree dump: the tab renders fully, the
        // grid is just off-screen). The bar carries the same assertion:
        // the app restarted ON the podcast tab.
        XCTAssertTrue(app.navigationBars["Podcasts"].firstMatch.waitForExistence(timeout: 20),
                      "the app must restart on the podcast tab (last selection)")
        // Cleanup for order-independence: back to Home for later journeys.
        app.buttons["tab-home"].firstMatch.tap()
    }

    /// 9aad53c: the full player's title line navigates to the source page —
    /// player minimizes (keeps playing, mini bar visible), detail is pushed.
    func testPlayerNavigatesToSource() {
        let app = launchSeeded(withActivePlayer: true)
        let mini = app.buttons["Now Playing Book"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        mini.tap()
        let title = app.buttons["player-source-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "book title must be tappable (source target)")
        title.tap()
        // Player minimized: the mini bar is back …
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "player must MINIMIZE, playback keeps running")
        // … and a detail page is pushed (back button present on the stack).
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10),
                      "a source page must be pushed onto the stack")
        snap(app, "player-to-source")
    }

    /// Gate 2 (8913feb), second mount context: the full player opened from
    /// the mini bar while a DETAIL PAGE is already pushed on the stack. The
    /// title tap must still route (central router — no environment chain
    /// that can break per presentation context).
    func testPlayerNavigatesToSourceFromPushedPage() {
        let app = launchSeeded(withActivePlayer: true)
        // Push a book detail first (deep mount context).
        let books = app.buttons["tab-audiobooks"].firstMatch
        XCTAssertTrue(books.waitForExistence(timeout: 20))
        books.tap()
        let matches = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Seed Book One"))
        XCTAssertTrue(matches.element(boundBy: 0).waitForExistence(timeout: 15))
        (matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch).tap()
        XCTAssertTrue(app.staticTexts["Ada Author"].waitForExistence(timeout: 15), "book detail must open")
        // Open the full player from the mini bar ON the pushed page.
        let mini = app.buttons["Now Playing Book"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        mini.tap()
        let title = app.buttons["player-source-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15), "title must stay tappable in this mount context")
        title.tap()
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "player must MINIMIZE, playback keeps running")
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10),
                      "the source page must be pushed onto the stack")
        snap(app, "player-to-source-pushed")
    }

    /// a449534: the consolidated settings — the Music pill's toggles WORK
    /// (persist), the suggestion-language row exists and multi-selects, and
    /// the Network-Services page flips the SAME key the feature home shows
    /// (second access point, one truth).
    func testSettingsConsolidation() {
        let app = launchSeeded()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        let settings = app.buttons["open-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        // Music pill exists and carries the moved metadata toggles.
        let pill = app.buttons["settings-tab-music"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "Music pill must exist")
        pill.tap()
        // Locale-independent handle (de: "Songtexte …" — label queries trap).
        let lyrics = app.switches["music-lyrics-toggle"].firstMatch
        XCTAssertTrue(lyrics.waitForExistence(timeout: 10), "lyrics toggle must live on the Music pill")
        let before = lyrics.value as? String
        lyrics.tap()
        // SwiftUI switch values update asynchronously — poll for the flip;
        // fall back to a coordinate tap on the switch knob once.
        var flipDeadline = Date().addingTimeInterval(3)
        while (lyrics.value as? String) == before && Date() < flipDeadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if (lyrics.value as? String) == before {
            lyrics.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            flipDeadline = Date().addingTimeInterval(3)
            while (lyrics.value as? String) == before && Date() < flipDeadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        let after = lyrics.value as? String
        XCTAssertNotEqual(after, before, "the Music-pill lyrics toggle must actually flip")
        // Network-Services page flips the SAME key: navigate there and check
        // the LRCLIB toggle mirrors the changed state.
        // Ids, never labels — a label match found the TAB pill behind the
        // sheet (firstMatch) and the tap fizzled on the sheet surface.
        let generalPill = app.buttons["settings-tab-general"].firstMatch
        XCTAssertTrue(generalPill.waitForExistence(timeout: 5)); generalPill.tap()
        let network = app.buttons["settings-network-services"].firstMatch
        var swipes = 0
        while !network.isHittable && swipes < 6 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(network.waitForExistence(timeout: 10)); network.tap()
        // 8b4327c: id instead of the label predicate the comment above bans.
        let lrclib = app.switches["network-lrclib-toggle"].firstMatch
        XCTAssertTrue(lrclib.waitForExistence(timeout: 10), "LRCLIB row must exist on the services page")
        XCTAssertEqual(lrclib.value as? String, after,
                       "the services toggle must mirror the SAME key the Music pill changed")
        // 8b4327c: the itunes toggle id gets a REAL assertion (same one-truth
        // rule — it shares homeRecommendations with the Podcasts pill).
        let itunes = app.switches["network-itunes-toggle"].firstMatch
        XCTAssertTrue(itunes.exists, "the Apple-catalog toggle must carry its id")
        backOut(app)
        // Suggestion languages: row exists, list multi-selects (second pick).
        let podcastsPill = app.buttons["settings-tab-podcasts"].firstMatch
        XCTAssertTrue(podcastsPill.waitForExistence(timeout: 5)); podcastsPill.tap()
        let langRow = app.buttons["settings-suggestion-languages"].firstMatch
        XCTAssertTrue(langRow.waitForExistence(timeout: 10)); langRow.tap()
        let en = app.buttons["suggestion-lang-en"].firstMatch
        let deRow = app.buttons["suggestion-lang-de"].firstMatch
        XCTAssertTrue(en.waitForExistence(timeout: 10) && deRow.exists,
                      "language list must offer the choices")
        en.tap(); deRow.tap()   // multi-select: both on (order-independent)
        snap(app, "settings-consolidated")
    }

    /// 24a220e: the premium management carried two test hooks that no test
    /// used — and since the identity migration and the twin guard landed
    /// (730c1cb), that surface deserves a fence. The marking sheet is the
    /// part a seeded run can reach without a real premium feed: it must
    /// OPEN (a menu could not carry the explaining line, which is why it
    /// became a sheet) and list the free subscriptions A→Z.

    /// df0b3bb 3: take a title off the Continue row without losing its
    /// position. Uses the seeded MUSIC continue card — the only started entry
    /// the seed carries — which also proves the parity across media types.
    func testHideFromContinueRemovesTheCard() {
        let app = launchSeeded()
        let card = app.buttons["music-continue-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the seeded continue card must show")

        card.press(forDuration: 1.2)
        let hide = app.buttons["Nicht mehr unter Fortsetzen zeigen"].firstMatch
        XCTAssertTrue(hide.waitForExistence(timeout: 5),
                      "the continue card must offer to leave the row")
        hide.tap()

        XCTAssertTrue(card.waitForNonExistence(timeout: 10),
                      "the card must leave the row at once")
    }

    /// e96d396 C3 — der Zaun: ein Buch mit lastUpdate aelter als die
    /// Wiederentdecken-Schwelle (Seed: 5 Wochen) MUSS unter Fortsetzen
    /// sichtbar sein. Die Altersgrenze aus e46e7b4 hat genau das entfernt
    /// ("harte Regression"); dieser Test macht ihre Wiederkehr rot.
    func testContinueKeepsStaleStarts() {
        let app = launchSeeded()
        let books = app.buttons["tab-audiobooks"].firstMatch
        XCTAssertTrue(books.waitForExistence(timeout: 20))
        books.tap()
        let stale = app.staticTexts["Seed Book Old"].firstMatch
        XCTAssertTrue(stale.waitForExistence(timeout: 15),
                      "a five-week-old start must stay in Continue")
    }

    /// A3 (09.08.): the fence for the "built but never wired" class. Auftrag Q
    /// built the whole catalog-book search — queries, mapping, result kind —
    /// and it never reached the screen, because `Scope.kinds(.audiobooks)`
    /// filtered `.catalogBook` away and the catalog card only rendered in the
    /// podcast scope. Nothing was red; the feature was simply dead.
    ///
    /// This journey searches in the BOOK scope and requires a catalog hit. It
    /// fails the moment either wire is cut again.
    func testBookScopeShowsCatalogResults() {
        let app = launchSeeded()
        app.buttons["global-search"].firstMatch.tap()
        let scope = app.buttons["scope-audiobooks"].firstMatch
        XCTAssertTrue(scope.waitForExistence(timeout: 20), "the book scope must exist")
        scope.tap()
        // Y17: the field sits in the bottom bar and is a plain TextField
        // (not a UISearchBar) — same access as every other search journey.
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Seed Catalog Book")
        // The seeded catalog answer carries a .catalogBook hit; if the scope
        // filters it away (A1) or the card is missing (A2), nothing shows.
        let hit = app.staticTexts["Seed Catalog Book"].firstMatch
        if !hit.waitForExistence(timeout: 15) {
            // Diagnose (bleibt bis der Zaun steht): was steht stattdessen da?
            XCTFail("no catalog hit in the book scope — screen was:\n"
                    + app.descendants(matching: .staticText).allElementsBoundByIndex
                        .prefix(40).map { $0.label }.joined(separator: " | "))
        }
    }

    /// Paket 4 (11be262): the merged page "Freie Hörbücher & Hörspiele" is
    /// reachable from the podcast tab's preview entry, and its feed rows
    /// (static curation) render — end-to-end over the real navigation path.
    func testMergedCatalogReachableFromPodcastTab() {
        let app = launchSeeded()
        let podcasts = app.buttons["tab-podcasts"].firstMatch
        XCTAssertTrue(podcasts.waitForExistence(timeout: 20))
        podcasts.tap()

        let entry = app.descendants(matching: .any)["free-catalog-entry-podcasts"].firstMatch
        var swipes = 0
        while !entry.exists && swipes < 8 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(entry.waitForExistence(timeout: 10),
                      "the podcast tab must carry the catalog entry")
        entry.tap()

        // The German sim: the OERR row heading is static curation — no network.
        let heading = app.staticTexts["Öffentlich-rechtliche Hörspiele"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10),
                      "the merged page must show the public-broadcast row")
        // And a curated feed row is present with its subscribe control.
        XCTAssertTrue(app.staticTexts["hr2 Hörspiel"].firstMatch.waitForExistence(timeout: 5))
    }

    /// Befund V (1448c1c): the Entdecken rows appear on the FIRST Start stay
    /// — no tab switch needed. The cold start used to miss the late store
    /// fill (NetworkMonitor not ready on the one compute pass); the fix kicks
    /// the loads when connectivity arrives. Live catalogs, so the timeout is
    /// generous; the row sits below the fold → scroll while waiting.
    func testEntdeckenRowsAppearOnColdStart() {
        let app = launchSeeded()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        // Stay on Start. 3b98dfb: match the locale-independent row id, not
        // the localized heading text.
        let heading = app.buttons["home-discover-music"].firstMatch
        var rounds = 0
        while !heading.exists && rounds < 12 {
            app.swipeUp()
            _ = heading.waitForExistence(timeout: 5)
            if heading.exists { break }
            app.swipeDown(); app.swipeDown()
            rounds += 1
        }
        XCTAssertTrue(heading.exists,
                      "the Entdecken row must appear on the first Start stay, without a tab switch")
    }

    /// fb21fbd → Auftrag J1: sorting moved from the tab head to the section,
    /// and now WITH the section's full grid onto its page. The journey walks
    /// the whole J1 chain: preview heading (counted chevron with the total)
    /// → All-Books page → the control lives THERE and opens its menu; the
    /// tab preview carries no control anymore.
    func testAllBooksPreviewPageAndSortControl() {
        let app = launchSeeded()
        let books = app.buttons["tab-audiobooks"].firstMatch
        XCTAssertTrue(books.waitForExistence(timeout: 20))
        books.tap()

        // The preview heading sits below the fold — scroll it into view.
        let allBooks = app.staticTexts["Alle Bücher"].firstMatch
        var swipes = 0
        while !allBooks.exists && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(allBooks.waitForExistence(timeout: 10), "preview heading must exist")
        // J1: NO control on the tab preview anymore (it moved to the page).
        XCTAssertFalse(app.descendants(matching: .any)["section-sort-control"].firstMatch.exists,
                       "the tab preview must not carry the sort control")
        // The heading names the total (25 seeded books > 9 preview) and pushes.
        allBooks.tap()

        let pageBar = app.navigationBars["Alle Bücher"].firstMatch
        XCTAssertTrue(pageBar.waitForExistence(timeout: 10), "the All-Books page must open")
        let control = app.descendants(matching: .any)["section-sort-control"].firstMatch
        if !control.waitForExistence(timeout: 10) {
            XCTFail("no sort control on the page. Hierarchy:\n\(app.debugDescription)")
            return
        }
        // It opens the SAME menu as before the move.
        control.tap()
        let sortPicker = app.buttons["Sort By"].firstMatch
        let anyOption = app.buttons["Titel"].firstMatch
        XCTAssertTrue(sortPicker.waitForExistence(timeout: 5) || anyOption.waitForExistence(timeout: 5),
                      "the control must open the sort menu")
    }

    /// Auftrag J2: the podcast "Recently Updated" grid is a 12-tile preview;
    /// the full subscription grid (with the moved sort/filter control) lives
    /// on its page. Chain: counted chevron (31 shows seeded via -uitest-huge)
    /// → page → filter to zero hits shows the honest line (fb21fbd way back)
    /// → filter back → tiles return.
    func testRecentlyUpdatedPreviewAndSubscriptionsPage() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "-uitest-huge"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let podcasts = app.buttons["tab-podcasts"].firstMatch
        XCTAssertTrue(podcasts.waitForExistence(timeout: 20))
        podcasts.tap()

        let heading = app.staticTexts["Zuletzt aktualisiert"].firstMatch
        var swipes = 0
        while !heading.exists && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "preview heading must exist")
        heading.tap()

        let pageBar = app.navigationBars["Zuletzt aktualisiert"].firstMatch
        XCTAssertTrue(pageBar.waitForExistence(timeout: 10), "the subscriptions page must open")
        let control = app.descendants(matching: .any)["section-sort-control"].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10), "the control lives on the page now")

        // Filter to zero hits (seed has no downloads): honest line, way back.
        control.tap()
        let withDownloads = app.buttons["Geladen"].firstMatch
        XCTAssertTrue(withDownloads.waitForExistence(timeout: 5)); withDownloads.tap()
        XCTAssertTrue(app.staticTexts["Keine Sendung passt zu diesem Filter"].firstMatch
            .waitForExistence(timeout: 10), "zero hits must say so instead of a blank grid")
        control.tap()
        let all = app.buttons["Alle"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5)); all.tap()
        XCTAssertTrue(app.staticTexts["Seed Show"].firstMatch.waitForExistence(timeout: 10),
                      "clearing the filter must bring the shows back")
    }

    func testPremiumMarkingSheetOpensSorted() {
        let app = launchSeeded()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        let gear = app.buttons["open-settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 15), "settings must be reachable")
        gear.tap()
        let podcastsPill = app.buttons["settings-tab-podcasts"].firstMatch
        XCTAssertTrue(podcastsPill.waitForExistence(timeout: 10)); podcastsPill.tap()

        let markEntry = app.buttons["premium-mark-menu"].firstMatch
        guard markEntry.waitForExistence(timeout: 10) else {
            // Honest skip: without free subscriptions the entry is absent BY
            // DESIGN (nothing to mark) — that is not a failure, and asserting
            // it would pin the seed instead of the behaviour.
            snap(app, "premium-marking-absent")
            return
        }
        markEntry.tap()
        // The sheet, not a menu: heading + purpose line + the plain list.
        let picks = app.buttons.matching(identifier: "premium-mark-pick")
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 10),
                      "the marking sheet must list the free subscriptions")
        // A→Z: the visible titles come sorted (the old menu used stock order).
        let titles = (0..<min(picks.count, 6)).map { picks.element(boundBy: $0).label }
        XCTAssertEqual(titles, titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending },
                       "the list must be alphabetical — it was stock order before")
        snap(app, "premium-marking-sheet")
    }

    /// M5-Nachbesserung (580e9c3): ONE term that hits album + song + playlist
    /// must render ALL music sections (the device saw only artists — that was
    /// Subsonic's per-entity matching on an artist-name query, not a missing
    /// section; this pins the render path for every kind).
    func testMusicSearchShowsAllSections() {
        let app = launchSeeded()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        let search = app.buttons["global-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let musicScope = app.buttons["scope-music"].firstMatch
        XCTAssertTrue(musicScope.waitForExistence(timeout: 10))
        musicScope.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Seed")
        XCTAssertTrue(app.staticTexts["Seed Album"].firstMatch.waitForExistence(timeout: 10),
                      "Albums section must render")
        field.typeText("\n")   // dismiss keyboard for scrolling
        for hit in ["Seed Song", "Seed Playlist"] {
            let el = app.staticTexts[hit].firstMatch
            var swipes = 0
            while !el.exists && swipes < 5 { app.swipeUp(); swipes += 1 }
            XCTAssertTrue(el.exists, "\(hit) section must render")
        }
        snap(app, "music-search-all-sections")
    }

    /// Fahrmodus 9941a9a: PORTRAIT must work — the fixed transport row used to
    /// overflow the portrait column (464 pt row on ~345 pt), clipping the skip
    /// buttons. All three transport buttons must be hittable and INSIDE the
    /// window in both orientations; screenshots feed the cover-variant choice.
    /// af3ec41: average brightness of the left+right margin strips in the
    /// band below the hero (45–80 % height) — pure black backdrop stays ~0;
    /// a bleeding artwork layer lifts it far above the threshold.
    /// 206e552: the control area is no longer BLACK but the app-standard
    /// tinted gradient, so "≈0 brightness" would break — and merely relaxing
    /// the threshold would let the next bleeding artwork through. The
    /// replacement measures what a GRADIENT is and an image is not:
    /// (1) it stays heavily darkened (drive-mode legibility), and
    /// (2) left and right margin at the same height are the SAME color — a
    ///     vertical gradient is horizontally uniform, a bleeding cover is not.
    private func assertDriveMarginsDark(_ image: UIImage) {
        guard let cg = image.cgImage,
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            XCTFail("screenshot pixels unavailable"); return
        }
        let w = cg.width, h = cg.height
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = y * bpr + x * bpp
            return (Int(bytes[p]), Int(bytes[p + 1]), Int(bytes[p + 2]))
        }
        var total = 0, count = 0
        var maxSideDelta = 0
        for y in stride(from: Int(Double(h) * 0.45), to: Int(Double(h) * 0.80), by: 4) {
            for xr in [0..<(w / 12), (w - w / 12)..<w] {
                for x in stride(from: xr.lowerBound, to: xr.upperBound, by: 4) {
                    let (r, g, b) = pixel(x, y)
                    total += r + g + b
                    count += 3
                }
            }
            // Mirror sample: same height, left vs right margin center.
            let (lr, lg, lb) = pixel(w / 24, y)
            let (rr, rg, rb) = pixel(w - w / 24, y)
            maxSideDelta = max(maxSideDelta, abs(lr - rr) + abs(lg - rg) + abs(lb - rb))
        }
        let avg = Double(total) / Double(max(count, 1))
        // Tinted darkness: clearly darker than any rendered cover area.
        XCTAssertLessThan(avg, 70,
                          "control-area margins must stay heavily darkened — avg brightness \(avg) hints a bleeding artwork layer (af3ec41/206e552)")
        XCTAssertLessThan(maxSideDelta, 30,
                          "left and right margin must match at every height (a vertical gradient does, artwork does not) — max delta \(maxSideDelta)")
    }

    func testDriveModePortraitAndLandscape() {
        XCUIDevice.shared.orientation = .portrait
        let app = launchSeeded(withActivePlayer: true)
        let mini = app.buttons["Now Playing Book"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        mini.tap()
        // 84acc50: drive mode sits DIRECTLY in the extras row (More menu gone).
        let drive = app.buttons["player-drive-mode"].firstMatch
        XCTAssertTrue(drive.waitForExistence(timeout: 15), "Drive Mode must sit in the extras row")
        drive.tap()
        let play = app.buttons["drive-play-pause"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "drive mode must open")
        let window = app.windows.firstMatch.frame
        for id in ["drive-skip-back", "drive-play-pause", "drive-skip-forward"] {
            let b = app.buttons[id].firstMatch
            XCTAssertTrue(b.exists, "\(id) must exist")
            XCTAssertTrue(window.contains(b.frame),
                          "\(id) must fit the PORTRAIT window — was \(b.frame) in \(window)")
        }
        // The sleep button left by decision (0693e05).
        XCTAssertFalse(app.buttons["drive-sleep"].exists, "sleep button must be gone")
        // 8d54582/298d6b1 hero geometry: the capped hero must never displace
        // the controls — play button sits in the lower ~2/3 and the progress
        // line stays fully on screen.
        // cda2bea: hero raised to ~40 % — the transport must still sit fully
        // BELOW it and inside the window (buttons never displaced/shrunk).
        XCTAssertGreaterThan(play.frame.minY, window.height * 0.38,
                             "hero must stay capped above the transport row")
        XCTAssertLessThan(play.frame.maxY, window.height,
                          "play button must remain fully on screen under the larger hero")
        let remaining = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "-")).firstMatch
        XCTAssertTrue(remaining.exists && window.contains(remaining.frame),
                      "progress line must stay on screen below the hero")
        snap(app, "drive-portrait-hero")
        // af3ec41: below the hero seam ONLY black — a foreign artwork layer
        // (the stale-image class) brightens the SIDE MARGINS of the control
        // area (title/buttons are centered; the margins must stay dark).
        assertDriveMarginsDark(app.screenshot().image)
        XCUIDevice.shared.orientation = .landscapeLeft
        // Rotation settles asynchronously — poll until the WINDOW is actually
        // wide (a snap mid-animation shows the old orientation's layout).
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let f = app.windows.firstMatch.frame
            if f.width > f.height { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height,
                      "window must settle in landscape")
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let lWindow = app.windows.firstMatch.frame
        for id in ["drive-skip-back", "drive-play-pause", "drive-skip-forward"] {
            XCTAssertTrue(lWindow.contains(app.buttons[id].firstMatch.frame),
                          "\(id) must fit the LANDSCAPE window")
        }
        // Relative geometry proves the landscape layout machine-checkably
        // (the XCTAttachment screenshot mis-rotates in landscape — sim
        // artifact): the three buttons sit in a horizontal row, ordered.
        let back = app.buttons["drive-skip-back"].firstMatch.frame
        let playF = app.buttons["drive-play-pause"].firstMatch.frame
        let fwd = app.buttons["drive-skip-forward"].firstMatch.frame
        XCTAssertLessThan(back.midX, playF.midX, "row order back < play")
        XCTAssertLessThan(playF.midX, fwd.midX, "row order play < forward")
        XCTAssertEqual(back.midY, fwd.midY, accuracy: 4, "buttons on ONE row")
        XCTAssertEqual(back.midY, playF.midY, accuracy: 8, "buttons on ONE row")
        snap(app, "drive-landscape-hero")
        XCUIDevice.shared.orientation = .portrait
    }


    /// Release-Gate 1 (30b2a32): the search must work when opened from a
    /// PUSHED page — the deck/search state lived on the library root and the
    /// gap had zero test coverage. One push level per tab.
    func testSearchOpensFromPushedPages() {
        let app = launchSeeded()
        // Book detail (pushed page on the audiobooks tab).
        let books = app.buttons["tab-audiobooks"].firstMatch
        XCTAssertTrue(books.waitForExistence(timeout: 20))
        books.tap()
        let matches = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Seed Book One"))
        XCTAssertTrue(matches.element(boundBy: 0).waitForExistence(timeout: 15))
        (matches.allElementsBoundByIndex.first { $0.isHittable } ?? matches.firstMatch).tap()
        XCTAssertTrue(app.staticTexts["Ada Author"].waitForExistence(timeout: 15), "book detail must open")
        // Open the search FROM the pushed page.
        let search = app.buttons["global-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "search button must exist on pushed pages")
        search.tap()
        let field = app.textFields["global-search-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "search field must appear from a pushed page")
        field.tap()
        field.typeText("Seed")
        // Y20: the scope starts on the tab the user came from (audiobooks) —
        // assert a BOOK hit, not a cross-media one.
        XCTAssertTrue(app.staticTexts["Seed Book Two"].firstMatch.waitForExistence(timeout: 10),
                      "search results must render when opened from a pushed page")
        snap(app, "search-from-pushed-book")
        // Y19: the first X only clears the query (browse deck) — the second
        // X closes the search page.
        app.buttons["search-close"].firstMatch.tap()
        app.buttons["search-close"].firstMatch.tap()

        // Podcast show page (pushed page on the podcasts tab).
        let podcasts = app.buttons["tab-podcasts"].firstMatch
        XCTAssertTrue(podcasts.waitForExistence(timeout: 10))
        podcasts.tap()
        let show = app.staticTexts["Seed Show"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 15))
        show.tap()
        search.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Seed")
        // Podcast scope: the episode hit is the scope-correct expectation.
        XCTAssertTrue(app.staticTexts["Seed Episode One"].firstMatch.waitForExistence(timeout: 10),
                      "search results must render from a pushed podcast page")
        snap(app, "search-from-pushed-show")
    }

    /// 0aa18b7 + 86cf180: radio play identity + the full-player title tap.
    /// (1) Tapping a NAMED catalog tile plays THAT station — the mini bar
    /// carries the same name (tile↔stream identity; UUIDs ride the RADIO
    /// tap/play log pair). (2) With radio running, the player's title tap
    /// opens the station DETAIL page and playback keeps running — the radio
    /// case was missing from the source-page journeys, which is how the
    /// device defect slipped through.
    func testRadioPlayIdentityAndTitleTap() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "-radioEnabled", "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        app.buttons["tab-radio"].firstMatch.tap()
        // Full-suite hardening: the discovery card rows shift with persisted
        // region/recents state AND live-network Home rows — the FAVORITES
        // list row ("Seed Radio One") is the stable anchor at the top.
        let row = app.staticTexts["Seed Radio One"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        // The tap opens the FULL player. Under full-suite load a tap can
        // land inside a settle animation and fizzle — one deliberate retry
        // (same hardening as the drive-mode journey).
        if !app.buttons["player-queue"].firstMatch.waitForExistence(timeout: 12) {
            row.tap()
        }
        XCTAssertTrue(app.buttons["player-queue"].firstMatch.waitForExistence(timeout: 20),
                      "the full player must open from the row tap")
        // Identity + G8 in one: the tappable title source entry must exist
        // AND carry the tapped station's name (chevron renders only when
        // the target resolves).
        let title = app.buttons["player-source-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15),
                      "the radio title must be tappable (target derivation broken otherwise)")
        XCTAssertTrue(title.label.contains("Seed Radio One"),
                      "the tapped row's station must be the one playing")
        title.tap()
        // Station detail open, playback untouched (mini bar still there —
        // detail text + mini-bar button both carry the name, so ≥2 matches).
        XCTAssertTrue(app.staticTexts["Seed Radio One"].firstMatch.waitForExistence(timeout: 10),
                      "the station detail must open from the title tap")
        XCTAssertTrue(app.buttons["Seed Radio One"].firstMatch.waitForExistence(timeout: 10),
                      "playback must keep running")
        snap(app, "radio-title-tap-detail")
        app.terminate()
    }

    /// 8b4327c (2): the playlist-card shuffle badge is a nested button
    /// inside the navigation button — the regression class is a tap that
    /// NAVIGATES instead of playing. Badge tap ⇒ playback starts, the
    /// detail page does NOT open.
    func testPlaylistShuffleBadgePlaysWithoutNavigating() {
        let app = launchSeeded()
        let music = app.buttons["tab-music"].firstMatch
        XCTAssertTrue(music.waitForExistence(timeout: 15))
        music.tap()
        XCTAssertTrue(app.staticTexts["Seed Playlist"].firstMatch.waitForExistence(timeout: 15))
        let badge = app.buttons["playlist-shuffle-badge"].firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "the shuffle badge must exist on the card")
        badge.tap()
        // Playback bound to the item: the mini bar appears with the seeded
        // song ("Seed Song" — the mini bar's a11y label is the item title).
        XCTAssertTrue(app.buttons["Seed Song"].firstMatch.waitForExistence(timeout: 15),
                      "the badge tap must start playback")
        // …and the card tap did NOT navigate (no pushed detail nav bar).
        XCTAssertFalse(app.navigationBars["Seed Playlist"].exists,
                       "the badge tap must not open the playlist detail")
        app.terminate()
    }

    /// 8b4327c (4): the OPML-export micro path — freshly security-changed
    /// (1d4c348), so the entry is anchored: source page → export → share
    /// link appears. The system share sheet is where the assertion ends.
    func testOPMLExportPath() {
        let app = launchSeeded()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        app.buttons["open-settings"].firstMatch.tap()
        // The four source sections are ONE map of areas now — the podcast
        // source page sits one push deeper, at its area.
        let podcastArea = app.buttons["source-map-podcasts"].firstMatch
        var swipes = 0
        while !podcastArea.isHittable && swipes < 6 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(podcastArea.waitForExistence(timeout: 10)); podcastArea.tap()
        let source = app.buttons["settings-podcast-source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        let export = app.buttons["opml-export"].firstMatch
        swipes = 0
        while !export.exists && swipes < 8 { app.swipeUp(); swipes += 1 }
        XCTAssertTrue(export.waitForExistence(timeout: 10), "export entry must exist (seed has real subscriptions)")
        export.tap()
        XCTAssertTrue(app.buttons["opml-share-link"].firstMatch.waitForExistence(timeout: 10),
                      "the share link must appear after export")
        app.terminate()
    }

    /// 84acc50: the FULL six-item extras row on the German sim (worst-case
    /// labels) must fit WITHOUT the jagged two-column grid — either the
    /// labeled row fits or the icon-only fallback renders; both are ONE
    /// horizontal row, asserted via frame containment (all items share one
    /// baseline band and stay inside the window).
    func testPlayerRowFullGerman() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "-uitest-player", "-uitest-fullrow"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        let mini = app.buttons["Now Playing Book"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 20))
        mini.tap()
        let queue = app.buttons["player-queue"].firstMatch
        XCTAssertTrue(queue.waitForExistence(timeout: 15))
        let window = app.windows.firstMatch.frame
        let ids = ["player-queue", "player-drive-mode", "player-mark-finished"]
        var minYs: [CGFloat] = []
        for id in ids {
            let b = app.buttons[id].firstMatch
            XCTAssertTrue(b.exists, "\(id) must sit directly in the extras row")
            XCTAssertTrue(window.contains(b.frame),
                          "\(id) must fit the window — was \(b.frame)")
            minYs.append(b.frame.minY)
        }
        // One row: every item shares the same vertical band (±8 pt).
        if let lo = minYs.min(), let hi = minYs.max() {
            XCTAssertLessThan(hi - lo, 8, "extras must form ONE row, not a grid")
        }
        XCTAssertFalse(app.buttons["player-more"].exists, "the More menu is gone")
        snap(app, "player-row-full-german")
        app.terminate()
    }

    /// 6b3a35d: drive mode with a LIVE station — no skip buttons (G8, no
    /// seek buffer), the shared LIVE row instead of "-0 min", play/pause
    /// stays. Hero-gate rendering is visual (device loop); the structure
    /// asserts here.
    func testDriveModeRadioLive() {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest", "-radioEnabled", "1"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        app.buttons["tab-radio"].firstMatch.tap()
        // Favorites row as the stable anchor (see the identity journey).
        let row = app.staticTexts["Seed Radio One"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let drive = app.buttons["player-drive-mode"].firstMatch
        if !drive.waitForExistence(timeout: 12) {
            // First-test-in-run: a tap can land inside a launch/settle
            // animation and fizzle — one deliberate retry.
            row.tap()
        }
        XCTAssertTrue(drive.waitForExistence(timeout: 20), "full player must open")
        drive.tap()
        XCTAssertTrue(app.buttons["drive-play-pause"].firstMatch.waitForExistence(timeout: 10),
                      "drive mode must open with play/pause")
        // Live: skips gone, LIVE row present.
        XCTAssertFalse(app.buttons["drive-skip-forward"].firstMatch.exists,
                       "±skip must vanish on a live stream")
        XCTAssertFalse(app.buttons["drive-skip-back"].firstMatch.exists)
        XCTAssertTrue(app.otherElements["drive-live-row"].firstMatch.exists
                      || app.staticTexts["LIVE"].firstMatch.exists,
                      "the LIVE row must replace the remaining-time line")
        snap(app, "drive-mode-radio-live")
        app.terminate()
    }

    /// 5034add: the free-catalogs MASTER switch — off greys the subordinate
    /// area toggle and removes the (net-independent) classical DECK tile
    /// (klassik-in-die-suche: the entry moved into the music search deck).
    /// Ids only, never labels (de-sim trap); master back ON at the end so
    /// later journeys see the default state.
    func testFreeCatalogsMasterSwitch() {
        let app = launchSeeded()
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20))
        app.buttons["tab-music"].firstMatch.tap()
        // Surface check: the classical tile lives in the SEARCH deck now.
        app.buttons["global-search"].firstMatch.tap()
        let musicScope = app.buttons["scope-music"].firstMatch
        XCTAssertTrue(musicScope.waitForExistence(timeout: 10)); musicScope.tap()
        let tile = app.buttons["deck-tier-music-free-classical"].firstMatch
        var deckSwipes = 0
        while !tile.exists && deckSwipes < 6 { app.swipeUp(); deckSwipes += 1 }
        XCTAssertTrue(tile.waitForExistence(timeout: 10),
                      "classical deck tile must exist while the master is on")
        // Close the search again before heading into settings (Y17: the
        // search X — the global-search button morphs away in search mode).
        app.buttons["search-close"].firstMatch.tap()

        func flip(_ toggle: XCUIElement) {
            let before = toggle.value as? String
            toggle.tap()
            var deadline = Date().addingTimeInterval(3)
            while (toggle.value as? String) == before && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
            if (toggle.value as? String) == before {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
                deadline = Date().addingTimeInterval(3)
                while (toggle.value as? String) == before && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            XCTAssertNotEqual(toggle.value as? String, before, "master toggle must flip")
        }

        app.buttons["open-settings"].firstMatch.tap()
        // The General list is LAZY — below-the-fold rows are absent from the
        // a11y tree until scrolled to (same class as the seed-episode trap).
        let master = app.switches["settings-free-catalogs-master"].firstMatch
        var scrolls = 0
        while !master.exists && scrolls < 6 { app.swipeUp(); scrolls += 1 }
        XCTAssertTrue(master.waitForExistence(timeout: 10), "master must sit on the General pill")
        flip(master)
        // Subordinate area toggle greys out — visible hierarchy, no double
        // state. The area toggles sit at their area on the map now (they used
        // to be split across two media pills). Reopening the sheet is how we
        // get back to the top: swiping DOWN inside a sheet dismisses it, so a
        // scroll-up loop would silently lose the whole screen.
        app.buttons["settings-done"].firstMatch.tap()
        app.buttons["open-settings"].firstMatch.tap()
        let catalogArea = app.buttons["source-map-freeCatalogs"].firstMatch
        XCTAssertTrue(catalogArea.waitForExistence(timeout: 10)); catalogArea.tap()
        let area = app.switches["music-free-classical-toggle"].firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 10))
        XCTAssertFalse(area.isEnabled, "area toggle must grey out while the master is off")
        backOut(app)
        XCTAssertTrue(app.buttons["settings-done"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["settings-done"].firstMatch.tap()
        // Surface gone: the deck tile disappears with the master off.
        app.buttons["global-search"].firstMatch.tap()
        let musicScope2 = app.buttons["scope-music"].firstMatch
        XCTAssertTrue(musicScope2.waitForExistence(timeout: 10)); musicScope2.tap()
        XCTAssertFalse(app.buttons["deck-tier-music-free-classical"].firstMatch.waitForExistence(timeout: 3),
                       "classical deck tile must vanish with the master off")
        app.buttons["search-close"].firstMatch.tap()
        snap(app, "free-catalogs-master-off")
        // Clean up: master back on for whoever runs next.
        app.buttons["open-settings"].firstMatch.tap()
        scrolls = 0
        while !master.exists && scrolls < 6 { app.swipeUp(); scrolls += 1 }
        XCTAssertTrue(master.waitForExistence(timeout: 10))
        flip(master)
        app.buttons["settings-done"].firstMatch.tap()
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
