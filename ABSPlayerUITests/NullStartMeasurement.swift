// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import XCTest

/// c59e96e / ac97fb6 — the MEASUREMENT for the null start, not a regression
/// test. It runs against a stand-in server in the scratchpad (see
/// `tools/nullstart-messung/`), never against a real account: after a null
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

    /// These cases are a MEASUREMENT, not a regression test: they need the
    /// stand-in server from `tools/nullstart-messung/`. Without it there is
    /// nothing to sign in to, and a plain suite run would report three reds
    /// forever — a missing precondition is "not applicable", never "broken".
    /// Probed instead of declared, because a flag would have to be threaded
    /// through xcodebuild and would then lie whenever the stand-in died.
    private func skipWithoutStandIn() throws {
        try XCTSkipUnless(standInAnswers(),
                          "the stand-in server is not running — start it via tools/nullstart-messung/")
    }

    /// A TCP connect is enough and needs no trust store: the stand-in speaks
    /// TLS with its own CA, which only the SIMULATOR trusts, so an HTTP probe
    /// from this process would fail even with the server up.
    private func standInAnswers() -> Bool {
        guard let components = URLComponents(string: serverURL),
              let host = components.host else { return false }
        let port = UInt16(components.port ?? 443)
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        var limit = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &limit,
                   socklen_t(MemoryLayout<timeval>.size))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
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

    func testAProduceDownloadedStateAndListen() throws {
        try skipWithoutStandIn()
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
    func testCNullStartInOneRun() throws {
        try skipWithoutStandIn()
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

    // MARK: - Flugmodus-Matrix

    /// How many audio requests the stand-in has served — the precondition
    /// instrument: playback either happened or it did not.
    private func standInAudioHits() -> Int {
        guard let url = URL(string: "\(serverURL)/__writes") else { return 0 }
        var hits = 0
        let done = expectation(description: "audio hits")
        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json["audio_hits"] as? Int { hits = value }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 15)
        return hits
    }

    /// Tells the stand-in to go dark. Everything has to happen INSIDE one
    /// case: `test-without-building` reinstalls the app per case and hands it
    /// a fresh container, so a leg cannot inherit the state a previous case
    /// produced. The switch is the stand-in's own endpoint.
    private func standIn(mode: String) {
        guard let url = URL(string: "\(serverURL)/__mode?set=\(mode)") else { return }
        let done = expectation(description: "stand-in mode \(mode)")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 15)
    }

    /// Row 2 of the airplane-mode matrix: the RSS podcast class. Structurally
    /// different from the book leg — its stand travels over iCloud, not over
    /// the ABS server, and for a podcast the FEED is the server, so an
    /// unreachable feed IS the offline case.
    ///
    /// The question is only this: after a restart with the feed unreachable,
    /// does the episode continue where it stood, or at zero?
    func testMatrixRSSPodcastResumesOffline() throws {
        try skipWithoutStandIn()
        standIn(mode: "ok")
        // Deliberately the REAL path, not the seed: `_seedForUITest` REPLACES
        // the subscription store on every launch, so a feed added under
        // `-uitest` would be gone after the restart — and the restart is the
        // whole measurement. Serverless is also how a podcast-only user
        // actually starts.
        let app = launch()
        let serverless = app.buttons["start-serverless"].firstMatch
        if serverless.waitForExistence(timeout: 20) { serverless.tap() }

        // Subscribe through the NORMAL way in — an arbitrary feed URL. No test
        // seam in production code (which is why this leg exists and the
        // catalogue leg does not: archive.org's host is fixed).
        // Via the settings source map — the ONE route that exists regardless of
        // state. The tab's own "Add Podcasts" entry appears only in the EMPTY
        // state, and with recommendations loading there is no empty state; the
        // first attempt walked straight past it.
        let settings = app.buttons["open-settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 25),
                      "die Einstellungen muessen erreichbar sein")
        settings.tap()
        let area = app.buttons["source-map-podcasts"].firstMatch
        XCTAssertTrue(scrollTo(app, area, swipes: 8),
                      "die Quellen-Karte muss den Podcast-Bereich tragen")
        area.tap()
        let sourcePage = app.buttons["settings-podcast-source"].firstMatch
        XCTAssertTrue(scrollTo(app, sourcePage, swipes: 8),
                      "der Bereich muss zu den Podcast-Quellen fuehren")
        sourcePage.tap()
        // The field lives in a COLLAPSED disclosure group — it does not exist
        // in the tree until the group is opened.
        // By IDENTIFIER, not by label: the simulator runs in German, and a
        // journey that searches an English word measures the locale.
        let disclosure = app.descendants(matching: .any)["podcast-add-by-url"].firstMatch
        XCTAssertTrue(scrollTo(app, disclosure, swipes: 10),
                      "die Quellenseite muss den Aufklapp-Eintrag tragen")
        disclosure.tap()
        let field = app.textFields["feed-url"].firstMatch
        XCTAssertTrue(scrollTo(app, field, swipes: 6), "die Quellenseite muss das Feed-Feld tragen")
        fill(field, with: "\(serverURL)/feed.xml")
        let addFeed = app.buttons["podcast-add-feed"].firstMatch
        XCTAssertTrue(addFeed.waitForExistence(timeout: 10))
        addFeed.tap()

        // The subscription lands in the podcast TAB, not in the settings sheet
        // it was added from — leave the sheet and go there.
        Thread.sleep(forTimeInterval: 4)
        snap(app, "matrix-rss-added")
        // Out of the settings sheet: back out of the pushed pages first, then
        // close. A swipe alone does nothing on a scrolled list, and the source
        // view's subscription row is not a link — measured both.
        for _ in 0..<3 {
            let done = app.buttons["settings-done"].firstMatch
            if done.exists, done.isHittable { done.tap(); break }
            // The TOPMOST navigation bar is the pushed page; its first button
            // is the back chevron. Unconditional — a guard on `isHittable`
            // broke out of the loop before the first tap.
            let bars = app.navigationBars
            guard bars.count > 0 else { break }
            let back = bars.element(boundBy: bars.count - 1).buttons.element(boundBy: 0)
            if back.exists { back.tap() }
            Thread.sleep(forTimeInterval: 1.5)
        }
        let done = app.buttons["settings-done"].firstMatch
        if done.exists, done.isHittable { done.tap() }
        let podcasts = app.buttons["tab-podcasts"].firstMatch
        XCTAssertTrue(podcasts.waitForExistence(timeout: 20),
                      "die Tableiste muss nach dem Blatt wieder dastehen")
        podcasts.tap()
        let show = app.staticTexts["Mock Podcast"].firstMatch
        XCTAssertTrue(scrollTo(app, show, swipes: 12),
                      "die abonnierte Sendung des Ersatz-Feeds muss im Tab stehen")
        show.tap()
        let episode = app.staticTexts["Mock Folge"].firstMatch
        XCTAssertTrue(scrollTo(app, episode, swipes: 10),
                      "die Folge des Ersatz-Feeds muss ankommen")
        snap(app, "matrix-rss-subscribed")
        // DOWNLOAD first, then play. Measured: the stand-in serves the file
        // without range support, so a STREAM stalls — the app requested the
        // audio (the counter saw it) but never played, and the ticker never
        // ran. A downloaded episode is also the truer offline case, and it is
        // exactly what the book leg does.
        let download = app.buttons["episode-row-download"].firstMatch
        if download.waitForExistence(timeout: 10) {
            download.tap()
            let anyway = app.buttons["Download Anyway"].firstMatch
            if anyway.waitForExistence(timeout: 5) { anyway.tap() }
            Thread.sleep(forTimeInterval: 12)
        }
        let rowPlay = app.buttons["episode-row-play"].firstMatch
        XCTAssertTrue(rowPlay.waitForExistence(timeout: 10),
                      "die Folgenzeile muss ihren Abspiel-Knopf tragen")
        rowPlay.tap()
        Thread.sleep(forTimeInterval: 6)
        // The case ASSURES its precondition: without a single audio request the
        // ticker never ran and everything below would be a green nothing.
        XCTAssertGreaterThan(standInAudioHits(), 0,
                             "keine Ton-Anfrage — die Wiedergabe lief nicht, der Fall misst nichts")

        // MEASURED, after a green case that measured nothing: the row body
        // OPENS the episode page — playback sits on the row's own play button
        // at its trailing edge. The first draft tapped the row, saw no audio
        // request reach the stand-in, and still reported green.
        // Nothing about playback is asserted in the UI at all: every anchor
        // the mini bar offers is a LOCALIZED label, and a case that searches
        // an English word measures the locale. The harness reads the container
        // afterwards, which is also the instrument the book leg used.
        Thread.sleep(forTimeInterval: 16)
        snap(app, "matrix-rss-before-restart")

        // Now the world goes away, and only then the restart.
        standIn(mode: "down")
        app.terminate()
        let again = launch()

        // Back the same way a user would: tab → show → the row's play button.
        let podcastsAgain = again.buttons["tab-podcasts"].firstMatch
        XCTAssertTrue(podcastsAgain.waitForExistence(timeout: 25))
        podcastsAgain.tap()
        let showAgain = again.staticTexts["Mock Podcast"].firstMatch
        XCTAssertTrue(scrollTo(again, showAgain, swipes: 12),
                      "die abonnierte Sendung muss OHNE Feed noch dastehen")
        showAgain.tap()
        let row = again.staticTexts["Mock Folge"].firstMatch
        XCTAssertTrue(scrollTo(again, row, swipes: 12),
                      "die abonnierte Folge muss OHNE Feed noch dastehen")
        let rowPlayAgain = again.buttons["episode-row-play"].firstMatch
        XCTAssertTrue(scrollTo(again, rowPlayAgain, swipes: 8),
                      "die Folgenzeile muss ihren Abspiel-Knopf auch offline tragen")
        rowPlayAgain.tap()
        // Long enough for the 5-second writer to record where we ACTUALLY are.
        // THAT number is the verdict: a null start reads as ~10, a correct
        // resume as ~26.
        Thread.sleep(forTimeInterval: 11)
        snap(again, "matrix-rss-after-restart")
        again.terminate()
    }

    /// The acceptance of the serverless-library finding: a sideloaded file
    /// must reach the library WITHOUT any Audiobookshelf login, and listening
    /// to it must leave a local stand.
    ///
    /// It used to reach nothing: the collector for every secondary audiobook
    /// source sat behind the server guard, so a start without a login gathered
    /// none of them. In the same session after an import everything looked
    /// right — only the next launch showed the empty library.
    ///
    /// The harness plants the item (index JSON + audio in the container);
    /// importing through the document picker is not reachable from a journey
    /// and is not what this case measures. The PRECONDITION is probed, never
    /// declared — an environment flag does not reach the test runner through
    /// xcodebuild, measured twice now.
    func testSideloadReachesLibraryWithoutServer() throws {
        let app = launch()
        let serverless = app.buttons["start-serverless"].firstMatch
        if serverless.waitForExistence(timeout: 20) { serverless.tap() }

        let books = app.buttons["tab-audiobooks"].firstMatch
        XCTAssertTrue(books.waitForExistence(timeout: 25), "der Buecher-Tab muss dastehen")
        books.tap()
        let title = app.staticTexts["Mock Sideload"].firstMatch
        try XCTSkipUnless(scrollTo(app, title, swipes: 12),
                          "the harness has not planted a sideloaded item")
        snap(app, "sideload-in-library")
        title.tap()

        let play = app.buttons["book-play"].firstMatch
        let toggle = app.buttons["book-play-toggle"].firstMatch
        if play.waitForExistence(timeout: 10) { play.tap() }
        else if toggle.waitForExistence(timeout: 10) { toggle.tap() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 25),
                      "ohne laufende Wiedergabe misst der Fall nichts")
        // Past the 5-second writer, twice over. The harness reads the stand
        // from the container — that number is the proof that the local class
        // keeps its own truth.
        Thread.sleep(forTimeInterval: 14)
        snap(app, "sideload-played")
        app.terminate()
    }

    // MARK: - B: open the downloaded book, whatever the stand-in does

    /// Opens the book that case A left downloaded and lets it run briefly. The
    /// verdict is NOT here — it is in the stand-in's write log and in the
    /// app container, both read by the harness. This case only has to reach
    /// the state without failing.
    func testBOpenDownloadedBook() throws {
        try skipWithoutStandIn()
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
