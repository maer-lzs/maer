// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Die Kennung der App steht an EINER Stelle. Vorher setzte jede Aufrufstelle
/// sie von Hand, zwanzigmal und ueber drei Aliasse, und vier Wege (der Feed-Trichter, RSSProvider,
/// Transkripte, Pocket Casts) gingen ohne sie hinaus. Jetzt setzen die drei
/// Wege nach aussen sie, und nur `AppUserAgent` nennt den Kopf.
struct UserAgentFenceTests {
    private static func code(_ file: URL) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
    }

    @Test("Kennung: gesetzt, wenn keine da ist; eine vorhandene bleibt")
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

    /// Wer den Kopf nennt, setzt eine zweite Kennung; wer `applyIfMissing`
    /// ruft, ist ein Weg nach aussen und steht auf der Liste.
    nonisolated static let ways: Set<String> = ["HTTP.swift", "Retry.swift", "FileDownloader.swift"]

    @Test("Kennung: nur AppUserAgent nennt den Kopf, und genau die drei Wege setzen ihn", .needsTheSources)
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

    @Test("Kennung: jeder Weg setzt sie, bevor er fragt", .needsTheSources)
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

    /// A media asset asks its server itself. Only the one that asks a
    /// foreign service carries the identity; the rest are named here.
    nonisolated static let assetExceptions: [String: (count: Int, reason: String)] = [
        "PlayerViewModel.swift": (2, "playback: the stream belongs to the item's source, own servers carry their headers, and a station's stream is played as the platform's player asks for it"),
        "DownloadManager.swift": (1, "a local file is checked for playability, no network"),
        "LocalLibrary.swift": (2, "local files are read for their tags, no network"),
    ]

    @Test("Kennung: ein Medien-Asset an einem fremden Dienst traegt sie, die Ausnahmen sind benannt", .needsTheSources)
    func assetsCarryItOrAreNamed() throws {
        var found: [String: Int] = [:]
        var carrying: [String] = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try Self.code(file)
            let sites = text.components(separatedBy: "AVURLAsset(url:").count - 1
            guard sites > 0 else { continue }
            let name = file.lastPathComponent
            if text.contains("AVURLAssetHTTPUserAgentKey: AppUserAgent.value") { carrying.append(name) }
            else { found[name] = sites }
        }
        #expect(carrying == ["GutenbergWorks.swift"], "the one asset that asks a foreign service: \(carrying)")
        #expect(found == Self.assetExceptions.mapValues(\.count),
                "an asset without the identity and without a reason: \(found)")
    }
}
#endif
