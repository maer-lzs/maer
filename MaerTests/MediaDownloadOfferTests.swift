// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// „Darf hier ueberhaupt geladen werden?" had no place, and the whole
/// tree asked „liegt es schon hier?" instead. In the normal case the two read
/// the same, and differently in exactly the cases that matter.
///
/// The trigger was a regression of mine: the delete gate learned to ask
/// whether WE fetched something, and so an imported local audiobook
/// no longer offered „Download loeschen" (correct) but „Save for Offline"
/// (wrong, and with the library provider for a file it does not
/// know). A dead offer traded for a pointless one.
struct MediaDownloadOfferTests {
    @Test("Only a source that CAN download gets the offer")
    func onlyADownloadableSourceIsOffered() {
        #expect(MediaDownloadOffer.isPossible([.downloadable]))
        #expect(MediaDownloadOffer.isPossible([.progressSync, .downloadable, .bookmarks]))
        // Imported local files: they are there, cannot be downloaded.
        #expect(!MediaDownloadOffer.isPossible([.alwaysLocal]))
        // Free catalogs and radio carry none at all.
        #expect(!MediaDownloadOffer.isPossible([]))
        #expect(!MediaDownloadOffer.isPossible([.remoteSearch]))
    }

    /// The providers themselves, so that the truth table above does not hang on
    /// invented sets: what the tree really carries.
    @MainActor
    @Test("The real providers answer as expected")
    func therealProvidersAnswerAsExpected() {
        #expect(!MediaDownloadOffer.isPossible(LocalProvider.shared.capabilities),
                "eine importierte Datei darf kein Download-Angebot bekommen")
        #expect(!MediaDownloadOffer.isPossible(FreeCatalogProvider.shared.capabilities))
        #expect(!MediaDownloadOffer.isPossible(RadioProvider.shared.capabilities))
        #expect(MediaDownloadOffer.isPossible(RSSProvider.shared.capabilities))
        #expect(MediaDownloadOffer.isPossible(SubsonicProvider.shared.capabilities))
        #expect(MediaDownloadOffer.isPossible(JellyfinProvider.shared.capabilities))
    }

    /// The stock: every place that OFFERS a download asks first.
    /// The call that starts the download is counted; whoever offers one
    /// without asking the question in the same branch stands out.
    @Test("No download offer without the question whether it works", .needsTheSources)
    func noOfferWithoutTheQuestion() throws {
        // These start a download WITHOUT offering it: they act on
        // a decision that has already been made.
        //
        // The detail page stood here first with the reason
        // „das Angebot entscheidet der Abschnitt". That was a CLAIM and not
        // measured: its last branch offered „Save Offline" unchecked. An
        // exception nobody has looked into is a hole with a justification.
        let actsWithoutOffering: [String: String] = [
            "Sources/ViewModels/PlayerViewModel.swift":
                "Selbstheilung: fragt `.downloadable` selbst, direkt daneben, und bietet nichts an",
            "Sources/Views/BookFeaturedCard.swift":
                "CardDownloadBadge zeigt die Ecke; sie fragt isDownloaded, und fuer eine "
                + "lokale Datei ist das richtig (liegt offline vor), also kein Angebot",
            "Sources/Views/Podcasts/PodcastComponents.swift":
                "dieselbe Karten-Ecke, plus die zwei Zweige, die die Frage stellen",
        ]
        var offersWithoutAsking: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        for url in SourceTree.files(under: root) where url.pathExtension == "swift" {
            let relative = SourceTree.relativePath(of: url)
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            guard code.contains(".download(item:") else { continue }
            if code.contains("MediaDownloadOffer.isPossible") { continue }
            if actsWithoutOffering[relative] != nil { continue }
            offersWithoutAsking.append(relative)
        }
        #expect(offersWithoutAsking.isEmpty,
                "startet einen Download, ohne zu fragen, ob die Quelle das kann: \(offersWithoutAsking)")
    }
}
#endif
