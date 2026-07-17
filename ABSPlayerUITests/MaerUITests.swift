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
