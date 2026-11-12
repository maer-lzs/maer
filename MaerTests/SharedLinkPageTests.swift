// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The page `/l` on maer.fm for a link without the app: it reads only the
/// fragment, asks no server, loads nothing from another host, sets no
/// cookie and plays the audio of the link straight from its address. The
/// form it reads is the one `SharedLink` writes.
struct SharedLinkPageTests {
    static let page = "site/l/index.html"
    /// The one address the page names: the app in the App Store.
    static let store = "https://apps.apple.com/app/id6799687154"

    private static func text() throws -> String {
        try String(contentsOf: SourceTree.root.appendingPathComponent(page), encoding: .utf8)
    }

    @Test("die Seite liest nur den Teil hinter dem #, fragt nichts ab und setzt kein Cookie", .needsTheSite)
    func thePageReadsOnlyTheFragment() throws {
        let html = try Self.text()
        #expect(html.contains("location.hash"), "the page does not read the fragment")
        #expect(html.contains("addEventListener(\"hashchange\""),
                "a second link in the same tab would show the first one's content")
        let asking = ["fetch(", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "import(",
                      "document.cookie", "localStorage", "sessionStorage", "indexedDB",
                      "innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"]
        let found = asking.filter { html.contains($0) }
        #expect(found.isEmpty, "the page asks or writes where it must not: \(found)")
    }

    @Test("die Seite laedt nichts von einem fremden Host: kein Bild, keine Schrift, kein Skript, keine Vorlage", .needsTheSite)
    func thePageLoadsNothingFromElsewhere() throws {
        let html = try Self.text()
        let loading = ["<img", "<link", "<iframe", "<object", "<embed", "<source", "<script src", "@import", "url(", "srcdoc"]
        let found = loading.filter { html.lowercased().contains($0) }
        #expect(found.isEmpty, "the page loads from elsewhere: \(found)")
        // Every address in the page is the store's, or the scheme the page
        // lets play.
        let pattern = try Regex("https?://[^\\s\"'<>)]*")
        let addresses = html.ranges(of: pattern).map { String(html[$0]) }
        let foreign = addresses.filter { $0 != Self.store && $0 != "https://" }
        #expect(!addresses.isEmpty, "the precondition: the page names the store")
        #expect(foreign.isEmpty, "the page names another address: \(foreign)")
        // The policy in the page itself: nothing from anywhere, audio over https.
        #expect(html.contains("default-src 'none'") && html.contains("media-src https:"),
                "the page carries no policy that keeps it to itself")
        #expect(html.contains("<meta name=\"referrer\" content=\"no-referrer\">"))
        #expect(html.contains("preload=\"none\""), "the audio loads before it is played")
    }

    @Test("die Seite liest die Form, die SharedLink schreibt: Fassung, Arten, Schluessel", .needsTheSite)
    func thePageReadsTheFormOfTheLink() throws {
        let html = try Self.text()
        #expect(html.contains("indexOf(\"\(SharedLink.version)?\")"), "the page reads another version")
        for kind in ["e: [\"f\", \"g\"]", "s: [\"f\"]", "r: [\"i\"]", "b: [\"i\"]"] {
            #expect(html.contains(kind), "the page misses the identity of a kind: \(kind)")
        }
        #expect(html.contains("> \(SharedLink.longestFragment)"), "the page reads a longer fragment than the app")
        for key in ["link.t", "link.s", "link.a"] {
            #expect(html.contains(key), "the page does not show \(key)")
        }
        // The kinds and keys the app writes are the ones the page reads.
        let written = try #require(SharedLink.url(for: .episode(feedURL: "https://f.example/x", guid: "g",
                                                               .init(title: "T", subtitle: "S", audioURL: "https://a.example/a.mp3"))))
        let keys = written.fragment(percentEncoded: true)?.dropFirst(2).split(separator: "&")
            .map { String($0.split(separator: "=")[0]) } ?? []
        #expect(keys == ["k", "f", "g", "t", "s", "a"], "the app writes other keys than the page reads: \(keys)")
    }
}
#endif
