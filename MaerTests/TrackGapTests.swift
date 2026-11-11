// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A track that cannot be built is a track that does not load: what is
/// before it plays, playback holds at its start, the title is not
/// finished, and nothing after it plays.
@MainActor
struct TrackGapTests {
    @Test("eine Spur ohne Adresse in der Mitte: bis dorthin, dort halten, nie fertig", .needsAudio)
    func aTrackWithoutAnAddressHolds() async throws {
        let tone = try TickWorkTests().tone(seconds: 1)
        defer { try? FileManager.default.removeItem(at: tone) }
        // Tracks 0 and 2 lie here, track 1 has no address at all.
        let model = PlayerViewModel(provider: MockProvider(), localTracks: { _ in [0: tone, 2: tone] }, isOnline: { true })
        let tracks = (0..<3).map { index in
            ABSAudioTrack(index: index, startOffset: Double(index), duration: 1,
                          contentUrl: "/gap/\(index)", metadata: nil)
        }
        let book = LibraryItemDetail(id: "gap-\(UUID().uuidString)",
                                     media: LibraryItemMedia(metadata: nil, duration: 3, chapters: nil, tracks: tracks),
                                     userMediaProgress: nil)
        await model.load(item: book)
        #expect(model.player?.items().count == 1, "the queue holds a track after the gap: \(model.player?.items().count ?? -1)")
        model.play(caller: "witness")
        for _ in 0..<40 where model.isPlaying { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!model.isPlaying, "playback went on past the gap")
        #expect(!model.isFinished, "the title counts as finished at a track that could not be built")
        #expect(abs(model.currentTime - 1) < 0.01, "playback did not hold at the start of the gap: \(model.currentTime)")
        model.stop()
    }
}
#endif
