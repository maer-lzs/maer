import XCTest

/// Permanent UI-test harness (Stage 2). Read-only journeys only — never mutate a
/// live server (mirrors the audit harness discipline). Data-dependent journeys
/// (mixed queue, tab/bar) need a DEBUG launch-arg seeding hook; this smoke test
/// verifies the harness target itself builds, launches the app and runs.
///
/// `nonisolated`: the target inherits SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
/// from the app, but XCTestCase's lifecycle (init/setUp) is nonisolated — opt out.
nonisolated final class MaerUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAppLaunches() {
        let app = XCUIApplication()
        app.launch()
        // On a clean simulator the app opens on its login/setup gate; on a seeded
        // one, the library. Either way the process must come up and render.
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        XCTAssertGreaterThan(app.windows.count, 0)
    }
}
