// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A feed that parses as a valid show without
/// episodes SAYS so when subscribing. The subscription happens anyway.
///
/// The rule is pure because it weighs three facts, none of which belongs to a
/// view, and because there are THREE subscription paths (settings page,
/// cards/show page, catalog page) that already do not do the same today.
/// The notice is therefore created in the store and shown in ONE
/// place.
struct PodcastSubscribeNoticeTests {
    @Test("Only the first own subscribing to an episode-less feed says anything")
    func onlyAFirstOwnSubscribeOfAnEmptyFeedSpeaks() {
        #expect(PodcastSubscribeNotice.shouldTell(episodeCount: 0, isSingleUserAct: true,
                                                  isFirstSubscribe: true))
        // With episodes there is nothing to say.
        #expect(!PodcastSubscribeNotice.shouldTell(episodeCount: 1, isSingleUserAct: true,
                                                   isFirstSubscribe: true))
        // From the account or from gpodder: nobody's tap, so no notice
        // out of nothing. AND the import: the person acts, but not on
        // THIS feed. It runs over hundreds and reports its own
        // summary; an alert per feed would have named the last empty one
        // and kept quiet about the others. The first version borrowed
        // `notesCloud` for that and warned that the two could diverge;
        // they already had, exactly at the import.
        #expect(!PodcastSubscribeNotice.shouldTell(episodeCount: 0, isSingleUserAct: false,
                                                   isFirstSubscribe: true))
        // Re-subscribing MERGES with the cache, so a thin
        // second parse loses nothing and is worth no notice.
        #expect(!PodcastSubscribeNotice.shouldTell(episodeCount: 0, isSingleUserAct: true,
                                                   isFirstSubscribe: false))
    }

    /// The notice exists ONCE. Whoever builds a second presentation must
    /// touch this count; that was exactly the requirement („bau die Meldung
    /// einmal statt dreimal"), and a count holds it, an intent does not.
    @Test("There is exactly one host for the notice", .needsTheSources)
    func exactlyOneHostShowsIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var readers: [String: Int] = [:]
        var setters: [String: Int] = [:]
        for url in SourceTree.files(under: root) where url.lastPathComponent.hasSuffix(".swift") {
            let path = SourceTree.relativePath(of: url)
            let lines = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            // The DECLARATION is neither reading nor setting. My first
            // detector counted it as a read and turned the case red: a
            // line that exists because the thing exists is no access.
            let hits = lines.filter {
                $0.contains("emptyFeedNotice") && !$0.contains("var emptyFeedNotice")
            }
            guard !hits.isEmpty else { continue }
            // The assignment `= …` is the setting, everything else reads.
            let written = hits.filter { $0.contains("emptyFeedNotice = ") && !$0.contains("== nil") }
            if !written.isEmpty { setters[path] = written.count }
            let read = hits.count - written.count
            if read > 0 { readers[path] = read }
        }
        #expect(Set(readers.keys) == ["Sources/Views/Podcasts/PodcastSubscribeNoticeHost.swift"],
                "die Meldung wird an mehr als einer Stelle gezeigt: \(readers.keys.sorted())")
        // It is set in the store (where it arises) and reset in the host
        // when the person has clicked it away.
        #expect(Set(setters.keys) == ["Sources/Providers/PodcastSubscriptions.swift",
                                      "Sources/Views/Podcasts/PodcastSubscribeNoticeHost.swift"],
                "die Meldung entsteht woanders als in der Ablage: \(setters.keys.sorted())")
    }

    /// Whoever subscribes says whether it was a SINGLE act. The count names per
    /// caller the reason, because exactly here the first version was wrong: it
    /// borrowed `notesCloud` as a stand-in, and the import calls with the
    /// default value. A borrowed trait is a claim about all
    /// present AND future callers.
    @Test("Every subscription caller says whether it is a single act", .needsTheSources)
    func everySubscribeCallerSaysWhetherItIsASingleAct() throws {
        let bulk: [String: String] = [
            "Sources/Networking/GPodderSync.swift":
                "vom Server abgeleitet, zweimal. Kein Tipp der Person",
            "Sources/Networking/PinchflatClient.swift":
                "gespiegelte Kapseln, Mechanik",
            "Sources/Providers/PodcastSubscriptions.swift":
                "zweimal die Wolken-Uebernahme (Mechanik) und EINMAL der Import: die Person "
                + "handelt, aber nicht an diesem Feed, und er meldet seine eigene Zusammenfassung",
        ]
        let single: [String: String] = [
            "Sources/Views/PodcastSourceView.swift": "ein Feed, von Hand eingegeben",
            "Sources/Views/CatalogDetailExtras.swift": "ein Feed, von der Katalogseite",
            "Sources/Views/Podcasts/PodcastComponents.swift": "ein Feed, Knopf auf Karte oder Seite",
            "Sources/Providers/PodcastSubscriptions.swift":
                "ein Feed: der neue Link, den die Person fuer einen abgelehnten Bezahl-Feed einfuegt",
        ]
        var foundBulk: Set<String> = []
        var foundSingle: Set<String> = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.lastPathComponent.hasSuffix(".swift") {
            let path = SourceTree.relativePath(of: url)
            let flat = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("///") }
                .joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            // Without the DECLARATION: `func subscribe(urlString:` looks like a
            // call and ended up in „Einzel-Akt" on the first run. Second
            // detector trap of the same kind in one day (the first counted
            // a `var` declaration as a read): a source-text searcher must
            // say whether it counts the thing or its use.
            // The door before `subscribe` (`subscribeUnlessOnServer`) is the
            // same call with the same parameters and counts as it.
            let calls = flat.replacingOccurrences(of: "func subscribe(urlString:", with: "func subscribe(DECL:")
                .replacingOccurrences(of: "func subscribeUnlessOnServer(urlString:", with: "func subscribeUnlessOnServer(DECL:")
                .replacingOccurrences(of: "subscribeUnlessOnServer(urlString:", with: "subscribe(urlString:")
            for range in calls.ranges(of: "subscribe(urlString:") {
                let to = calls.index(range.upperBound, offsetBy: 200, limitedBy: calls.endIndex) ?? calls.endIndex
                let call = String(calls[range.upperBound..<to])
                // The window reaches to the closing parenthesis of the call;
                // the question is asked LOCALLY, not in the neighborhood.
                if call.contains("isSingleUserAct: false") { foundBulk.insert(path) }
                else { foundSingle.insert(path) }
            }
        }
        #expect(foundBulk == Set(bulk.keys),
                "ein maschineller oder Massen-Rufer sagt es nicht mehr: \(foundBulk.symmetricDifference(Set(bulk.keys)).sorted())")
        #expect(foundSingle == Set(single.keys),
                "ein Einzel-Rufer ist dazugekommen oder verschwunden: \(foundSingle.symmetricDifference(Set(single.keys)).sorted())")
    }

    /// The sentence is in the catalog, with a German translation. Without this case
    /// a missing translation shows up only on the device, and there
    /// English then appears in a German app.
    @Test("The sentence is translated", .needsTheSources)
    func theSentenceIsTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = json?["strings"] as? [String: Any]
        let entry = strings?["Subscribed. This feed has no episodes yet."] as? [String: Any]
        let de = ((entry?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"]
            as? [String: Any]
        #expect(de?["state"] as? String == "translated")
        #expect((de?["value"] as? String)?.isEmpty == false)
        // No dashes in user text, as everywhere.
        #expect((de?["value"] as? String)?.contains("—") == false)
    }
}
#endif
