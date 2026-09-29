// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Broken chapter metadata (Armageddon repro) must not produce nonsense
/// chapter labels / negative "min left". ChapterModel drops untrustworthy
/// chapters and only reports a current chapter that actually contains the time.
struct ChapterModelTests {

    private func ch(_ id: Int, _ start: Double, _ end: Double) -> ABSChapter {
        ABSChapter(id: id, start: start, end: end, title: "C\(id)")
    }

    private func track(_ i: Int, _ duration: Double, title: String? = nil) -> ABSAudioTrack {
        ABSAudioTrack(index: i, startOffset: nil, duration: duration, contentUrl: "https://x/\(i).mp3",
                      metadata: ABSFileMetadata(size: nil, title: title))
    }
    private func detail(chapters: [ABSChapter]?, tracks: [ABSAudioTrack]?, duration: Double? = nil) -> LibraryItemDetail {
        LibraryItemDetail(id: "lva:album", media: LibraryItemMedia(metadata: nil, duration: duration,
                                                                    chapters: chapters, tracks: tracks),
                          userMediaProgress: nil)
    }

    @Test("Die Spurenliste der Album-Seite: Kapitel wenn genannt, sonst eine je Spur mit ihrem Namen, sonst leer und benannt (E89)")
    func albumTrackListHasAnEndStateForEveryAnswer() {
        // A server album states chapters: they are the list.
        let stated = MusicAlbumView.trackList(of: detail(chapters: [ch(0, 0, 100), ch(1, 100, 200)], tracks: [track(0, 100), track(1, 100)]))
        #expect(stated.chapters.map(\.id) == [0, 1] && stated.source == "chapters")
        // A catalogue release states no chapters, its songs are the tracks
        // (red probe of the old page: it read only the chapters and got []).
        let release = MusicAlbumView.trackList(of: detail(chapters: nil, tracks: [track(0, 120, title: "Intro"), track(1, 200, title: "Neuroses")]))
        #expect(release.source == "tracks")
        #expect(release.chapters.map(\.title) == ["Intro", "Neuroses"])
        #expect(release.chapters.map(\.start) == [0, 120])
        #expect(release.chapters.last?.end == 320, "the duration is the sum of the tracks when the detail states none")
        // Nothing at all: empty, said as none, never the loading state.
        let empty = MusicAlbumView.trackList(of: detail(chapters: [], tracks: []))
        #expect(empty.chapters.isEmpty && empty.source == "none")
        // A book's parts without names keep "Part N of M".
        let parts = ChapterModel.trackChapters([track(0, 100), track(1, 100)], duration: 200)
        #expect(parts.map(\.title).allSatisfy { !$0.isEmpty && $0 != "Intro" })
    }

    @Test("Valid contiguous chapters are all kept, in order")
    func validKept() {
        let raw = [ch(0, 0, 100), ch(1, 100, 200), ch(2, 200, 300)]
        let v = ChapterModel.validated(raw, duration: 300)
        #expect(v.map(\.id) == [0, 1, 2])
    }

    @Test("TF4: BookFeaturedCard.chapterTitle memo helper resolves the current chapter (nil past the end / no inputs)")
    func featuredCardChapterTitle() {
        let raw = [ch(0, 0, 100), ch(1, 100, 200), ch(2, 200, 300)]
        #expect(BookFeaturedCard.chapterTitle(raw: raw, currentTime: 150, duration: 300) == "C1")
        #expect(BookFeaturedCard.chapterTitle(raw: raw, currentTime: nil, duration: 300) == nil)
        #expect(BookFeaturedCard.chapterTitle(raw: [], currentTime: 150, duration: 300) == nil)
        #expect(BookFeaturedCard.chapterTitle(raw: nil, currentTime: 150, duration: 300) == nil)
        // Past the last real chapter (coverage-fallback book) → nil, not a phantom.
        #expect(BookFeaturedCard.chapterTitle(raw: raw, currentTime: 5000, duration: 300) == nil)
    }

    @Test("Zero-length / reversed chapters are dropped")
    func zeroLengthDropped() {
        let raw = [ch(0, 0, 100), ch(1, 100, 100), ch(2, 200, 150), ch(3, 200, 300)]
        let v = ChapterModel.validated(raw, duration: 300)
        #expect(v.map(\.id) == [0, 3])
    }

