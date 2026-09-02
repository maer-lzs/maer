// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import Maer

/// The negative cache poisoned itself. A transport failure was
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

    /// A stored "no" is only valid for the chain that produced
    /// it. The sibling stage joined on 21.08.. Negatives booked by the
    /// shorter chain kept answering for 14 days ("bigFM Deutsch Rap" showed
    /// initials although the family favicon exists). v3→v4 drops negatives
    /// once; positives (URL or commons file) stay. A hit is a hit under any
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

    /// The audit caught the runtime P154 stage booking FOREIGN
    /// marks. And a positive never expires. v5 drops exactly the MEASURED
    /// files (LIFE magazine, Reset Media), nothing else: no sweep, no
    /// negative touched, every honest positive stays.
    @Test func knownForeignMarksAreDroppedOnceAndOnlyThose() {
        let suite = "radio-logo-v5-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date().timeIntervalSince1970
        write(["radio:rb:life": Stored(url: nil, resolvedAt: now,
                                       commonsFile: "LIFE magazine logo.svg"),
               "radio:rb:reshet": Stored(url: nil, resolvedAt: now,
                                         commonsFile: "Reset Media.svg"),
               "radio:rb:ndr": Stored(url: nil, resolvedAt: now,
                                      commonsFile: "NDR Info Logo.svg"),
               "radio:rb:touch": Stored(url: "https://a.example/touch.png", resolvedAt: now),
               "radio:rb:no": Stored(url: nil, resolvedAt: now)], to: defaults)
        let dropped = RadioLogoService.migratePersisted(defaults: defaults, storedVersion: 4)
        #expect(dropped == 2)
        let kept = read(defaults)
        #expect(kept["radio:rb:life"] == nil)
        #expect(kept["radio:rb:reshet"] == nil)
        #expect(kept["radio:rb:ndr"] != nil, "ehrliche Positive bleiben")
        #expect(kept["radio:rb:touch"] != nil)
        #expect(kept["radio:rb:no"] != nil, "v4->v5 fasst keine Negative an")
    }

    @Test("bc11ed5: the politeness spacing leaves room for a screen full of tiles")
    func politeSpacing() {
        // The old 1 s came from the MusicBrainz manners; this chain talks to
        // Wikidata/Commons. With a screenful of tiles the fourth station's
        // turn came minutes late. Long after SwiftUI cancelled its task.
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
    /// ~46 px. The gate would reject the very source the decision made
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
        // And the requested width is actually 800. The URL carries it.
        let url = ArtistPortraitLookup.commonsThumbURL(fileName: "X.svg", width: 800)
        #expect(url?.query?.contains("width=800") == true)
    }

    /// The v3 healing. A positive persisted as a width=400 Commons
    /// URL becomes FILE-based, so the read builds today's width; touch icons
    /// and negatives stay as they are. The width change that shipped without
    /// a bump left devices on rejected 400×46 renders for 14 days.
    @Test("v3 heals persisted Commons positives to file names")
    func v3HealsCommonsPositives() throws {
        let file = "Deutschlandfunk Kultur Logo 2017.svg"
        #expect(RadioLogoService.commonsFileName(
            fromStoredURL: "https://commons.wikimedia.org/wiki/Special:FilePath/Deutschlandfunk%20Kultur%20Logo%202017.svg?width=400") == file)
        // Touch icons and garbage answer nil. They are not healed, kept.
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
    /// 64er-Zeit blockierte die Wiedervorlage. Ein Schwellen-Fix erreichte
    /// das Geraet nie. Dieselbe Klasse wie die eingebackene Breite (v3), nur
    /// fuer Urteile statt URLs.
    @Test("die Tor-Signatur leitet sich aus den Schwellen ab — kein Handzaehler")
    func signatureFollowsTheThresholds() {
        let signature = RadioLogoService.gateSignature
        #expect(signature.contains("\(RadioFaviconGate.minSide)"))
        #expect(signature.contains("\(RadioFaviconGate.touchIconMinSide)"))
        // Genau das ist der Punkt: aendert jemand eine Schwelle, aendert
        // sich die Signatur MIT. Niemand muss an eine Version denken
        // (die Falle, in die der 400→800-Wechsel lief).
        #expect(signature == "\(RadioFaviconGate.minSide)-\(RadioFaviconGate.touchIconMinSide)")
    }
}

// MARK: - Die generierten Daten sind die erste Stufe

