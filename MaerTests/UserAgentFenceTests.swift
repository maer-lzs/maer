// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The identity of the app stands in ONE place. Before, every call site set
/// it by hand, twenty times and across three aliases, and four paths (the feed funnel, RSSProvider,
/// transcripts, Pocket Casts) went out without it. Now the three
/// paths to the outside set it, and only `AppUserAgent` names the header.
struct UserAgentFenceTests {
    private static func code(_ file: URL) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
    }

    @Test("Identity: set when none is there; an existing one stays")
    func appliesOnlyWhenMissing() {
        var bare = URLRequest(url: URL(string: "https://example.org/feed")!)
        AppUserAgent.applyIfMissing(to: &bare)
        #expect(bare.value(forHTTPHeaderField: "User-Agent") == AppUserAgent.value)
        #expect(AppUserAgent.value.hasPrefix("Maer/") && AppUserAgent.value.contains("+https://maer.fm"),
                "MusicBrainz and Radio Browser require an identifying agent with a contact path")
        var named = URLRequest(url: URL(string: "https://example.org/feed")!)
        named.setValue("Probe/1", forHTTPHeaderField: "User-Agent")
        AppUserAgent.applyIfMissing(to: &named)
        #expect(named.value(forHTTPHeaderField: "User-Agent") == "Probe/1")
    }

    /// Whoever names the header sets a second identity; whoever calls `applyIfMissing`
    /// is a path to the outside and stands on the list.
    nonisolated static let ways: Set<String> = ["HTTP.swift", "Retry.swift", "FileDownloader.swift"]

    @Test("Identity: only AppUserAgent names the header, and exactly the three paths set it", .needsTheSources)
    func oneOwnerThreeWays() throws {
        var namesHeader: [String] = []
        var setters: Set<String> = []
        var read = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try Self.code(file)
            read += 1
            let name = file.lastPathComponent
            if name != "AppUserAgent.swift", text.contains("\"User-Agent\"") { namesHeader.append(name) }
            if text.contains("AppUserAgent.applyIfMissing(") { setters.insert(name) }
        }
        #expect(read > 100, "der Zaun hat die Quellen nicht gelesen, also misst er nichts: \(read)")
        #expect(namesHeader.isEmpty, "a second place names the header: \(namesHeader)")
        #expect(setters == Self.ways, "the ways out that set the identity: \(setters.sorted())")
    }

    @Test("Identity: every path sets it before it asks", .needsTheSources)
    func eachWaySetsItBeforeAsking() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func order(_ path: String, _ ask: String) throws {
            let text = try Self.code(root.appendingPathComponent(path))
            let set = try #require(text.range(of: "AppUserAgent.applyIfMissing("), "\(path)")
            let asked = try #require(text.range(of: ask), "\(path): \(ask)")
            #expect(set.lowerBound < asked.lowerBound, "\(path) asks before it names the app")
        }
        try order("Sources/Networking/Retry.swift", "session.data(for: request")
        try order("Sources/Networking/FileDownloader.swift", "session.downloadTask(with: request)")
        let http = try Self.code(root.appendingPathComponent("Sources/Networking/HTTP.swift"))
        let prepare = try #require(http.range(of: "static func prepare("))
        let setInPrepare = try #require(http.range(of: "AppUserAgent.applyIfMissing(to: &out)"))
        #expect(prepare.upperBound < setInPrepare.lowerBound)
        // Every way through the door starts with `prepare`.
        #expect(http.components(separatedBy: "= prepare(").count - 1 == 5,
                "webSocket, data, bytes, download and upload each prepare their request")
    }

    /// A media asset asks its server itself. Every asset that goes to the
    /// network carries the identity (the Gutenberg runtime, the playback);
    /// the ones that read a local file are named here.
    nonisolated static let assetExceptions: [String: (count: Int, reason: String)] = [
        "PlayerViewModel.swift": (1, "playback of a local file of a partly downloaded book, no network"),
        "LocalLibrary.swift": (2, "local files are read for their tags, no network"),
    ]

    @Test("Identity: every media asset on the network carries it, the local exceptions are named", .needsTheSources)
    func assetsCarryItOrAreNamed() throws {
        var found: [String: Int] = [:]
        var carrying: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try Self.code(file)
            let sites = text.components(separatedBy: "AVURLAsset(url:").count - 1
            guard sites > 0 else { continue }
            let name = file.lastPathComponent
            let carried = text.components(separatedBy: "AVURLAssetHTTPUserAgentKey: AppUserAgent.value").count - 1
            if carried > 0 { carrying.append(name) }
            if sites > carried { found[name] = sites - carried }
        }
        #expect(carrying.sorted() == ["GutenbergWorks.swift", "PlayerViewModel.swift"],
                "the assets that ask the network: \(carrying)")
        #expect(found == Self.assetExceptions.mapValues(\.count),
                "an asset without the identity and without a reason: \(found)")
    }
}
#endif