    @Test("Overlapping chapters: the overlapper is dropped")
    func overlapDropped() {
        // ch1 (50–250) overlaps ch0 (0–100) → dropped; ch2 (100–200) fits.
        let raw = [ch(0, 0, 100), ch(1, 50, 250), ch(2, 100, 200)]
        let v = ChapterModel.validated(raw, duration: 300)
        #expect(v.map(\.id) == [0, 2])
    }

    @Test("Out-of-range chapters (start past end / end beyond duration) are dropped")
    func outOfRangeDropped() {
        let raw = [ch(0, 0, 100), ch(1, 100, 5000), ch(2, 9000, 9100), ch(3, -10, 50)]
        let v = ChapterModel.validated(raw, duration: 300)
        // ch1 end beyond duration, ch2 start past duration, ch3 negative start → all dropped.
        #expect(v.map(\.id) == [0])
    }

    @Test("Unknown duration (0): only span/overlap checks apply")
    func unknownDuration() {
        let raw = [ch(0, 0, 100), ch(1, 100, 99999)]
        let v = ChapterModel.validated(raw, duration: 0)
        #expect(v.map(\.id) == [0, 1])
    }

    @Test("current(at:) finds the containing chapter, nil in gaps / past the end")
    func currentLookup() {
        let v = [ch(0, 0, 100), ch(1, 100, 200)]
        #expect(ChapterModel.current(at: 50, in: v)?.id == 0)
        #expect(ChapterModel.current(at: 150, in: v)?.id == 1)
        #expect(ChapterModel.current(at: 100, in: v)?.id == 1)   // boundary belongs to next
        #expect(ChapterModel.current(at: 250, in: v) == nil)     // past the end
        #expect(ChapterModel.current(at: 0, in: []) == nil)      // no chapters
    }

    @Test("A gap between valid chapters yields nil (omit) rather than a wrong chapter")
    func gapYieldsNil() {
        // After dropping the broken middle chapter a 100–200 gap remains.
        let raw = [ch(0, 0, 100), ch(1, 100, 50), ch(2, 200, 300)]
        let v = ChapterModel.validated(raw, duration: 300)
        #expect(v.map(\.id) == [0, 2])
        #expect(ChapterModel.current(at: 150, in: v) == nil)
    }

    // MARK: - Coverage + track fallback

    private func trk(_ i: Int, _ start: Double, _ dur: Double) -> ABSAudioTrack {
        ABSAudioTrack(index: i, startOffset: start, duration: dur, contentUrl: "f\(i)", metadata: nil)
    }

    @Test("coversBook: reliable at >=90%, unreliable below / empty")
    func coverage() {
        #expect(ChapterModel.coversBook([ch(0, 0, 100), ch(1, 900, 1000)], duration: 1000) == true)
        #expect(ChapterModel.coversBook([ch(0, 0, 100), ch(1, 800, 850)], duration: 1000) == false)
        #expect(ChapterModel.coversBook([], duration: 1000) == false)
    }

    @Test("resolved: chapters that cover the book are kept (not a fallback)")
    func resolvedReliable() {
        let r = ChapterModel.resolved(chapters: [ch(0, 0, 500), ch(1, 500, 1000)], tracks: [], duration: 1000)
        #expect(r.isFallback == false)
        #expect(r.chapters.map(\.id) == [0, 1])
    }

    // MARK: - Parts (file navigation) vs real chapters

    @Test("chaptersMirrorTracks: one aligned chapter per track mirrors the files")
    func mirrorTrue() {
        let tracks = [trk(0, 0, 100), trk(1, 100, 100), trk(2, 200, 100)]
        let chapters = [ch(0, 0, 100), ch(1, 100, 200), ch(2, 200, 300)]
        #expect(ChapterModel.chaptersMirrorTracks(chapters, tracks: tracks, duration: 300))
    }

    @Test("chaptersMirrorTracks: a different count does NOT mirror (real chapters)")
    func mirrorFalseCount() {
        let tracks = [trk(0, 0, 150), trk(1, 150, 150)]
        let chapters = [ch(0, 0, 100), ch(1, 100, 200), ch(2, 200, 300)]   // 3 ≠ 2 tracks
        #expect(!ChapterModel.chaptersMirrorTracks(chapters, tracks: tracks, duration: 300))
    }

