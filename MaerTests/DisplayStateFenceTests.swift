// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// What a surface shows says what is true: an unknown running time stays
/// unknown, a lasting refusal shows on every lock, and a state a picture
/// carries (the heart, the running ring) is named for VoiceOver too.
struct DisplayStateFenceTests {
    private func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    @Test("eine Playlist ohne angegebene Laufzeit zeigt keine 0:00, sondern nur die Titelzahl", .needsTheSources)
    func anUnknownRunningTimeStaysUnknown() throws {
        #expect(PlaylistPresentation.knownSeconds(nil) == nil, "no running time became a number")
        #expect(PlaylistPresentation.knownSeconds(0) == nil && PlaylistPresentation.knownSeconds(0.4) == nil,
                "nothing above zero became 0:00")
        #expect(PlaylistPresentation.knownSeconds(4332.7) == 4332)
        let card = try code("Sources/Views/Music/PlaylistCard.swift")
        #expect(card.contains("durationSeconds: PlaylistPresentation.knownSeconds(playlist.duration)"),
                "the server card reads the running time another way")
        #expect(!card.contains("Int(playlist.duration ?? 0)"), "the unknown running time turns into zero again")
    }

    /// Every lock asks the refusal, not only the show tiles.
    @Test("jedes Schloss fragt die dauerhafte Verweigerung, nicht nur die Sendungs-Kacheln", .needsTheSources)
    func everyLockAsksTheRefusal() throws {
        var bare: [String] = []
        var locks = 0
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = FetchAnswerTests.squeezed(text)
            for part in code.components(separatedBy: "PremiumLockBadge(isPremium:").dropFirst() {
                locks += 1
                if !part.prefix(160).contains("refused:") { bare.append("\(name): \(part.prefix(60))") }
            }
        }
        #expect(locks >= 3, "the fence found the locks it guards: \(locks)")
        #expect(bare.isEmpty, "a lock that does not ask the refusal: \(bare)")
        let grid = try code("Sources/Views/Podcasts/LatestEpisodesGrid.swift")
        #expect(grid.contains("subs.isAccessRefused(feedURL:"), "Latest Episodes does not ask the refusal")
        let card = try code("Sources/Views/Podcasts/PodcastComponents.swift")
        #expect(card.contains("refused: PodcastSubscriptions.shared.isAccessRefused(feedURL: feed)"),
                "the Continue card does not ask the refusal")
    }

    /// The heart and the running ring carry their state for VoiceOver, and
    /// the ring is one control.
    @Test("das Herz sagt Namen und Zustand, der laufende Ring ist ein Bauteil mit Namen und Fortschritt", .needsTheSources)
    func picturedStatesAreNamed() throws {
        let album = try code("Sources/Views/Music/MusicAlbumView.swift")
        let heart = try #require(album.range(of: "Image(systemName: starred ? \"heart.fill\" : \"heart\")"),
                                 "the heart is gone or spelled another way")
        let after = album[heart.upperBound...].prefix(400)
        #expect(after.contains(".accessibilityLabel(Text(\"Favorite\"))"), "the heart has no name")
        #expect(after.contains(".accessibilityAddTraits(starred ? .isSelected : [])"), "the heart does not say whether it is on")
        var rings: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources/Views"]) where name != "DownloadRing.swift" {
            // A bare ring, not the control that wraps it nor the shape beneath.
            let code = SyncContractFenceTests.stripped(text)
            let bareRings = code.components(separatedBy: "DownloadRing(fraction:").count
                - code.components(separatedBy: "CancelDownloadRing(fraction:").count
                - code.components(separatedBy: "UnifiedDownloadRing(fraction:").count + 1
            if bareRings > 0 { rings.append(name) }
        }
        #expect(rings.isEmpty, "a ring is built beside the one control: \(rings)")
        let ring = try code("Sources/Views/DownloadRing.swift")
        #expect(ring.contains(".accessibilityLabel(Text(\"Cancel Download\"))") && ring.contains(".accessibilityValue("),
                "the ring control has no name or no progress")
    }
}
#endif
