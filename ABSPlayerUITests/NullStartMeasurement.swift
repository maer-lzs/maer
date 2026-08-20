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

        // Second half: the restart. The local class has no server at all, so
        // "offline" is not a state it can be put into — the only question is
        // whether the stand carries a restart.
        app.terminate()
        let again = launch()
        let booksAgain = again.buttons["tab-audiobooks"].firstMatch
        XCTAssertTrue(booksAgain.waitForExistence(timeout: 25))
        booksAgain.tap()
        let titleAgain = again.staticTexts["Mock Sideload"].firstMatch
        XCTAssertTrue(scrollTo(again, titleAgain, swipes: 12),
                      "das eingelegte Buch muss nach dem Neustart noch dastehen")
        // MEASURED: after the restart the title stands as a CONTINUE CARD, and
        // a continue card PLAYS on tap (the house tap convention) — no book
        // page opens, so there is no play handle to press. My first version
        // waited for one and read the app's correct behaviour as a defect.
        //
        // The card itself already carries the answer in its label ("4 min
        // left", 3 %): the local stand survived. The number below is the
        // harder proof.
        // The card CARRIES the verdict, and that is the better witness: its
        // value is the progress the app resolved for this item after the
        // restart. A lost stand reads as 0 % — or as no continue card at all.
        //
        // Deliberately NOT "play again and see whether the number grows": the
        // previous version did that, the second playback silently did not
        // start, the stand stayed where it was, and the case reported green.
        // Third time in one night that a measurement nearly passed without
        // measuring; a witness that needs no second action cannot fail that way.
        // The title appears on several elements (mini bar, player, card) and
        // only the CARD carries a progress value — so the value is what picks
        // it, not the label alone.
        let candidates = again.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Mock Sideload"))
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 20),
                      "das eingelegte Buch muss nach dem Neustart sichtbar sein")
        let card = candidates.allElementsBoundByIndex.first {
            ((($0.value as? String) ?? "").contains("%"))
        }
        XCTAssertNotNil(card, "keine Fortsetzen-Karte mit Fortschritt gefunden")
        let progress = ((card?.value as? String) ?? "")
        let stamp = XCTAttachment(string: "KARTE NACH NEUSTART: \(card?.label ?? "—") — \(progress)")
        stamp.name = "sideload-resume"
        stamp.lifetime = .keepAlways
        add(stamp)
        let digits = progress.filter(\.isNumber)
        XCTAssertFalse(digits.isEmpty, "die Karte nennt keinen Fortschritt: \(progress)")
        XCTAssertNotEqual(Int(digits), 0,
                          "der lokale Stand ging beim Neustart verloren (\(progress))")
        snap(again, "sideload-after-restart")
        again.terminate()
    }

    /// What a FRESH install actually finds in the radio tab — the open question
    /// behind "do the rows stay empty until something kicks the country
    /// cascade". Nothing is chosen, nothing is stored: the country can only
    /// come from the device locale.
    ///
    /// Two statements, both read where they stand: the region section must
    /// offer its way IN (its station list is legitimately empty without a
    /// chosen region, but an entry point that only appears after the choice
    /// would be a door behind itself), and the national row's stations must
    /// have arrived — read from the persisted discovery cache, because the row
    /// heading is a localized string and the simulator runs German.
    func testFreshRadioTabFillsFromTheLocale() throws {
        let app = launch()
        let serverless = app.buttons["start-serverless"].firstMatch
        if serverless.waitForExistence(timeout: 20) { serverless.tap() }

        let radioTab = app.buttons["tab-radio"].firstMatch
        XCTAssertTrue(radioTab.waitForExistence(timeout: 25), "der Radio-Tab muss dastehen")
        radioTab.tap()

        let started = Date()
        let picker = app.buttons["radio-region-picker"].firstMatch
        let found = picker.waitForExistence(timeout: 60) || scrollTo(app, picker, swipes: 10)
        let regionAfter = Date().timeIntervalSince(started)
        XCTAssertTrue(found,
                      "ohne gewaehlte Region muss die Regions-Reihe ihren Einstieg zeigen")

        // "Land aendern" hängt UNTER der Beliebt-Reihe und existiert nur mit
        // ihr — ein Zeuge, der schon dasteht, statt eines neuen Griffs.
        let countryLink = app.buttons["radio-country-change-inline"].firstMatch
        let popularUp = countryLink.waitForExistence(timeout: 120)
        let popularAfter = Date().timeIntervalSince(started)
        snap(app, "fresh-radio-tab")
        let report = XCTAttachment(string: """
            Regions-Einstieg nach \(String(format: "%.1f", regionAfter)) s
            Beliebt-Reihe \(popularUp ? "nach \(String(format: "%.1f", popularAfter)) s" : "NICHT innerhalb von 120 s")
            """)
        report.name = "radio-kaskade-zeiten"
        report.lifetime = .keepAlways
        add(report)
        XCTAssertTrue(popularUp,
                      "die nationale Reihe muss aus dem Gebietsschema kommen, ohne dass jemand etwas waehlt")
        app.terminate()
    }

    /// The cover report: letters instead of logos until a station has been
    /// played once. Measured on the path that produces it — the SECOND start,
    /// where the rows paint from the persisted cache in frame 1.
    ///
    /// Both launches have to live in ONE case: the harness reinstalls the app
    /// per case, so a second case would start from an empty container and
    /// never reach the cached path at all.
    func testCoverRaceOnTheCachedPath() throws {
        let app = launch()
        let serverless = app.buttons["start-serverless"].firstMatch
        if serverless.waitForExistence(timeout: 20) { serverless.tap() }
        let radioTab = app.buttons["tab-radio"].firstMatch
        XCTAssertTrue(radioTab.waitForExistence(timeout: 25))
        radioTab.tap()
        // Wait until the rows really stand — only then is a cache persisted.
        XCTAssertTrue(app.buttons["radio-country-change-inline"].firstMatch
            .waitForExistence(timeout: 90), "ohne geladene Reihen gibt es keinen Zwischenspeicher")
        app.terminate()

        // Second start: the rows come from the cache, in frame one.
        let again = launch()
        let tabAgain = again.buttons["tab-radio"].firstMatch
        XCTAssertTrue(tabAgain.waitForExistence(timeout: 25))
        tabAgain.tap()
        _ = again.buttons["radio-country-change-inline"].firstMatch.waitForExistence(timeout: 60)
        snap(again, "cover-race-cached-path")
        again.terminate()
    }

    /// The layout contract of a tile row: EVERY tile the same height, whatever
    /// is playing. A tile that grows when its station starts pushes everything
    /// below it down — which is what a person sees as "pressing play shifts the
    /// layout".
    ///
    /// Measured against the running station, because that is the only tile that
    /// used to differ. Both the play and the measurement live in ONE case: the
    /// harness reinstalls per case, so a second one would start without a
    /// playing station and measure nothing.
    func testTileHeightsDoNotDependOnPlayback() throws {
        let app = launch()
        let serverless = app.buttons["start-serverless"].firstMatch
        if serverless.waitForExistence(timeout: 20) { serverless.tap() }
        let radioTab = app.buttons["tab-radio"].firstMatch
        XCTAssertTrue(radioTab.waitForExistence(timeout: 25))
        radioTab.tap()

        // A genre page carries station ROWS, whose play control is explicit.
        let genre = app.buttons["radio-genre-pop"].firstMatch
        XCTAssertTrue(genre.waitForExistence(timeout: 30) || scrollTo(app, genre, swipes: 10))
        genre.tap()
        let play = app.buttons["station-play"].firstMatch
        try XCTSkipUnless(play.waitForExistence(timeout: 90),
                          "das Verzeichnis hat keine Sender geliefert (Netz?)")
        // Remember WHICH station is played — the assertion below is about that
        // tile, and a list of numbers cannot say which one it is.
        let playedName = String(play.firstMatch.frame.height > 0
                                ? (app.staticTexts.allElementsBoundByIndex.first {
                                    $0.exists && $0.frame.minY >= play.frame.minY - 40
                                        && $0.frame.minY <= play.frame.maxY + 40
                                    && !$0.label.isEmpty }?.label ?? "")
                                : "")
        play.tap()
        try XCTSkipUnless(app.buttons["mini-player"].firstMatch.waitForExistence(timeout: 40),
                          "der Sender hat nicht zu spielen begonnen")

        // Back to the tab: "Most Played" now carries a tile for the running
        // station, next to dormant ones.
        app.navigationBars.buttons.firstMatch.tap()
        let tiles = app.buttons.matching(identifier: "radio-tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 30), "die Kachelreihen muessen stehen")
        // Let the running title arrive — it is what used to add the line.
        Thread.sleep(forTimeInterval: 12)

        var heights: [CGFloat] = []
        var lines: [String] = []
        for index in 0..<min(tiles.count, 12) {
            let tile = tiles.element(boundBy: index)
            guard tile.exists, tile.frame.height > 0 else { continue }
            let height = tile.frame.height.rounded()
            heights.append(height)
            // WHICH tile differs is the whole question — a bare list of numbers
            // says that something is off, not what.
            lines.append("\(height) · y=\(tile.frame.origin.y.rounded()) · \(tile.label.prefix(40))")
        }
        let report = XCTAttachment(string: "Kachel-Hoehen:\n" + lines.joined(separator: "\n")
                                   + "\n\nroh: \(heights)")
        report.name = "radio-tile-heights"
        report.lifetime = .keepAlways
        add(report)
        snap(app, "radio-tile-heights")

        try XCTSkipUnless(heights.count >= 2, "zu wenige Kacheln sichtbar zum Vergleichen")
        // The contract this case guards is NOT "all tiles are identical" — a
        // tile may legitimately differ for reasons of its own picture. It is:
        // the tile of the RUNNING station is the same height as the majority.
        // That is what the layout jump was about, and only that.
        let majority = heights.reduce(into: [CGFloat: Int]()) { $0[$1, default: 0] += 1 }
            .max { $0.value < $1.value }?.key
        let running = tiles.allElementsBoundByIndex.first {
            $0.exists && $0.label.contains(playedName)
        }
        if let running, let majority {
            XCTAssertEqual(running.frame.height.rounded(), majority,
                           "die Kachel der laufenden Station weicht ab: \(heights)")
        }
        app.terminate()
    }

    /// The acceptance the order names: play on a tile while watching the row —
    /// NOTHING below it moves.
    ///
    /// the owner's own wording is the better diagnosis: "we get new info at the
    /// moment we click." The running title arrives SECONDS after the tap, so
    /// the case measures across exactly that arrival: distance between the tile
    /// row and the surface below it, before the line lands and after.
    ///
    /// The distance, not the absolute position: the mini bar appears at the
    /// same moment and changes the scroll area's bottom — an absolute y would
    /// mix the two causes and blame the wrong one.
    ///
    /// And it refuses to pass quietly: if no running title ever arrives, this
    /// harness cannot observe the mechanism at all, and it SAYS so. A previous
    /// measurement of this row reported "no deviation" while it had no ICY line
    /// in hand — a green that meant nothing.
    func testNothingBelowTheRowMovesWhenTheTitleArrives() throws {
        let app = launch()
        let serverless = app.buttons["start-serverless"].firstMatch
        if serverless.waitForExistence(timeout: 20) { serverless.tap() }
        let radioTab = app.buttons["tab-radio"].firstMatch
        XCTAssertTrue(radioTab.waitForExistence(timeout: 25))
        radioTab.tap()

        let tiles = app.buttons.matching(identifier: "radio-tile")
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 60), "die Kachelreihen muessen stehen")
        let lines = app.staticTexts.matching(identifier: "radio-nowplaying-line")
        // The reference below the row: the "Change Country" link sits directly
        // under the popular row.
        let below = app.buttons["radio-country-change-inline"].firstMatch
        XCTAssertTrue(below.waitForExistence(timeout: 30), "die Bezugsflaeche unter der Reihe fehlt")

        /// Distance from the first tile's top edge to the surface below the row
        /// — grows exactly when the row grows, and is INDIFFERENT to the mini
        /// bar appearing, which moves the whole page instead.
        func spread() -> CGFloat? {
            let top = tiles.firstMatch
            guard top.exists, top.frame.height > 0, below.exists else { return nil }
            return (below.frame.minY - top.frame.minY).rounded()
        }

        let before = spread()
        // Start a station OF THIS ROW while watching it — a first attempt
        // played through the genre page and measured nothing, because the
        // station it started appeared in no tile at all. The row's own play
        // control is its context menu (a tile navigates, house convention).
        tiles.firstMatch.press(forDuration: 1.1)
        let menuPlay = app.buttons["radio-menu-play"].firstMatch
        try XCTSkipUnless(menuPlay.waitForExistence(timeout: 10), "das Kachel-Menue kam nicht")
        menuPlay.tap()
        try XCTSkipUnless(app.buttons["mini-player"].firstMatch.waitForExistence(timeout: 40),
                          "der Sender hat nicht zu spielen begonnen")
        // Wait for the CONTENT, not for a duration: the arrival is the event.
        var titleArrived = false
        for _ in 0..<30 {
            if lines.allElementsBoundByIndex.contains(where: {
                $0.exists && !$0.label.trimmingCharacters(in: .whitespaces).isEmpty
            }) { titleArrived = true; break }
            Thread.sleep(forTimeInterval: 1)
        }
        let after = spread()

        // A blind measurement must say WHY it is blind: no ICY title at all, or
        // a title the player has while no tile of that station is on screen.
        // Those are different findings and lead to different next steps.
        let mini = app.buttons["mini-player"].firstMatch
        let report = XCTAttachment(string: """
        Titel eingetroffen: \(titleArrived)
        Abstand vor dem Titel:  \(before.map(String.init(describing:)) ?? "—")
        Abstand nach dem Titel: \(after.map(String.init(describing:)) ?? "—")
        Mini-Leiste sagt: \(mini.exists ? mini.label : "—")
        Kacheln sichtbar: \(tiles.count) · Zeilen-Knoten: \(lines.count)
        Kachel-Beschriftungen: \(tiles.allElementsBoundByIndex.prefix(8).map { $0.label })
        """)
        report.name = "radio-row-spread"
        report.lifetime = .keepAlways
        add(report)
        snap(app, "radio-row-spread")

        // The fence that found the actual defect, and it must stay a FAILURE,
        // not a skip: if the mini bar carries a running title while every line
        // of the row stays empty, the mirror on the coordinator is broken again
        // and the tiles never hear the title arrive. A station that simply
        // sends no ICY is a different matter — that one skips.
        let miniCarriesATitle = mini.exists && !mini.label.isEmpty
            && !tiles.firstMatch.label.contains(mini.label)
        XCTAssertFalse(miniCarriesATitle && !titleArrived, """
            die Mini-Leiste trägt einen laufenden Titel ("\(mini.label)"), die Kachel-Zeilen \
            sind leer — die Kachel hört den Titel nicht eintreffen (Spiegel auf dem \
            Koordinator kaputt?)
            """)
        try XCTSkipUnless(titleArrived,
                          "dieser Sender hat keinen laufenden Titel gesendet — nichts zu messen")
        guard let before, let after else {
            throw XCTSkip("Kachelreihe oder Bezugsfläche nicht sichtbar")
        }
        XCTAssertEqual(before, after,
                       "die Reihe ist gewachsen, als der laufende Titel eintraf: \(before) → \(after)")
        app.terminate()
    }

    /// decb049 / 7fb1cc1: no title is squeezed on its own — and the proof run
    /// needs ALL FIVE areas, or it measures nothing.
    ///
    /// the owner measured the condition himself: with four tabs "Hörbücher" is
    /// normal, with five it is squeezed. A run with four tabs would therefore
    /// report green WITHOUT EVER REACHING the case — literally the cover-saga
    /// pattern (a tool that does not contain the broken step can only measure
    /// success). So the case counts the tabs and SKIPS rather than passing.
    func testAllTabTitlesShareOneSize() throws {
        let app = launch()
        let serverless = app.buttons["start-serverless"].firstMatch
        if serverless.waitForExistence(timeout: 20) { serverless.tap() }
        XCTAssertTrue(app.buttons["tab-radio"].firstMatch.waitForExistence(timeout: 25))

        // Every tab of the bar, whatever the areas are set to.
        let ids = ["tab-home", "tab-audiobooks", "tab-podcasts", "tab-music", "tab-radio"]
        let present = ids.compactMap { id -> (String, XCUIElement)? in
            let element = app.buttons[id].firstMatch
            return element.exists ? (id, element) : nil
        }
        var heights: [String: CGFloat] = [:]
        for (id, tab) in present {
            // The LABEL, not the button: the button is padded to a common size,
            // the label carries the font — and a squeezed font is a shorter
            // text box. That is the only handle a UI test has on "smaller".
            let label = tab.staticTexts.firstMatch
            guard label.exists, label.frame.height > 0 else { continue }
            heights[id] = (label.frame.height * 10).rounded() / 10
        }
        let report = XCTAttachment(string: """
        Tabs sichtbar: \(present.map(\.0))
        Label-Höhen:   \(heights)
        """)
        report.name = "tab-label-heights"
        report.lifetime = .keepAlways
        add(report)
        snap(app, "tab-label-heights")

        try XCTSkipUnless(present.count >= 5, """
            nur \(present.count) Bereiche aktiv — mit weniger als fünf tritt die             Bedingung gar nicht ein, und ein grüner Lauf hier bestätigte eine             Reparatur, die nie gemessen wurde
            """)
        try XCTSkipUnless(heights.count == present.count, "nicht jeder Reiter trug ein Label")
        let distinct = Set(heights.values)
        XCTAssertEqual(distinct.count, 1,
                       "die Reiter-Titel tragen verschiedene Größen: \(heights)")
        app.terminate()
    }

    /// 2c0a907 as its own case: the settings tab bar may change its line count
    /// with the WIDTH, never with the active tab — it sits at the very top, and
    /// a height that jumps on switching pushes the whole page.
    func testSettingsTabBarHeightIsStableAcrossTabs() throws {
        let app = launch()
        let serverless = app.buttons["start-serverless"].firstMatch
        if serverless.waitForExistence(timeout: 20) { serverless.tap() }
        guard app.buttons["open-settings"].firstMatch.waitForExistence(timeout: 25) else {
            throw XCTSkip("Einstellungen nicht erreichbar")
        }
        app.buttons["open-settings"].firstMatch.tap()

        let ids = ["general", "audiobooks", "podcasts", "music", "radio"]
        let chips = ids.compactMap { id -> XCUIElement? in
            let element = app.buttons["settings-tab-\(id)"].firstMatch
            return element.waitForExistence(timeout: 10) ? element : nil
        }
        try XCTSkipUnless(chips.count >= 2, "zu wenige Reiter sichtbar")

        /// Distance from the topmost chip's top edge to the LOWEST chip's
        /// bottom — the bar's height, however many lines it takes.
        func barHeight() -> CGFloat {
            let tops = chips.filter { $0.exists }.map { $0.frame.minY }
            let bottoms = chips.filter { $0.exists }.map { $0.frame.maxY }
            guard let top = tops.min(), let bottom = bottoms.max() else { return 0 }
            return ((bottom - top) * 10).rounded() / 10
        }

        var seen: [CGFloat] = []
        for chip in chips where chip.exists {
            chip.tap()
            seen.append(barHeight())
        }
        let report = XCTAttachment(string: "Leistenhöhe je aktivem Reiter: \(seen)")
        report.name = "settings-tabbar-heights"
        report.lifetime = .keepAlways
        add(report)
        XCTAssertEqual(Set(seen).count, 1,
                       "die Reiter-Leiste ändert ihre Höhe je nach aktivem Reiter: \(seen)")
        app.terminate()
    }

    /// Row 4 of the matrix — the class that is NOT like the others. A live
    /// stream has no end to be at, so its local state is deliberately NOT a
    /// position: the progress stock stays empty and the last-listened time
    /// lives in the radio store. Before this train the ticker was class-blind
    /// and wrote a GROWING number for an endless stream, one entry per
    /// station, forever.
    ///
    /// A CATALOGUE station on purpose: a manually added URL surfaces in no row
    /// of the radio tab (own finding, reported separately), and the radio
    /// statement does not depend on which station it is.
    ///
    /// The route runs over a GENRE page, and that is the measured part: in a
    /// fresh state the radio tab has no favorites, no recents and no most-played,
    /// so its only station surfaces are the browse CARDS — and a card navigates
    /// (house convention), it does not play. The explicit play control lives on
    /// the station ROW, which the genre page renders; its gate is the network
    /// alone, with no country cascade in front of it.
    ///
    /// Verdict and precondition are both read from the container by the
    /// harness: a radio MRU entry proves it played, and no
    /// `localPosition.radio:` key may exist. The in-app precondition is the
    /// mini player — it stands by itself once playback started, so it needs no
    /// second action that could silently fail.
    func testMatrixRadioKeepsNoPosition() throws {
        let app = launch()
        let serverless = app.buttons["start-serverless"].firstMatch
        if serverless.waitForExistence(timeout: 20) { serverless.tap() }

        let radioTab = app.buttons["tab-radio"].firstMatch
        XCTAssertTrue(radioTab.waitForExistence(timeout: 25), "der Radio-Tab muss dastehen")
        radioTab.tap()
        // "Pop" carries the widest station stock of the ten genres — the case
        // is about the radio CLASS, not about a particular genre.
        let genre = app.buttons["radio-genre-pop"].firstMatch
        XCTAssertTrue(genre.waitForExistence(timeout: 30) || scrollTo(app, genre, swipes: 10),
                      "die Genre-Kacheln haengen nur am Netz, nicht am Katalog")
        genre.tap()
        // The station list comes from the open directory over the network.
        let station = app.buttons["station-play"].firstMatch
        try XCTSkipUnless(station.waitForExistence(timeout: 90),
                          "das Radio-Verzeichnis hat keine Sender geliefert (Netz?)")
        snap(app, "matrix-radio-genre")
        station.tap()
        // A live stream that never started would leave the container empty and
        // the case would report a green "no position" without measuring one.
        let playing = app.buttons["mini-player"].firstMatch
        try XCTSkipUnless(playing.waitForExistence(timeout: 40),
                          "der Sender hat nicht zu spielen begonnen (Stream nicht erreichbar?)")
        Thread.sleep(forTimeInterval: 20)
        snap(app, "matrix-radio-played")
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
