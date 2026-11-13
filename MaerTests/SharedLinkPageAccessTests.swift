// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import JavaScriptCore
@testable import Maer

/// The page on maer.fm asks the app's question before it shows a link: an
/// address with a user or password before its host, or a query name that
/// says access, carries access, and then the page loads no picture and no
/// sound and says its one sentence. The witnesses run the page's own script
/// in JavaScriptCore over a stand-in of the few page elements it touches.
struct SharedLinkPageAccessTests {
    static let uuid = "9617a958-0601-11e8-ae97-52543be04c81"

    /// What the script left on the page for one fragment.
    struct Drawn {
        let title: String
        let cover: String
        let audio: String
    }

    private static func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    /// Runs `site/l/l.js` for a link with these keys after "#1?".
    static func draw(_ pairs: [(String, String)]) throws -> Drawn {
        let script = try String(contentsOf: SourceTree.root.appendingPathComponent("site/l/l.js"), encoding: .utf8)
        let fragment = "#1?" + pairs.map { "\($0.0)=\(encoded($0.1))" }.joined(separator: "&")
        let context = try #require(JSContext())
        var thrown: String?
        context.exceptionHandler = { _, value in thrown = value?.toString() }
        context.setObject(fragment, forKeyedSubscript: "HASH" as NSString)
        context.evaluateScript("""
            var parts = {};
            function element(id) {
              if (!parts[id]) {
                parts[id] = { id: id, hidden: true, textContent: "", src: "", href: "",
                              classList: { add: function () {} }, addEventListener: function () {} };
              }
              return parts[id];
            }
            var document = { getElementById: element, documentElement: {}, title: "" };
            var navigator = { language: "en" };
            var window = { addEventListener: function () {} };
            var location = { hash: HASH, reload: function () {} };
            """)
        context.evaluateScript(script)
        #expect(thrown == nil, "the script threw: \(thrown ?? "")")
        func read(_ path: String) -> String { context.evaluateScript(path)?.toString() ?? "" }
        return Drawn(title: read("element('title').textContent"),
                     cover: read("element('cover').src"),
                     audio: read("element('audio').src"))
    }

    static func station(cover: String, audio: String) throws -> Drawn {
        try draw([("k", "r"), ("i", uuid), ("t", "Radio"), ("a", audio), ("c", cover)])
    }

    @Test("eine Adresse mit Zugang zeigt kein Bild, spielt keinen Ton und sagt den einen Satz", .needsTheSite)
    func anAddressWithAccessShowsNothing() throws {
        let clean = try Self.station(cover: "https://img.example/a.png", audio: "https://s.example/a.mp3")
        #expect(clean.cover == "https://img.example/a.png" && clean.audio == "https://s.example/a.mp3",
                "the precondition: a clean link shows its cover and its sound: \(clean)")
        let tainted: [(cover: String, audio: String)] = [
            ("https://img.example/a.png?token=s3cr3t", "https://s.example/a.mp3"),
            ("https://img.example/a.png", "https://s.example/a.mp3?api_key=s3cr3t"),
            ("https://user:pw@img.example/a.png", "https://s.example/a.mp3"),
            ("https://img.example/a.png", "https://listener@s.example/a.mp3"),
            ("https://img.example/a.png?authToken=s3cr3t", "https://s.example/a.mp3"),
        ]
        for case_ in tainted {
            let drawn = try Self.station(cover: case_.cover, audio: case_.audio)
            #expect(drawn.cover.isEmpty && drawn.audio.isEmpty, "the page loads an address with access: \(case_)")
            #expect(drawn.title == "This link can't be opened.", "the page does not say its sentence: \(case_)")
        }
        let feed = try Self.draw([("k", "s"), ("f", "https://feeds.example/show.xml?key=s3cr3t"), ("t", "Show"),
                                  ("c", "https://img.example/a.png")])
        #expect(feed.cover.isEmpty && feed.title == "This link can't be opened.", "a feed with access shows its page")
    }

    @Test("die Seite gibt dieselbe Antwort wie die App, je Adresse", .needsTheSite)
    func thePageAnswersAsTheApp() throws {
        let names = ["token", "auth", "key", "secret", "freebie", "api_key", "access_token", "authToken", "sessionid",
                     "accesskey", "password", "pwd", "hmac", "sig", "author", "keyword", "design", "passage",
                     "monkey", "sigma", "bypass", "compass", "page", "id", "format"]
        var addresses = names.map { "https://img.example/a.png?\($0)=v" }
        addresses += ["https://img.example/a.png?token=", "https://img.example/a.png?=x",
                      "https://u@img.example/a.png", "https://img.example/a@b.png", "https://img.example/a.png#x@y"]
        for address in addresses {
            let shown = try Self.station(cover: address, audio: "https://s.example/a.mp3").cover == address
            #expect(shown == !PodcastFeedAddress.carriesAccess(address),
                    "page and app answer apart for \(address): page shows \(shown)")
        }
    }

    @Test("Zaun: die drei Listen der Seite sind die der App, Wort fuer Wort", .needsTheSite)
    func theListsAreTheApps() throws {
        let script = try String(contentsOf: SourceTree.root.appendingPathComponent("site/l/l.js"), encoding: .utf8)
        func list(_ name: String) throws -> [String] {
            let line = try #require(script.components(separatedBy: "\n").first { $0.contains("var \(name) = [") },
                                    "the page holds no list \(name)")
            let inner = try #require(line.components(separatedBy: "[").dropFirst().first?.components(separatedBy: "]").first)
            return inner.components(separatedBy: ",").map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        #expect(Set(try list("ACCESS_PARTS")) == PodcastFeedAddress.accessNameParts)
        #expect(try list("ACCESS_HARD") == PodcastFeedAddress.accessHardWords)
        #expect(try list("ACCESS_KEY_LEADS") == PodcastFeedAddress.accessKeyLeads)
    }
}
#endif
