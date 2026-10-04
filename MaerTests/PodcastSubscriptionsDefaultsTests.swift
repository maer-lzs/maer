// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every store the podcast subscriptions touch takes the subscriptions'
/// own `defaults`: a store built with a defaults suite of its own sees and
/// writes nothing in the app's domain.
@MainActor
@Suite(.serialized)
struct PodcastSubscriptionsDefaultsTests {
    /// Adds `value` to the string list under `key` in the app's domain for
    /// the length of `body`, then puts the list back as it was.
    private func withStandardEntry(_ key: String, _ value: String, _ body: () async throws -> Void) async rethrows {
        let before = UserDefaults.standard.stringArray(forKey: key)
        UserDefaults.standard.set((before ?? []) + [value], forKey: key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await body()
    }

    @Test("die Premium-Pruefung liest Sperre und Markierung aus den uebergebenen defaults, nicht aus denen der App")
    func thePremiumTestReadsTheGivenDefaults() async {
        let feed = "https://feeds.example.org/\(UUID().uuidString)/feed.xml"
        let key = PodcastSubscriptions.feedKey(feed)
        let suite = "premium-defaults-\(UUID().uuidString)"
        let own = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(!PodcastSubscriptions.isPremiumFeed(feed, defaults: own), "the precondition: a free feed")
        await withStandardEntry(AppStorageKeys.blockedFeedKeys, key) {
            #expect(PodcastSubscriptions.isPremiumFeed(feed), "the precondition: the app's domain holds the block")
            #expect(!PodcastSubscriptions.isPremiumFeed(feed, defaults: own), "the block came from the app's domain")
        }
        await withStandardEntry(AppStorageKeys.premiumMarkedFeeds, key) {
            #expect(PodcastSubscriptions.isPremiumFeed(feed), "the precondition: the app's domain holds the mark")
            #expect(!PodcastSubscriptions.isPremiumFeed(feed, defaults: own), "the mark came from the app's domain")
        }
    }

    @Test("ein Speicher mit eigenen defaults liest die offenen Uebernahmen nicht aus denen der App")
    func aStoreReadsItsOwnPendingAdoptions() async throws {
        let feedKey = "pending-\(UUID().uuidString)"
        FeedAdoptionPending.mark(feedKey: feedKey, feedURL: "https://feeds.example.org/x.xml", reason: .dismissed)
        defer { FeedAdoptionPending.clear(feedKey: feedKey) }
        #expect(FeedAdoptionPending.pending()[feedKey] != nil, "the precondition: the app's domain holds the entry")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subs-defaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "subs-defaults-\(UUID().uuidString)"
        let own = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let subs = PodcastSubscriptions(fileURL: folder.appendingPathComponent("podcast_subscriptions.json"),
                                        database: MaerDatabase(path: folder.appendingPathComponent("maer.sqlite").path),
                                        defaults: own, isTheApp: false)
        await subs.ensureLoaded()
        #expect(subs.feedsNotFollowed[feedKey] == nil, "the store read the app's pending adoptions")
    }

    /// The class, asked of the source: every call from the subscriptions to
    /// a function that takes `defaults:` passes it on.
    @Test("jeder Aufruf einer Funktion mit defaults aus dem Abo-Speicher reicht seine defaults weiter", .needsTheSources)
    func everyCallPassesTheDefaults() throws {
        let store = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/PodcastSubscriptions.swift"), encoding: .utf8))
        let pending = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/FeedAdoptionPending.swift"), encoding: .utf8))
        let offenders = Self.callsWithoutDefaults(in: store, declaredIn: [("", store), ("FeedAdoptionPending.", pending)])
        #expect(!Self.declaredWithDefaults(in: store).isEmpty, "the fence found no function that takes defaults")
        #expect(offenders == Self.namedExceptions, "calls without defaults outside the named one: \(offenders)")
        // Calibration: the shape the store had before.
        let before = "func a(x: Int, defaults: UserDefaults = .standard) {}\nfunc b() { a(x: 1) }\nfunc c() { a(x: 1, defaults: d) }"
        #expect(Self.callsWithoutDefaults(in: before, declaredIn: [("", before)]) == ["a(x: 1)"])
    }

    /// The one call without the store's defaults, with its reason:
    /// `fetchOutcome` runs off the main actor without a store, `UserDefaults`
    /// cannot be sent into it, so a channel block it finds is noted in the
    /// app's domain; a store built for a test fetches through
    /// `_testFeedFetcher` and never reaches it. Held in both directions.
    nonisolated static let namedExceptions = ["noteFeedBlocked(feedURL.absoluteString)"]

    /// The names of the functions in `code` that take `defaults:`.
    nonisolated static func declaredWithDefaults(in code: String) -> Set<String> {
        var names: Set<String> = []
        for match in code.matches(of: #/func (\w+)\(([^)]*)\)/#) where match.2.contains("defaults: UserDefaults") {
            names.insert(String(match.1))
        }
        return names
    }

    /// Every call in `code` to a function declared with `defaults:` in one of
    /// `declaredIn` (with the prefix it is called by) whose arguments lack
    /// `defaults:`, as written. Declarations are no calls.
    nonisolated static func callsWithoutDefaults(in code: String, declaredIn: [(prefix: String, code: String)]) -> [String] {
        var found: [String] = []
        let chars = Array(code)
        for (prefix, declaring) in declaredIn {
            for name in declaredWithDefaults(in: declaring).sorted() {
                let needle = Array(prefix + name + "(")
                var i = 0
                while i + needle.count <= chars.count {
                    guard Array(chars[i..<(i + needle.count)]) == needle else { i += 1; continue }
                    let before = i == 0 ? " " : chars[i - 1]
                    let head = String(chars[max(0, i - 5)..<i])
                    let attached = before.isLetter || before.isNumber || before == "_" || (prefix.isEmpty && before == "." && !head.hasSuffix("Self."))
                    if attached || head.hasSuffix("func ") { i += needle.count; continue }
                    var depth = 0
                    var j = i + needle.count - 1
                    repeat {
                        if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1 }
                        j += 1
                    } while depth > 0 && j < chars.count
                    let call = String(chars[i..<j])
                    if !call.contains("defaults:") { found.append(call.split(whereSeparator: \.isWhitespace).joined(separator: " ")) }
                    i = j
                }
            }
        }
        return found
    }
}
#endif
