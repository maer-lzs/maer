// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import XCTest
import UIKit
import Synchronization

/// The journeys against the test instances: a fresh app signs in to a real
/// server through its own forms, finds a title of the server's stock by the
/// search and plays it.
///
/// They run only when `scripts/journeys.sh` is started with
/// `MAER_JOURNEY_SERVERS=1`. The runner checks each server before the run and
/// hands over two things through the test runner's environment: what it
/// reached (`MAER_SERVER_REACH`, `name=ok` or `name=down`) and the path of a
/// file that only this user can read, holding the access values
/// (`MAER_SERVER_ACCESS`). A value never appears in the arguments, the log or
/// the result bundle: it travels through the pasteboard into the field and
/// the pasteboard is emptied right after.
///
/// A server that cannot be reached is its own outcome, a skip that says so,
/// never red for the code: before the run, and again when a sign-in fails,
/// the journey asks the server itself before it blames the app.
nonisolated final class ServerJourneys: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    override func tearDown() {
        UIPasteboard.general.items = []
    }

    // MARK: - Audiobooks against the demo server

    func testAudiobookServerSignInFindAndPlay() throws {
        let server = try instance("abs")
        let app = launchFresh()

        // A fresh app opens on the map of areas; the form lies behind the
        // audiobook area, on some sizes behind its source row.
        let area = app.buttons["source-map-audiobooks"].firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 30), "a fresh app must show the map of sources")
        area.tap()
        let url = app.textFields["setup-url"].firstMatch
        if !url.waitForExistence(timeout: 5) {
            let row = app.buttons["settings-abs-source"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "the audiobook area must lead to its server")
            row.tap()
        }
        XCTAssertTrue(url.waitForExistence(timeout: 10), "the audiobook server must offer its form")
        url.tap()
        url.typeText(server.url)
        if let token = server.values["token"] {
            app.buttons["API Token"].firstMatch.tap()
            try paste(token, into: app.secureTextFields["setup-token"].firstMatch, app)
        } else {
            try paste(try server.value("user"), into: app.textFields["setup-username"].firstMatch, app)
            try paste(try server.value("pass"), into: app.secureTextFields["setup-password"].firstMatch, app)
        }
        let connect = app.buttons["abs-connect"].firstMatch
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()

        let library = app.buttons["tab-audiobooks"].firstMatch
        let refused = app.staticTexts["setup-error"].firstMatch
        let signedIn = waitForEither(library, refused, timeout: 40)
        if signedIn !== library {
            try skipIfUnreachable(server)
            XCTFail("the sign-in did not reach the library: \(refused.exists ? refused.label : "no answer")")
        }
        declineSavingThePassword(app)

        try findAndPlay(app, title: "Treasure Island")
        app.terminate()
    }

    /// The demo server offers single sign-on: its button stands under the
    /// form, and a tap brings the system's question to sign in with Mär.
    /// The journey cancels there, so it never signs in at the provider and
    /// the server stays as it was; a cancelled question says nothing.
    func testAudiobookServerOffersSingleSignOnUpToTheSystemQuestion() throws {
        let server = try instance("abs")
        let app = launchFresh()

        let area = app.buttons["source-map-audiobooks"].firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 30), "a fresh app must show the map of sources")
        area.tap()
        let url = app.textFields["setup-url"].firstMatch
        if !url.waitForExistence(timeout: 5) {
            let row = app.buttons["settings-abs-source"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "the audiobook area must lead to its server")
            row.tap()
        }
        XCTAssertTrue(url.waitForExistence(timeout: 10), "the audiobook server must offer its form")
        url.tap()
        url.typeText(server.url + "\n")

        let signOn = app.buttons["abs-sso"].firstMatch
        if !signOn.waitForExistence(timeout: 30) {
            try skipIfUnreachable(server)
            XCTFail("the server offers single sign-on, the form shows no button for it")
        }
        signOn.tap()

        // The system asks before its sign-in window opens, naming the app.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cancel = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Abbrechen"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "the system did not ask to sign in")
        let question = springboard.alerts.firstMatch
        XCTAssertTrue(question.label.contains("Mär") || question.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Mär")).firstMatch.exists,
                      "the system's question does not name the app: \(question.label)")
        cancel.tap()

        // Cancelled: back on the form, the button still there, no sentence.
        XCTAssertTrue(signOn.waitForExistence(timeout: 10), "the form did not come back after the cancel")
        XCTAssertFalse(app.staticTexts["setup-error"].firstMatch.exists, "a cancelled question must say nothing")
        XCTAssertFalse(app.buttons["tab-audiobooks"].firstMatch.exists, "a cancelled question must not sign in")
        app.terminate()
    }

    // MARK: - Music against gonic

    func testMusicServerSignInFindAndPlay() throws {
        let server = try instance("gonic")
        let app = launchFresh()

        let area = app.buttons["source-map-music"].firstMatch
        XCTAssertTrue(area.waitForExistence(timeout: 30), "a fresh app must show the map of sources")
        area.tap()
        let row = app.buttons["settings-music-source"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let url = app.textFields["subsonic-url"].firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        url.tap()
        url.typeText(server.url)
        try paste(try server.value("user"), into: app.textFields["subsonic-username"].firstMatch, app)
        try paste(try server.value("pass"), into: app.secureTextFields["subsonic-password"].firstMatch, app)
        // The keyboard covers the switch: away with it first, then the knob,
        // and the value is waited for (a centre tap hits the label only).
        app.navigationBars.element(boundBy: app.navigationBars.count - 1).tap()
        let toggle = app.switches["music-tab-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        for _ in 0..<4 where !toggle.isHittable { app.swipeUp() }
        if toggle.value as? String != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let on = NSPredicate(format: "value == '1'")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: on, object: toggle)], timeout: 5),
                           .completed, "the music source must switch on")
        }
        let test = app.buttons["subsonic-test-connection"].firstMatch
        XCTAssertTrue(test.waitForExistence(timeout: 5))
        test.tap()
        let ok = app.staticTexts["subsonic-status-ok"].firstMatch
        let error = app.staticTexts["subsonic-status-error"].firstMatch
        if waitForEither(ok, error, timeout: 40) !== ok {
            try skipIfUnreachable(server)
            XCTFail("the connection test did not pass: \(error.exists ? error.label : "no answer")")
        }
        declineSavingThePassword(app)

        // Out of the source page and the map into the library.
        let serverless = app.buttons["start-serverless"].firstMatch
        for _ in 0..<3 where !serverless.exists {
            let bar = app.navigationBars.element(boundBy: app.navigationBars.count - 1)
            bar.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(serverless.waitForExistence(timeout: 10), "the setup must offer to go on without a book server")
        serverless.tap()
        XCTAssertTrue(app.buttons["tab-music"].firstMatch.waitForExistence(timeout: 20), "the music server must surface the tab")

        try findAndPlay(app, title: "Music for Spaceports")
        app.terminate()
    }

    // MARK: - Steps

    /// Searches the library for a title of the server's stock, opens it and
    /// starts it; the mini player is the proof that something plays.
    private func findAndPlay(_ app: XCUIApplication, title: String) throws {
        declineSavingThePassword(app)
        let search = app.buttons["global-search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 20), "the library must offer the search")
        // Right after the start a tap can land while the page still moves:
        // the scope bar on top of the search page is the proof it opened.
        let scopes = app.buttons["scope-library"].firstMatch
        for _ in 0..<3 where !scopes.exists {
            search.tap()
            _ = scopes.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(scopes.exists, "the search page must open")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the search page must offer its field")
        field.tap()
        field.typeText(title + "\n")
        let hit = app.staticTexts[title].firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 30), "the search must find \(title) on the server")
        hit.tap()
        // A book page starts with `book-play`, an album page with its Play capsule.
        let play = app.buttons["book-play"].firstMatch
        let albumPlay = app.buttons.matching(NSPredicate(format: "label == 'Play'")).firstMatch
        let start = waitForEither(play, albumPlay, timeout: 20)
        XCTAssertNotNil(start, "the page of \(title) must offer to play it")
        start?.tap()
        XCTAssertTrue(app.buttons["mini-player"].firstMatch.waitForExistence(timeout: 30),
                      "\(title) must start playing from the server")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "server-\(title)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// After a sign-in the system offers to save the password in a sheet
    /// over the app, and every tap lands on it. The journey declines: no
    /// access value goes into the simulator's keychain. The system speaks the
    /// simulator's language, not the app's.
    private func declineSavingThePassword(_ app: XCUIApplication) {
        for label in ["Später", "Not Now"] {
            let later = app.buttons[label].firstMatch
            if later.waitForExistence(timeout: 3) {
                later.tap()
                return
            }
        }
    }

    private func launchFresh() -> XCUIApplication {
        let app = XCUIApplication()
        // The harness marker without the seed: the app talks to the real
        // servers, keeps the cloud store in memory and skips the next steps.
        app.launchArguments += ["-uitest-harness", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30), "the app did not come up")
        return app
    }

    /// A value into a field through the pasteboard: typed text would stand
    /// in the activity log of the result bundle.
    private func paste(_ value: String, into field: XCUIElement, _ app: XCUIApplication) throws {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        UIPasteboard.general.string = value
        defer { UIPasteboard.general.items = [] }
        field.tap()
        field.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"].firstMatch
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the field must offer to paste")
        paste.tap()
    }

    private func waitForEither(_ first: XCUIElement, _ second: XCUIElement, timeout: TimeInterval) -> XCUIElement? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if first.exists { return first }
            if second.exists { return second }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return nil
    }

    // MARK: - The instances

    private struct Instance {
        let name: String
        let url: String
        let values: [String: String]
        func value(_ key: String) throws -> String {
            guard let value = values[key], !value.isEmpty else {
                throw XCTSkip("Zugang fehlt: \(name).\(key) steht nicht in der Zugangsdatei")
            }
            return value
        }
    }

    /// The instance as the runner handed it over, or a skip that names why
    /// it cannot run: no server run, server not reached, access missing.
    private func instance(_ name: String) throws -> Instance {
        let environment = ProcessInfo.processInfo.environment
        guard let reach = environment["MAER_SERVER_REACH"], let path = environment["MAER_SERVER_ACCESS"] else {
            throw XCTSkip("kein Serverlauf: scripts/journeys.sh mit MAER_JOURNEY_SERVERS=1 starten")
        }
        let reached = Dictionary(reach.split(separator: ",").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { $1 })
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw XCTSkip("Zugang fehlt: die Zugangsdatei ist nicht lesbar")
        }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].hasPrefix(name + ".") else { continue }
            values[String(parts[0].dropFirst(name.count + 1))] = parts[1]
        }
        guard let url = values["url"] else { throw XCTSkip("Zugang fehlt: \(name) steht nicht in der Zugangsdatei") }
        if reached[name] != "ok" { throw XCTSkip("Server nicht erreichbar: \(url)") }
        return Instance(name: name, url: url, values: values)
    }

    /// After a failed sign-in: asks the server itself, without access. A
    /// server that does not answer is its own outcome, not the app's fault.
    private func skipIfUnreachable(_ server: Instance) throws {
        guard let address = URL(string: server.url) else { return }
        var request = URLRequest(url: address)
        request.timeoutInterval = 10
        let answered = expectation(description: "server answers")
        let reached = Mutex(false)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            reached.withLock { $0 = response != nil }
            answered.fulfill()
        }.resume()
        wait(for: [answered], timeout: 15)
        if !reached.withLock({ $0 }) { throw XCTSkip("Server nicht erreichbar: \(server.url), waehrend des Laufs") }
    }
}
