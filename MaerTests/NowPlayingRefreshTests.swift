// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import UIKit
@testable import Maer

/// When the tick writes the lock screen again: on a changed field, and on
/// a drift of the time the system runs on (a stall, a jump no event
/// wrote); and the artwork is built anew for a new image only.
@MainActor
struct NowPlayingRefreshTests {
    private let fields = NowPlayingRefresh.Fields(title: "Buch", subtitle: "Kapitel 1", duration: 3600, rate: 1,
                                                  isLive: false, artwork: nil)

    @Test("ohne Schrieb und bei einem geaenderten Feld ist er faellig, bei laufender Zeit nicht")
    func aChangedFieldIsDue() {
        let written = NowPlayingRefresh.Written(fields: fields, elapsed: 100, at: 1_000)
        #expect(NowPlayingRefresh.isDue(last: nil, fields: fields, elapsed: 100, at: 1_000))
        #expect(!NowPlayingRefresh.isDue(last: written, fields: fields, elapsed: 110, at: 1_010),
                "ten seconds ran on as the system runs them on")
        var chapter = fields
        chapter.subtitle = "Kapitel 2"
        #expect(NowPlayingRefresh.isDue(last: written, fields: chapter, elapsed: 110, at: 1_010))
    }

    /// The system runs the time on from the last write; a stall leaves the
    /// real time behind it, and past the tolerance the tick writes anew.
    @Test("ein Stocken laesst die weitergelaufene Zeit abweichen: ueber der Toleranz ist der Schrieb faellig")
    func aDriftIsDue() {
        let written = NowPlayingRefresh.Written(fields: fields, elapsed: 100, at: 1_000)
        #expect(!NowPlayingRefresh.isDue(last: written, fields: fields, elapsed: 109.5, at: 1_010),
                "half a second off stays within the tolerance")
        #expect(NowPlayingRefresh.isDue(last: written, fields: fields, elapsed: 103, at: 1_010),
                "a stall of seven seconds is not written")
        #expect(NowPlayingRefresh.isDue(last: written, fields: fields, elapsed: 160, at: 1_010),
                "a jump forward no event wrote is not written")
        var fast = fields
        fast.rate = 2
        let atTwo = NowPlayingRefresh.Written(fields: fast, elapsed: 100, at: 1_000)
        #expect(!NowPlayingRefresh.isDue(last: atTwo, fields: fast, elapsed: 120, at: 1_010), "at rate 2 the time runs twice")
        var live = fields
        live.isLive = true
        let onAir = NowPlayingRefresh.Written(fields: live, elapsed: 100, at: 1_000)
        #expect(!NowPlayingRefresh.isDue(last: onAir, fields: live, elapsed: 0, at: 1_010), "a stream shows no running time")
        #expect(NowPlayingRefresh.driftTolerance == 1)
    }

    /// The info is written on every event; the artwork is built once per
    /// image, and a new image builds it anew.
    @Test("das Artwork wird einmal je Bild gebaut, ein neues Bild baut es neu")
    func aNewImageBuildsANewArtwork() {
        let model = PlayerViewModel(provider: TrackFileSizeTests.SizedProvider(original: false),
                                    localTracks: { _ in [:] }, isOnline: { true })
        let first = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        let second = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        model.artworkImage = first
        let before = model.artworkBuilds
        model.updateNowPlayingInfo()
        model.updateNowPlayingInfo()
        #expect(model.artworkBuilds == before + 1, "the same image built twice")
        model.artworkImage = second
        model.updateNowPlayingInfo()
        #expect(model.artworkBuilds == before + 2, "a new image kept the old artwork")
        #expect(model.lastNowPlaying?.fields.artwork == ObjectIdentifier(second))
    }
}
#endif
