// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Musik kommt von Subsonic ODER Jellyfin, und WELCHER es ist, beantwortet
/// `AppSession.musicProvider`: Jellyfin, sobald es die einzige aktive
/// Musikquelle ist, sonst Subsonic.
///
/// Eine allgemeine Musik-Flaeche darf deshalb keinen konkreten Server nennen.
/// `MusicAlbumView` tat es an DREI von achtzehn Stellen (beide Album-Downloads
/// und die Zufallswiedergabe fragten fest Subsonic), waehrend die uebrigen
/// fuenfzehn den eingestellten Anbieter fragten. Bei einer Jellyfin-Quelle
/// liefen genau diese drei am Anbieter vorbei: der Download bekam den
/// falschen Anbieter mitgegeben, und die Zufallswiedergabe fragte Subsonic
/// nach den Titeln einer `jf:`-Kennung.
///
/// Der Bestand nennt die Ausnahmen mit Grund. Es sind genau die zwei
/// EINSTELLUNGSSEITEN, und dort ist der konkrete Server die Sache selbst.
struct MusicProviderDoorFenceTests {
    private func codeOf(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test("Keine allgemeine Flaeche nennt einen konkreten Musikserver")
    func noGeneralSurfaceNamesAConcreteMusicServer() throws {
        let allowed: [String: String] = [
            "Sources/AppSession.swift":
                "die Tuer selbst: hier wird entschieden, WELCHER Server der Musikanbieter ist",
            "Sources/Providers/SubsonicProvider.swift": "der Anbieter selbst",
            "Sources/Providers/JellyfinProvider.swift": "der Anbieter selbst",
            "Sources/Views/SubsonicSourceView.swift":
                "die EINSTELLUNGSSEITE dieses Servers: Verbindung testen, Bibliotheken lesen, "
                + "jetzt abgleichen. Hier IST der konkrete Server die Sache",
            "Sources/Views/JellyfinSourceView.swift":
                "dieselbe Seite fuer Jellyfin, dieselbe Begruendung",
            "Sources/UITestSeed.swift":
                "die Saat der Journeys setzt einen bestimmten Server, weil sie ihn stellt",
        ]
        var offenders: [String] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(atPath: root.path) else {
            Issue.record("Sources nicht lesbar"); return
        }
        for case let name as String in walker where name.hasSuffix(".swift") {
            let relative = "Sources/" + name
            if allowed[relative] != nil { continue }
            let code = try codeOf(relative)
            for needle in ["SubsonicProvider.shared", "JellyfinProvider.shared",
                           "subsonicProvider", "jellyfinProvider"] where code.contains(needle) {
                offenders.append("\(relative) (\(needle))")
            }
        }
        #expect(offenders.isEmpty,
                "eine allgemeine Flaeche nennt einen konkreten Musikserver: \(offenders)")
    }

