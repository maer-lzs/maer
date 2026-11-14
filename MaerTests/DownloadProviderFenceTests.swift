// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A download gets the provider OF THE TITLE, never a named one.
///
/// Two findings of the same class in one day, in two tabs:
///
/// - `MusicAlbumView` passed the Subsonic provider as fixed to both album
///   downloads. With a Jellyfin library that was the wrong server.
/// - `PodcastComponents` passed the RSS provider as fixed to two episode
///   downloads (continue card and download button). An ABS episode carries an
///   `abspod:` id, the RSS store is an exact index over its
///   own guids, so it does not find it. The guard behind it returned
///   silently. The button did nothing and said nothing.
///
/// Both times the right version stood in the SAME file: `PodcastComponents`
/// long since asks `router.provider(item.id)` in a third place, and in
/// `MusicAlbumView` fifteen of the eighteen handles asked the configured
/// provider. It was never an opinion, it was a remnant.
struct DownloadProviderFenceTests {
    private func codeOf(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// The stock is ZERO: no download names a provider by name.
    /// Allowed is what comes from the title or from the running session
    /// (`router.provider(id)`, a derived `provider`, the provider of the
    /// coordinator). Every fixed name is forbidden.
    @Test("No download names a provider by name", .needsTheSources)
    func noDownloadNamesAProvider() throws {
        let named = ["AppSession.shared.rssProvider", "AppSession.shared.absPodcastProvider",
                     "AppSession.shared.subsonicProvider", "AppSession.shared.jellyfinProvider",
                     "AppSession.shared.musicProvider", "AppSession.shared.localProvider",
                     "SubsonicProvider.shared", "JellyfinProvider.shared",
                     "RSSProvider.shared", "ABSPodcastProvider.shared"]
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let path = SourceTree.relativePath(of: url)
            let flat = try codeOf(path)
            for range in flat.ranges(of: "download(item:") {
                // The argument extends to the closing bracket of the
                // call; a window suffices, because provider: follows
                // directly. Asked LOCALLY, not in the neighborhood.
                let to = flat.index(range.upperBound, offsetBy: 160, limitedBy: flat.endIndex) ?? flat.endIndex
                let window = String(flat[range.upperBound..<to])
                guard let arg = window.range(of: "provider:") else { continue }
                let argEnd = window.index(arg.upperBound, offsetBy: 60, limitedBy: window.endIndex) ?? window.endIndex
                let argument = String(window[arg.upperBound..<argEnd])
                for needle in named where argument.contains(needle) {
                    offenders.append("\(path) → \(needle)")
                }
            }
        }
        #expect(offenders.isEmpty, "ein Download bekommt einen benannten Anbieter: \(offenders)")
    }

    /// „Detail holen, dann laden" is ONE action, and it has one place.
    /// Six surfaces wrote the three steps by hand, and they did not
    /// agree: two asked the coordinator for a provider that answers for
    /// the library and not for the title, and ALL SIX
    /// swallowed a failed fetch with `try?` and a
    /// `return`. The button did nothing and said nothing, while the
    /// automatic loop next door catches the error and reports it.
    ///
    /// Whoever still calls the loader directly now ALREADY HOLDS the detail: it
    /// acts on a decision that has already been made.
    @Test("Whoever loads from an id takes the one action", .needsTheSources)
    func startingFromAnIdUsesTheOneAction() throws {
        let holdsTheDetail: [String: String] = [
            "Sources/ViewModels/PlayerViewModel.swift":
                "Selbstheilung und Spur-Reparatur: das Item liegt vor, es wird nichts geholt",
            "Sources/Views/BookDetailScreen.swift":
                "die Seite hat ihr Detail geladen und reicht den Anbieter weiter, DER es geladen hat",
            "Sources/Views/Music/MusicAlbumView.swift":
                "zweimal: die Album-Seite haelt ihr Detail, der Anbieter kommt aus der Kennung",
            "Sources/Views/Podcasts/PodcastHelpers.swift":
                "die Auto-Download-Schleife: eine Massenhandlung mit eigener Fehlermeldung je Folge",
        ]
        // `DownloadManager` is NOT in the list: its own call in
        // `startDownload` has no receiver („download(item:" without a dot)
        // and so the finder does not notice it at all. That is right, and
        // writing it down here is cheaper than making the finder less
        // precise.
        var callers: Set<String> = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let path = SourceTree.relativePath(of: url)
            let code = try codeOf(path)
            // The wrapper itself is not a caller.
            let calls = code.replacingOccurrences(of: "func download(item:", with: "func download(DECL:")
            if calls.contains(".download(item:") { callers.insert(path) }
        }
        #expect(callers == Set(holdsTheDetail.keys),
                "jemand laedt aus einer Kennung, ohne die eine Handlung zu nehmen: \(callers.symmetricDifference(Set(holdsTheDetail.keys)).sorted())")
    }

    /// And the half that belongs to the person: a failed fetch
    /// is REPORTED. The red probe revealed that my first fence did not check this at
    /// all. I could have emptied the `catch` and everything would have stayed
    /// green, so the fence would have let through exactly the error
    /// the action is built against.
    @Test("The one action reports a failed fetch", .needsTheSources)
    func theOneActionReportsAFailedFetch() throws {
        let code = try codeOf("Sources/Networking/DownloadManager.swift")
        guard let action = code.range(of: "func startDownload(itemId: String, kind: DownloadKind) async") else {
            Issue.record("die Handlung wurde umbenannt"); return
        }
        let to = code.index(action.lowerBound, offsetBy: 700, limitedBy: code.endIndex) ?? code.endIndex
        let body = String(code[action.lowerBound..<to])
        #expect(body.contains("} catch {"), "der Abruf faengt nichts mehr")
        #expect(body.contains("phase[itemId] = .failed("),
                "ein fehlgeschlagener Abruf sagt nichts mehr: der Knopf taete wieder nichts")
        #expect(body.contains("Logger."), "der Fehlschlag hinterlaesst keine Spur im Geraete-Log")
    }

    /// Counter-check, so the stock above is not empty because there
    /// are no downloads any more: there are still the thirteen calls, and
    /// the door that gets the provider from the id exists.
    @Test("The download places still exist, and the door too", .needsTheSources)
    func theCallSitesAndTheDoorStillExist() throws {
        var sites = 0
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            sites += try codeOf(SourceTree.relativePath(of: url)).ranges(of: "download(item:").count
        }
        // Were thirteen before „Detail holen, dann laden" became one action;
        // six of them collapsed into `startDownload`. The
        // number stands here as a floor against vanishing, not as a target.
        #expect(sites >= 8, "die Download-Aufrufe sind verschwunden, der Bestand oben prueft nichts")
        #expect(try codeOf("Sources/Views/ItemRouterEnvironment.swift").contains("var provider:"),
                "der Router beantwortet die Anbieter-Frage nicht mehr")
    }
}
#endif
