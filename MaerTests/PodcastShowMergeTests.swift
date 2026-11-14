// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The cross-source show list stood five times in the tree, copied by
/// hand, and the copies were NOT equal: two asked the ABS source
/// switch, three did not. Three of them claimed in their own comment
/// to mirror the others.
///
/// This case pins two things: what „einmal" means (on the behavior of the
/// pure rule) and that there is no sixth hand-written version any more
/// (on the source text, with count and reason per entry).
struct PodcastShowMergeTests {
    private func show(_ id: String, feed: String) -> PodcastShow {
        PodcastShow(id: id, title: id, author: nil, artworkURL: nil,
                    description: nil, feedURL: feed, episodes: [])
    }

    private func sourceText(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - The pure rule

    @Test("The same show from both sources appears once, and the ABS side wins")
    func duplicateKeepsTheServerSide() {
        let merged = PodcastShowMerge.merge(
            abs: [show("abs", feed: "https://example.org/feed.xml")],
            rss: [show("rss", feed: "https://example.org/feed.xml")])
        #expect(merged.map(\.id) == ["abs"])
    }

    /// The comparison runs over the NORMALIZED address. Two spellings
    /// of the same feed are the same show, otherwise it would appear
    /// twice: exactly the case the rule exists for.
    @Test("Two spellings of the same address are one show")
    func spellingDoesNotSplitAShow() {
        // Two addresses that differ in scheme, www, letter case,
        // slash and counting parameter and mean the same feed.
        // Were they spelled the same, the case would check nothing.
        let a = "https://www.Example.org/feed.xml/"
        let b = "http://example.org/feed.xml?utm_source=irgendwas"
        #expect(a != b)
        let merged = PodcastShowMerge.merge(abs: [show("abs", feed: a)],
                                            rss: [show("rss", feed: b)])
        #expect(merged.map(\.id) == ["abs"],
                "verschieden geschriebene Adressen desselben Feeds wurden zu zwei Sendungen")
    }