    /// Gegenprobe, damit der Bestand oben nicht deshalb leer ist, weil die
    /// Tuer verschwunden ist: sie waehlt wirklich zwischen beiden, und die
    /// Bedingung ist die, auf die sich der Bestand beruft.
    @Test("Die Tuer waehlt wirklich zwischen beiden Servern")
    func theDoorReallyChooses() throws {
        let code = try codeOf("Sources/AppSession.swift")
        #expect(code.contains("var musicProvider: any MusicProvider"))
        #expect(code.contains("JellyfinProvider.shared") && code.contains("SubsonicProvider.shared"),
                "die Tuer nennt nicht mehr beide Server, dann waehlt sie nichts")
        #expect(code.contains("jellyfinActive"),
                "die Wahl haengt nicht mehr an der aktiven Quelle")
    }

    /// Every question to the DEVICE's music source, counted at its
    /// SIGNATURE whoever the receiver is: `AppSession.shared`, a `session`,
    /// or a name bound to either. Counting the spelling
    /// `AppSession.shared.musicProvider` let `session.musicProvider` through
    /// (the search result in the library). The door per item, which is called
    /// with `(for:`, does not count.
    nonisolated static func deviceQuestions(in code: String) -> Int {
        code.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(IdQuestionDoorFenceTests.withoutComment($0)).replacing(#/"(?:[^"\\]|\\.)*"/#, with: "\"\"") }
            .joined(separator: "\n")
            // No `\b` after the name: under Unicode word rules
            // `musicProvider.genres` is ONE word, so the common form slipped by.
            .matches(of: #/\.\s*musicProvider(?![A-Za-z0-9_])(?!\s*\()/#).count
    }

    /// Die Klasse eine Etage weiter, und diesmal ueber ALLE Ansichten.
    ///
    /// Der Zaun darueber haelt, dass keine Flaeche einen konkreten Server
    /// NENNT. Das laesst die andere Haelfte offen: eine Flaeche darf
    /// `AppSession.shared.musicProvider` fragen, und der antwortet „welche
    /// Musikquelle nutzt dieses GERAET". Fuer eine Bibliotheks-Liste ist das
    /// richtig. Fuer einen TITEL ist es falsch, denn der traegt seine Quelle
    /// in der Kennung, und mit zwei eingerichteten Servern gewinnt Subsonic.
    ///
    /// Gemessen und geheilt wurden **elf Stellen in FUENF Dateien** (drei je
    /// `MixedMediaPage`, `MusicContinueCard` und `AddToPlaylistSheet`, je eine
    /// in `MusicLibraryPages` und `Lyrics`); die zwoelfte steht in
    /// `MusicAlbumView` und ist seit dem 09.09. geheilt. Alle mit sichtbarer
    /// Folge: eine Jellyfin-Liste bekam die falsche Karte und das falsche
    /// Platzhalter-Zeichen, ihre Zufallswiedergabe fand keine Titel, ihre
    /// Cover fehlten, ihre Downloads standen nicht auf der Seite, und „zur
    /// Playlist hinzufuegen" antwortete mit „Nothing to add".
    ///
    /// Der Bestand nennt, was BLEIBEN darf, mit Grund je Datei, und er faellt
    /// nur. Ein Aufzaehlen der erlaubten Ruf-Formen waere der Fehler von
    /// gestern: ein Zaun, der Formen kennt, bewacht nur, was er schon gesehen
    /// hat.
    @Test("keine Ansicht fragt das GERAET nach einem Titel", .needsTheSources)
    func noViewAsksTheDeviceAboutATitle() throws {
        let stock: [String: (count: Int, reason: String)] = [
            "HomeView.swift":
                (1, "der Fortschritt der ganzen Musik-Bibliothek, eine Frage an das Geraet"),
            "MusicViewModel.swift":
                (1, "ein Griff fuer die Listen, die das Modell laedt (Alben, Regal, Kuenstler, Playlisten), "
                    + "bei zwei Servern den Satz, welcher nicht geantwortet hat, und ob hier ein Server da ist"),
            "MusicLibraryPages.swift":
                (5, "Seitenweises Blaettern, Genres (die Genre-Seite ueber EINEN Zugang), Regale, "
                    + "Zufallswiedergabe der Bibliothek"),
            "MusicView.swift":
                (1, "das Signal der eingestellten Quelle, dass ihre Bibliothek sich bewegt hat"),
            // AddToPlaylistSheet fragt den Server des Ziels
            // (`musicProvider(serving: .one(server))`), nie mehr das Geraet: 2 → 0.
        ]
        // Kuenstler und Playlists tragen ihre Kennung mit Namensraum
        // (`MusicArtist.itemId`, `MusicPlaylist.itemId`, gesetzt am Rand des
        // Anbieters); die Kuenstler-Seite, das Portraet und jede
        // Playlist-Kennung fragen deshalb die Tuer, keine rohe Nummer mehr.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Views")
        let walker = try #require(FileManager.default.enumerator(at: root,
                                                                includingPropertiesForKeys: nil))
        var checked = 0
        var found: [String: Int] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let code = try codeOf("Sources/Views/"
                                  + url.path.components(separatedBy: "Sources/Views/")[1])
            checked += 1
            let count = Self.deviceQuestions(in: code)
            if count > 0 { found[url.lastPathComponent] = count }
        }
        #expect(checked > 0, "der Zaun hat keine Ansicht gelesen, also misst er nichts")
        #expect(Self.deviceQuestions(in: "let music = session.musicProvider\n_ = music.allArtists()") == 1,
                "der Zaehler sieht die Geraete-Frage ueber eine Bindung, gleich welcher Empfaenger")
        #expect(Self.deviceQuestions(in: "_ = AppSession.shared\n    .musicProvider.genres()") == 1,
                "der Zaehler sieht sie ueber einen Umbruch")
        #expect(Self.deviceQuestions(in: "_ = session.musicProvider(for: id).genres()") == 0,
                "die Tuer je Eintrag zaehlt nicht")
        // BEIDE Richtungen, und die zweite ist die stille: sperrt der Bestand
        // nur nach oben, behauptet ein Eintrag weiter, sechs Rufe seien in
        // Ordnung, lange nachdem es zwei sind. Ein Grund, der zu viel deckt,
        // ist eine Ausnahme, die niemand mehr nachgesehen hat. Faellt die
        // Zahl, wird sie hier zurueckgeschrieben, wie am Wachstums-Zaun.
        var tooMany: [String] = []
        var stale: [String] = []
        for (name, entry) in stock {
            let actual = found[name] ?? 0
            if actual > entry.count { tooMany.append("\(name): \(actual) statt \(entry.count)") }
            if actual < entry.count { stale.append("\(name): nur noch \(actual) von \(entry.count)") }
        }
        for (name, count) in found where stock[name] == nil {
            tooMany.append("\(name): \(count) ohne Eintrag im Bestand")
        }
        #expect(tooMany.isEmpty,
                "eine Ansicht fragt das Geraet, wo die Kennung antwortet: \(tooMany.sorted())")
        // Ein Literal, kein zusammengesetzter Text: der Kommentar eines
        // `#expect` nimmt keinen.
        #expect(stale.isEmpty,
                "der Bestand deckt mehr, als es gibt: \(stale.sorted())")
        // Gegenprobe: die Tuer, auf die geheilt wurde, gibt es wirklich, und
        // sie leitet an der Kennung.
        let session = try codeOf("Sources/AppSession.swift")
        #expect(session.contains("func musicProvider(for itemId: String) -> any MusicProvider"))
        #expect(session.contains("MusicSourceRule.item(itemId"),
                "die Tuer fragt nicht mehr die eine Regel")
        let rule = try codeOf("Sources/Models/MusicSourceRule.swift")
        #expect(rule.contains("ItemNamespace.isJellyfin(itemId)"),
                "die Tuer leitet nicht mehr am Namensraum")
    }

    /// Dieselbe Frage fuer die BIBLIOTHEK, und der Satz daneben war falsch
    /// gemessen: `coordinator.provider` ist NICHT die laufende Sitzung,
    /// sondern ein `let` aus dem `init`, das `AppSession` mit dem HAUPT-
    /// Anbieter baut. Er beantwortet also keine Frage nach einem Titel, und
    /// zwar aus einem anderen Grund als bisher behauptet: nicht weil er
    /// wechselt, sondern weil er sich NIE aendert. Genau eine Flaeche darf ihn
    /// nennen, und dort ist der Haupt-Anbieter die Sache selbst.
    @Test("der Haupt-Anbieter wird nur dort gefragt, wo er gemeint ist", .needsTheSources)
    func theRunningSessionIsAskedOnlyWhereItIsMeant() throws {
        let allowed = "ABSSourceView.swift"
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Views")
        let walker = try #require(FileManager.default.enumerator(at: root,
                                                                includingPropertiesForKeys: nil))
        var checked = 0
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let code = try codeOf("Sources/Views/"
                                  + url.path.components(separatedBy: "Sources/Views/")[1])
            checked += 1
            // KLEIN geschrieben gesucht, und das ist keine Feinheit: die
            // Rot-Probe setzte `playerCoordinator.provider` ein, also genau
            // eine der vier Formen, an denen die Klasse gemessen wurde, und
            // der Zaun blieb gruen. Ein Zaun, der die Schreibweise mitprueft,
            // bewacht den Namen und nicht die Sache. Der Nachbar-Zaun in
            // `JellyfinBooksSurfaceTests` macht es seit je so.
            guard code.lowercased().contains("coordinator.provider") else { continue }
            // Die Einrichtungsseite von Audiobookshelf: dort wird die
            // Verbindung des HAUPT-Anbieters geprueft und seine Warteschlange
            // geleert. Er IST dort die Sache.
            if url.lastPathComponent != allowed { offenders.append(url.lastPathComponent) }
        }
        #expect(checked > 0, "der Zaun hat keine Ansicht gelesen, also misst er nichts")
        #expect(offenders.isEmpty,
                "eine Ansicht fragt wieder den Haupt-Anbieter: \(offenders.sorted())")
    }

    /// Und die Frage, an der der Fund haengt, am Protokoll: beide Anbieter
    /// koennen sie beantworten, es gab also nie einen Grund, einen davon zu
    /// nennen.
    @Test("Was die drei Stellen brauchten, steht im Protokoll")
    func whatTheThreeSitesNeededIsInTheProtocol() throws {
        let code = try codeOf("Sources/Providers/MusicProvider.swift")
        #expect(code.contains("func songItems(forItemId itemId: String) async -> [LibraryItem]"),
                "songItems steht nicht mehr im Protokoll, dann braucht die Zufallswiedergabe wieder einen Server")
        for provider in ["Sources/Providers/SubsonicProvider.swift",
                         "Sources/Providers/JellyfinProvider.swift"] {
            #expect(try codeOf(provider).contains("func songItems(forItemId itemId: String)"),
                    "\(provider) erfuellt songItems nicht mehr")
        }
    }
}
#endif
