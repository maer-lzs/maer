// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A feed address that carries access, or belongs to a private feed, goes
/// to no directory.
struct FeedAddressStaysHomeTests {

    private final class Asked {
        var addresses: [String] = []
    }

    private func show(_ feedURL: String) -> PodcastShow {
        PodcastShow(id: "feed:\(PodcastIdentity.feedKey(feedURL))", title: "Home", author: nil, artworkURL: nil,
                    description: nil, feedURL: feedURL, episodes: [])
    }

    @Test("eine Feed-Adresse mit Geheimnis geht nicht an das Verzeichnis",
          arguments: ["https://paid.example/feed.xml?token=abc123",
                      "https://paid.example/feed.xml?show=7&freebie=xyz",
                      "https://user:secret@paid.example/feed.xml",
                      "https://user@paid.example/feed.xml"])
    func anAddressWithASecretIsNotSent(address: String) async {
        let asked = Asked()
        let answer = await PodcastSubscriptions.historyAdditions(of: show(address), browsed: false) { sent in
            asked.addresses.append(sent)
            return []
        }
        #expect(asked.addresses.isEmpty, "the directory was sent \(asked.addresses.count) address")
        #expect(answer == nil, "not asked is no finding")
    }

    @Test("eine freie Feed-Adresse wird gefragt")
    func aFreeAddressIsAsked() async throws {
        let address = "https://free.example/feed.xml?page=2"
        try #require(!PodcastSubscriptions.staysHome(address), "the free address counts as private here")
        let asked = Asked()
        let answer = await PodcastSubscriptions.historyAdditions(of: show(address), browsed: true) { sent in
            asked.addresses.append(sent)
            return []
        }
        #expect(asked.addresses == [address])
        #expect(answer?.isEmpty == true)
    }

    @Test("die Regel: ein Geheimnis in der Adresse oder von Hand als bezahlt markiert bleibt, eine freie Adresse geht")
    func theRule() throws {
        let name = "stays-home-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let free = "https://free.example/feed.xml"
        let marked = "https://marked.example/feed.xml"
        #expect(!PodcastSubscriptions.staysHome(free, defaults: defaults))
        #expect(PodcastSubscriptions.staysHome("https://paid.example/f?token=abc", defaults: defaults))
        #expect(PodcastSubscriptions.staysHome("https://u:p@paid.example/f", defaults: defaults))
        #expect(!PodcastSubscriptions.staysHome(marked, defaults: defaults))
        defaults.set([PodcastIdentity.feedKey(marked)], forKey: AppStorageKeys.premiumMarkedFeeds)
        #expect(PodcastSubscriptions.staysHome(marked, defaults: defaults))
        #expect(!PodcastSubscriptions.staysHome(free, defaults: defaults), "a marking of one feed holds another back")
        // A mirrored feed is never premium, but a secret in its address stays one.
        let mirrored = "https://mirror.example/feed.xml?token=abc"
        defaults.set([PodcastIdentity.feedKey(mirrored)], forKey: AppStorageKeys.pinchflatMirroredFeedKeys)
        #expect(PodcastSubscriptions.staysHome(mirrored, defaults: defaults))
    }

    @Test("der Export haelt auch eine Adresse mit Anmeldung vor dem Host zurueck")
    func theExportHoldsAnAddressWithUserInfoBack() {
        let split = OPMLExport.partition(
            shows: [("Free", "https://free.example/feed.xml"), ("Login", "https://u:p@paid.example/feed.xml"),
                    ("Token", "https://paid.example/feed.xml?key=abc")],
            isPremium: { _ in false })
        #expect(split.safe.map(\.title) == ["Free"])
        #expect(split.excluded.map(\.title) == ["Login", "Token"])
    }

    @Test("nur ein Weg sendet eine Feed-Adresse an das Verzeichnis, und er fragt die Regel vor dem Senden; der Knopf steht unter derselben Regel",
          .needsTheSources)
    func oneWayOutAndItAsksFirst() throws {
        let root = SourceTree.root.appendingPathComponent("Sources")
        var callers: [String] = []
        var senders: [String] = []
        for file in SourceTree.files(under: root) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            if code.contains(".episodes(feedURL:") { callers.append(file.lastPathComponent) }
            if code.contains("byfeedurl") { senders.append(file.lastPathComponent) }
        }
        #expect(callers == ["PodcastSubscriptions.swift"], "the directory's episode list is asked from \(callers)")
        #expect(senders == ["PodcastDirectory.swift"], "a feed address is sent to the directory from \(senders)")
        let store = try String(contentsOf: root.appendingPathComponent("Providers/PodcastSubscriptions.swift"), encoding: .utf8)
        #expect(store.components(separatedBy: "try await ask(").count - 1 == 1, "the directory is asked in another place")
        let head = try #require(store.range(of: "static func historyAdditions("))
        let guardAt = try #require(store.range(of: "guard !staysHome(show.feedURL, defaults: defaults) else {",
                                               range: head.upperBound..<store.endIndex))
        let askAt = try #require(store.range(of: "try await ask(show.feedURL)", range: head.upperBound..<store.endIndex))
        #expect(guardAt.lowerBound < askAt.lowerBound, "the address is sent before the rule is asked")
        let page = try String(contentsOf: root.appendingPathComponent("Views/Podcasts/PodcastShowView.swift"), encoding: .utf8)
        #expect(page.contains("if let show = liveShow, PodcastSubscriptions.mayAskDirectory(for: show.feedURL) {"))
    }
}
#endif
