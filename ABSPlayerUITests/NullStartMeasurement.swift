// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import XCTest

/// c59e96e / ac97fb6 — the MEASUREMENT for the null start, not a regression
/// test. It runs against a stand-in server in the scratchpad (see
/// `tools/nullstart-measurement/`), never against a real account: after a null
/// start `lastSyncedTime` is 0 and the 5-second sync threshold fires within
/// seconds, so the app may push a 0. Measuring that on real data would destroy
/// what it measures.
///
/// The run is SPLIT deliberately. `testA…` produces the state once (sign in,
/// download, listen, sync); the `testB…` cases only open the book. The
/// simulator is NOT erased in between, so the state survives — that is what
/// lets the harness restart the stand-in in a different mode between cases and
/// still measure the same downloaded book.
///
/// The primary instrument is not this test's assertions but the stand-in's
/// write log: where the book STARTS answers the reviewer's question, what the app
/// PUSHES answers the one behind it (display nuisance vs. data loss).
/// `nonisolated` for the same reason as the journeys: XCTestCase's
/// lifecycle is nonisolated while the target defaults to MainActor.
nonisolated final class NullStartMeasurement: XCTestCase {

    private var serverURL: String {
        ProcessInfo.processInfo.environment["MOCK_URL"] ?? "https://127.0.0.1:8770"
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extra
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "app did not come up")
        return app
    }

    /// A measurement that fails must say WHAT it saw — otherwise the next run
    /// is a guess. Attaches the element tree, which is the only honest answer
    /// to "why was the control not there".
    private func dumpTree(_ app: XCUIApplication, _ name: String) {
        let text = XCTAttachment(string: app.debugDescription)
        text.name = name
        text.lifetime = .keepAlways
        add(text)
    }

    /// Types into a field that may already hold something. The setup screen
    /// remembers known servers, so an empty field is not a given — appending
    /// to a leftover value is how the address ended up doubled.
    private func fill(_ field: XCUIElement, with text: String) {
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty,
           existing != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                  count: existing.count))
        }
        field.typeText(text)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Scroll helper — same reason as in the journeys: below the fold does not
    /// exist in a lazy container.
    @discardableResult
    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement,
                          swipes: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 10) { return true }
        for _ in 0..<swipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    // MARK: - A: produce the state (runs once, against mode `ok`)

    func testAProduceDownloadedStateAndListen() {
        let app = launch(["-uitest-setup"])
        signIn(app)
        downloadAndListen(app)
    }

    private func signIn(_ app: XCUIApplication) {
        // The setup map: the audiobook area carries the ABS login.
        let area = app.buttons["source-map-audiobooks"].firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 20), "setup map must offer the audiobook area")
        area.tap()
        // One step further than the map: the area page carries the source
        // entry, and only that opens the login form.
        let source = app.buttons["settings-abs-source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 15),
                      "the audiobook area must lead to the Audiobookshelf setup")
        source.tap()

        let url = app.textFields["setup-url"].firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 15), "the login form must carry the server field")
        fill(url, with: serverURL)
        let user = app.textFields["setup-username"].firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 10))
        fill(user, with: "mock")
        let pass = app.secureTextFields["setup-password"].firstMatch
        XCTAssertTrue(pass.waitForExistence(timeout: 10))
        fill(pass, with: "mock")
        // Read back instead of trusting the typing: a field that kept an old
        // value (or swallowed the text) produced a doubled URL and an empty
        // password once, and the run then failed three screens later.
        XCTAssertEqual(url.value as? String, serverURL, "the server field did not take the address")
        snap(app, "measurement-login")

        let connect = app.buttons["abs-connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()

        // Deliberately via the AUDIOBOOKS TAB, not via the start page: there
        // the title also appears as a card, and tapping it PLAYS instead of
        // opening the page — the first run measured that the hard way.
        let booksTab = app.buttons["tab-audiobooks"].firstMatch
        XCTAssertTrue(booksTab.waitForExistence(timeout: 30),
                      "the library must come up after signing in")
        booksTab.tap()
        let book = app.staticTexts["Mock Buch"].firstMatch
        XCTAssertTrue(scrollTo(app, book, swipes: 10), "the stand-in's book must reach the library")
        snap(app, "measurement-library")
        book.tap()
    }

    private func downloadAndListen(_ app: XCUIApplication) {

        // Download it — this is the moment the cached detail is written, and
        // the whole finding hangs on WHAT it contains at this moment.
        let download = app.buttons["book-download-start"].firstMatch
        if !scrollTo(app, download, swipes: 6) {
            snap(app, "measurement-no-download-control")
            dumpTree(app, "tree-no-download-control")
            XCTFail("the book page must offer the download")
        }
        download.tap()
        // The simulator reports no Wi-Fi, so the cellular warning stands in the
        // way — it is a real dialog of the app, not test scaffolding, so the
        // measurement answers it instead of switching the warning off.
        let anyway = app.buttons["Download Anyway"].firstMatch
        if anyway.waitForExistence(timeout: 5) { anyway.tap() }
        let done = app.descendants(matching: .any)["book-download-done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 120), "the book must end up downloaded")
        snap(app, "measurement-downloaded")

        // Listen past the 5-second sync threshold so a real progress write
        // reaches the stand-in and the crash backup is deleted afterwards.
        let play = app.buttons["book-play"].firstMatch
        XCTAssertTrue(scrollTo(app, play, swipes: 6), "the book page must offer play")
        play.tap()
        // The sync timer ticks every 30 s — 20 s of listening left the crash
        // backup in place and nothing reached the stand-in, so the state was
        // not the one the measurement needs. 40 s guarantee one tick.
        Thread.sleep(forTimeInterval: 40)
        // Pause deliberately: it forces a sync, and THAT is the moment the
        // crash backup is deleted (:99). Without it the per-second writer
        // recreates the witness immediately and the state is not the one the
        // real incident had — a downloaded book with NO local witness left.
        let toggle = app.buttons["book-play-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10),
                      "the running book must offer pause on its page")
        toggle.tap()
        Thread.sleep(forTimeInterval: 5)
        snap(app, "measurement-listened")
    }

    /// The whole measurement in ONE case — because splitting it was the bug.
    /// Measured: every `test-without-building` run REINSTALLS the app and gets
    /// a fresh data container (container id changed between the runs), so the
    /// state case A produced never reached case B. That, not the 5-second
    /// throttle, is why the write log and the position stayed empty while the
    /// case still reported green. `terminate()` + `launch()` inside one case
    /// keeps the container.
    ///
    /// Reads the START position from the mini bar, which names it directly.
    func testCNullStartInOneRun() {
        let app = launch(["-uitest-setup"])
        signIn(app)
        downloadAndListen(app)
        // Second launch, same container: this is the moment of the incident.
        app.terminate()
        let again = launch()
        let book = again.staticTexts["Mock Buch"].firstMatch
        XCTAssertTrue(scrollTo(again, book, swipes: 10),
                      "the continue card must stand after the restart")
        book.tap()
        // the reviewer's hint, and it was the miss: after terminate() + launch() the
        // player is restored PAUSED. "The mini bar stands" and "it plays" are
        // two different statements — the 5-second ticker writes only while
        // playing. So press play through WHICHEVER handle the page offers:
        // the start button on an idle book, the toggle on the active one.
        let play = again.buttons["book-play"].firstMatch
        let toggle = again.buttons["book-play-toggle"].firstMatch
        if play.waitForExistence(timeout: 5) {
            play.tap()
        } else if toggle.waitForExistence(timeout: 10) {
            toggle.tap()
        }
        let mini = again.buttons["Mock Buch"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 25), "the player must come up")
        // The mini bar carries the position in its label ("ab 0:00:41 …").
        // Long enough for the 5-second local writer to record where we
        // actually are — that number IS the start position plus the time
        // played, and it is the only readable one.
        Thread.sleep(forTimeInterval: 15)
        let label = mini.label
        let shot = XCTAttachment(string: "START-LABEL: \(label)")
        shot.name = "start-position"
        shot.lifetime = .keepAlways
        add(shot)
        snap(again, "measurement-start-position")
    }

    // MARK: - B: open the downloaded book, whatever the stand-in does

    /// Opens the book that case A left downloaded and lets it run briefly. The
    /// verdict is NOT here — it is in the stand-in's write log and in the
    /// app container, both read by the harness. This case only has to reach
    /// the state without failing.
    func testBOpenDownloadedBook() {
        let app = launch()
        // Via the START page, not the library list: measured, the list comes
        // from the SERVER, so with the server down or slow the downloaded book
        // is not in it at all — the run then measures the list instead of the
        // start position. The continue card stands offline, and it is also the
        // way the real incident happened: open what you were listening to.
        let book = app.staticTexts["Mock Buch"].firstMatch
        XCTAssertTrue(scrollTo(app, book, swipes: 10),
                      "the continue card of the downloaded book must stand offline too")
        book.tap()
        // Two possible outcomes, depending on WHICH surface carried the title:
        // a continue card plays at once, a list row opens the page. Both are
        // fine — but the run must end up PLAYING, otherwise it measures
        // nothing at all. The first version of this case did exactly that:
        // empty write log, empty position, and it still reported rc=0.
        let play = app.buttons["book-play"].firstMatch
        if play.waitForExistence(timeout: 5) { play.tap() }
        let mini = app.buttons["Mock Buch"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 25),
                      "playback must actually start — without it the case measures nothing")
        // Long enough for the reconcile window (1.5 s) AND one tick of the
        // 30-second sync timer — otherwise the run cannot tell "started
        // wrong" from "started wrong and told the server so".
        Thread.sleep(forTimeInterval: 40)
        snap(app, "measurement-opened")
    }
}
