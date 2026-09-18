// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// One switch, two names, and the fence says which site may read which.
///
/// The setting decides whether anything travels between a person's own
/// devices. Its key is called `podcastICloudSync` and cannot be renamed
/// (renaming resets everyone's setting), so the NAME says iCloud while the
/// MEANING has been "sync at all" since the service became a carrier. That
/// gap is not theoretical: it misled a careful reader into concluding from
/// the key's name that the playback claim depends on iCloud, which it does
/// not, and into writing that conclusion down as a measurement.
///
/// So: a carrier that really means Apple reads `podcastICloudSyncEnabled`.
/// Everything ABOVE a carrier reads `syncAcrossDevicesEnabled`, the same
/// value under the name of the question it answers. The stock may only
/// fall.
struct PodcastICloudSwitchFenceTests {
    /// Who may read the Apple name, and why, with the reason IN the entry.
    nonisolated static let appleReaders: [String: (count: Int, reason: String)] = [
        "AppStorageKeys.swift": (2, "die Deklaration selbst und die Tuer, die denselben Wert unter dem richtigen Namen weiterreicht"),
        "CloudKitStandCarrier.swift": (1, "gate: am CarrierRefreshers-Eintrag; ein CloudKit-Traeger DARF am iCloud-Schalter haengen"),
        "CloudKitStatsCarrier.swift": (1, "gate: am CarrierRefreshers-Eintrag"),
        "CloudKitPlaylistCarrier.swift": (1, "gate: am CarrierRefreshers-Eintrag"),
        "CloudKitChoiceCarrier.swift": (1, "gate: am CarrierRefreshers-Eintrag"),
        "PodcastFeedAuth.swift": (1, "die Wegewahl `travelsOverApple`: Apple nur ohne Dienst-Zugang und mit Schalter, dieselbe Frage wie in den fuenf Fabriken; der Leser steht in ihrem Default-Parameter"),
    ]

    /// Where the KEY itself may be named. The reader's name begins with the
    /// key's name, so these are counted with the readers stripped out;
    /// otherwise every reading site would count as a key use.
    nonisolated static let keyHolders: [String: (count: Int, reason: String)] = [
        "AppStorageKeys.swift": (2, "die Deklaration und das Lesen aus den Defaults"),
        "SettingsView.swift": (3, "die Bindung des Schalters, der Schalter selbst und sein onChange, der alle sechs Laeufer startet"),
        "MaerSyncSettingsView.swift": (1, "die Bindung, mit der die Dienst-Seite den Zustand des Schalters nennt"),
        "UserChoiceSync.swift": (1, "die Einstufung als geraete-eigene Wahl: der Schalter selbst reist NICHT mit"),
    ]

    /// The runners and the one diagnosis above the carriers. Each asks the
    /// door, and none of them may read the Apple name: their question is
    /// "does anything travel", not "is iCloud on".
    nonisolated static let aboveTheCarriers = [
        "PlaybackClaimSync.swift", "PodcastCloudSync.swift", "MaerPlaylistCloudSync.swift",
        "ListeningStats.swift", "UserChoiceCloudSync.swift", "RadioView.swift",
        "FeedAuthSync.swift",
    ]

    /// Non-comment lines that contain the token.
    nonisolated static func lines(naming token: String, in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains(token)
            }.count
    }

    /// Non-comment lines naming the KEY, with the readers stripped first.
    nonisolated static func linesNamingTheKey(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { return false }
                let withoutReaders = trimmed.replacingOccurrences(of: "podcastICloudSyncEnabled", with: "")
                return withoutReaders.contains("podcastICloudSync")
            }.count
    }

    @Test("den Apple-Namen liest nur, wer wirklich Apple meint")
    func onlyAppleCarriersReadTheAppleName() throws {
        var offenders: [String] = []
        var named = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let count = Self.lines(naming: "podcastICloudSyncEnabled", in: try String(contentsOf: file, encoding: .utf8))
            guard count > 0 else { continue }
            named += 1
            let allowed = Self.appleReaders[file.lastPathComponent]?.count ?? 0
            if count > allowed { offenders.append("\(file.lastPathComponent): \(count) > \(allowed)") }
        }
        #expect(named >= 1, "der Sucher findet den Namen ueberhaupt noch: \(named) Dateien")
        #expect(offenders.isEmpty, "hier liest jemand den Apple-Namen fuer eine wege-uebergreifende Frage: \(offenders)")
    }

    @Test("ueber den Traegern fragt jeder die Tuer, und keiner den Apple-Namen")
    func everythingAboveTheCarriersAsksTheDoor() throws {
        var offenders: [String] = []
        var seen = 0
        for file in ProjectFileIntegrityTests.sourceFiles() where Self.aboveTheCarriers.contains(file.lastPathComponent) {
            seen += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            if Self.lines(naming: "syncAcrossDevicesEnabled", in: text) == 0 {
                offenders.append("\(file.lastPathComponent): fragt die Tuer nicht")
            }
            if Self.lines(naming: "podcastICloudSyncEnabled", in: text) > 0 {
                offenders.append("\(file.lastPathComponent): liest den Apple-Namen")
            }
        }
        #expect(seen == Self.aboveTheCarriers.count, "jede Datei ueber den Traegern gefunden: \(seen) von \(Self.aboveTheCarriers.count)")
        #expect(offenders.isEmpty, "\(offenders)")
    }

    @Test("der Schluessel wird nur dort genannt, wo er gebunden oder eingestuft wird")
    func theKeyIsNamedOnlyWhereItIsBound() throws {
        var offenders: [String] = []
        var named = 0
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let count = Self.linesNamingTheKey(in: try String(contentsOf: file, encoding: .utf8))
            guard count > 0 else { continue }
            named += 1
            let allowed = Self.keyHolders[file.lastPathComponent]?.count ?? 0
            if count > allowed { offenders.append("\(file.lastPathComponent): \(count) > \(allowed)") }
        }
        #expect(named >= 1, "der Sucher findet den Schluessel ueberhaupt noch: \(named) Dateien")
        #expect(offenders.isEmpty, "hier wird der Schluessel an der Tuer vorbei gelesen: \(offenders)")
        // The counter to the stripping: a line that carries only the reader
        // is NOT a key use, or every reading site would count twice.
        #expect(Self.linesNamingTheKey(in: "let x = AppStorageKeys.podcastICloudSyncEnabled") == 0)
        #expect(Self.linesNamingTheKey(in: "let k = AppStorageKeys.podcastICloudSync") == 1)
    }

    @Test("die Tuer reicht denselben Wert weiter, sie entscheidet nichts eigenes")
    func theDoorForwardsTheSameValue() throws {
        // Two witnesses, because one alone would not hold. At runtime the
        // two names must agree; that catches a door that decides something
        // of its own. But equality in ONE state would also pass for a door
        // hard-wired to that state, so the source says it too: the line
        // that declares the door reads the raw name and nothing else.
        #expect(AppStorageKeys.syncAcrossDevicesEnabled == AppStorageKeys.podcastICloudSyncEnabled)
        let keys = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "AppStorageKeys.swift" })
        let declaration = try String(contentsOf: keys, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains("static var syncAcrossDevicesEnabled") }
        let line = try #require(declaration.map(String.init), "die Tuer steht in AppStorageKeys")
        #expect(line.contains("podcastICloudSyncEnabled"), "die Tuer reicht den rohen Leser weiter: \(line)")
    }
}
#endif
