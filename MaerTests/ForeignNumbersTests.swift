// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A huge finite number from outside (a chapter JSON, archive.org, a
/// server's chapter end) reaches no conversion to whole seconds: `Int(_:)`
/// on 1e300 stops the app.
struct ForeignNumbersTests {
    @Test("Foreign numbers: a chapter mark 1e300 drops out, the ordinary ones stay")
    func aHugeChapterMarkIsLeftOut() throws {
        let json = #"{"chapters":[{"startTime":0,"title":"A"},{"startTime":1e300,"title":"B"},{"startTime":-5,"title":"C"},{"startTime":60,"title":"D"}]}"#
        let chapters = try #require(RSSProvider.chapters(from: Data(json.utf8), duration: 120))
        #expect(chapters.map(\.title) == ["A", "D"], "a mark that is no length stayed: \(chapters.map(\.title))")
        #expect(chapters.map(\.end) == [60, 120])
        let none = #"{"chapters":[{"startTime":1e300}]}"#
        #expect(RSSProvider.chapters(from: Data(none.utf8), duration: 120) == nil)
    }

    @Test("Foreign numbers: whole seconds, minutes and remainders from huge or non-finite lengths are 0")
    func theSinksTakeNoHugeNumber() {
        for raw in [1e300, -1e300, .infinity, -.infinity, .nan] {
            #expect(PodcastDuration.wholeSeconds(raw) == 0, "\(raw)")
            #expect(ProgressMark.minutesLeft(raw) == 0, "\(raw)")
            #expect(DurationText.length(seconds: raw) == DurationText.length(minutes: 0), "\(raw)")
        }
        #expect(PodcastDuration.wholeSeconds(3_725.9) == 3_725)
        #expect(ProgressMark.minutesLeft(61) == 2)
        #expect(DurationText.length(seconds: 3_600) == DurationText.length(minutes: 60))
    }

    @Test("Foreign numbers: a length from archive.org that is none counts as unknown")
    func anArchiveLengthThatIsNoLength() {
        #expect(FreeCatalog.fileLength("1e300") == nil)
        #expect(FreeCatalog.fileLength("99999999999999999999:00:00") == nil)
        #expect(FreeCatalog.fileLength("640.61") == 640.61)
        #expect(FreeCatalog.fileLength("10:40") == 640)
    }
}
#endif
