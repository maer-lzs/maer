// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import WebKit
@testable import Maer

/// The page on maer.fm reads the feed of a show or an episode in the
/// visitor's browser. The witnesses run the page's own HTML and script in
/// WebKit, with a stand-in for `fetch` that hands over a feed built here:
/// what the feed says is set as text only, an address with access is left
/// out, and a feed that fails leaves the page as it was.
@MainActor
struct SharedLinkPageFeedTests {
    static let feedURL = "https://feeds.example/show.xml"
    static let cover = "https://img.example/show.jpg"

    struct Episode {
        var title: String
        var guid: String?
        var audio: String
        var daysAgo: Double
        var duration = "1:01:30"
        var description = "About this episode."
    }

    struct Shown: Decodable {
        struct Part: Decodable { let hidden: Bool; let text: String }
        struct Row: Decodable { let title: String; let meta: String; let href: String?; let target: String? }
        struct Asked: Decodable { let url: String; let credentials: String?; let referrer: String? }
        let title: Part
        let subtitle: Part
        let publisher: Part
        let facts: Part
        let about: Part
        let description: Part
        let descriptionElements: Int
        let more: Part
        let websiteHidden: Bool
        let websiteHref: String?
        let episodes: Part
        let rows: [Row]
        let images: Int
        let scripts: Int
        let pwned: String?
        let asked: [Asked]
        let toShow: String?
    }

    static func date(daysAgo: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: Date(timeIntervalSince1970: 1_763_000_000 - daysAgo * 86_400))
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// An RSS feed with the iTunes names, each part only when it is given.
    static func feed(author: String? = "The Publisher", owner: String? = nil, category: String? = "Technology",
                     language: String? = "en", description: String = "About the show.",
                     website: String? = "https://show.example/", episodes: [Episode]) -> String {
        var channel = "<title>The Show</title>"
        if let author { channel += "<itunes:author>\(escaped(author))</itunes:author>" }
        if let owner { channel += "<itunes:owner><itunes:name>\(escaped(owner))</itunes:name></itunes:owner>" }
        if let category { channel += "<itunes:category text=\"\(escaped(category))\"/>" }
        if let language { channel += "<language>\(language)</language>" }
        if let website { channel += "<link>\(escaped(website))</link>" }
        channel += "<description><![CDATA[\(description)]]></description>"
        for episode in episodes {
            channel += "<item><title>\(escaped(episode.title))</title>"
            if let guid = episode.guid { channel += "<guid>\(escaped(guid))</guid>" }
            channel += "<pubDate>\(date(daysAgo: episode.daysAgo))</pubDate>"
            channel += "<itunes:duration>\(episode.duration)</itunes:duration>"
            channel += "<enclosure url=\"\(escaped(episode.audio))\" type=\"audio/mpeg\" length=\"1\"/>"
            channel += "<description><![CDATA[\(episode.description)]]></description></item>"
        }
        return "<?xml version=\"1.0\"?><rss version=\"2.0\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel>\(channel)</channel></rss>"
    }

    static func episodes(gaps days: Double, count: Int = 5) -> [Episode] {
        (0..<count).map { Episode(title: "Episode \($0)", guid: "g\($0)", audio: "https://a.example/\($0).mp3", daysAgo: Double($0) * days) }
    }

