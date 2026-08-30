// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Testing
import Foundation
@testable import Maer

/// Die Bruecken-Faehre des ID-Umzugs: EIN versioniertes Format, das
/// Manifest ist das Siegel, und keine Seite zerstoert je Bestand.
struct BridgeFerryTests {

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("faehre-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Export nur als alte App, Import nur als neue: die Weiche haengt an
    /// der Bundle-ID, nicht an einem Flag, und kann darum nie falsch
    /// stehen.
    @Test("die Faehre faehrt nur in ihre Richtung")
    func ferryRunsOneWayPerBundle() throws {
        let brief = tempDir(); let docs = tempDir()
        let suite = "faehre-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // Die NEUE App exportiert nie.
        BridgeFerry.exportIfOldApp(bundleId: "fm.maer.app", directory: brief,
                                   documents: docs, defaults: defaults)
        #expect(!FileManager.default.fileExists(
            atPath: brief.appendingPathComponent("manifest.json").path))
        // Die ALTE App importiert nie.
        #expect(BridgeFerry.importIfNeeded(bundleId: "de.lzs.ABSPlayer",
                                           directory: brief, documents: docs,
                                           defaults: defaults) == nil)
    }

    /// Der ganze Weg: die alte Seite exportiert (Siegel zuletzt), die neue
    /// uebernimmt einmal, meldet ehrlich und ueberschreibt nie Bestehendes.
    @Test("Export, Import, Meldung, und nichts wird ueberschrieben")
    func fullFerryRun() throws {
        let brief = tempDir()
        let altDocs = tempDir(); let neuDocs = tempDir()
        let altSuite = "alt-\(UUID().uuidString)"; let neuSuite = "neu-\(UUID().uuidString)"
        let alt = try #require(UserDefaults(suiteName: altSuite))
        let neu = try #require(UserDefaults(suiteName: neuSuite))
        defer {
            UserDefaults.standard.removePersistentDomain(forName: altSuite)
            UserDefaults.standard.removePersistentDomain(forName: neuSuite)
        }
        try Data("abos".utf8).write(to: altDocs.appendingPathComponent("podcast_subscriptions.json"))
        alt.set([12.5, 1_000], forKey: "localPosition.rss:x:g1")
        BridgeFerry.exportIfOldApp(bundleId: "de.lzs.ABSPlayer", directory: brief,
                                   documents: altDocs, defaults: alt)
        let summary = try #require(BridgeFerry.importIfNeeded(
            bundleId: "fm.maer.app", directory: brief, documents: neuDocs, defaults: neu))
        #expect(summary.subscriptionsTaken)
        #expect(!summary.playlistsTaken, "eine nie exportierte Fracht gilt als gefunden")
        #expect(summary.positionsTaken == 1)
        #expect(neu.array(forKey: "localPosition.rss:x:g1") as? [Double] == [12.5, 1_000])
        // Einmalig: der zweite Lauf tut nichts mehr.
        #expect(BridgeFerry.importIfNeeded(bundleId: "fm.maer.app", directory: brief,
                                           documents: neuDocs, defaults: neu) == nil)
        // Nie ueberschreiben: ein weiterer Import (frische Marke) laesst
        // vorhandene Dateien und Staende stehen.
        neu.removeObject(forKey: AppStorageKeys.bridgeFerryImported)
        neu.set([99.0, 2_000], forKey: "localPosition.rss:x:g1")
        try Data("eigene".utf8).write(to: neuDocs.appendingPathComponent("podcast_subscriptions.json"))
        let zweiter = try #require(BridgeFerry.importIfNeeded(
            bundleId: "fm.maer.app", directory: brief, documents: neuDocs, defaults: neu))
        #expect(!zweiter.subscriptionsTaken, "die Faehre hat Bestehendes ueberschrieben")
        #expect(zweiter.positionsTaken == 0)
        #expect(neu.array(forKey: "localPosition.rss:x:g1") as? [Double] == [99.0, 2_000])
    }

    /// Kein Siegel = keine Sendung: der Import bucht sich NICHT als
    /// gelaufen und nimmt eine spaetere Lieferung noch an. Und ein fremdes
    /// Format wird verweigert statt geraten.
    @Test("ohne Siegel wartet der Import; fremde Version wird verweigert")
    func sealAndVersionRules() throws {
        let brief = tempDir(); let docs = tempDir()
        let suite = "siegel-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // Fracht ohne Manifest (Absturz mitten im Export).
        try Data("abos".utf8).write(to: brief.appendingPathComponent("podcast_subscriptions.json"))
        #expect(BridgeFerry.importIfNeeded(bundleId: "fm.maer.app", directory: brief,
                                           documents: docs, defaults: defaults) == nil)
        #expect(defaults.object(forKey: AppStorageKeys.bridgeFerryImported) == nil,
                "der Import hat sich ohne Sendung als gelaufen gebucht")
        // Die Lieferung kommt nach: jetzt nimmt er sie.
        BridgeFerry.exportIfOldApp(bundleId: "de.lzs.ABSPlayer", directory: brief,
                                   documents: docs, defaults: defaults)
        #expect(BridgeFerry.importIfNeeded(bundleId: "fm.maer.app", directory: brief,
                                           documents: docs, defaults: defaults) != nil)
        // Fremde Version: verweigert.
        let brief2 = tempDir()
        let fremd = BridgeFerry.Manifest(version: 99, exportedAt: 1, sourceBundleId: "x",
                                         subscriptionBytes: 0, playlistBytes: 0, positionCount: 0)
        try JSONEncoder().encode(fremd).write(to: brief2.appendingPathComponent("manifest.json"))
        defaults.removeObject(forKey: AppStorageKeys.bridgeFerryImported)
        #expect(BridgeFerry.importIfNeeded(bundleId: "fm.maer.app", directory: brief2,
                                           documents: docs, defaults: defaults) == nil)
    }
}
