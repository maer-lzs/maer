// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// The ONE audiobook detail page: the server page is the form, a
/// catalog title enters through a second door. The acceptance mark is
/// that the SERVER page stays unchanged.
struct BookDetailEntryTests {

    private func seite() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/BookDetailScreen.swift"),
            encoding: .utf8)
    }

    /// The server entry continues to demand its LibraryViewModel as
    /// mandatory: no call site can silently drop it. The
    /// catalog entry does without.
    @Test("both doors exist, and the server door keeps requiring its model", .needsTheSources)
    func bothDoorsStand() throws {
        let text = try seite().split(whereSeparator: \.isWhitespace).joined()
        #expect(text.contains("init(entry:LibraryEntry,coordinator:PlayerCoordinator,libraryViewModel:LibraryViewModel)"),
                "die Server-Tuer hat ihr Pflicht-Modell verloren")
        #expect(text.contains("init(catalogItem:LibraryItem,coordinator:PlayerCoordinator)"),
                "die Katalog-Tuer ist wieder zu")
    }

    /// What differs is resolved PER IMAGE from the identifier,
    /// never remembered at opening. The same rule that kept the show page
    /// honest at cold start.
    @Test("the difference depends on the identifier, resolved per image", .needsTheSources)
    func theDifferenceHangsOnTheId() throws {
        let text = try seite().split(whereSeparator: \.isWhitespace).joined()
        #expect(text.contains("FreeCatalog.isCatalogId(entry.id)"),
                "die Katalog-Frage haengt nicht mehr an der Kennung")
        // The provider follows the same rule as the question: it comes from the
        // IDENTIFIER. The old switch routed only catalog titles and passed everything
        // else to the coordinator, that is to the MAIN provider (its
        // `provider` is a `let` from the `init`, not what is playing); measured live at
        // the test bench this meant that a Jellyfin book asked the
        // library server and its page stayed without parts.
        #expect(text.contains("detailProvider:anyAudioProvider{router.provider(entry.id)}"),
                "die Aufloesung des Anbieters haengt nicht mehr an der Kennung")
        #expect(!text.contains(":coordinator.provider"),
                "die Sitzung beantwortet wieder eine Frage nach dem Titel")
    }

    /// "Mark as finished" holds everywhere. The page hands the gesture to
    /// the one door (`BookFinishMark`), whose catalogue branch writes the
    /// local mark (`BookFinishMarkTests`). What stays here: the door is asked
    /// with the provider of the TITLE (`detailProvider`), never the running
    /// session's, or a Jellyfin book reports its mark to the library server,
    /// which does not know it.
    @Test("the catalog branch of marking writes locally, the server branch stays", .needsTheSources)
    func theCatalogMarkWritesLocally() throws {
        let rumpf = try #require(functionBody(of: "private func toggleFinishedMark() async {",
                                              in: try seite()))
            .split(whereSeparator: \.isWhitespace).joined()
        #expect(rumpf.contains("BookFinishMark.apply(entry"),
                "the page writes the mark past the door")
        #expect(rumpf.contains("provider:detailProvider"),
                "the door is asked with another provider than the title's")
    }

    /// The secondary buttons follow the RIGHTS: a catalog title gets
    /// no download button, because every other surface keeps this path
    /// closed. Marking stays for it.
    @Test("a catalog title gets no download button", .needsTheSources)
    func aCatalogTitleGetsNoDownloadButton() throws {
        let rumpf = try #require(functionBody(of: "private func downloadSection(compact: Bool) -> some View {",
                                              in: try seite()))
            .split(whereSeparator: \.isWhitespace).joined()
        #expect(rumpf.contains("ifisCatalogTitle{EmptyView()"),
                "der Katalog-Titel bekommt einen Download-Weg, den R47 geschlossen haelt")
    }
}
