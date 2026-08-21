// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// 95c5c16: the negative cache poisoned itself — a transport failure was
/// written down as "this station has no logo" and held for 14 days, so ONE
/// disturbed phase (the RB outage on 03.08.) wiped every logo. These tests
/// fence the rule: only a clean run that found nothing may be booked.
struct RadioLogoCacheTests {
    private struct Stored: Codable {
        var url: String?
        var resolvedAt: Double
        var commonsFile: String? = nil
    }

    private func write(_ entries: [String: Stored], to defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(entries), forKey: "radioLogoChainResults")
    }

    private func read(_ defaults: UserDefaults) -> [String: Stored] {
        guard let data = defaults.data(forKey: "radioLogoChainResults") else { return [:] }
        return (try? JSONDecoder().decode([String: Stored].self, from: data)) ?? [:]
    }

    @Test("the poisoned negative generation is dropped once; positives survive")
    func selfHealing() {
        let suite = "radio-logo-heal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date().timeIntervalSince1970
        write(["radio:rb:good": Stored(url: "https://logo.example/a.png", resolvedAt: now),
               "radio:rb:poisoned": Stored(url: nil, resolvedAt: now)], to: defaults)

        // The migration the service performs on first load of this version.
        let dropped = RadioLogoService.migratePersisted(defaults: defaults,
                                                        storedVersion: 1)
        #expect(dropped == 1)
        let kept = read(defaults)
        #expect(kept["radio:rb:good"]?.url == "https://logo.example/a.png")
        #expect(kept["radio:rb:poisoned"] == nil)

        // Running it again at the current version changes nothing.
        #expect(RadioLogoService.migratePersisted(defaults: defaults,
                                                  storedVersion: RadioLogoService.currentStorageVersion) == 0)
        #expect(read(defaults).count == 1)
    }

    /// b9de792 (v4): a stored "no" is only valid for the chain that produced
    /// it. The sibling stage joined on 21.08. — negatives booked by the
    /// shorter chain kept answering for 14 days ("bigFM Deutsch Rap" showed
    /// initials although the family favicon exists). v3→v4 drops negatives
    /// once; positives (URL or commons file) stay — a hit is a hit under any
    /// chain.
    @Test func negativesFromTheShorterChainAreDroppedOnce() {
        let suite = "radio-logo-v4-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date().timeIntervalSince1970
        write(["radio:rb:hit": Stored(url: "https://logo.example/a.png", resolvedAt: now),
               "radio:rb:commons": Stored(url: nil, resolvedAt: now, commonsFile: "A.svg"),
               "radio:rb:preSiblingNo": Stored(url: nil, resolvedAt: now)], to: defaults)
        let dropped = RadioLogoService.migratePersisted(defaults: defaults, storedVersion: 3)
        #expect(dropped == 1)
        let kept = read(defaults)
        #expect(kept["radio:rb:hit"] != nil)
        #expect(kept["radio:rb:commons"] != nil)
        #expect(kept["radio:rb:preSiblingNo"] == nil)
    }

    @Test("bc11ed5: the politeness spacing leaves room for a screen full of tiles")
    func politeSpacing() {
        // The old 1 s came from the MusicBrainz manners; this chain talks to
        // Wikidata/Commons. With a screenful of tiles the fourth station's
        // turn came minutes late — long after SwiftUI cancelled its task.
        #expect(RadioLogoService.politeSpacingSeconds < 0.5)
        #expect(RadioLogoService.politeSpacingSeconds > 0.2)   // still polite
        // A screen of ~12 tiles must drain in seconds, not minutes.
        #expect(12 * RadioLogoService.politeSpacingSeconds < 5)
    }

    @Test("a failed fetch is not a finding — only a clean no-hit may be booked")
    func failureIsNotANegative() {
        // The rule as a pure decision, so it holds independently of the network.
        #expect(!RadioLogoService.mayPersist(outcomeFailed: true, foundURL: nil))
        #expect(RadioLogoService.mayPersist(outcomeFailed: false, foundURL: nil))
        #expect(RadioLogoService.mayPersist(outcomeFailed: false,
                                            foundURL: URL(string: "https://logo.example/a.png")))
    }

    /// The decided case, as numbers: DLF Kultur's P154 logo measures 960×110.
    /// At the portrait default width of 400 the render's short side lands at
    /// ~46 px — the gate would reject the very source the decision made
    /// primary. At 800 it clears the 64 px gate with room.
    @Test("the requested width keeps wide wordmark logos above the gate")
    func requestedWidthClearsTheGate() {
        func shortSide(renderWidth: Int, logoW: Double, logoH: Double) -> Int {
            Int(Double(renderWidth) * min(logoW, logoH) / max(logoW, logoH))
        }
        #expect(!RadioFaviconGate.acceptable(
            pixelWidth: 400, pixelHeight: shortSide(renderWidth: 400, logoW: 960, logoH: 110)))
        #expect(RadioFaviconGate.acceptable(
            pixelWidth: 800, pixelHeight: shortSide(renderWidth: 800, logoW: 960, logoH: 110)))
        // And the requested width is actually 800 — the URL carries it.
        let url = ArtistPortraitLookup.commonsThumbURL(fileName: "X.svg", width: 800)
        #expect(url?.query?.contains("width=800") == true)
    }

    /// cb8bac1: the v3 healing — a positive persisted as a width=400 Commons
    /// URL becomes FILE-based, so the read builds today's width; touch icons
    /// and negatives stay as they are. The width change that shipped without
    /// a bump left devices on rejected 400×46 renders for 14 days.
    @Test("v3 heals persisted Commons positives to file names")
    func v3HealsCommonsPositives() throws {
        let file = "Deutschlandfunk Kultur Logo 2017.svg"
        #expect(RadioLogoService.commonsFileName(
            fromStoredURL: "https://commons.wikimedia.org/wiki/Special:FilePath/Deutschlandfunk%20Kultur%20Logo%202017.svg?width=400") == file)
        // Touch icons and garbage answer nil — they are not healed, kept.
        #expect(RadioLogoService.commonsFileName(fromStoredURL: "https://www.dlf.de/apple-touch-icon.png") == nil)
        #expect(RadioLogoService.commonsFileName(fromStoredURL: nil) == nil)
        // And the current width rides in the rebuilt URL.
        let rebuilt = ArtistPortraitLookup.commonsThumbURL(fileName: file, width: RadioLogoService.commonsWidth)
        #expect(rebuilt?.query?.contains("width=800") == true)
    }
}
#endif