    static func showFragment(subtitle: String? = nil) -> String {
        var pairs = [("k", "s"), ("f", feedURL), ("t", "The Show")]
        if let subtitle { pairs.append(("s", subtitle)) }
        pairs.append(("c", cover))
        return "#1?" + pairs.map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.1)" }.joined(separator: "&")
    }

    final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done?.resume(); done = nil }
    }

    /// Runs the page for a fragment. `feed` nil: the fetch fails as a feed
    /// server without CORS fails; `status` is the answer's status.
    static func render(_ fragment: String, feed: String?, status: Int = 200, language: String = "en-US",
                       pressMore: Bool = false) async throws -> Shown {
        let root = SourceTree.root.appendingPathComponent("site/l")
        let html = try String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8)
            .replacingOccurrences(of: "<script src=\"/l/l.js\"></script>", with: "")
        let script = try String(contentsOf: root.appendingPathComponent("l.js"), encoding: .utf8)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let loaded = Loaded()
        view.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.done = continuation
            view.loadHTMLString(html, baseURL: URL(string: "https://maer.fm/l/"))
        }
        let literal = { (value: String?) -> String in
            guard let value else { return "null" }
            let data = try? JSONSerialization.data(withJSONObject: [value])
            return String(data: data ?? Data(), encoding: .utf8).map { String($0.dropFirst().dropLast()) } ?? "null"
        }
        _ = try await view.evaluateJavaScript("""
            history.replaceState(null, "", \(literal(fragment)));
            Object.defineProperty(navigator, "language", { get: function () { return \(literal(language)); } });
            window.__asked = [];
            window.fetch = function (url, options) {
              window.__asked.push({ url: url, credentials: options && options.credentials, referrer: options && options.referrerPolicy });
              var body = \(literal(feed));
              if (body === null) { return Promise.reject(new TypeError("Load failed")); }
              return Promise.resolve({ ok: \(status) >= 200 && \(status) < 300, text: function () { return Promise.resolve(body); } });
            };
            true;
            """)
        _ = try await view.evaluateJavaScript(script + "\ntrue;")
        let result = try await view.callAsyncJavaScript("""
            await new Promise(function (r) { setTimeout(r, 150); });
            if (\(pressMore ? "true" : "false")) { document.getElementById("more").click(); }
            function part(id) { var e = document.getElementById(id); return { hidden: e.hidden, text: e.textContent }; }
            var rows = Array.prototype.map.call(document.querySelectorAll("#list li"), function (li) {
              var a = li.querySelector("a.episode");
              return { title: li.querySelector(".episode-title").textContent, meta: li.querySelector(".episode-meta").textContent,
                       href: a ? a.getAttribute("href") : null, target: a ? a.getAttribute("target") : null };
            });
            var site = document.getElementById("website");
            var toShow = document.getElementById("to-show");
            return JSON.stringify({ title: part("title"), subtitle: part("subtitle"), publisher: part("publisher"),
              facts: part("facts-line"), about: part("about"), description: part("description"),
              descriptionElements: document.getElementById("description").children.length, more: part("more"),
              websiteHidden: site.hidden, websiteHref: site.getAttribute("href"), episodes: part("episodes"), rows: rows,
              images: document.images.length, scripts: document.scripts.length,
              pwned: window.pwned === undefined ? null : String(window.pwned), asked: window.__asked,
              toShow: toShow ? toShow.getAttribute("href") : null });
            """, contentWorld: .page)
        let json = try #require(result as? String, "the page did not answer")
        return try JSONDecoder().decode(Shown.self, from: Data(json.utf8))
    }

    @Test("ein sauberer Feed: Herausgeber, Angaben, Beschreibung, Webseite und die Folgen, neueste zuerst, je mit eigener Seite im selben Tab", .needsTheSite)
    func aCleanFeedFillsThePage() async throws {
        let feed = Self.feed(episodes: Self.episodes(gaps: 7, count: 3))
        let shown = try await Self.render(Self.showFragment(), feed: feed)
        #expect(shown.asked.count == 1 && shown.asked.first?.url == Self.feedURL, "the page asked another address: \(shown.asked)")
        #expect(shown.asked.first?.credentials == "omit" && shown.asked.first?.referrer == "no-referrer",
                "the feed is asked with cookies or a referrer")
        #expect(shown.subtitle.text == "The Publisher" && !shown.subtitle.hidden, "the publisher is not under the title")
        #expect(shown.facts.text == "Technology · English · 3 episodes · weekly", "the facts line: \(shown.facts.text)")
        #expect(shown.description.text == "About the show." && !shown.about.hidden && shown.more.hidden)
        #expect(!shown.websiteHidden && shown.websiteHref == "https://show.example/")
        #expect(shown.rows.map(\.title) == ["Episode 0", "Episode 1", "Episode 2"], "the episodes are not newest first")
        #expect(shown.rows.allSatisfy { $0.target == nil }, "an episode opens another tab")
        let first = try #require(shown.rows.first?.href)
        #expect(first.hasPrefix("#1?k=e&f=https%3A%2F%2Ffeeds.example%2Fshow.xml&g=g0&t=Episode%200&s=The%20Show&a="),
                "the episode's link is not the app's form: \(first)")
        #expect(shown.rows.first?.meta.hasSuffix("1 h 2 min") == true, "the length of an episode: \(shown.rows.first?.meta ?? "")")
        #expect(shown.pwned == nil && shown.scripts == 0)

        // The episode's own page from that link: its description, date and
        // length, and the way back to the show.
        let page = try await Self.render(first, feed: feed)
        #expect(page.title.text == "Episode 0")
        #expect(page.description.text == "About this episode.")
        #expect(page.facts.text.hasSuffix("1 h 2 min") && page.facts.text.contains("2025"), "date and length: \(page.facts.text)")
        let back = try #require(page.toShow, "the show of an episode is no link")
        #expect(back.hasPrefix("#1?k=s&f=https%3A%2F%2Ffeeds.example%2Fshow.xml&t=The%20Show&s=The%20Publisher&c="),
                "the link back is not the show's: \(back)")
    }

    @Test("HTML und Skript aus dem Feed kommen nur als Text auf die Seite, nichts davon laeuft oder laedt", .needsTheSite)
    func theFeedIsOnlyText() async throws {
        let hostile = "<p>Line one</p><script>window.pwned = 1</script><img src=\"https://evil.example/x.png\" onerror=\"window.pwned = 2\"><br>Line two"
        let feed = Self.feed(description: hostile, episodes: Self.episodes(gaps: 7, count: 1))
        let shown = try await Self.render(Self.showFragment(), feed: feed)
        #expect(shown.description.text.contains("Line one") && shown.description.text.contains("Line two"),
                "the precondition: the description is shown: \(shown.description.text)")
        #expect(!shown.description.text.contains("<"), "markup of the feed is in the text: \(shown.description.text)")
        #expect(shown.descriptionElements == 0, "the description holds elements of the feed")
        #expect(shown.pwned == nil, "a script of the feed ran")
        #expect(shown.images == 2 && shown.scripts == 0, "the feed added pictures or scripts: \(shown.images) \(shown.scripts)")
    }

    @Test("eine Audio- oder Webadresse mit Zugang aus dem Feed fehlt auf der Seite", .needsTheSite)
    func anAddressWithAccessIsLeftOut() async throws {
        var episodes = Self.episodes(gaps: 7, count: 3)
        episodes[1].audio = "https://a.example/1.mp3?token=s3cr3t"
        episodes[2].audio = "http://a.example/2.mp3"
        let feed = Self.feed(website: "https://show.example/?api_key=s3cr3t", episodes: episodes)
        let shown = try await Self.render(Self.showFragment(), feed: feed)
        #expect(shown.rows.map(\.title) == ["Episode 0"], "an episode with access or without https is listed: \(shown.rows.map(\.title))")
        #expect(shown.websiteHidden, "a website with access is linked")
        #expect(!shown.rows.contains { $0.href?.contains("s3cr3t") == true })
    }

    @Test("ein kaputter, leerer, gesperrter oder fehlender Feed laesst die Seite wie sie war", .needsTheSite)
    func aFeedThatFailsLeavesThePage() async throws {
        let cases: [(String, String?, Int)] = [
            ("broken", "<rss><channel><title>x", 200),
            ("empty", "<?xml version=\"1.0\"?><rss version=\"2.0\"><channel></channel></rss>", 200),
            ("no CORS", nil, 200),
            ("not found", Self.feed(episodes: Self.episodes(gaps: 7)), 404),
            ("no RSS", "<html><body>nothing</body></html>", 200),
        ]
        for (name, feed, status) in cases {
            let shown = try await Self.render(Self.showFragment(subtitle: "From the Link"), feed: feed, status: status)
            #expect(shown.title.text == "The Show" && shown.subtitle.text == "From the Link", "\(name): the head changed")
            #expect(shown.about.hidden && shown.episodes.hidden && shown.facts.hidden && shown.rows.isEmpty,
                    "\(name): the page shows something of a feed that failed")
            #expect(shown.asked.count == 1, "\(name): the precondition: the feed was asked")
        }
    }

    @Test("der Rhythmus aus festen Datumsreihen: taeglich, mehrmals pro Woche, woechentlich, alle zwei Wochen, monatlich, sonst nichts", .needsTheSite)
    func theRhythmFollowsTheDates() async throws {
        let expected: [(Double, String?)] = [(1, "daily"), (3, "several times a week"), (7, "weekly"),
                                             (14, "every two weeks"), (30, "monthly"), (60, nil), (20, nil)]
        for (gap, word) in expected {
            let shown = try await Self.render(Self.showFragment(), feed: Self.feed(episodes: Self.episodes(gaps: gap)))
            let last = shown.facts.text.components(separatedBy: " · ").last
            if let word {
                #expect(last == word, "a gap of \(gap) days reads as \(shown.facts.text)")
            } else {
                #expect(last == "5 episodes", "a gap of \(gap) days names a rhythm: \(shown.facts.text)")
            }
        }
        let two = try await Self.render(Self.showFragment(), feed: Self.feed(episodes: Self.episodes(gaps: 7, count: 2)))
        #expect(two.facts.text == "Technology · English · 2 episodes", "two dates name a rhythm: \(two.facts.text)")
    }

    @Test("eine lange Beschreibung endet am Wort mit einem Auslassungszeichen, ohne Satzzeichen davor; Mehr zeigt den ganzen Text", .needsTheSite)
    func aLongDescriptionIsCutCleanly() async throws {
        var text = ""
        while text.count < 300 { text += "word " }
        text += "online. " + String(repeating: "b", count: 60) + " end."
        let feed = Self.feed(description: text, episodes: Self.episodes(gaps: 7, count: 1))
        let shown = try await Self.render(Self.showFragment(), feed: feed)
        #expect(shown.description.text.hasSuffix("online…"), "the cut ends otherwise: \(shown.description.text.suffix(20))")
        #expect(!shown.description.text.contains(".…") && !shown.description.text.contains("...."), "points before the ellipsis")
        #expect(!shown.more.hidden && shown.more.text == "More")
        let open = try await Self.render(Self.showFragment(), feed: feed, pressMore: true)
        #expect(open.description.text == text && open.more.hidden, "More does not show the whole text")
    }

    @Test("der Herausgeber kommt aus dem Link, sonst aus itunes:author, sonst aus dem Eigentuemer", .needsTheSite)
    func thePublisherComesFromTheLinkThenTheFeed() async throws {
        let episodes = Self.episodes(gaps: 7, count: 1)
        let fromLink = try await Self.render(Self.showFragment(subtitle: "From the Link"), feed: Self.feed(episodes: episodes))
        #expect(fromLink.subtitle.text == "From the Link")
        let fromOwner = try await Self.render(Self.showFragment(), feed: Self.feed(author: nil, owner: "The Owner", episodes: episodes))
        #expect(fromOwner.subtitle.text == "The Owner")
        let none = try await Self.render(Self.showFragment(), feed: Self.feed(author: nil, episodes: episodes))
        #expect(none.subtitle.hidden, "a publisher nobody names is shown")
    }

    @Test("deutsch: Kategorie aus der Tabelle, Sprache als Name, Folgen und Rhythmus in der Sprache der Seite", .needsTheSite)
    func theFactsSpeakThePagesLanguage() async throws {
        let shown = try await Self.render(Self.showFragment(), feed: Self.feed(episodes: Self.episodes(gaps: 7, count: 3)), language: "de-DE")
        #expect(shown.facts.text == "Technik · Englisch · 3 Folgen · wöchentlich", "the German facts line: \(shown.facts.text)")
        let unknown = try await Self.render(Self.showFragment(), feed: Self.feed(category: "Podcasting Odds", language: "xx",
                                                                                episodes: Self.episodes(gaps: 7, count: 1)), language: "de-DE")
        #expect(unknown.facts.text == "Podcasting Odds · 1 Folge", "an unknown category or language: \(unknown.facts.text)")
    }
}
#endif