    @Test("A show from only one source stays, and the order stays too")
    func orderIsKept() {
        let merged = PodcastShowMerge.merge(
            abs: [show("a1", feed: "https://a.org/1"), show("a2", feed: "https://a.org/2")],
            rss: [show("r1", feed: "https://r.org/1"), show("r2", feed: "https://r.org/2")])
        #expect(merged.map(\.id) == ["a1", "a2", "r1", "r2"],
                "die Liste ordnet sich unter dem Nutzer um")
    }

    @Test("Empty sources yield the respective other one")
    func emptySideChangesNothing() {
        let one = [show("r1", feed: "https://r.org/1")]
        #expect(PodcastShowMerge.merge(abs: [], rss: one).map(\.id) == ["r1"])
        #expect(PodcastShowMerge.merge(abs: one, rss: []).map(\.id) == ["r1"])
        #expect(PodcastShowMerge.merge(abs: [], rss: []).isEmpty)
    }

    @Test("The subscription question finds the feed regardless of spelling")
    func containsNormalises() {
        let shows = [show("s", feed: "https://example.org/feed.xml")]
        #expect(PodcastShowMerge.contains(feedURL: "https://example.org/feed.xml", in: shows))
        #expect(!PodcastShowMerge.contains(feedURL: "https://other.org/feed.xml", in: shows))
    }

    // MARK: - The seed of the recommendations (product decision 08.09.2026)

    @Test("A show from both pots appears once in the seed")
    func seedFoldsTheTwins() {
        let groups = PodcastShowMerge.foldByFeed([
            show("abs", feed: "https://example.org/feed.xml"),
            show("rss", feed: "https://example.org/feed.xml"),
            show("nur-rss", feed: "https://other.org/feed.xml"),
        ])
        #expect(groups.count == 2, "die Zwillinge wurden nicht gefaltet")
        #expect(groups.map { $0.first?.id } == ["abs", "nur-rss"],
                "der Sieger ist nicht die Kopie, die auch die Anzeige behaelt")
        #expect(groups[0].map(\.id) == ["abs", "rss"],
                "die Gruppe muss ihre Zwillinge behalten, sonst geht Hoerzeit verloren")
    }

    /// Without this case the folding could make a show WEAKER:
    /// the listening time is kept per show identifier, and the two copies have
    /// two identifiers. If one drops out, its time drops with it.
    @Test("Folding does not cost a show its listening time")
    func foldingCostsNoListeningTime() {
        let groups = PodcastShowMerge.foldByFeed([
            show("abs", feed: "https://example.org/feed.xml"),
            show("rss", feed: "https://example.org/feed.xml"),
        ])
        // The whole history lies under the identifier that does NOT survive.
        let lifted = PodcastShowMerge.liftingTwins(["rss": 900], groups: groups)
        #expect(lifted["abs"] == 900, "die Zeit des Zwillings ging verloren")
    }

    /// MAX and not sum: the same episode can carry a stored position
    /// under both spellings. Summing would count one listen twice
    /// and be exactly the error the folding is built against.
    @Test("Two copies with time do not give the sum")
    func twinsDoNotAddUp() {
        let groups = PodcastShowMerge.foldByFeed([
            show("abs", feed: "https://example.org/feed.xml"),
            show("rss", feed: "https://example.org/feed.xml"),
        ])
        let lifted = PodcastShowMerge.liftingTwins(["abs": 600, "rss": 900], groups: groups)
        #expect(lifted["abs"] == 900, "die Zwillingszeiten wurden addiert statt verglichen")
    }

    @Test("A show from only one source keeps its time unchanged")
    func singleSourceIsUntouched() {
        let groups = PodcastShowMerge.foldByFeed([show("nur-rss", feed: "https://other.org/feed.xml")])
        #expect(PodcastShowMerge.liftingTwins(["nur-rss": 120], groups: groups)["nur-rss"] == 120)
        // Without time none arises either.
        #expect(PodcastShowMerge.liftingTwins([:], groups: groups)["nur-rss"] == nil)
    }

    /// The capsule exclusion of the seed asks the ADDRESS and not the copy.
    /// `origin` is set only locally, ABS never sets it, and the server
    /// mirroring carries capsules over like everything else, so the ABS
    /// twin comes back WITHOUT a mark. A filter per copy
    /// would let it run into a PUBLIC catalog search (the IDA incident).
    @Test("A mirrored capsule stays out also as an ABS twin")
    func mirroredCapsuleStaysOutThroughItsTwin() {
        var capsule = show("rss-kapsel", feed: "https://pinchflat.local/feed.xml")
        capsule.origin = "pinchflat"
        let twin = show("abs-kapsel", feed: "https://pinchflat.local/feed.xml")  // without origin
        #expect(PodcastShowMerge.seedGroups(abs: [twin], rss: [capsule]).isEmpty,
                "der unmarkierte Server-Zwilling der Kapsel kam durch")
        // Counter-check: the same show WITHOUT a mark stays in. Otherwise
        // the case could also be green because the seed lets nothing through.
        var plain = capsule
        plain.origin = nil
        #expect(PodcastShowMerge.seedGroups(abs: [twin], rss: [plain]).count == 1)
    }

    @Test("The seed folds a show from both pots into one")
    func seedFoldsAcrossPots() {
        let groups = PodcastShowMerge.seedGroups(
            abs: [show("abs", feed: "https://example.org/feed.xml")],
            rss: [show("rss", feed: "https://example.org/feed.xml"),
                  show("nur-rss", feed: "https://other.org/feed.xml")])
        #expect(groups.map { $0.first?.id } == ["abs", "nur-rss"])
    }

    // MARK: - What we OWN (the second question of the door)

    @Test("The subscription addresses are a set, and the spelling folds along")
    func normalizedFeedsFoldsSpelling() {
        let feeds = PodcastShowMerge.normalizedFeeds([
            show("a", feed: "https://www.Example.org/feed.xml/"),
            show("b", feed: "http://example.org/feed.xml?utm_source=x"),
            show("c", feed: "https://other.org/feed.xml"),
        ])
        #expect(feeds.count == 2, "zwei Schreibweisen desselben Feeds gelten als zwei Abos")
        #expect(feeds.contains(PodcastIdentity.normalizeFeedURL("https://other.org/feed.xml")))
    }

    /// Six places built the union „was wir besitzen" by hand,
    /// always over the same two full lists, always to pass it to
    /// `excludingSubscribed`. They agreed on what luck was:
    /// a set that lacks an address puts a show someone
    /// already follows back into their recommendations.
    @Test("Nobody builds the ownership union by hand any more", .needsTheSources)
    func nobodyBuildsTheOwnedUnionByHand() throws {
        let allowed = "Sources/ViewModels/PodcastShowSources.swift"
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let relative = SourceTree.relativePath(of: url)
            if relative == allowed { continue }
            // Whitespace collapsed, so that a line break in the middle of the
            // expression does not hide the find.
            let flat = try sourceText(relative)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if flat.contains(".shows + ABSPodcastProvider.shared.shows") { offenders.append(relative) }
        }
        #expect(offenders.isEmpty, "handgeschriebene Besitz-Vereinigung in: \(offenders)")
    }

    // MARK: - The count on the source text

    /// The intermediate quantity of the hand-written version. Whoever assembles the list
    /// again by hand needs it; whoever calls the rule does not.
    @Test("Nobody assembles the cross-source list by hand any more", .needsTheSources)
    func nobodyBuildsTheMergeByHand() throws {
        let allowed = ["Sources/Models/PodcastShowMerge.swift"]
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let relative = SourceTree.relativePath(of: url)
            if allowed.contains(relative) { continue }
            let text = try sourceText(relative)
            if text.contains("absFeeds") { offenders.append(relative) }
        }
        #expect(offenders.isEmpty,
                "handgeschriebene Fassung der Quellen-Vereinigung in: \(offenders.joined(separator: ", "))")
    }

    /// `activeShows` means „nicht archiviert" and knows nothing of the source
    /// switch. Exactly in this gap the three ungated copies
    /// landed. The count names per reader the reason why it reads it.
    @Test("activeShows is read in only two places, and both say why", .needsTheSources)
    func activeShowsHasTwoReadersWithReasons() throws {
        let expected: [String: String] = [
            "Sources/ViewModels/PodcastShowSources.swift":
                "das eine Tor: liest activeShows UND fragt den Quellenschalter davor",
            "Sources/Providers/PodcastRecommendationsStore.swift":
                "andere Frage: Saat der Empfehlungen. Faltet seit dem Entscheid vom 08.09.2026 "
                + "ueber PodcastShowMerge.seedGroups, aber OHNE Quellenschalter — „zeig mir diese "
                + "Quelle nicht\" ist nicht „vergiss, was ich dort gehoert habe\"",
        ]
        var found: Set<String> = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let relative = SourceTree.relativePath(of: url)
            let body = try sourceText(relative)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            // The explanation in the provider itself is the definition, not a reader.
            if body.contains("activeShows"), !body.contains("var activeShows") {
                found.insert(relative)
            }
        }
        #expect(found == Set(expected.keys),
                "neue oder verschwundene Leser von activeShows: \(found.symmetricDifference(Set(expected.keys)).sorted())")
    }
}
#endif
