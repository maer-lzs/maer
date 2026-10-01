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

    /// Leave the current detail page by its OWN back button. Using
    /// `app.navigationBars.buttons` by index reaches across every bar in the
    /// hierarchy — including the library's, whose leading button is present
    /// only on tabs that have something to sort.
    private func backOut(_ app: XCUIApplication) {
        let bar = app.navigationBars.element(boundBy: app.navigationBars.count - 1)
        let back = bar.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5), "the detail page must offer a way back")
        back.tap()
    }

    /// THE launch. Every journey comes up through here, so "the process really
    /// reached the foreground" is asserted once instead of being forgotten:
    /// two radio journeys tapped their tab straight after `launch()` and paid
    /// for it with a "deliberate retry" that hid the actual cause.
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        // The harness marker rides on EVERY start, seeded or bare: the cloud
        // families stay silent on it, and a source fence keeps it here.
        app.launchArguments += ["-uitest-harness"] + arguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app did not come up")
        return app
    }

    /// The seeded start on top of it. `extra` carries the per-journey switches
    /// (radio, bulk seed, kept tab) — they change what is seeded, not that the
    /// start page has to stand.
    private func launchSeeded(withActivePlayer: Bool = false,
                              extra: [String] = []) -> XCUIApplication {
        // Opt-in: only the full-player journey wants an active player; other
        // journeys stay free of the ever-present, tappable mini player.
        let app = launch(["-uitest"] + (withActivePlayer ? ["-uitest-player"] : []) + extra)
        // THE shared launch precondition — it lived as twelve
        // word-identical copies, each asserting a seed book that sits BELOW
        // the fold (the first viewport is the Continue hero plus the
        // recommendation row). In a lazy container the invisible does not
        // exist, so every copy was a bet on layout. Waiting here on an anchor
        // that is ALWAYS in the first viewport says what the copies meant:
        // "the seeded start page stands". Whoever really needs the book
        // scrolls to it with `waitScrollingTo`.
        XCTAssertTrue(app.buttons["open-settings"].firstMatch.waitForExistence(timeout: 30),
                      "seeded start page did not come up")
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// THE scroll helper for lazy roots. An element below
    /// the fold is not in the AX tree until its row materializes, so looking
    /// once is a bet on the device height and on how fast the delayed rows
    /// above land. Twenty hand-rolled `while !x.exists { swipeUp() }` loops
    /// said the same thing with different swipe budgets and different waits;
    /// this is that loop, once.
    ///
    /// Two predicates, because the journeys mean two different things: reading
    /// something asks for `.exists`, tapping it asks for `.isHittable` — an
    /// element half under the tab bar exists and still swallows the tap.
    ///
    /// `returningToTop` is for rows that ARRIVE late instead of merely sitting
    /// low: searching downward only would walk past the fold while the row
    /// lands above the current position. Those rounds scroll back before
    /// looking again.
    @discardableResult
    private func waitScrollingTo(_ app: XCUIApplication, element: XCUIElement,
                                 hittable: Bool = false, swipes: Int = 8,
                                 returningToTop: Bool = false) -> Bool {
        let reached = { hittable ? element.isHittable : element.exists }
        if element.waitForExistence(timeout: 15), reached() { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if element.waitForExistence(timeout: returningToTop ? 5 : 2), reached() { return true }
            if returningToTop { app.swipeDown(); app.swipeDown() }
        }
        return false
    }

    private func waitScrollingTo(_ app: XCUIApplication, text: String,
                                 swipes: Int = 8) -> Bool {
        waitScrollingTo(app, element: app.staticTexts[text].firstMatch, swipes: swipes)
    }

    /// ONE query on the search PAGE finds the seeded book, episode and
    /// album, the "New Shows" catalog sits behind the explicit row (seeded
    /// directory — no real catalog request leaves the harness), the scope
    /// bar narrows single-select, and the X button clears then closes
    /// (with the recents chip on the deck in between).
    func testGlobalSearchFindsAllTypes() {
        let app = launchSeeded()
        let search = app.buttons["global-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        // The standing scope bar tops the page; Home opens at "Library".
        XCTAssertTrue(app.buttons["scope-library"].firstMatch.waitForExistence(timeout: 10),
                      "the scope bar must stand on the search page")
        // The field sits in the bottom bar.
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
        XCTAssertTrue(waitScrollingTo(app, element: album), "search must find the seeded album")
        snap(app, "global-search-library")
        // The catalog sits behind the explicit catalog row — scroll it
        // into reach (keyboard already dismissed above); on the full page it
        // trails ALL own sections.
        let catalogRow = app.buttons["search-catalog-row"].firstMatch
        XCTAssertTrue(waitScrollingTo(app, element: catalogRow, hittable: true),
                      "catalog row must close the library results")
        catalogRow.tap()
        XCTAssertTrue(app.staticTexts["Seed Catalog Show"].firstMatch.waitForExistence(timeout: 10),
                      "the catalog view must show the seeded catalog show")
        snap(app, "global-search-catalog")
        // Single-select — the music scope narrows to the album hit.
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
        // First X clears the query → the browse deck appears with the
        // just-run query as a recents chip.
        let close = app.buttons["search-close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the round X must sit next to the field")
        close.tap()
        let recentChip = app.buttons["Seed"].firstMatch
        XCTAssertTrue(recentChip.waitForExistence(timeout: 5),
                      "the deck must offer the recent search")
        snap(app, "global-search-deck")
        // A drill swaps the same stack as the catalog does, and on iOS 27
        // that swap once left a white page. The seeded library's author
        // drill must draw its list, and the back chip must bring the deck
        // back. (The music deck's artists come from a server the harness
        // does not have, so that drill would be empty by its data.)
        app.buttons["scope-library"].firstMatch.tap()
        let authorsTile = app.buttons["deck-tier-authors"].firstMatch
        XCTAssertTrue(waitScrollingTo(app, element: authorsTile, hittable: true),
                      "the library deck must offer its authors")
        authorsTile.tap()
        XCTAssertTrue(app.staticTexts["Ada Author"].firstMatch.waitForExistence(timeout: 10),
                      "the author drill must draw its list, never a white page")
        snap(app, "global-search-drill")
        app.buttons["search-drill-back"].firstMatch.tap()
        XCTAssertTrue(recentChip.waitForExistence(timeout: 5), "the back chip must bring the deck back")
        // Back to the music scope, where the steps below expect the page.
        app.buttons["scope-music"].firstMatch.tap()
        // The artist drill asks a music server the harness does not have.
        // It must say so in one sentence, never stand as an empty page.
        let artistsTile = app.buttons["deck-tier-artists"].firstMatch
        XCTAssertTrue(waitScrollingTo(app, element: artistsTile, hittable: true),
                      "the music deck must offer its artists")
        artistsTile.tap()
        XCTAssertTrue(app.staticTexts["search-drill-sentence"].firstMatch.waitForExistence(timeout: 10),
                      "an artist drill without answer must say so, not stand empty")
        snap(app, "global-search-artists-said")
        // Without a server the question failed, so the page offers to ask
        // again; asking again says the same sentence, never an empty page.
        let retry = app.buttons["search-drill-retry"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "a failed drill must offer to try again")
        retry.tap()
        XCTAssertTrue(app.staticTexts["search-drill-sentence"].firstMatch.waitForExistence(timeout: 10),
                      "the retried drill must say its answer again")
        app.buttons["search-drill-back"].firstMatch.tap()
        XCTAssertTrue(recentChip.waitForExistence(timeout: 5), "the back chip must bring the deck back")
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

    /// The serverless path — the setup offers the equal "start without a
    /// server" button; tapping it lands in the app (settings reachable, no
    /// audiobooks tab without a book source).
    func testServerlessOnboarding() {
        // No seeded start here — this journey MEANS the setup gate.
        let app = launch(["-uitest-setup"])
        // The first screen is the MAP: every area with one line about what it
        // needs, and three of five need nothing.
        let audiobooks = app.buttons["source-map-audiobooks"].firstMatch
        XCTAssertTrue(audiobooks.waitForExistence(timeout: 15), "the setup must show the map of areas")
        for area in ["music", "podcasts", "radio", "freeCatalogs"] {
            XCTAssertTrue(app.buttons["source-map-\(area)"].firstMatch.exists,
                          "area \(area) must be on the map")
        }
        // The equal choice is on the first screen as it opens: no scrolling
        // here, because a button below the fold is a finding at the screen.
        let start = app.buttons["start-serverless"].firstMatch
        XCTAssertTrue(start.exists && start.isHittable,
                      "the serverless path must be visible on the first screen without scrolling")
        // An area without a server says what it would need, and leads there.
        audiobooks.tap()
        XCTAssertTrue(app.buttons["settings-abs-source"].firstMatch.waitForExistence(timeout: 10),
                      "the audiobook area must lead to the Audiobookshelf setup")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // The map's row for the sync service stands there too. It sits below
        // the fold, so this scrolls, after the no-scrolling check above.
        XCTAssertTrue(waitScrollingTo(app, element: app.buttons["source-map-sync"].firstMatch),
                      "the map must carry the Mär Sync row")

        XCTAssertTrue(start.waitForExistence(timeout: 15), "setup must offer the serverless path")
        start.tap()
        XCTAssertTrue(app.buttons["open-settings"].firstMatch.waitForExistence(timeout: 15),
                      "serverless start must land in the app")
        // FLIPPED assurance: serverless, EVERY tab opens and
        // shows its free core — a missing server hides sections, never tabs.
        XCTAssertTrue(app.buttons["tab-audiobooks"].firstMatch.waitForExistence(timeout: 10),
                      "serverless, the audiobooks tab must exist and carry the free area")
        app.terminate()
    }

    /// FLIPPED assurance: the SOURCE toggle no longer touches the
    /// tab bar — a tab is the user's master decision, a source only fills or
    /// empties its section. The MASTER toggle (settings → Libraries) is what
    /// removes and restores the tab, live.
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
            // Anchor on the CURRENT navigation bar, not on index 0 of
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

        func setMasterToggle() {
            let gear = app.buttons["open-settings"].firstMatch
            XCTAssertTrue(gear.waitForExistence(timeout: 10))
            gear.tap()
            let toggle = app.switches["tab-master-music"].firstMatch
            XCTAssertTrue(waitScrollingTo(app, element: toggle, hittable: true))
            let before = toggle.value as? String
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let flipped = NSPredicate(format: "value != %@", before ?? "")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: flipped, object: toggle)],
                                          timeout: 5), .completed, "the master toggle must flip")
            let done = app.buttons["settings-done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
        }

        setMusicToggle()   // SOURCE off
        XCTAssertTrue(music.waitForExistence(timeout: 10),
                      "the source toggle must NOT remove the tab — sections empty, tabs stay")
        setMusicToggle()   // source on again
        setMasterToggle()  // MASTER off
        XCTAssertTrue(music.waitForNonExistence(timeout: 10),
                      "the master toggle removes the tab live")
        setMasterToggle()  // master on again
        XCTAssertTrue(music.waitForExistence(timeout: 10),
                      "the master toggle restores the tab live")
    }

    /// The presentation host. A sheet cannot be presented from the root while
    /// another sheet is already up — so the queue, which LIVES in a sheet,
    /// carries its own host and the request is stamped with it. Without that
    /// the create form would never appear here, and nothing in the compiler
    /// would say so.
    func testQueueSheetPresentsTheCreateDialogOverItself() {
        let app = launchSeeded(withActivePlayer: true)
        // The bar's STABLE handle; its label is the running title.
        let miniPlayer = app.buttons["mini-player"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 20))
        miniPlayer.press(forDuration: 1.6)
        let menuEntry = app.buttons["mini-queue-entry"].firstMatch
        XCTAssertTrue(menuEntry.waitForExistence(timeout: 10))
        menuEntry.tap()
        XCTAssertTrue(app.descendants(matching: .any)["play-queue-list"].firstMatch
                        .waitForExistence(timeout: 10),
                      "queue sheet must open from the mini player")

        let save = app.buttons["queue-save-as-playlist"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10),
                      "the queue must offer saving itself as a playlist")
        save.tap()
        XCTAssertTrue(app.textFields["new-playlist-name"].firstMatch.waitForExistence(timeout: 10),
                      "the create dialog must present from INSIDE the queue sheet")
        snap(app, "playlist-dialog-over-sheet")
        app.terminate()
    }

    // The large title must survive BOTH known killer
    // cycles — search open/close and fast tab switches while scrolled (the
    // dynamic ternary title on the live bar used to drop it, leaving its
    // reserved gap; pinned by navigationBarTitleDisplayMode(.large)).
    func testLargeTitleSurvivesCycles() {
        let app = launchSeeded()
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
        // Guarded by the tick-decoupled bar title in LibraryView
        // (FB18304716 family damping) — the title transition no longer lands
        // inside the bar's tab transition.
        XCTAssertTrue(recovered, "title PERMANENTLY gone after tab cycle (the device bug)")
    }


    /// Letzter-Tab (01.08): the app restarts on the last selected tab (master
    /// toggle permitting) — the "always lands on Home again" complaint.
    func testAppRestartsOnLastSelectedTab() {
        var app = launchSeeded(extra: ["-uitest-keeptab"])
        let podcasts = app.buttons["tab-podcasts"].firstMatch
        XCTAssertTrue(podcasts.waitForExistence(timeout: 15))
        podcasts.tap()
        XCTAssertTrue(app.navigationBars["Podcasts"].firstMatch.waitForExistence(timeout: 15))
        app.terminate()
        app = launchSeeded(extra: ["-uitest-keeptab"])
        // The marker is the podcast NAVIGATION BAR, not the "Seed
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

    /// The full player's title line navigates to the source page —
    /// player minimizes (keeps playing, mini bar visible), detail is pushed.
    func testPlayerNavigatesToSource() {
        let app = launchSeeded(withActivePlayer: true)
        // The bar's STABLE handle; its label is the running title.
        let mini = app.buttons["mini-player"].firstMatch
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

    /// A foreign import shows its preview BEFORE anything is written, and
    /// its result names what no episode claimed. The harness hands the read
    /// library in (no file picker); the fixture carries no feeds, so Apply
    /// touches no network and only the state adopter runs.
    func testForeignImportPreviewThenResultNamesUnmatched() {
        let app = launchSeeded(extra: ["-uitest-foreign-import"])
        app.buttons["open-settings"].firstMatch.tap()
        let podcastArea = app.buttons["source-map-podcasts"].firstMatch
        XCTAssertTrue(waitScrollingTo(app, element: podcastArea, hittable: true)); podcastArea.tap()
        let source = app.buttons["settings-podcast-source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10)); source.tap()
        let apply = app.buttons["foreign-import-apply"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 15), "the preview must open with the seeded library")
        XCTAssertTrue(app.descendants(matching: .any)["foreign-import-preview"].firstMatch.exists,
                      "before Apply the sheet shows the preview, not a result")
        snap(app, "foreign-import-preview")
        apply.tap()
        let applied = app.descendants(matching: .any)["foreign-import-applied"].firstMatch
        XCTAssertTrue(applied.waitForExistence(timeout: 15), "after Apply the sheet shows the result")
        XCTAssertEqual(applied.value as? String, "1", "the seeded episode's state must land")
        XCTAssertTrue(app.staticTexts["Nowhere Episode"].firstMatch.waitForExistence(timeout: 5),
                      "the unmatched state must be named, not only counted")
        snap(app, "foreign-import-result")
        app.terminate()
    }
}
