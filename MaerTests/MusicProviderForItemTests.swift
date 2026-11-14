// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// `musicProvider` answers „welche Musikquelle benutzt dieses Geraet",
/// and with two active servers Subsonic wins for now. That is the right
/// answer for a library list and the wrong one for a title that
/// carries its source in the identifier.
///
/// The album page is also reached from the FULL PLAYER (source page jump).
/// A running `jf:` album could therefore open it while the
/// configured answer was Subsonic, and every question about that identifier went
/// to a server that had never seen it: no titles, no star, no
/// album details.
@MainActor
struct MusicProviderForItemTests {
    @Test("The identifier decides, not the setting")
    func theIdDecidesNotTheSetting() {
        let session = AppSession.shared
        #expect(session.musicProvider(for: "jf:album:1") as AnyObject === JellyfinProvider.shared,
                "eine jf-Kennung muss zu Jellyfin, egal welche Quelle eingestellt ist")
        #expect(session.musicProvider(for: "sub:album:1") as AnyObject === SubsonicProvider.shared)
        #expect(session.musicProvider(for: "sub:song:7") as AnyObject === SubsonicProvider.shared)
    }

    /// Without a music namespace there is nothing to decide, and then the
    /// configured source is the only sensible answer. Without this case
    /// the door could point at a fixed server and the case above
    /// would still be green.
    @Test("Without a namespace the configured source answers")
    func withoutANamespaceTheConfiguredSourceAnswers() {
        let session = AppSession.shared
        #expect(session.musicProvider(for: "maer-playlist-42") as AnyObject
                === session.musicProvider as AnyObject)
        #expect(session.musicProvider(for: "") as AnyObject === session.musicProvider as AnyObject)
    }

    /// The stock: the album page no longer asks the CONFIGURED source.
    /// Sixteen lines did, and four of them even bound it beforehand to
    /// a local `music`: the file showed the pattern itself and still meant
    /// the wrong source.
    @Test("The album page no longer asks the configured source", .needsTheSources)
    func thealbumPageNoLongerAsksTheConfiguredSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let code = try String(contentsOf: root.appendingPathComponent("Sources/Views/Music/MusicAlbumView.swift"),
                              encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        // The one allowed mention is the door itself, with the identifier.
        let asksTheDevice = code.components(separatedBy: "AppSession.shared.musicProvider").count - 1
        let asksTheItem = code.components(separatedBy: "AppSession.shared.musicProvider(for:").count - 1
        #expect(asksTheDevice == asksTheItem,
                "die Seite fragt die eingestellte Quelle wieder ohne Kennung")
        #expect(asksTheItem == 1, "die Tuer steht nicht mehr genau einmal")
    }
}
#endif