struct RadioLogoDataTests {
    @Test("die Tabelle traegt DATEINAMEN, nie fertige URLs")
    func storesFileNamesOnly() {
        // Strukturell geprueft: kein Eintrag ist eine URL, sonst waere die
        // Breite wieder eingebacken.
        for (_, file) in RadioLogoData.commonsFiles {
            #expect(!file.contains("http"))
            #expect(!file.contains("width="))
        }
    }

    @Test("Kern-Sender werden ohne Netz beantwortet")
    func coreStationsResolveOffline() {
        // Stichproben aus den DACH-Kernen. Sie sind der Grund fuer die
        // Tabelle: das Geraet soll fuer sie gar nicht erst die Kette laufen.
        let hits = ["SWR3", "WDR 2", "Ö 3", "SRF 1"]
            .compactMap { RadioLogoData.commonsFile(forName: $0) }
        #expect(hits.count >= 3, "die Kern-Koepfe sollten in den Daten stehen")
        #expect(RadioLogoData.commonsFile(forName: "Ein Sender ohne Eintrag") == nil)
    }

    /// Family stage of the table: a variant name carries the family
    /// head's mark. Measured 12/122 initial-showing core stations covered,
    /// 0 false heads. The guards ARE the test surface.
    @Test("Familienkopf deckt Varianten; eigener Eintrag gewinnt; Wortgrenze hart")
    func familyHeadCoversVariants() {
        // The variant has no own entry. The family mark answers. The fence
        // rides on a family whose mark is an SVG and scales; a 256×37 raster
        // entry can never render and would fall at the quality gate.
        #expect(RadioLogoData.commonsFile(forName: "Radio Bob! rockt Schleswig-Holstein") == nil)
        let head = RadioLogoData.commonsFile(forName: "RADIO BOB!")
        #expect(head != nil)
        #expect(RadioLogoService.curatedFile(forName: "Radio Bob! rockt Schleswig-Holstein") == head)
        // An OWN entry always wins (the DLF-Kultur guard, by order):
        #expect(RadioLogoService.curatedFile(forName: "Deutschlandfunk Kultur")
                == RadioLogoData.commonsFile(forName: "Deutschlandfunk Kultur"))
        // Word boundary: a name CONTINUING the head in the same word is no kin.
        #expect(RadioLogoService.curatedFile(forName: "RADIO BOB!X") == nil)
        // No head, no answer.
        #expect(RadioLogoService.curatedFile(forName: "Völlig Unbekannt 9000") == nil)
        // The gate corpse itself stays OUT: bigFM has no table entry any
        // more, so the healed sibling favicon is visible again.
        #expect(RadioLogoData.commonsFile(forName: "bigFM") == nil)
        #expect(RadioLogoService.curatedFile(forName: "bigFM Deutsch Rap") == nil)
    }

    /// The display re-opens the decision. An undersized stored
    /// positive discards immediately, a dead address after TWO consecutive
    /// load failures; one failure is never a verdict, success clears strikes.
    @Test @MainActor func displayReDecision() async {
        struct Entry: Codable { var url: String?; var resolvedAt: Double }
        func write(_ entries: [String: Entry], to defaults: UserDefaults) {
            defaults.set(try! JSONEncoder().encode(entries), forKey: "radioLogoChainResults")
        }
        func read(_ defaults: UserDefaults) -> [String: Entry] {
            guard let data = defaults.data(forKey: "radioLogoChainResults") else { return [:] }
            return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
        }
        let suite = "radio-logo-redecide-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = "radio:rb:redecide-\(UUID().uuidString)"
        let now = Date().timeIntervalSince1970
        write([id: Entry(url: "https://dead.example/v5.176/icon.png", resolvedAt: now)],
              to: defaults)

        // First failure: entry stays (Negativ-Cache-Regel one level up).
        #expect(!RadioLogoService.registerDisplayFailure(stationID: id, defaults: defaults))
        #expect(read(defaults)[id] != nil)
        // A success in between clears the strike …
        RadioLogoService.clearDisplayStrikes(stationID: id, defaults: defaults)
        #expect(!RadioLogoService.registerDisplayFailure(stationID: id, defaults: defaults))
        #expect(read(defaults)[id] != nil, "strikes must be consecutive")
        // … two consecutive failures discard, re-opening the chain.
        #expect(RadioLogoService.registerDisplayFailure(stationID: id, defaults: defaults))
        #expect(read(defaults)[id] == nil)

        // Undersized: deterministic, discards on the first look.
        let small = "radio:rb:small-\(UUID().uuidString)"
        write([small: Entry(url: "https://x.example/apple-icon-57x57.png", resolvedAt: now)],
              to: defaults)
        #expect(RadioLogoService.discardStoredEntry(stationID: small, defaults: defaults))
        #expect(read(defaults)[small] == nil)
    }
}

