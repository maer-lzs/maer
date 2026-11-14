// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The page `/l/` on maer.fm for a link without the app: it reads only the
/// fragment, asks no server of its own, reads the feed of a show or an
/// episode from the link's address in the visitor's browser, loads only its
/// own script, style and badge and the cover and audio of the link and of
/// its feed's episodes, sets no cookie, and runs no inline script or style,
/// so the site's policy (`script-src 'self'`, `style-src 'self'`) lets it
/// run. The form it reads is the one `SharedLink` writes.
struct SharedLinkPageTests {
    static let page = "site/l/index.html"
    static let script = "site/l/l.js"
    static let style = "site/l/l.css"
    /// The one address the page names: the app in the App Store.
    static let store = "https://apps.apple.com/app/id6799687154"
    /// The pages of a shared music track at its source, the id appended.
    static let jamendoTrack = "https://www.jamendo.com/track/"
    static let archiveDetails = "https://archive.org/details/"
    /// The picture of the preview card, the same for every link.
    static let card = "https://maer.fm/l/maer-card.png"

    private static func text(_ name: String) throws -> String {
        try String(contentsOf: SourceTree.root.appendingPathComponent(name), encoding: .utf8)
    }

    private static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test("the page reads only the part after the #, asks only the link's feed and sets no cookie", .needsTheSite)
    func thePageReadsOnlyTheFragment() throws {
        let js = try Self.text(Self.script)
        #expect(js.contains("location.hash"), "the page does not read the fragment")
        #expect(js.contains("addEventListener(\"hashchange\""),
                "a second link in the same tab would show the first one's content")
        let asking = ["XMLHttpRequest", "WebSocket", "EventSource", "sendBeacon", "import(",
                      "document.cookie", "localStorage", "sessionStorage", "indexedDB", "window.open", "target",
                      "innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function"]
        let all = try [Self.page, Self.script, Self.style].map(Self.text).joined(separator: "\n")
        let found = asking.filter { all.contains($0) }
        #expect(found.isEmpty, "the page asks or writes where it must not: \(found)")
        // One request: the feed of a show or an episode, from the link's own
        // address, over https, without cookies and without a referrer.
        #expect(Self.count("fetch(", in: js) == 1
                && js.contains("fetch(address, { credentials: \"omit\", referrerPolicy: \"no-referrer\" })"),
                "the page asks another way than the one feed request")
        #expect(Self.count("readFeed(", in: js) == 2
                && js.contains("if ((link.k === \"s\" || link.k === \"e\") && link.f.indexOf(\"https://\") === 0) {")
                && js.contains("readFeed(link.f)"),
                "the page asks another address than the feed of the link")
        // The HTML of a description goes into a document that is never
        // shown, and only its text comes out.
        #expect(js.contains("new DOMParser().parseFromString(html, \"text/html\")") && js.contains("return doc.body.textContent"),
                "a description reaches the page as HTML")
    }

    @Test("Fence: the page loads only its own script and its own style, nothing inline, nothing from a foreign host", .needsTheSite)
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
                       "srcset", "new image"]
        let found = loading.filter { all.lowercased().contains($0) }
        #expect(found.isEmpty, "the page loads from elsewhere: \(found)")
        // The page builds only rows, text, links and buttons, never an
        // element that loads.
        let js = try Self.text(Self.script)
        let built = Set(js.components(separatedBy: "createElement(").dropFirst().map { String($0.prefix(while: { $0 != ")" })) })
        #expect(built == ["\"li\"", "row.page ? \"a\" : \"div\"", "\"div\"", "\"p\"", "\"span\"", "\"button\"", "\"a\""],
                "the page builds other elements: \(built.sorted())")
        // Every address in the page is the store's, a page of a track's
        // source, or a scheme the page checks an address against.
        let pattern = try Regex("https?://[^\\s\"'<>)]*")
        let addresses = all.ranges(of: pattern).map { String(all[$0]) }
        let foreign = addresses.filter { ![Self.store, "https://", "http://", Self.jamendoTrack, Self.archiveDetails, Self.card].contains($0) }
        #expect(!addresses.isEmpty, "the precondition: the page names the store")
        #expect(foreign.isEmpty, "the page names another address: \(foreign)")
        // The policy in the page itself, the same the site sets for /l/:
        // pictures from the site and over https, sound over https, and the
        // feed of the link read over https.
        #expect(html.contains("content=\"default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' https:; media-src https:; connect-src https:; base-uri 'none'; form-action 'none'\""),
                "the page carries another policy than the site's for /l/")
        #expect(!all.contains("unsafe-inline"), "the page asks for inline script or style")
        #expect(html.contains("<meta name=\"referrer\" content=\"no-referrer\">"))
        #expect(html.contains("preload=\"none\""), "the audio loads before it is played")
    }

    @Test("Fence: the page shows two images, the cover from c over https without referrer and the store badge from the page itself", .needsTheSite)
    func thePageShowsOnlyTheCoverOfTheLink() throws {
        let html = try Self.text(Self.page)
        let js = try Self.text(Self.script)
        let css = try Self.text(Self.style)
        let images = Self.count("<img", in: html.lowercased())
        #expect(images == 2, "the page holds \(images) pictures, the cover and the badge are the two")
        #expect(html.contains("<img class=\"cover\" id=\"cover\" alt=\"\" referrerpolicy=\"no-referrer\" hidden>"),
                "the cover is not the one picture without an address, without a referrer, hidden until the link names it")
        #expect(html.contains("<img class=\"badge\" id=\"badge\" src=\"/l/app-store-badge-en.svg\""),
                "the badge does not come from the site")
        for badge in ["site/l/app-store-badge-en.svg", "site/l/app-store-badge-de.svg"] {
            let svg = try Self.text(badge).lowercased()
            #expect(svg.hasPrefix("<svg") && !svg.contains("<script") && !svg.contains("href") && !svg.contains("<image"),
                    "the badge \(badge) runs or loads something")
        }
        // The addresses that load into the page: the audio from a and the
        // cover from c, each only over https; the German badge from the
        // site; an episode of the feed, only over https and without access.
        let assigned = js.components(separatedBy: ".src = ").dropFirst().map { String($0.prefix(while: { $0 != ";" })) }
        #expect(assigned.sorted() == ["\"/l/app-store-badge-de.svg\"", "link.a", "link.c", "row.audio"],
                "the page loads from somewhere else: \(assigned)")
        #expect(js.contains("if (!usable(audio, [\"https://\"])) { continue; }"),
                "an episode of the feed plays over http or with access")
        #expect(js.contains("if (!jamendo && link.a && link.a.indexOf(\"https://\") === 0)"),
                "the audio plays over http, or a Jamendo track plays")
        #expect(js.contains("if (link.c && link.c.indexOf(\"https://\") === 0)"), "the cover loads over http")
        #expect(js.contains("cover.classList.add(\"failed\")") && css.contains(".cover.failed { visibility: hidden; }"),
                "a cover that does not load does not leave its place empty")
    }

    @Test("Fence: a music title names its provider and its page there, Jamendo never plays, archive.org carries the app's sentence", .needsTheSite)
    func aMusicTrackNamesItsSource() throws {
        let html = try Self.text(Self.page)
        let js = try Self.text(Self.script)
        // The two forms the app shares, and nothing else reads as a track.
        #expect(js.contains("var JAMENDO = /^jam:([0-9]+)$/;") && js.contains("var ARCHIVE = /^lva:([^#]+)#[0-9]+$/;"),
                "the page reads other track forms than SharedLink")
        #expect(js.contains("if (values.k === \"m\" && !JAMENDO.test(values.i) && !ARCHIVE.test(values.i)) { return null; }"))
        // The pages named: a track's page at its source, built from the id
        // of the link; the show's website from the feed, checked like every
        // address; an episode's page and its show's page, links of this page.
        let links = js.components(separatedBy: ".href = ").dropFirst().map { String($0.prefix(while: { $0 != ";" })) }
        #expect(links.sorted() == ["\"\(Self.archiveDetails)\" + encodeURIComponent(archive[1])",
                                   "\"\(Self.jamendoTrack)\" + jamendo[1]", "page", "row.page", "toShow", "website"],
                "the page links elsewhere: \(links)")
        #expect(js.contains("usable(feed.website, [\"https://\", \"http://\"]) ? feed.website : null"),
                "the website of a show is linked without the check")
        #expect(js.contains("return fragment.length > 4096 ? null : \"#\" + fragment;"),
                "a link of this page leaves the page")
        #expect(html.contains("<a class=\"source\" id=\"source\" rel=\"noreferrer noopener\" hidden></a>"))
        // The attribution and the rights sentence are the app's own.
        #expect(js.contains("viaJamendo: \"Creative Commons, via Jamendo\""), "the provider line is not the app's")
        #expect(js.contains(FreeCatalog.archiveRightsNotice), "the rights sentence is not the app's: \(FreeCatalog.archiveRightsNotice)")
    }

    @Test("Fence: the head carries a general preview card, the same for every link, with the image from the page itself", .needsTheSite)
    func theHeadCarriesOneCardForEveryLink() throws {
        let html = try Self.text(Self.page)
        let head = try #require(html.components(separatedBy: "</head>").first)
        for tag in ["<meta property=\"og:title\" content=\"Mär\">",
                    "<meta property=\"og:site_name\" content=\"Mär\">",
                    "<meta property=\"og:type\" content=\"website\">",
                    "<meta property=\"og:image\" content=\"\(Self.card)\">",
                    "<meta name=\"twitter:card\" content=\"summary\">"] {
            #expect(head.contains(tag), "the head lacks \(tag)")
        }
        let description = try #require(head.components(separatedBy: "<meta property=\"og:description\" content=\"").dropFirst().first?
            .components(separatedBy: "\"").first, "the head lacks a description")
        #expect(!description.isEmpty && !description.contains("\u{2014}") && !description.contains("\u{2013}"), "the description: \(description)")
        // The server never sees what is shared, so nothing of the link can be
        // in the card: the card is the same text in every page.
        let metas = head.components(separatedBy: "<meta").dropFirst().filter { $0.contains("og:") || $0.contains("twitter:") }
        #expect(metas.allSatisfy { !$0.contains("#") && !$0.contains("{") }, "a card names something of the link")
        // The picture lies beside the page, a square PNG.
        let picture = try Data(contentsOf: SourceTree.root.appendingPathComponent("site/l/maer-card.png"))
        #expect(picture.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "the card's picture is no PNG")
        #expect(head.contains("<meta property=\"og:image:width\" content=\"600\">") && head.contains("<meta property=\"og:image:height\" content=\"600\">"))
    }

    @Test("the page reads the form that SharedLink writes: version, kinds, keys", .needsTheSite)
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
