// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Die Groesse des Cover-Caches zu erfragen heisst, das ganze
/// Verzeichnis aufzuzaehlen und je Datei eine Groesse zu lesen. Gemessen im
/// Simulator: 3,1 ms bei tausend Covern, 6,6 ms bei zweitausend (die Groesse,
/// die das Geraetelog zeigte), 13,8 ms bei viertausend, gegen ein Bild von
/// 16,7 ms.
///
/// Bis eben stand genau diese Frage als „billige Pruefung" vor dem
/// zusaetzlichen Fegelauf und wurde AUF DEM HAUPTSTRANG bei jedem
/// Zurueckkommen in die App gestellt, um eine Frage zu beantworten, deren
/// Antwort fast immer nein ist (`evicted=0` im Geraetelog, immer wieder).
/// Die Wache kostete mehr als das, was sie bewachte.
///
/// Der Zaun haelt, dass sie nicht zurueckkommt: die Frage darf nur dort
/// stehen, wo ihre Antwort das ANGEZEIGTE ist.
struct CoverSweepCostFenceTests {
    /// Die teure SACHE ist die Verzeichnis-Aufzaehlung, nicht der Name, den
    /// sie gerade traegt. Sie hat zwei: den gebundenen (`cacheSizeBytes`,
    /// auf den Cover-Cache festgelegt) und den allgemeinen
    /// (`directoryBytes`, nimmt jedes Verzeichnis). Der allgemeine ist der
    /// naheliegendere Griff, also muss er im Zaun stehen, sonst waere
    /// dieselbe Regression unter neuem Namen gruen.
    private static let names = ["cacheSizeBytes", "directoryBytes"]

    static func asks(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && names.contains { trimmed.contains($0) }
            }.count
    }

    /// Wer nach der Groesse fragen darf, mit Grund im Eintrag.
    nonisolated static let stock: [String: (count: Int, reason: String)] = [
        "ImageCache.swift":
            (3, "die Aufzaehlung selbst wohnt hier: ihre Deklaration, ihr Rufer im Fegelauf und "
                + "die gebundene Fassung fuer die Einstellungen, deren Zeile beide Namen traegt"),
        "Artwork.swift":
            (2, "die Bild-Tuer reicht sie an die Einstellungen weiter; zwei Zeilen, weil der "
                + "Zaehler den NAMEN sucht und die Deklaration ihn ebenso traegt wie der Rumpf"),
        "SettingsView.swift":
            (2, "die Einstellungen ZEIGEN die Zahl, einmal beim Erscheinen und einmal nach dem "
                + "Leeren; dort ist die Antwort das Angezeigte, also ist der Preis der Zweck"),
    ]

    @Test("Nach der Cache-Groesse fragt nur, wer die Antwort zeigt", .needsTheSources)
    func onlyTheSurfaceThatShowsItAsks() throws {
        var counts: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            counts[file.lastPathComponent, default: 0] += Self.asks(in: try String(contentsOf: file, encoding: .utf8))
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.stock.mapValues(\.count))
        #expect(drift.isEmpty, "a surface asks for the size again, or a stock above the count: \(drift)")
        // Rot-Probe in beide Richtungen, ueber BEIDE Namen: der Pruefer
        // saehe den gebundenen…
        #expect(Self.asks(in: "if cacheSizeBytes() > cap { sweep() }") == 1)
        // …und den allgemeinen, der die eigentliche Sache ist.
        #expect(Self.asks(in: "let n = ImageCache.directoryBytes(someDir)") == 1)
        // Ein Kommentar darueber loest nicht aus.
        #expect(Self.asks(in: "// war cacheSizeBytes()") == 0)
    }

    @Test("Die Zaehlung liest, was da ist, und ein fehlendes Verzeichnis ist null")
    func theCountReadsWhatIsThere() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cover-sweep-fence-\(UUID().uuidString)")
        // Ein fehlendes Verzeichnis gibt null und nicht etwa einen Fehler,
        // der als „leer" durchgeht: die Zusicherung, die eine Gegenmessung
        // schon einmal still hat scheitern lassen.
        #expect(ImageCache.directoryBytes(dir) == 0)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        #expect(ImageCache.directoryBytes(dir) == 0)
        for i in 0..<3 {
            try Data(count: 1_000).write(to: dir.appendingPathComponent("cover-\(i).jpg"))
        }
        #expect(ImageCache.directoryBytes(dir) == 3_000)
    }

    @Test("Der Deckel und sein Ueberschuss entscheiden den zusaetzlichen Lauf")
    func theCapAndItsOvershootDecide() {
        // Die Regel hinter dem Tor, pur und ohne Dateien: der zusaetzliche
        // Lauf kommt erst, wenn der Cache den Deckel um die Haelfte
        // ueberschritten hat, nicht schon beim Erreichen.
        let cap = ImageCache.cacheCapBytes(freeBytes: 100 * 1024 * 1024 * 1024)
        let trigger = Int64(Double(cap) * ImageCache.enforcementOvershoot)
        #expect(trigger > cap)
        #expect(ImageCache.enforcementOvershoot == 1.5)
        // Und der Deckel selbst bleibt zwischen Boden und Obergrenze, auch
        // auf einer vollen Platte.
        #expect(ImageCache.cacheCapBytes(freeBytes: 0) == 150 * 1024 * 1024)
        #expect(ImageCache.cacheCapBytes(freeBytes: .max) == 500 * 1024 * 1024)
    }
}
#endif
