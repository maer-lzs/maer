// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import ABSPlayer

/// Die EINE Hoerbuch-Detailseite: die Server-Seite ist die Form, ein
/// Katalog-Titel tritt durch eine zweite Tuer ein. Die Abnahme-Marke ist,
/// dass die SERVER-Seite unveraendert bleibt.
struct BookDetailEntryTests {

    private func seite() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/BookDetailScreen.swift"),
            encoding: .utf8)
    }

    /// Der Server-Eintritt verlangt sein LibraryViewModel weiter als
    /// Pflicht: keine Aufrufstelle kann es still fallen lassen. Der
    /// Katalog-Eintritt kommt ohne aus.
    @Test("beide Tueren stehen, und die Server-Tuer verlangt ihr Modell weiter")
    func bothDoorsStand() throws {
        let text = try seite().split(whereSeparator: \.isWhitespace).joined()
        #expect(text.contains("init(entry:LibraryEntry,coordinator:PlayerCoordinator,libraryViewModel:LibraryViewModel)"),
                "die Server-Tuer hat ihr Pflicht-Modell verloren")
        #expect(text.contains("init(catalogItem:LibraryItem,coordinator:PlayerCoordinator)"),
                "die Katalog-Tuer ist wieder zu")
    }

    /// Was sich unterscheidet, wird JE BILD aus der Kennung aufgeloest,
    /// nie beim Oeffnen gemerkt. Dieselbe Regel, die die Sendungsseite beim
    /// Kaltstart ehrlich gehalten hat.
    @Test("der Unterschied haengt an der Kennung, je Bild aufgeloest")
    func theDifferenceHangsOnTheId() throws {
        let text = try seite().split(whereSeparator: \.isWhitespace).joined()
        #expect(text.contains("FreeCatalog.isCatalogId(entry.id)"),
                "die Katalog-Frage haengt nicht mehr an der Kennung")
        // Der Provider folgt der Frage: Katalog nach Kennung, Server wie
        // bisher ueber den Koordinator. Beide Haelften muessen dastehen.
        #expect(text.contains("AppSession.shared.provider(for:entry.id):coordinator.provider"),
                "die Provider-Weiche ist gefallen")
    }

    /// „Als gehoert markieren" gilt ueberall. Der Katalog-Zweig schreibt
    /// den LOKALEN Stand; der Provider-Weg ist dort ein No-op und haette
    /// die Geste spurlos verschluckt. Der Server-Zweig bleibt unveraendert.
    @Test("der Katalog-Zweig des Markierens schreibt lokal, der Server-Zweig bleibt")
    func theCatalogMarkWritesLocally() throws {
        let rumpf = try #require(functionBody(of: "private func toggleFinishedMark() async {",
                                              in: try seite()))
            .split(whereSeparator: \.isWhitespace).joined()
        #expect(rumpf.contains("ifisCatalogTitle{"),
                "der Katalog-Zweig fehlt — die Geste laeuft in den No-op")
        #expect(rumpf.contains("ListeningStore.store(entry.id"),
                "der Katalog-Zweig schreibt nicht in den lokalen Bestand")
        #expect(rumpf.contains("PlayQueue.shared.markedPlayed(entry.id)"),
                "gehoert-fliegt-raus gilt im Katalog-Zweig nicht")
        // Abnahme-Marke: der Server-Weg schreibt weiter ueber den Provider
        // des Koordinators, mit der Warteschlange als Netz.
        #expect(rumpf.contains("coordinator.provider.updateProgress"),
                "der Server-Zweig hat seinen Schreibweg verloren")
        #expect(rumpf.contains("SyncQueue.shared.enqueue"),
                "der Server-Zweig hat seine Warteschlange verloren")
    }

    /// Die Zweitknoepfe folgen den RECHTEN: ein Katalog-Titel bekommt
    /// keinen Download-Knopf, weil jede andere Flaeche diesen Weg
    /// geschlossen haelt. Das Markieren bleibt ihm.
    @Test("ein Katalog-Titel bekommt keinen Download-Knopf")
    func aCatalogTitleGetsNoDownloadButton() throws {
        let rumpf = try #require(functionBody(of: "private var downloadSection: some View {",
                                              in: try seite()))
            .split(whereSeparator: \.isWhitespace).joined()
        #expect(rumpf.contains("ifisCatalogTitle{EmptyView()"),
                "der Katalog-Titel bekommt einen Download-Weg, den R47 geschlossen haelt")
    }
}
