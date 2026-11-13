// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The page `/l/` on maer.fm for a link without the app: it reads only the
/// fragment, asks no server, loads only its own script and style and the
/// cover and audio of the link, sets no cookie, and runs no inline script
/// or style, so the site's policy (`script-src 'self'`, `style-src 'self'`)
/// lets it run. The form it reads is the one `SharedLink` writes.
struct SharedLinkPageTests {
    static let page = "site/l/index.html"
    static let script = "site/l/l.js"
    static let style = "site/l/l.css"
    /// The one address the page names: the app in the App Store.
    static let store = "https://apps.apple.com/app/id6799687154"

    private static func text(_ name: String) throws -> String {
        try String(contentsOf: SourceTree.root.appendingPathComponent(name), encoding: .utf8)
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("die Seite liest nur den Teil hinter dem #, fragt nichts ab und setzt kein Cookie", .needsTheSite)
    func thePageReadsOnlyTheFragment() throws {
        let js = try Self.text(Self.script)
        #expect(js.contains("location.hash"), "the page does not read the fragment")
        #expect(js.contains("addEventListener(\"hashchange\""),
                "a second link in the same tab would show the first one's content")
        let asking = ["fetch(", "XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "import(",
                      "document.cookie", "localStorage", "sessionStorage", "indexedDB",
                      "innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"]
        let all = try [Self.page, Self.script, Self.style].map(Self.text).joined(separator: "\n")
        let found = asking.filter { all.contains($0) }
        #expect(found.isEmpty, "the page asks or writes where it must not: \(found)")
    }

    @Test("Zaun: die Seite laedt nur ihr eigenes Skript und ihre eigene Vorlage, nichts inline, nichts von einem fremden Host", .needsTheSite)
    func thePageLoadsNothingFromElsewhere() throws {
        let html = try Self.text(Self.page)
        let all = try [Self.page, Self.script, Self.style].map(Self.text).joined(separator: "\n")
        // One script and one style sheet, both from the page's own folder;
        // no script and no style written into the page.
        #expect(Self.count("<script", in: html.lowercased()) == 1 && html.contains("<script src=\"/l/l.js\"></script>"),
                "the page runs another script than its own file")
        #expect(Self.count("<link", in: html.lowercased()) == 1 && html.contains("<link rel=\"stylesheet\" href=\"/l/l.css\">"),
                "the page loads another style than its own file")
        let inline = ["<style", " style=", " onload=", " onerror=", " onclick=", "javascript:"].filter { html.lowercased().contains($0) }
        #expect(inline.isEmpty, "the page carries inline script or style: \(inline)")
        let loading = ["<iframe", "<object", "<embed", "<source", "@import", "url(", "srcdoc",
                       "srcset", "createelement", "new image"]
        let found = loading.filter { all.lowercased().contains($0) }
        #expect(found.isEmpty, "the page loads from elsewhere: \(found)")
        // Every address in the page is the store's, or the scheme the page
        // lets load.
        let pattern = try Regex("https?://[^\\s\"'<>)]*")
        let addresses = all.ranges(of: pattern).map { String(all[$0]) }
        let foreign = addresses.filter { $0 != Self.store && $0 != "https://" }
        #expect(!addresses.isEmpty, "the precondition: the page names the store")
        #expect(foreign.isEmpty, "the page names another address: \(foreign)")
        // The policy in the page itself, the same the site sets for /l/.
        #expect(html.contains("content=\"default-src 'none'; script-src 'self'; style-src 'self'; img-src https:; media-src https:; base-uri 'none'; form-action 'none'\""),
                "the page carries another policy than the site's for /l/")
        #expect(!all.contains("unsafe-inline"), "the page asks for inline script or style")
        #expect(html.contains("<meta name=\"referrer\" content=\"no-referrer\">"))
        #expect(html.contains("preload=\"none\""), "the audio loads before it is played")
    }

    @Test("Zaun: die Seite zeigt genau ein Bild, das Cover aus c, nur ueber https und ohne Referrer", .needsTheSite)
    func thePageShowsOnlyTheCoverOfTheLink() throws {
        let html = try Self.text(Self.page)
        let js = try Self.text(Self.script)
        let css = try Self.text(Self.style)
        let images = Self.count("<img", in: html.lowercased())
        #expect(images == 1, "the page holds \(images) pictures, the cover is the one")
        #expect(html.contains("<img class=\"cover\" id=\"cover\" alt=\"\" referrerpolicy=\"no-referrer\" hidden>"),
                "the cover is not the one picture without an address, without a referrer, hidden until the link names it")
        // Exactly two addresses come into the page, each from its key of the
        // link and each only over https: the audio from a, the cover from c.
        let assigned = js.components(separatedBy: ".src = ").dropFirst().map { String($0.prefix(while: { $0 != ";" })) }
        #expect(assigned.sorted() == ["link.a", "link.c"], "the page loads from somewhere else: \(assigned)")
        #expect(js.contains("if (link.a && link.a.indexOf(\"https://\") === 0)"), "the audio plays over http")
        #expect(js.contains("if (link.c && link.c.indexOf(\"https://\") === 0)"), "the cover loads over http")
        #expect(js.contains("cover.classList.add(\"failed\")") && css.contains(".cover.failed { visibility: hidden; }"),
                "a cover that does not load does not leave its place empty")
    }

    @Test("die Seite liest die Form, die SharedLink schreibt: Fassung, Arten, Schluessel", .needsTheSite)
    func thePageReadsTheFormOfTheLink() throws {
        let js = try Self.text(Self.script)
        #expect(js.contains("indexOf(\"\(SharedLink.version)?\")"), "the page reads another version")
        for kind in ["e: [\"f\", \"g\"]", "s: [\"f\"]", "r: [\"i\"]", "b: [\"i\"]", "m: [\"i\"]"] {
            #expect(js.contains(kind), "the page misses the identity of a kind: \(kind)")
        }
        #expect(js.contains("> \(SharedLink.longestFragment)"), "the page reads a longer fragment than the app")
        for key in ["link.t", "link.s", "link.a", "link.c"] {
            #expect(js.contains(key), "the page does not show \(key)")
        }
        // The kinds and keys the app writes are the ones the page reads, and
        // the page stands at the path the app writes.
        let written = try #require(SharedLink.url(for: .episode(feedURL: "https://f.example/x", guid: "g",
                                                               .init(title: "T", subtitle: "S", audioURL: "https://a.example/a.mp3",
                                                                     coverURL: "https://c.example/c.jpg"))))
        let keys = written.fragment(percentEncoded: true)?.dropFirst(2).split(separator: "&")
            .map { String($0.split(separator: "=")[0]) } ?? []
        #expect(keys == ["k", "f", "g", "t", "s", "a", "c"], "the app writes other keys than the page reads: \(keys)")
        #expect("site" + written.path(percentEncoded: true) + "index.html" == Self.page, "the page stands elsewhere: \(written)")
    }
}
#endif
