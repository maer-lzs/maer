// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The spelling of a source namespace is one fact and lives in
/// `ItemNamespace`. Views, view models, CarPlay, the models and the
/// networking layer ask it; they never spell a prefix themselves. A
/// provider may check its OWN namespace, nobody else's. The router
/// (`AppSession`) is the named exception: it IS the map.
struct SourcePrefixFenceTests {
    /// The one file that spells the namespaces, and the router.
    nonisolated static let namedExceptions = ["ItemNamespace.swift", "AppSession.swift"]
    nonisolated static let prefixes = ["rss:", "abspod:", "sub:", "jf:", "radio:", "local:", "lva:", "lv:", "gut:", "jam:"]

    /// The prefixes a file spells in `hasPrefix("…")` calls. Pure over text.
    nonisolated static func spelledPrefixes(in text: String) -> [String] {
        var found: [String] = []
        for prefix in prefixes {
            let needle = "hasPrefix(\"\(prefix)"
            found += Array(repeating: prefix, count: text.components(separatedBy: needle).count - 1)
        }
        return found
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static func files(under folder: String) -> [URL] {
        SourceTree.files(under: root.appendingPathComponent("Sources/\(folder)"))
            .filter { $0.pathExtension == "swift" }
    }

    /// The files directly in `Sources`: the app, the router, the seed.
    private static func rootFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Sources"),
                                                    includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    @Test("Views, ViewModels, CarPlay, Models, Networking and the root spell no source prefix", .needsTheSources)
    func surfacesSpellNoPrefix() throws {
        var offenders: [String] = []
        var files = try Self.rootFiles()
        for folder in ["Views", "ViewModels", "CarPlay", "Models", "Networking"] { files += Self.files(under: folder) }
        try #require(files.count > 100, "the finder must still find the sources: \(files.count)")
        for file in files where !Self.namedExceptions.contains(file.lastPathComponent) {
            let spelled = Self.spelledPrefixes(in: try String(contentsOf: file, encoding: .utf8))
            if !spelled.isEmpty { offenders.append("\(file.lastPathComponent): \(spelled)") }
        }
        #expect(offenders.isEmpty, "these surfaces spell a namespace themselves: \(offenders)")
        // Red probe on the checker.
        #expect(Self.spelledPrefixes(in: "if id.hasPrefix(\"rss:\") || id.hasPrefix(\"abspod:\") {") == ["rss:", "abspod:"])
        #expect(Self.spelledPrefixes(in: "if ItemNamespace.isPodcastEpisode(id) {").isEmpty)
    }

    /// Which namespaces a provider file may spell: its own. Bridges name
    /// their second namespace (the podcast twins).
    nonisolated static let ownNamespaces: [String: Set<String>] = [
        "SubsonicProvider.swift": ["sub:"],
        "JellyfinProvider.swift": ["jf:"],
        "RSSProvider.swift": ["rss:"],
        "ABSPodcastProvider.swift": ["abspod:", "rss:"],
        "PodcastSubscriptions.swift": ["rss:"],
        "RadioProvider.swift": ["radio:"],
        "LocalProvider.swift": ["local:"],
        "FreeCatalogProvider.swift": ["lva:", "lv:", "gut:", "jam:"],
        "PlayQueue.swift": ["radio:"],
    ]

    @Test("A provider spells only its own source", .needsTheSources)
    func providersSpellOnlyTheirOwnSource() throws {
        var offenders: [String] = []
        for file in Self.files(under: "Providers") {
            let spelled = Set(Self.spelledPrefixes(in: try String(contentsOf: file, encoding: .utf8)))
            let allowed = Self.ownNamespaces[file.lastPathComponent] ?? []
            let foreign = spelled.subtracting(allowed)
            if !foreign.isEmpty { offenders.append("\(file.lastPathComponent): \(foreign.sorted())") }
        }
        #expect(offenders.isEmpty, "these providers spell a namespace that is not theirs: \(offenders)")
    }
}
#endif
