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

    private func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest"]
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

    /// T3/T5 proof: the global Up-Next queue renders ALL media types together —
    /// a book, a music album and a podcast episode in one list. Before the fix
    /// the book + album were dropped (resolver only knew podcasts).
    func testMixedQueueRendersAllTypes() {
        let app = launchSeeded()
        // The seeded mixed queue surfaces in the podcast tab's "Up Next" section.
        let podcasts = app.buttons["Podcasts"].firstMatch
        if podcasts.waitForExistence(timeout: 15) { podcasts.tap() }

        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 15),
                      "queued audiobook must render (T3/T5)")
        XCTAssertTrue(app.staticTexts["Seed Album"].firstMatch.exists,
                      "queued music album must render (T3/T5)")
        XCTAssertTrue(app.staticTexts["Seed Episode One"].firstMatch.exists,
                      "queued podcast episode must render")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "mixed-queue-all-types"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Tab/bar behaviour: switching between the audiobook and podcast tabs swaps
    /// the content (and exercises the shared bottom bar's active-gate).
    func testTabSwitching() {
        let app = launchSeeded()
        // Audiobook tab shows the seeded books.
        XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 15))

        let podcasts = app.buttons["Podcasts"].firstMatch
        XCTAssertTrue(podcasts.waitForExistence(timeout: 10))
        podcasts.tap()
        // Podcast tab shows the seeded show.
        XCTAssertTrue(app.staticTexts["Seed Show"].waitForExistence(timeout: 15)
                      || app.staticTexts["Seed Episode One"].firstMatch.waitForExistence(timeout: 5))

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "podcast-tab"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
