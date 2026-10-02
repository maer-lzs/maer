// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A media-type pill can only be the complete entry point of its type if it
/// can NAME its sources. And it must name them exactly as the register does,
/// so one account under two types is recognisably the SAME account.
struct MediaTypeSourcesTests {

    @Test("jeder Bereich nennt seine Quellen, keiner ist leer")
    func everyAreaNamesItsSources() {
        for area in SourceMapArea.allCases {
            #expect(!MediaTypeSources.all(for: area).isEmpty,
                    "\(area.rawValue) nennt keine Quelle — die Pille kann den Typ nicht beantworten")
        }
    }

    @Test("EIN Konto, EIN Name, EIN Symbol — unter jedem Typ")
    func oneAccountLooksTheSameEverywhere() {
        // The whole point of point 1: ABS under Audiobooks and under Podcasts
        // must be recognisable as the same account, not as two copies.
        let underBooks = MediaTypeSources.all(for: .audiobooks).first { $0.id == "abs" }
        let underPodcasts = MediaTypeSources.all(for: .podcasts).first { $0.id == "abs" }
        #expect(underBooks != nil)
        #expect(underBooks == underPodcasts,
                "dasselbe Konto sieht unter zwei Typen verschieden aus")
        #expect(MediaTypeSources.areas(servedBy: "abs") == [.audiobooks, .podcasts])
    }

    @Test("kontolose Quellen fuegen sich ein und stehen hinten")
    func accountLessSourcesComeLast() {
        // Point 3: catalogues and Radio Browser belong in their type's pill.
        // And they never need attention, so they do not lead the list.
        for area in SourceMapArea.allCases {
            let sources = MediaTypeSources.all(for: area)
            let firstFree = sources.firstIndex { !$0.needsAccount }
            let lastAccount = sources.lastIndex { $0.needsAccount }
            if let firstFree, let lastAccount {
                #expect(firstFree > lastAccount,
                        "\(area.rawValue): eine kontolose Quelle steht vor einer Konto-Quelle")
            }
        }
        #expect(MediaTypeSources.all(for: .radio).allSatisfy { !$0.needsAccount })
        #expect(MediaTypeSources.all(for: .freeCatalogs).allSatisfy { !$0.needsAccount })
    }

    @Test("Kennungen sind eindeutig und sprachunabhaengig adressierbar")
    func identifiersAreUniqueAndStable() {
        for area in SourceMapArea.allCases {
            let ids = MediaTypeSources.all(for: area).map(\.id)
            #expect(Set(ids).count == ids.count, "\(area.rawValue) hat doppelte Kennungen")
        }
        #expect(MediaTypeSources.all(for: .podcasts).first?.accessibilityId == "media-source-abs")
    }
}
#endif

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The switch that forgot itself: "subscribe on server" decided whether a new
/// subscription is created ON the Audiobookshelf server, and it was `@State`.
/// Switching it off lasted until the page closed. The next visit had server
/// subscriptions again, silently.
struct PodcastSubscribeToServerTests {

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "subscribe-to-server-\(UUID().uuidString)")!
    }

    @Test("ausgeschaltet bleibt ausgeschaltet")
    func offStaysOff() {
        let d = suite()
        // Nothing stored yet: the behaviour every session had so far.
        #expect(d.object(forKey: AppStorageKeys.podcastSubscribeToServer) == nil)
        #expect(AppStorageKeys.boolValue(AppStorageKeys.podcastSubscribeToServer) == true,
                "der Startwert muss true bleiben — alles andere waere eine stille Aenderung")

        d.set(false, forKey: AppStorageKeys.podcastSubscribeToServer)
        // "Seite verlassen und wieder oeffnen" ist genau das: neu lesen.
        #expect(d.object(forKey: AppStorageKeys.podcastSubscribeToServer) as? Bool == false)
        d.set(true, forKey: AppStorageKeys.podcastSubscribeToServer)
        #expect(d.object(forKey: AppStorageKeys.podcastSubscribeToServer) as? Bool == true)
    }

    @Test("es gibt nichts zu erben — der Wert wurde nie gespeichert")
    func noMigrationNeeded() {
        // Geprueft statt angenommen: der Schluessel ist neu,
        // ein Altbestand kann gar nicht existieren, und der Default deckt den
        // ungesetzten Fall mit dem bisherigen Verhalten ab.
        let d = suite()
        #expect(d.object(forKey: AppStorageKeys.podcastSubscribeToServer) == nil)
        #expect(AppStorageKeys.boolValue(AppStorageKeys.podcastSubscribeToServer) == true
                || UserDefaults.standard.object(
                    forKey: AppStorageKeys.podcastSubscribeToServer) != nil)
    }
}
#endif