// MARK: - Bundesliga-Sender

struct RadioLogoBundesligaTests {

    /// Der Entscheid lautet: BEIDE Bundesliga-Familien tragen das
    /// Bundesliga-Logo. Gebaut ist das als EIN kuratierter Eintrag, den die
    /// Praefix-Regel in `curatedFile` an beide Familien weiterreicht. Die
    /// Kacheln heissen "Fußball-Bundesliga: Spiel 1" und
    /// "Fußball-Bundesliga 2: Spiel 1". Ein zweiter Eintrag waere eine
    /// zweite Wahrheit fuer dieselbe Entscheidung.
    @Test("ein Eintrag traegt beide Bundesliga-Familien")
    func oneEntryCarriesBothFamilies() {
        let expected = "Bundesliga logo.svg"
        #expect(RadioLogoData.commonsFile(forName: "Fußball-Bundesliga") == expected)
        for name in ["Fußball-Bundesliga: Spiel 1",
                     "Fußball-Bundesliga: Konferenz",
                     "Fußball-Bundesliga 2: Spiel 1",
                     "Fußball-Bundesliga 2: Konferenz"] {
            #expect(RadioLogoService.curatedFile(forName: name) == expected,
                    "\(name) muss das Bundesliga-Logo erben")
        }
    }

    /// Rot-Probe der Praefix-Regel: sie darf nicht zu "faengt zufaellig
    /// gleich an" verkommen. Die Fortsetzung MUSS an einer Wortgrenze
    /// beginnen (die laut.fm-Lehre: Text-Treffer ohne Semantik).
    @Test("ein fortgesetztes Wort erbt NICHT")
    func aContinuedWordIsNoFamily() {
        #expect(RadioLogoService.curatedFile(forName: "Fußball-Bundesligahasser") == nil)
    }

    /// Die Auflage aus dem Entscheid: der Eintrag muss die
    /// Gate-Leichen-Pruefung bestehen. Am Datum pruefbar ist die eine
    /// Bedingung, unter der sie IMMER haelt. MediaWiki skaliert Raster nie
    /// hoch, eine SVG dagegen rendert in jeder Breite. Ein Raster hier waere
    /// nur mit einer Netzmessung zu verantworten, und die gehoert in den
    /// Generator (`renders_at_tile_size`), nicht in den Zaun.
    @Test("der Eintrag kann am Tor nicht sterben")
    func theEntryCannotBeAGateCorpse() {
        let file = RadioLogoData.commonsFile(forName: "Fußball-Bundesliga")
        #expect(file?.lowercased().hasSuffix(".svg") == true,
                "Raster muesste am width-800-Render gemessen werden — SVG ist die Zusage")
    }
}

/// The booking probe: reachable is not usable. Every chain stage runs its
/// answer through the SAME probe before a positive is written down, so an
/// error page with status 200 or an undersized stamp can no longer become
/// a stored "logo" that the display then refuses forever.
struct RadioLogoBookingProbeTests {
    private func pngData(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    @Test("a body that is no image never books, whatever the status said")
    func nonImageBodiesAreRefused() {
        let softErrorPage = Data("<html><body>Not found</body></html>".utf8)
        #expect(!RadioLogoLookup.usableLogo(softErrorPage))
        #expect(!RadioLogoLookup.usableLogo(Data()))
    }

    @Test("the probe applies the display's own floor, so booking and showing agree")
    func theGateDecides() {
        // 57 px is the classic touch-icon stock and clears the floor of 48;
        // a 20 px stamp is exactly what the display would refuse later.
        #expect(RadioLogoLookup.usableLogo(pngData(width: 57, height: 57)))
        #expect(!RadioLogoLookup.usableLogo(pngData(width: 20, height: 20)))
    }

    @Test("the pixel reading is exact, not a decode guess")
    func pixelReadingIsExact() {
        let pixels = ImageProbe.pixels(in:pngData(width: 100, height: 60))
        #expect(pixels?.width == 100)
        #expect(pixels?.height == 60)
    }
}

