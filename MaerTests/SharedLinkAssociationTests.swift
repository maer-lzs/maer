// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The two halves of a universal link: the app claims maer.fm, and the file
/// on maer.fm names this app and only the path of the shared links. Both
/// follow `SharedLink` and the project file, so neither can drift alone.
struct SharedLinkAssociationTests {
    static let association = "site/.well-known/apple-app-site-association"

    private static func plist(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent(name))
        let read = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(read as? [String: Any])
    }

    /// Team and bundle id of the target that signs with `Maer.entitlements`,
    /// one pair for all its configurations.
    private static func appIdentity() throws -> (team: String, bundle: String) {
        let project = try String(contentsOf: SourceTree.root.appendingPathComponent("Maer.xcodeproj/project.pbxproj"),
                                 encoding: .utf8)
        let blocks = project.components(separatedBy: "buildSettings = {").dropFirst()
            .map { String($0.prefix(while: { $0 != "}" })) }
            .filter { $0.contains("CODE_SIGN_ENTITLEMENTS = Maer.entitlements;") }
        func value(_ key: String, in block: String) -> String? {
            guard let line = block.split(separator: "\n").first(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(key + " = ")
            }) else { return nil }
            return line.split(separator: "=", maxSplits: 1)[1]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t;\""))
        }
        let pairs = Set(blocks.map { "\(value("DEVELOPMENT_TEAM", in: $0) ?? "")|\(value("PRODUCT_BUNDLE_IDENTIFIER", in: $0) ?? "")" })
        #expect(blocks.count >= 2, "the precondition: the app's configurations sign with Maer.entitlements (\(blocks.count))")
        #expect(pairs.count == 1, "the app's configurations name different teams or bundles: \(pairs)")
        let parts = try #require(pairs.first).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        try #require(parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty, "no team or bundle: \(parts)")
        return (parts[0], parts[1])
    }

    @Test("Die App beansprucht genau maer.fm fuer ihre Links, das Widget nichts", .needsTheProjectFile)
    func theAppClaimsTheHostOfTheLinks() throws {
        let app = try Self.plist("Maer.entitlements")
        let domains = app["com.apple.developer.associated-domains"] as? [String]
        #expect(domains == ["applinks:\(SharedLink.host)"], "the app claims other domains: \(String(describing: domains))")
        let widget = try Self.plist("MaerWidgets.entitlements")
        #expect(!widget.keys.contains("com.apple.developer.associated-domains"), "the widget claims links it cannot open")
    }

    @Test("Die Apple-Datei nennt genau diese App und nur den Pfad der Links", .needsTheSite, .needsTheProjectFile)
    func theAssociationNamesThisAppAndThePath() throws {
        let identity = try Self.appIdentity()
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent(Self.association))
        let read = try JSONSerialization.jsonObject(with: data)
        let file = try #require(read as? [String: Any])
        #expect(Set(file.keys) == ["applinks"], "the file claims more than links: \(file.keys.sorted())")
        let applinks = try #require(file["applinks"] as? [String: Any])
        #expect(Set(applinks.keys) == ["details"], "\(applinks.keys.sorted())")
        let details = try #require(applinks["details"] as? [[String: Any]])
        try #require(details.count == 1, "the file names \(details.count) apps")
        let appIDs = details[0]["appIDs"] as? [String]
        #expect(appIDs == ["\(identity.team).\(identity.bundle)"], "the file names another app: \(String(describing: appIDs))")
        let components = try #require(details[0]["components"] as? [[String: Any]])
        for component in components {
            #expect(Set(component.keys).isSubset(of: ["/", "comment"]),
                    "a path is narrowed or widened by another key: \(component.keys.sorted())")
        }
        let paths = components.compactMap { $0["/"] as? String }
        #expect(paths.count == components.count, "a component names no path")
        #expect(Set(paths) == SharedLink.paths && paths.count == SharedLink.paths.count,
                "the file opens other paths than the app reads: \(paths)")
        // The link the app writes falls under one of them.
        let link = try #require(SharedLink.url(for: .show(feedURL: "https://feeds.example.org/x.xml", .init())))
        #expect(link.host == SharedLink.host)
        #expect(paths.contains(link.path(percentEncoded: true)), "\(link)")
    }
}
#endif
