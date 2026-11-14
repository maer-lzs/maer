// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Music comes from Subsonic OR Jellyfin, and WHICH one it is is answered by
/// `AppSession.musicProvider`: Jellyfin as soon as it is the only active
/// music source, otherwise Subsonic.
///
/// A general music surface must therefore not name a concrete server.
/// `MusicAlbumView` did so at THREE of eighteen places (both album downloads
/// and the random playback asked Subsonic outright), while the remaining
/// fifteen asked the configured provider. With a Jellyfin source
/// exactly these three bypassed the provider: the download was handed the
/// wrong provider, and the random playback asked Subsonic
/// for the titles of a `jf:` identifier.
///
/// The stock names the exceptions with a reason. They are exactly the two
/// SETTINGS PAGES, and there the concrete server is the subject itself.
struct MusicProviderDoorFenceTests {
    private func codeOf(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("No general surface names a concrete music server", .needsTheSources)
    func noGeneralSurfaceNamesAConcreteMusicServer() throws {
        let allowed: [String: String] = [
            "Sources/AppSession.swift":
                "die Tuer selbst: hier wird entschieden, WELCHER Server der Musikanbieter ist",
            "Sources/Providers/SubsonicProvider.swift": "der Anbieter selbst",
            "Sources/Providers/JellyfinProvider.swift": "der Anbieter selbst",
            "Sources/Views/SubsonicSourceView.swift":
                "die EINSTELLUNGSSEITE dieses Servers: Verbindung testen, Bibliotheken lesen, "
                + "jetzt abgleichen. Hier IST der konkrete Server die Sache",
            "Sources/Views/JellyfinSourceView.swift":
                "dieselbe Seite fuer Jellyfin, dieselbe Begruendung",
            "Sources/UITestSeed.swift":
                "die Saat der Journeys setzt einen bestimmten Server, weil sie ihn stellt",
        ]
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let relative = SourceTree.relativePath(of: url)
            if allowed[relative] != nil { continue }
            let code = try codeOf(relative)
            for needle in ["SubsonicProvider.shared", "JellyfinProvider.shared",
                           "subsonicProvider", "jellyfinProvider"] where code.contains(needle) {
                offenders.append("\(relative) (\(needle))")
            }
        }
        #expect(offenders.isEmpty,
                "eine allgemeine Flaeche nennt einen konkreten Musikserver: \(offenders)")
    }

    /// Cross-check, so that the stock above is not empty merely because the
    /// door has vanished: it really chooses between both, and the
    /// condition is the one the stock relies on.
    @Test("The door really chooses between both servers", .needsTheSources)
    func theDoorReallyChooses() throws {
        let code = try codeOf("Sources/AppSession.swift")
        #expect(code.contains("var musicProvider: any MusicProvider"))
        #expect(code.contains("JellyfinProvider.shared") && code.contains("SubsonicProvider.shared"),
                "die Tuer nennt nicht mehr beide Server, dann waehlt sie nichts")
        #expect(code.contains("jellyfinActive"),
                "die Wahl haengt nicht mehr an der aktiven Quelle")
    }

    /// Every question to the DEVICE's music source, counted at its
    /// SIGNATURE whoever the receiver is: `AppSession.shared`, a `session`,
    /// or a name bound to either. Counting the spelling
    /// `AppSession.shared.musicProvider` let `session.musicProvider` through
    /// (the search result in the library). The door per item, which is called
    /// with `(for:`, does not count.
    nonisolated static func deviceQuestions(in code: String) -> Int {
        code.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(IdQuestionDoorFenceTests.withoutComment($0)).replacing(#/"(?:[^"\\]|\\.)*"/#, with: "\"\"") }
            .joined(separator: "\n")
            // No `\b` after the name: under Unicode word rules
            // `musicProvider.genres` is ONE word, so the common form slipped by.
            .matches(of: #/\.\s*musicProvider(?![A-Za-z0-9_])(?!\s*\()/#).count
    }

    /// The class one floor further, and this time over ALL views.
    ///
    /// The fence above holds that no surface NAMES a concrete server.
    /// That leaves the other half open: a surface may ask
    /// `AppSession.shared.musicProvider`, and that answers „welche
    /// Musikquelle nutzt dieses GERAET". For a library list that is
    /// right. For a TITLE it is wrong, because the title carries its source
    /// in the identifier, and with two configured servers Subsonic wins.
    ///
    /// Measured and healed were **eleven places in FIVE files** (three each in
    /// `MixedMediaPage`, `MusicContinueCard` and `AddToPlaylistSheet`, one each
    /// in `MusicLibraryPages` and `Lyrics`); the twelfth is in
    /// `MusicAlbumView` and has been healed since 09.09. All with a visible
    /// consequence: a Jellyfin list got the wrong card and the wrong
    /// placeholder symbol, its random playback found no titles, its
    /// covers were missing, its downloads were not on the page, and
    /// „zur Playlist hinzufuegen" answered with „Nothing to add".
    ///
    /// The stock names what MAY STAY, with a reason per file, and it only
    /// falls. Listing the allowed call forms would be yesterday's mistake:
    /// a fence that knows forms guards only what it has already seen.
    @Test("no view asks the DEVICE for a title", .needsTheSources)
    func noViewAsksTheDeviceAboutATitle() throws {
        let stock: [String: (count: Int, reason: String)] = [
            "HomeView.swift":
                (1, "der Fortschritt der ganzen Musik-Bibliothek, eine Frage an das Geraet"),
            "MusicViewModel.swift":
                (1, "ein Griff fuer die Listen, die das Modell laedt (Alben, Regal, Kuenstler, Playlisten), "
                    + "bei zwei Servern den Satz, welcher nicht geantwortet hat, und ob hier ein Server da ist"),
            "MusicLibraryPages.swift":
                (5, "Seitenweises Blaettern, Genres (die Genre-Seite ueber EINEN Zugang), Regale, "
                    + "Zufallswiedergabe der Bibliothek"),
            "MusicView.swift":
                (1, "das Signal der eingestellten Quelle, dass ihre Bibliothek sich bewegt hat"),
            // AddToPlaylistSheet asks the server of the target
            // (`musicProvider(serving: .one(server))`), never the device any more: 2 → 0.
        ]
        // Artists and playlists carry their identifier with namespace
        // (`MusicArtist.itemId`, `MusicPlaylist.itemId`, set at the edge of the
        // provider); the artist page, the portrait and every
        // playlist identifier therefore ask the door, no raw number any more.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Views")
        var checked = 0
        var found: [String: Int] = [:]
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let code = try codeOf("Sources/Views/"
                                  + url.path.components(separatedBy: "Sources/Views/")[1])
            checked += 1
            let count = Self.deviceQuestions(in: code)
            if count > 0 { found[url.lastPathComponent] = count }
        }
        #expect(checked > 0, "der Zaun hat keine Ansicht gelesen, also misst er nichts")
        #expect(Self.deviceQuestions(in: "let music = session.musicProvider\n_ = music.allArtists()") == 1,
                "der Zaehler sieht die Geraete-Frage ueber eine Bindung, gleich welcher Empfaenger")
        #expect(Self.deviceQuestions(in: "_ = AppSession.shared\n    .musicProvider.genres()") == 1,
                "der Zaehler sieht sie ueber einen Umbruch")
        #expect(Self.deviceQuestions(in: "_ = session.musicProvider(for: id).genres()") == 0,
                "die Tuer je Eintrag zaehlt nicht")
        // BOTH directions, and the second is the silent one: if the stock locks
        // only upward, an entry keeps claiming that six calls are
        // fine, long after there are two. A reason that covers too much
        // is an exception nobody has looked into any more. If the
        // number falls, it is written back here, as at the growth fence.
        let drift = StockDrift.findings(counts: found, stock: stock.mapValues(\.count))
        #expect(drift.isEmpty,
                "eine Ansicht fragt das Geraet, wo die Kennung antwortet, oder der Bestand liegt ueber der Zaehlung: \(drift)")
        // Cross-check: the door that was healed to really exists, and
        // it routes by the identifier.
        let session = try codeOf("Sources/AppSession.swift")
        #expect(session.contains("func musicProvider(for itemId: String) -> any MusicProvider"))
        #expect(session.contains("MusicSourceRule.item(itemId"),
                "die Tuer fragt nicht mehr die eine Regel")
        let rule = try codeOf("Sources/Models/MusicSourceRule.swift")
        #expect(rule.contains("ItemNamespace.isJellyfin(itemId)"),
                "die Tuer leitet nicht mehr am Namensraum")
    }

    /// The same question for the LIBRARY, and the sentence next to it was
    /// measured wrongly: `coordinator.provider` is NOT the running session,
    /// but a `let` from the `init` that `AppSession` builds with the MAIN
    /// provider. So it answers no question about a title, and
    /// for a different reason than claimed so far: not because it
    /// switches, but because it NEVER changes. Exactly one surface may name
    /// it, and there the main provider is the subject itself.
    @Test("the main provider is asked only where it is meant", .needsTheSources)
    func theRunningSessionIsAskedOnlyWhereItIsMeant() throws {
        let allowed = "ABSSourceView.swift"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Views")
        var checked = 0
        var offenders: [String] = []
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let code = try codeOf("Sources/Views/"
                                  + url.path.components(separatedBy: "Sources/Views/")[1])
            checked += 1
            // Searched for in LOWER case, and that is no subtlety: the
            // red probe inserted `playerCoordinator.provider`, exactly
            // one of the four forms the class was measured on, and
            // the fence stayed green. A fence that also checks the spelling
            // guards the name and not the thing. The neighbouring fence in
            // `JellyfinBooksSurfaceTests` has always done it this way.
            guard code.lowercased().contains("coordinator.provider") else { continue }
            // The setup page of Audiobookshelf: there the
            // connection of the MAIN provider is checked and its queue
            // emptied. It IS the subject there.
            if url.lastPathComponent != allowed { offenders.append(url.lastPathComponent) }
        }
        #expect(checked > 0, "der Zaun hat keine Ansicht gelesen, also misst er nichts")
        #expect(offenders.isEmpty,
                "eine Ansicht fragt wieder den Haupt-Anbieter: \(offenders.sorted())")
    }

    /// And the question on which the finding hangs, at the protocol: both providers
    /// can answer it, so there was never a reason to name one of them.
    @Test("What the three places needed is in the protocol", .needsTheSources)
    func whatTheThreeSitesNeededIsInTheProtocol() throws {
        let code = try codeOf("Sources/Providers/MusicProvider.swift")
        #expect(code.contains("func songItems(forItemId itemId: String) async -> [LibraryItem]"),
                "songItems steht nicht mehr im Protokoll, dann braucht die Zufallswiedergabe wieder einen Server")
        for provider in ["Sources/Providers/SubsonicProvider.swift",
                         "Sources/Providers/JellyfinProvider.swift"] {
            #expect(try codeOf(provider).contains("func songItems(forItemId itemId: String)"),
                    "\(provider) erfuellt songItems nicht mehr")
        }
    }
}
#endif
