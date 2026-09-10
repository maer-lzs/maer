// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Mär sync service is a carrier BEHIND the two seams, not beside
/// them. Three things hold that: the service's paths and its one header
/// are built in one file; the runners and the rules never name the
/// service; and the session is reached only by the two carriers and the
/// two factories, never by name from anywhere else. Comment lines do not
/// count.
struct MaerSyncDoorFenceTests {
    /// The one file that knows how the service is addressed.
    nonisolated static let addressHome = "MaerSyncClient.swift"

    /// The service's own path words. Other services have a `/v1/` of
    /// their own (the catalogue stock does), so the fence asks for the
    /// words only this service uses.
    nonisolated static let pathWords = ["v1/doc", "v1/changes", "v1/token", "v1/health"]

    /// Where the session may be named, each with its reason IN the entry.
    /// The two factories reach it through `MaerSyncCarriers.session`,
    /// which is the door's name, not the session's.
    nonisolated static let sessionStock: [String: (count: Int, reason: String)] = [
        "MaerSyncCarriers.swift": (14, "die Sitzung selbst, ihre zwei Dokumentfamilien, die FUENF Traeger darauf (Topf, Playlist, Wahlen, Anspruch, Statistik) und die Fabrik, die die eine baut"),
    ]

    /// The files that carry the rules and the runners of the pot and the
    /// claim. None of them may know the service exists.
    nonisolated static let blind = ["PodcastCloudSync.swift", "PlaybackClaimSync.swift", "PlaybackClaim.swift",
                                    "PlayerViewModel+Sync.swift"]

    /// Non-comment lines that contain the token.
    nonisolated static func lines(naming token: String, in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains(token)
            }.count
    }

    @Test("die Pfade des Dienstes entstehen in einer Datei, und nur sie liest das Zeichen")
    func addressesLiveInOneFile() throws {
        var pathFiles: Set<String> = []
        var tokenFiles: Set<String> = []
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in Self.pathWords where Self.lines(naming: word, in: text) > 0 {
                pathFiles.insert(file.lastPathComponent)
            }
            // Other services set a bearer header of their own, and other
            // accesses have a token too; what is this service's alone is
            // the call that puts its token on a request.
            if Self.lines(naming: "MaerSyncHeaders.authorize(", in: text) > 0 { tokenFiles.insert(file.lastPathComponent) }
        }
        #expect(pathFiles == [Self.addressHome], "the service's paths are built here: \(pathFiles.sorted())")
        #expect(tokenFiles == [Self.addressHome], "the service's header is put on here: \(tokenFiles.sorted())")
        #expect(Self.lines(naming: "v1/doc", in: "// the path is v1/doc\nlet p = \"v1/doc\"") == 1)
    }

    @Test("die Laeufer und die Regeln kennen den Dienst nicht")
    func runnersAndRulesAreBlind() throws {
        var offenders: [String] = []
        var seen = 0
        for file in ProjectFileIntegrityTests.sourceFiles() where Self.blind.contains(file.lastPathComponent) {
            seen += 1
            if Self.lines(naming: "MaerSync", in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(seen == Self.blind.count, "every blind file was found: \(seen) of \(Self.blind.count)")
        #expect(offenders.isEmpty, "these name the service beside the seam: \(offenders)")
    }

    @Test("die Sitzung wird nur von den Traegern und den Fabriken genannt")
    func theSessionIsNamedOnlyBehindTheSeam() throws {
        var offenders: [String] = []
        var named = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let count = Self.lines(naming: "MaerSyncSession", in: try String(contentsOf: file, encoding: .utf8))
            guard count > 0 else { continue }
            named += 1
            let allowed = Self.sessionStock[file.lastPathComponent]?.count ?? 0
            if count > allowed { offenders.append("\(file.lastPathComponent): \(count) > \(allowed)") }
        }
        #expect(named >= 1, "the fence still finds the session: \(named) files")
        #expect(offenders.isEmpty, "the session is reached past the seam: \(offenders)")
    }

    @Test("keine Adresse des Dienstes traegt das Zeichen, und ein Zeichen in der Adresse wird abgewiesen")
    func noAddressCarriesTheToken() throws {
        let access = MaerSyncAccess(baseURL: try #require(URL(string: "https://sync.example.test")), token: "the-secret-token")
        let addresses = [
            MaerSyncPaths.document(access.baseURL, kind: "stands", scope: ""),
            MaerSyncPaths.document(access.baseURL, kind: "claim", scope: "dev-a"),
            MaerSyncPaths.listing(access.baseURL, kind: "claim"),
            MaerSyncPaths.token(access.baseURL),
            MaerSyncPaths.health(access.baseURL),
            try #require(MaerSyncPaths.changes(access.baseURL)),
        ]
        for address in addresses {
            #expect(!address.absoluteString.contains(access.token), "the token rides in this address: \(address.absoluteString)")
            #expect(address.query?.contains("token") != true, "a token in the query: \(address.absoluteString)")
        }
        var request = URLRequest(url: addresses[0])
        MaerSyncHeaders.authorize(&request, access)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer the-secret-token")
        #expect(MaerSyncPaths.normalized("https://the-owner:the-secret-token@sync.example.test") == nil)
    }
}
#endif