    @Test("resolved: multi-file whose chapters mirror the files → parts (Teil), fallback")
    func resolvedMirrorIsParts() {
        let tracks = [trk(0, 0, 100), trk(1, 100, 100), trk(2, 200, 100)]
        // A covering, file-aligned server chapter list. Must still read as parts.
        let chapters = [ch(0, 0, 100), ch(1, 100, 200), ch(2, 200, 300)]
        let r = ChapterModel.resolved(chapters: chapters, tracks: tracks, duration: 300)
        #expect(r.isFallback == true)
        #expect(r.chapters.count == 3)
    }

    @Test("resolved: multi-file with genuine cross-file chapters stays real (Kapitel)")
    func resolvedGenuineMultiFileChapters() {
        let tracks = [trk(0, 0, 150), trk(1, 150, 150)]   // 2 files
        let chapters = [ch(0, 0, 100), ch(1, 100, 200), ch(2, 200, 300)]   // 3 real chapters, cover
        let r = ChapterModel.resolved(chapters: chapters, tracks: tracks, duration: 300)
        #expect(r.isFallback == false)
        #expect(r.chapters.count == 3)
    }

    @Test("resolved: music song-chapters mirror tracks but are kept (not parts)")
    func resolvedMusicKeepsSongs() {
        // Each song is one track; its chapters mirror the tracks. For music that
        // must stay real (song titles), never relabel to 'Part N'.
        let tracks = [trk(0, 0, 100), trk(1, 100, 100), trk(2, 200, 100)]
        let chapters = [ch(0, 0, 100), ch(1, 100, 200), ch(2, 200, 300)]
        let r = ChapterModel.resolved(chapters: chapters, tracks: tracks, duration: 300, isMusic: true)
        #expect(r.isFallback == false)
        #expect(r.chapters.count == 3)
    }

    @Test("resolved: partial chapters + multi-track -> one chapter per track (mp3 case)")
    func resolvedMultiTrack() {
        let tracks = [trk(0, 0, 300), trk(1, 300, 300), trk(2, 600, 400)]
        let r = ChapterModel.resolved(chapters: [ch(0, 0, 100)], tracks: tracks, duration: 1000)
        #expect(r.isFallback == true)
        #expect(r.chapters.map(\.start) == [0, 300, 600])
        #expect(r.chapters.last?.end == 1000)
    }

    @Test("resolved: partial chapters + single file -> chapters + remaining (m4b case)")
    func resolvedSingleFile() {
        let r = ChapterModel.resolved(chapters: [ch(0, 0, 100), ch(1, 100, 200)],
                                      tracks: [trk(0, 0, 1000)], duration: 1000)
        #expect(r.isFallback == true)
        #expect(r.chapters.count == 3)               // 2 chapters + "remaining"
        #expect(r.chapters.last?.start == 200)
        #expect(r.chapters.last?.end == 1000)
    }

