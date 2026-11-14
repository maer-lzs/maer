// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Asking for the size of the cover cache means listing the whole
/// directory and reading a size per file. Measured in the
/// simulator: 3.1 ms at a thousand covers, 6.6 ms at two thousand (the size
/// the device log showed), 13.8 ms at four thousand, against a frame of
/// 16.7 ms.
///
/// Until just now exactly this question stood as a „billige Pruefung" before the
/// additional sweep run and was asked ON THE MAIN THREAD on every
/// return to the app, to answer a question whose
/// answer is almost always no (`evicted=0` in the device log, again and again).
/// The guard cost more than what it guarded.
///
/// The fence holds that it does not come back: the question may only
/// stand where its answer is the DISPLAYED one.
struct CoverSweepCostFenceTests {
    /// The expensive THING is the directory listing, not the name it
    /// currently carries. It has two: the bound one (`cacheSizeBytes`,
    /// fixed to the cover cache) and the general one
    /// (`directoryBytes`, takes any directory). The general one is the
    /// more obvious grip, so it must stand in the fence, or
    /// the same regression under a new name would be green.
    private static let names = ["cacheSizeBytes", "directoryBytes"]

    static func asks(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && names.contains { trimmed.contains($0) }
            }.count
    }

    /// Who may ask for the size, with the reason in the entry.
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

    @Test("Only who shows the answer asks for the cache size", .needsTheSources)
    func onlyTheSurfaceThatShowsItAsks() throws {
        var counts: [String: Int] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            counts[file.lastPathComponent, default: 0] += Self.asks(in: try String(contentsOf: file, encoding: .utf8))
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.stock.mapValues(\.count))
        #expect(drift.isEmpty, "a surface asks for the size again, or a stock above the count: \(drift)")
        // Red probe in both directions, over BOTH names: the checker
        // sees the bound one…
        #expect(Self.asks(in: "if cacheSizeBytes() > cap { sweep() }") == 1)
        // …and the general one, which is the actual thing.
        #expect(Self.asks(in: "let n = ImageCache.directoryBytes(someDir)") == 1)
        // A comment about it does not trigger.
        #expect(Self.asks(in: "// war cacheSizeBytes()") == 0)
    }

    @Test("The count reads what is there, and a missing directory is zero")
    func theCountReadsWhatIsThere() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cover-sweep-fence-\(UUID().uuidString)")
        // A missing directory gives zero and not an error
        // that passes as „leer": the assertion that a counter-measurement
        // once let fail silently.
        #expect(ImageCache.directoryBytes(dir) == 0)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        #expect(ImageCache.directoryBytes(dir) == 0)
        for i in 0..<3 {
            try Data(count: 1_000).write(to: dir.appendingPathComponent("cover-\(i).jpg"))
        }
        #expect(ImageCache.directoryBytes(dir) == 3_000)
    }

    @Test("The cap and its excess decide the additional run")
    func theCapAndItsOvershootDecide() {
        // The rule behind the gate, pure and without files: the additional
        // run comes only when the cache has exceeded the cap by half,
        // not already on reaching it.
        let cap = ImageCache.cacheCapBytes(freeBytes: 100 * 1024 * 1024 * 1024)
        let trigger = Int64(Double(cap) * ImageCache.enforcementOvershoot)
        #expect(trigger > cap)
        #expect(ImageCache.enforcementOvershoot == 1.5)
        // And the cap itself stays between floor and ceiling, even
        // on a full disk.
        #expect(ImageCache.cacheCapBytes(freeBytes: 0) == 150 * 1024 * 1024)
        #expect(ImageCache.cacheCapBytes(freeBytes: .max) == 500 * 1024 * 1024)
    }
}
#endif