// MARK: - 🔴 Punkt 6: ein Urteil gilt nur unter seinem Tor

struct RadioLogoGateVersioningTests {
    /// Der SRF-1-Fixfall: die Kette liefert (463 px), aber ein NEIN aus der
    /// 64er-Zeit blockierte die Wiedervorlage — ein Schwellen-Fix erreichte
    /// das Geraet nie. Dieselbe Klasse wie die eingebackene Breite (v3), nur
    /// fuer Urteile statt URLs.
    @Test("die Tor-Signatur leitet sich aus den Schwellen ab — kein Handzaehler")
    func signatureFollowsTheThresholds() {
        let signature = RadioLogoService.gateSignature
        #expect(signature.contains("\(RadioFaviconGate.minSide)"))
        #expect(signature.contains("\(RadioFaviconGate.touchIconMinSide)"))
        // Genau das ist der Punkt: aendert jemand eine Schwelle, aendert
        // sich die Signatur MIT — niemand muss an eine Version denken
        // (die Falle, in die der 400→800-Wechsel lief).
        #expect(signature == "\(RadioFaviconGate.minSide)-\(RadioFaviconGate.touchIconMinSide)")
    }
}

// MARK: - e32454e: die generierten Daten sind die erste Stufe

struct RadioLogoDataTests {
    @Test("die Tabelle traegt DATEINAMEN, nie fertige URLs")
    func storesFileNamesOnly() {
        // Die cb8bac1-Regel strukturell geprueft: kein Eintrag ist eine URL,
        // sonst waere die Breite wieder eingebacken.
        for (_, file) in RadioLogoData.commonsFiles {
            #expect(!file.contains("http"))
            #expect(!file.contains("width="))
        }
    }

    @Test("Kern-Sender werden ohne Netz beantwortet")
    func coreStationsResolveOffline() {
        // Stichproben aus den DACH-Kernen — sie sind der Grund fuer die
        // Tabelle: das Geraet soll fuer sie gar nicht erst die Kette laufen.
        let hits = ["SWR3", "WDR 2", "Ö 3", "SRF 1"]
            .compactMap { RadioLogoData.commonsFile(forName: $0) }
        #expect(hits.count >= 3, "die Kern-Koepfe sollten in den Daten stehen")
        #expect(RadioLogoData.commonsFile(forName: "Ein Sender ohne Eintrag") == nil)
    }

    /// 383a3e8 family stage of the table: a variant name carries the family
    /// head's mark — measured 12/122 initial-showing core stations covered,
    /// 0 false heads. The guards ARE the test surface.
    @Test("Familienkopf deckt Varianten; eigener Eintrag gewinnt; Wortgrenze hart")
    func familyHeadCoversVariants() {
        // bigFM NRW has no own entry — the bigFM family mark answers.
        #expect(RadioLogoData.commonsFile(forName: "bigFM NRW") == nil)
        #expect(RadioLogoService.curatedFile(forName: "bigFM NRW")
                == RadioLogoData.commonsFile(forName: "bigFM"))
        // An OWN entry always wins (the DLF-Kultur guard, by order):
        #expect(RadioLogoService.curatedFile(forName: "Deutschlandfunk Kultur")
                == RadioLogoData.commonsFile(forName: "Deutschlandfunk Kultur"))
        // Word boundary: a name CONTINUING the head in the same word is no kin.
        #expect(RadioLogoService.curatedFile(forName: "bigFMX") == nil)
        // No head, no answer.
        #expect(RadioLogoService.curatedFile(forName: "Völlig Unbekannt 9000") == nil)
    }
}
