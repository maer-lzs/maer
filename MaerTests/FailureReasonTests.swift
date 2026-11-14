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

    @Test("an error from Objective-C names domain and code")
    func aBridgedErrorNamesItsDomainAndCode() {
        // A domain that does NOT bridge to URLError: exactly the kind that
        // stood in the line as `__NSCFError` on the device.
        let error = NSError(domain: NSPOSIXErrorDomain, code: 54)
        #expect(FailureReason.of(error) == "NSPOSIXErrorDomain=54")
        #expect(!FailureReason.of(error).contains("NSError"), "die Klasse ist kein Grund")
        #expect(!FailureReason.of(error).contains("__NSCF"), "die Klasse ist kein Grund")
    }

    /// Why the URLError branch has to stand FIRST: an `NSError` in
    /// `NSURLErrorDomain` bridges to `URLError` by itself, and the short
    /// form is the one the neighbors and the old log lines rest on.
    @Test("an NSError in the URL domain comes out as the short form, not as a domain")
    func anNSErrorInTheURLDomainComesOutShort() {
        #expect(FailureReason.of(NSError(domain: NSURLErrorDomain, code: -1001)) == "urlError=-1001")
    }

    @Test("the underlying error comes along once, because the mechanism is there")
    func theUnderlyingErrorComesAlongOnce() {
        let unten = NSError(domain: NSPOSIXErrorDomain, code: 54)
        let oben = NSError(domain: "kNWErrorDomainPOSIX", code: -1005,
                           userInfo: [NSUnderlyingErrorKey: unten])
        #expect(FailureReason.of(oben) == "kNWErrorDomainPOSIX=-1005 under=NSPOSIXErrorDomain=54")
        // Otherwise a chain grows without limit: exactly one level.
        let ganzUnten = NSError(domain: "A", code: 1, userInfo: [NSUnderlyingErrorKey: unten])
        let dreifach = NSError(domain: "B", code: 2, userInfo: [NSUnderlyingErrorKey: ganzUnten])
        #expect(FailureReason.of(dreifach) == "B=2 under=A=1")
    }

    @Test("a URLError keeps its short form, which the neighbors rest on")
    func aURLErrorKeepsItsShortForm() {
        #expect(FailureReason.of(URLError(.timedOut)) == "urlError=-1001")
        #expect(FailureReason.of(URLError(.cannotConnectToHost)) == "urlError=-1004")
        // The same form that MaerSyncSignIn and ArchiveOrgClient build on.
        #expect(MaerSyncFailure.reason(of: URLError(.timedOut)) == "urlError=-1001")
    }

    @Test("an own error stays its TYPE, so no address slips into a log")
    func anOwnErrorStaysItsTypeSoNoAddressLeaks() {
        let reason = FailureReason.of(Eigen.abgewiesen(at: "https://sync.example.test/v1/doc"))
        #expect(reason == "Eigen", "der Fall selbst gehoert nicht in die Zeile")
        #expect(!reason.contains("sync.example.test"), "eine Adresse steht nie in einem Grund")
        #expect(!reason.contains("https"), "eine Adresse steht nie in einem Grund")
    }

    @Test("the service's own cases keep their name")
    func theServicesOwnCasesKeepTheirName() {
        #expect(MaerSyncFailure.reason(of: MaerSyncFailure.sessionEnded) == "sessionEnded")
        #expect(MaerSyncFailure.reason(of: MaerSyncFailure.status(410)) == "status(410)")
        #expect(MaerSyncFailure.reason(of: NSError(domain: "D", code: 7)) == "D=7",
                "alles andere geht durch die geteilte Regel")
    }

    /// The shape that turns a TYPE into text, whatever the value is called:
    /// `String(describing:)` or `String(reflecting:)` around `type(of:)`, or
    /// an interpolation of it. A `type(of: error) is NSError.Type` is a
    /// question, not a sentence, and deliberately stays outside.
    static let blindFallbackShape = #"(?:String\s*\(\s*(?:describing|reflecting)\s*:|\\\()\s*type\s*\(\s*of\s*:"#

    /// The stock of the blind fallback. It may only shrink, and every entry
    /// names its reason: an entry without one would be an exception nobody
    /// looked at.
    ///
    /// **This fence measures the SHAPE, and that it has to is measured.**
    /// While it searched for the literal text `String(describing: type(of:
    /// error))` it hung on the NAME of one value. A site that builds the
    /// same string from a value called `provider` stood in the tree the
    /// whole time and the fence never saw it, so the stock read five files
    /// when it was six. A fence that measures a name answers about that
    /// name, and the class is about the shape.
    @Test("the blind fallback stands only where it is justified", .needsTheSources)
    func theBlindFallbackOnlyStandsWhereItIsReasoned() throws {
        let bestand: [String: String] = [
            "FailureReason.swift": "die Regel selbst, letzter Ausweg fuer einen Swift-Fehler",
            "CloudZoneDatabase.swift": "uebersetzt in einen eigenen Transport-Fall, kein Log-Grund",
            "GlobalSearchModel.swift": "Name einer Suchquelle fuer EINE Logzeile, nie ein Satz fuer die Flaeche",
        ]
        let wurzel = SourceTree.root.appendingPathComponent("Sources")
        let dateien = SourceTree.files(under: wurzel)
            .filter { $0.pathExtension == "swift" }
        try #require(dateien.count > 100, "der Zaun hat den Quellbaum nicht gelesen")
        let ausdruck = try NSRegularExpression(pattern: Self.blindFallbackShape)
        var gefunden: [String: Int] = [:]
        for datei in dateien {
            // Comment lines are cut away first: a sentence ABOUT the fallback
            // is not the fallback, and this very file's neighbours explain it
            // in their comments.
            let text = SyncContractFenceTests.stripped(try String(contentsOf: datei, encoding: .utf8))
            let treffer = ausdruck.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if treffer > 0 { gefunden[datei.lastPathComponent] = treffer }
        }
        // One blind fallback per file of the stock, no file beside it.
        let drift = StockDrift.findings(counts: gefunden, stock: bestand.mapValues { _ in 1 })
        #expect(drift.isEmpty, "a file falls back to the type name, or a stock above the count: \(drift)")
    }

    /// The measure of the fence above, on samples.
    ///
    /// It exists because that measure is the one part of the fence that can
    /// answer zero in silence: a stock that finds nothing looks exactly like
    /// a tree that carries nothing. Every line here is a shape the tree could
    /// grow tomorrow.
    @Test("the measure of the stock fence knows the shape, not the name of the value")
    func theStockMeasureKnowsTheShapeNotTheName() throws {
        let ausdruck = try NSRegularExpression(pattern: Self.blindFallbackShape)
        func trifft(_ text: String) -> Bool {
            ausdruck.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        #expect(trifft("String(describing: type(of: error))"))
        #expect(trifft("String(describing: type(of: provider))"), "der Wert darf heissen, wie er will")
        #expect(trifft("String(reflecting: type(of: fehler))"), "die zweite Schreibweise baut denselben Namen")
        #expect(trifft(#"let name = "\(type(of: whatever))""#), "auch eine Interpolation baut ihn")
        #expect(trifft("String(describing:\n            type(of: error))"), "ueber den Zeilenumbruch hinweg")
        #expect(!trifft("type(of: error) is NSError.Type"), "eine Typfrage erzaehlt nichts")
        #expect(!trifft("String(describing: error)"), "der Fehler selbst ist nicht sein Typ")
        let kommentar = "        // falls alles andere faellt: String(describing: type(of: error))"
        #expect(trifft(kommentar), "das Muster trifft die Form auch im Kommentar")
        #expect(!trifft(SyncContractFenceTests.stripped(kommentar)),
                "aber der Zaun zaehlt ihn nicht, weil er Kommentarzeilen wegschneidet")
    }
}
#endif
