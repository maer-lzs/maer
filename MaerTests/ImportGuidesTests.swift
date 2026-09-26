// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The import guides promise only what a source gives, end in the right
/// action, and tick themselves only when an import brought something.
struct ImportGuidesTests {
    @Test("Jede Anleitung endet in der richtigen Handlung")
    func actions() {
        #expect(ImportGuide.applePodcasts.action == .pickFile(.applePodcasts))
        #expect(ImportGuide.overcast.action == .pickFile(.opml))
        #expect(ImportGuide.otherOPML.action == .pickFile(.opml))
        #expect(ImportGuide.antennaPod.action == .pickFile(.antennaPod))
        #expect(ImportGuide.pocketCasts.action == .signIn(.pocketCasts))
        #expect(ImportGuide.spotify.action == .none)
    }

    @Test("Was eine Quelle nicht hergibt, wird nicht versprochen")
    func honestCarries() {
        #expect(ImportGuide.otherOPML.carries.subscriptions && !ImportGuide.otherOPML.carries.positions)
        #expect(ImportGuide.pocketCasts.carries.positions && !ImportGuide.pocketCasts.carries.moments)
        #expect(ImportGuide.spotify.carries == ImportGuide.Carries(subscriptions: false, positions: false, playedMarks: false, moments: false))
        for guide in ImportGuide.allCases where guide.action != .none {
            #expect(guide.carries.subscriptions, "\(guide) imports nothing?")
        }
        // The moments flag agrees with what the import actually records.
        #expect(ImportGuide.pocketCasts.carries.moments == ForeignSource.pocketCasts.carriesMoments)
        #expect(ImportGuide.applePodcasts.carries.moments == ForeignSource.applePodcasts.carriesMoments)
    }

    @Test("Jede Anleitung mit Handlung hat Schritte, Spotify hat nur den Satz warum")
    func steps() {
        for guide in ImportGuide.allCases {
            if guide.action == .none {
                #expect(guide.steps.isEmpty && !guide.notes.isEmpty, "\(guide)")
            } else {
                #expect(!guide.steps.isEmpty, "\(guide)")
            }
        }
        #expect(ImportGuide.applePodcasts.steps.contains { $0.contains(ImportGuide.appleLibraryFile) })
        // TF-8: quitting Podcasts comes before the copy, or the newest
        // states stay behind in the side file.
        let apple = ImportGuide.applePodcasts.steps
        let quit = apple.firstIndex { $0.contains("Quit Podcasts") }
        let copy = apple.firstIndex { $0.contains(ImportGuide.appleLibraryFile) }
        #expect(quit != nil && copy != nil && quit! < copy!, "quit before copy: \(apple)")
        #expect(ImportGuide.appleLibraryPath.hasSuffix("groups.com.apple.podcasts/Documents"))
        #expect(ImportGuide.antennaPod.steps.contains { $0.contains("Backup & restore") })
        #expect(ImportGuide.overcast.steps.contains { $0.contains("All data") })
    }

    /// The password sentence is ONE key: the guide carries it as its own
    /// note sentence, and the sign-in sheet renders the same constant. A
    /// second wording on either surface would drift.
    @Test("Der Pocket-Casts-Passwortsatz ist ein Schluessel an beiden Flaechen")
    func pocketCastsPrivacyLineIsShared() throws {
        #expect(ImportGuide.pocketCasts.notes.contains(ImportGuide.pocketCastsPrivacyLine))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sheet = try String(contentsOf: root.appendingPathComponent("Sources/Views/Podcasts/ForeignImportSheet.swift"), encoding: .utf8)
        #expect(sheet.contains("ImportGuide.pocketCastsPrivacyLine"))
        #expect(!sheet.contains("are sent to Pocket Casts only"), "the sheet carries its own wording of the sentence")
    }

    @Test("Das Haekchen ist gemessen: nur ein Import, der etwas brachte, setzt es")
    func doneIsMeasured() {
        ImportGuidesDone._resetForTest()
        defer { ImportGuidesDone._resetForTest() }
        #expect(!ImportGuidesDone.isDone(.overcast))
        ImportGuidesDone.mark(.opml)
        #expect(ImportGuidesDone.isDone(.overcast))
        #expect(ImportGuidesDone.isDone(.otherOPML))
        #expect(!ImportGuidesDone.isDone(.applePodcasts))
        #expect(!ImportGuidesDone.isDone(.spotify))
    }
}
#endif