    @Test("resolved: 90% coverage (last chapter END) is the cutoff")
    func resolvedBoundary() {
        let tracks = [trk(0, 0, 500), trk(1, 500, 500)]
        // last END at 900 (90%) → reliable; at 890 (89%) → fallback.
        #expect(ChapterModel.resolved(chapters: [ch(0, 0, 100), ch(1, 100, 900)],
                                      tracks: tracks, duration: 1000).isFallback == false)
        #expect(ChapterModel.resolved(chapters: [ch(0, 0, 100), ch(1, 100, 890)],
                                      tracks: tracks, duration: 1000).isFallback == true)
    }

    @Test("resolved: empty chapters + multi-track -> track fallback")
    func resolvedEmptyMultiTrack() {
        let r = ChapterModel.resolved(chapters: [], tracks: [trk(0, 0, 300), trk(1, 300, 300)], duration: 600)
        #expect(r.isFallback == true)
        #expect(r.chapters.count == 2)
    }

    // MARK: - Media-type-aware coverage (book vs podcast fixtures)

    /// The SAME partial-coverage chapters: a BOOK gets the fallback/rest marker,
    /// a PODCAST keeps them as-is (segment markers are legitimate there).
    @Test("T9b: partial coverage — book falls back, podcast is kept as-is")
    func partialCoverageByMediaType() {
        let raw = [ch(0, 0, 100), ch(1, 100, 300)]   // ends at 300 of 1000 = 30%
        let book = ChapterModel.resolved(chapters: raw, tracks: [trk(0, 0, 1000)], duration: 1000,
                                         isPodcast: false)
        #expect(book.isFallback == true)              // book → fallback (rest marker)
        #expect(book.chapters.count == 3)

        let podcast = ChapterModel.resolved(chapters: raw, tracks: [trk(0, 0, 1000)], duration: 1000,
                                            isPodcast: true)
        #expect(podcast.isFallback == false)          // podcast → as-is
        #expect(podcast.chapters.map(\.id) == [0, 1]) // NO rest marker appended
    }

    @Test("T9b: podcast with NO chapters stays empty (no track fallback)")
    func podcastNoChapters() {
        let r = ChapterModel.resolved(chapters: [], tracks: [trk(0, 0, 500), trk(1, 500, 500)],
                                      duration: 1000, isPodcast: true)
        #expect(r.isFallback == false)
        #expect(r.chapters.isEmpty)
    }

    /// Displays must derive the current chapter from the VALIDATED list, not
    /// the raw server chapters. "Letzte Flotte" shape: chapters cover only the
    /// first ~30% of the book; past that, the raw `last(where: t >= start)` names
    /// a phantom chapter, while validated `current` correctly returns nil.
    @Test("V6: raw chapters name a phantom chapter past coverage; validated does not")
    func v6CoverageFallbackChapterLabel() {
        let raw = [ch(0, 0, 100), ch(1, 100, 300)]   // covers 30% of a 1000s book
        // The old bug (raw): position 500 → last chapter whose start <= 500 is chapter 1.
        #expect(raw.last(where: { 500 >= $0.start })?.id == 1)
        // The fix (validated + current): 500 is past the last end → nil.
        let validated = ChapterModel.validated(raw, duration: 1000)
        #expect(ChapterModel.current(at: 500, in: validated) == nil)
        // Inside a real chapter it still resolves correctly.
        #expect(ChapterModel.current(at: 150, in: validated)?.id == 1)
    }

    // NOTE: these assert LOCALE-INDEPENDENT facts (positions, times, counts).
    // The marker titles are localized ("from"→"ab", "Part N of M"→"Teil N von M").

    @Test("T9d: single-file tail marks are labelled by their start time")
    func timeMarkLabelledByPosition() {
        let r = ChapterModel.resolved(chapters: [ch(0, 0, 100)], tracks: [trk(0, 0, 1000)], duration: 1000)
        #expect(r.isFallback == true)
        // timeLabel(100) == "1:40". The time is format, not localized.
        #expect(r.chapters.last?.title.contains("1:40") == true)
    }

    @Test("T9d: track fallback is one entry per track, named (not empty)")
    func trackFallbackNaming() {
        let r = ChapterModel.resolved(chapters: [ch(0, 0, 100)],
                                      tracks: [trk(0, 0, 500), trk(1, 500, 500)], duration: 1000)
        #expect(r.isFallback == true)
        #expect(r.chapters.count == 2)                       // one per track
        #expect(r.chapters.first?.title.isEmpty == false)    // named "Part 1 of 2"/"Teil 1 von 2"
    }

    @Test("T9d: a large m4b tail gets 15-minute jump marks, not one lump")
    func timeMarksForLargeTail() {
        // Real chapters cover 0..600 of a 3600s book; the 50-min tail gets marks.
        let r = ChapterModel.resolved(chapters: [ch(0, 0, 300), ch(1, 300, 600)],
                                      tracks: [trk(0, 0, 3600)], duration: 3600)
        #expect(r.isFallback == true)
        let marks = Array(r.chapters.dropFirst(2))           // after the 2 real chapters
        #expect(marks.count >= 3)                            // 3000s / 900s ≈ 3–4 marks
        #expect(marks.first?.start == 600)                   // starts at the coverage end
        #expect(marks.first?.title.contains("10:00") == true) // timeLabel(600) == "10:00"
    }

    @Test("X23: one selector label — tracks for music, parts for fallback, chapters otherwise")
    func selectorLabel() {
        // Keys, not localized values. Locale-independent.
        #expect(ChapterModel.selectorLabel(isMusic: true, isFallback: false)
                == String(localized: "Tracks"))
        #expect(ChapterModel.selectorLabel(isMusic: true, isFallback: true)
                == String(localized: "Tracks"))          // music wins over fallback
        #expect(ChapterModel.selectorLabel(isMusic: false, isFallback: true)
                == String(localized: "Parts"))
        #expect(ChapterModel.selectorLabel(isMusic: false, isFallback: false)
                == String(localized: "Chapters"))
    }
}
#endif
