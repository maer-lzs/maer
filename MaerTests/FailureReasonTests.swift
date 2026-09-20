// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The reason in a log line names the error, not its class.
///
/// Measured at a device before this existed: `reason=__NSCFError`, five times
/// in eleven minutes, while the same error carried `NSURLErrorDomain` and
/// `-1001` and nobody could read it.
struct FailureReasonTests {
    /// A Swift error whose associated value is an address: it must NEVER
    /// appear in a reason, which is why the last resort stays the type name.
    enum Eigen: Error { case abgewiesen(at: String) }

    @Test("ein Fehler aus Objective-C nennt Domaene und Code")
    func aBridgedErrorNamesItsDomainAndCode() {
        // Eine Domaene, die NICHT nach URLError brueckt: genau die Sorte, die
        // am Geraet als `__NSCFError` in der Zeile stand.
        let error = NSError(domain: NSPOSIXErrorDomain, code: 54)
        #expect(FailureReason.of(error) == "NSPOSIXErrorDomain=54")
        #expect(!FailureReason.of(error).contains("NSError"), "die Klasse ist kein Grund")
        #expect(!FailureReason.of(error).contains("__NSCF"), "die Klasse ist kein Grund")
    }

    /// Warum der URLError-Zweig VORNE stehen muss: ein `NSError` in
    /// `NSURLErrorDomain` brueckt von selbst nach `URLError`, und die kurze
    /// Form ist die, auf der die Nachbarn und die alten Logzeilen stehen.
    @Test("ein NSError in der URL-Domaene kommt als kurze Form heraus, nicht als Domaene")
    func anNSErrorInTheURLDomainComesOutShort() {
        #expect(FailureReason.of(NSError(domain: NSURLErrorDomain, code: -1001)) == "urlError=-1001")
    }

    @Test("der darunterliegende Fehler kommt einmal mit, weil dort der Mechanismus steht")
    func theUnderlyingErrorComesAlongOnce() {
        let unten = NSError(domain: NSPOSIXErrorDomain, code: 54)
        let oben = NSError(domain: "kNWErrorDomainPOSIX", code: -1005,
                           userInfo: [NSUnderlyingErrorKey: unten])
        #expect(FailureReason.of(oben) == "kNWErrorDomainPOSIX=-1005 under=NSPOSIXErrorDomain=54")
        // Eine Kette waechst sonst ohne Grenze: genau eine Ebene.
        let ganzUnten = NSError(domain: "A", code: 1, userInfo: [NSUnderlyingErrorKey: unten])
        let dreifach = NSError(domain: "B", code: 2, userInfo: [NSUnderlyingErrorKey: ganzUnten])
        #expect(FailureReason.of(dreifach) == "B=2 under=A=1")
    }

    @Test("ein URLError behaelt seine kurze Form, auf der die Nachbarn stehen")
    func aURLErrorKeepsItsShortForm() {
        #expect(FailureReason.of(URLError(.timedOut)) == "urlError=-1001")
        #expect(FailureReason.of(URLError(.cannotConnectToHost)) == "urlError=-1004")
        // Dieselbe Form, auf die MaerSyncSignIn und ArchiveOrgClient bauen.
        #expect(MaerSyncFailure.reason(of: URLError(.timedOut)) == "urlError=-1001")
    }

    @Test("ein eigener Fehler bleibt sein TYP, damit keine Adresse in ein Log rutscht")
    func anOwnErrorStaysItsTypeSoNoAddressLeaks() {
        let reason = FailureReason.of(Eigen.abgewiesen(at: "https://sync.example.test/v1/doc"))
        #expect(reason == "Eigen", "der Fall selbst gehoert nicht in die Zeile")
        #expect(!reason.contains("sync.example.test"), "eine Adresse steht nie in einem Grund")
        #expect(!reason.contains("https"), "eine Adresse steht nie in einem Grund")
    }

    @Test("die eigenen Faelle des Dienstes behalten ihren Namen")
    func theServicesOwnCasesKeepTheirName() {
        #expect(MaerSyncFailure.reason(of: MaerSyncFailure.sessionEnded) == "sessionEnded")
        #expect(MaerSyncFailure.reason(of: MaerSyncFailure.status(410)) == "status(410)")
        #expect(MaerSyncFailure.reason(of: NSError(domain: "D", code: 7)) == "D=7",
                "alles andere geht durch die geteilte Regel")
    }

    /// Bestand des blinden Rueckfalls. Er darf nur fallen, und jeder Eintrag
    /// nennt seinen Grund: ein Eintrag ohne Grund waere eine Ausnahme, die
    /// niemand nachgesehen hat.
    @Test("der blinde Rueckfall steht nur noch dort, wo er begruendet ist", .needsTheSources)
    func theBlindFallbackOnlyStandsWhereItIsReasoned() throws {
        let bestand: [String: String] = [
            "FailureReason.swift": "die Regel selbst, letzter Ausweg fuer einen Swift-Fehler",
            "FreeCatalog.swift": "eigene Katalog-Sprache, sie endet in einem Satz fuer die Flaeche",
            "CatalogStockService.swift": "Rueckfall NEBEN FreeCatalog.failureReason, gleiche Sprache",
            "MusicLibraryPages.swift": "dieselbe Stelle eine Flaeche weiter",
            "CloudZoneDatabase.swift": "uebersetzt in einen eigenen Transport-Fall, kein Log-Grund",
        ]
        let wurzel = SourceTree.root.appendingPathComponent("Sources")
        let dateien = try #require(FileManager.default.enumerator(at: wurzel, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        try #require(dateien.count > 100, "der Zaun hat den Quellbaum nicht gelesen")
        var gefunden: [String: Int] = [:]
        for datei in dateien {
            let text = try String(contentsOf: datei, encoding: .utf8)
            let treffer = text.components(separatedBy: "String(describing: type(of: error))").count - 1
            if treffer > 0 { gefunden[datei.lastPathComponent] = treffer }
        }
        for (name, zahl) in gefunden.sorted(by: { $0.key < $1.key }) {
            #expect(bestand[name] != nil, "\(name) faellt neu auf den Klassennamen zurueck")
            #expect(zahl <= 1, "\(name) traegt den blinden Rueckfall \(zahl) mal")
        }
        #expect(gefunden.count <= bestand.count,
                "der Bestand darf nur fallen (gefunden \(gefunden.count), erlaubt \(bestand.count))")
    }
}
#endif
