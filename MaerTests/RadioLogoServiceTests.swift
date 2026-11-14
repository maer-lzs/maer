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
    @Test("a failed fetch is not a finding — only a clean no-hit may be booked")
    func failureIsNotANegative() throws {
        // The rule as a pure decision, so it holds independently of the network.
        let logo = try #require(URL(string: "https://logo.example/a.png"))
        #expect(RadioLogoService.booking(.failed("wikidata-search")) == .skip(stage: "wikidata-search"))
        #expect(RadioLogoService.booking(.noHit) == .store(nil, commonsFile: nil))
        #expect(RadioLogoService.booking(.hit(logo, commonsFile: "A.png", stage: "p154"))
                == .store(logo, commonsFile: "A.png"))
    }

    /// The chain asks the rule and books in one place only, so a second
    /// write (a failure booked after all) or a switch past the rule shows.
    @Test("the logo chain books only through the rule, in one place", .needsTheSources)
    func theChainBooksThroughTheRuleOnly() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Networking/RadioLogoService.swift"),
            encoding: .utf8))
        #expect(code.contains("switch Self.booking(outcome)"), "the chain decides past the rule")
        let writes = code.components(separatedBy: "persistResult(stationID:").count - 1
        #expect(writes == 2, "one declaration and one booking call, found \(writes - 1) calls")
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
}
#endif

// MARK: - A verdict holds only under its gate

struct RadioLogoGateVersioningTests {
    /// The SRF 1 case: the chain delivers (463 px), but a NO stored under
    /// the 64 px gate blocked the retry, so a threshold change never reached
    /// the device. The same class as the baked-in width, for verdicts
    /// instead of URLs.
    @Test("the gate signature derives from the thresholds, no hand-kept counter")
    func signatureFollowsTheThresholds() {
        let signature = RadioLogoService.gateSignature
        #expect(signature.contains("\(RadioFaviconGate.minSide)"))
        #expect(signature.contains("\(RadioFaviconGate.touchIconMinSide)"))
        // A changed threshold changes the signature with it, so no version
        // has to be bumped by hand (the 400 to 800 width change missed one).
        #expect(signature == "\(RadioFaviconGate.minSide)-\(RadioFaviconGate.touchIconMinSide)")
    }
}

// MARK: - The generated data is the first stage

struct RadioLogoDataTests {
    @Test("the table carries FILE NAMES, never finished URLs")
    func storesFileNamesOnly() {
        // No entry is a URL; a URL would bake the width in again.
        for (_, file) in RadioLogoData.commonsFiles {
            #expect(!file.contains("http"))
            #expect(!file.contains("width="))
        }
    }

    @Test("core stations are answered without the network")
    func coreStationsResolveOffline() {
        // Samples from the DACH cores, each bound to its station object.
        // They are why the table exists: the device does not run the chain
        // for them.
        let hits = ["SWR3", "WDR 2", "Ö3", "1LIVE"]
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
        #expect(RadioLogoData.commonsFile(forName: "SWR3 Elchradio") == nil)
        let head = RadioLogoData.commonsFile(forName: "SWR3")
        #expect(head?.lowercased().hasSuffix(".svg") == true)
        #expect(RadioLogoService.curatedFile(forName: "SWR3 Elchradio") == head)
        // An OWN entry always wins (the DLF-Kultur guard, by order):
        #expect(RadioLogoService.curatedFile(forName: "Deutschlandfunk Kultur")
                == RadioLogoData.commonsFile(forName: "Deutschlandfunk Kultur"))
        // The two stations carry their house's square mark, not the word
        // mark their object declares.
        #expect(RadioLogoData.commonsFile(forName: "Deutschlandfunk") == "Deutschlandfunk Logo klein.png")
        #expect(RadioLogoData.commonsFile(forName: "Deutschlandfunk Kultur") == "Deutschlandfunk Kultur Logo klein.png")
        // Word boundary: a name CONTINUING the head in the same word is no kin.
        #expect(RadioLogoService.curatedFile(forName: "SWR3X") == nil)
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
        // The stored results live in the door's directory under `radio|`.
        func write(_ entries: [String: String], to defaults: UserDefaults) {
            for (id, url) in entries {
                Artwork.Memo.remember("radio|" + id, value: url, until: nil, defaults: defaults)
            }
        }
        func read(_ defaults: UserDefaults) -> [String: Artwork.Memo.Entry] {
            Artwork.Memo.entries(prefix: "radio|", defaults: defaults)
        }
        let suite = "radio-logo-redecide-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = "radio:rb:redecide-\(UUID().uuidString)"
        write([id: "https://dead.example/v5.176/icon.png"], to: defaults)

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
        write([small: "https://x.example/apple-icon-57x57.png"], to: defaults)
        #expect(RadioLogoService.discardStoredEntry(stationID: small, defaults: defaults))
        #expect(read(defaults)[small] == nil)
    }
}

// MARK: - Bundesliga streams

struct RadioLogoBundesligaTests {

    /// BOTH Bundesliga families carry the Bundesliga logo, through ONE
    /// curated entry that the prefix rule in `curatedFile` hands to both.
    /// The tiles are named "Fußball-Bundesliga: Spiel 1" and
    /// "Fußball-Bundesliga 2: Spiel 1". A second entry would be a second
    /// truth for the same assignment. No radio station object carries this
    /// logo, so the entry stands in belegt.json as the one entry without a
    /// binding.
    @Test("one entry carries both Bundesliga families")
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

    /// The prefix rule is not "happens to start alike": the rest MUST begin
    /// at a word boundary (a text match carries no meaning, measured on
    /// laut.fm names).
    @Test("a continued word does NOT inherit")
    func aContinuedWordIsNoFamily() {
        #expect(RadioLogoService.curatedFile(forName: "Fußball-Bundesligahasser") == nil)
    }

    /// The entry must pass the tile gate. Checkable on the data is the one
    /// condition under which it ALWAYS holds: MediaWiki never upscales a
    /// raster, an SVG renders at every width. A raster here would need a
    /// network measurement, and that belongs in the generator
    /// (`renders_at_tile_size`), not in the fence.
    @Test("the entry cannot die at the gate")
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

/// A refusal is not a finding. Before this rule every non-2xx below 500
/// became a clean "no logo" and was booked for the whole negative span, so
/// a throttled or blocking host took a station's logo away for two weeks.
/// The rule is pure; the second witness runs the WHOLE chain over a fake
/// host and reads the store, so the rule cannot drift from the booking.
struct RadioLogoRefusalTests {
    @Test("only a real not-there is a clean no; a refusal and a server error say nothing")
    func theStatusRule() {
        #expect(RadioLogoService.fetchResult(forStatus: 404) == .empty)
        #expect(RadioLogoService.fetchResult(forStatus: 410) == .empty)
        for refused in [401, 403, 429] {
            #expect(RadioLogoService.fetchResult(forStatus: refused) == .failed, "\(refused) is a refusal, not a no")
        }
        for server in [500, 502, 503] {
            #expect(RadioLogoService.fetchResult(forStatus: server) == .failed, "\(server) says nothing about the station")
        }
        #expect(RadioLogoService.fetchResult(forStatus: 400) == .failed)
    }

    /// A host that answers every question with the one status it was given.
    private actor Host {
        let status: Int
        private(set) var asked = 0
        init(status: Int) { self.status = status }
        func answer(_ request: URLRequest) -> (Data, HTTPURLResponse?) {
            asked += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status,
                                            httpVersion: nil, headerFields: nil))
        }
    }

    @Test("over the carrier: a 404 books a no, a 429 and a 500 book nothing")
    @MainActor func aRefusalLeavesNoNegativeMemo() async {
        let suite = "radio-logo-refusal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // The chain switch is a global default: set it, then put it back.
        let key = AppStorageKeys.radioLogoChainEnabled
        let was = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        func run(status: Int, station: String) async -> (booked: Bool, asked: Int) {
            let host = Host(status: status)
            let service = RadioLogoService(wire: { await host.answer($0) }, suite: suite)
            // A one-word name the curated table does not know, and no
            // homepage: the chain asks Wikidata and then has nowhere to go.
            _ = await service.logoURL(stationID: station, name: "Zzzunknownwave", homepage: nil)
            // The store lists its entries without the namespace prefix.
            let entry = Artwork.Memo.entries(prefix: "radio|", defaults: defaults)[station]
            return (entry != nil, await host.asked)
        }
        // 404 first: it proves the chain reaches the host and the booking,
        // so the two legs after it cannot pass by never getting there.
        let notThere = await run(status: 404, station: "s404")
        #expect(notThere.asked > 0, "the chain must have asked the host")
        #expect(notThere.booked, "a clean not-there is booked as a no")
        let throttled = await run(status: 429, station: "s429")
        #expect(throttled.asked > 0)
        #expect(!throttled.booked, "a refusal leaves no negative memo")
        let broken = await run(status: 500, station: "s500")
        #expect(broken.asked > 0)
        #expect(!broken.booked, "a server error leaves no negative memo")
    }

    @Test("the root of the host is the address without a path, a page at the root has none")
    func theRootOfTheHost() {
        let deep = URL(string: "https://www.radio.test/webradio/deutschrap?x=1#top")!
        #expect(RadioLogoLookup.rootPageURL(of: deep)?.absoluteString == "https://www.radio.test/")
        for root in ["https://www.radio.test", "https://www.radio.test/"] {
            #expect(RadioLogoLookup.rootPageURL(of: URL(string: root)!) == nil, "\(root) is asked twice")
        }
        #expect(RadioLogoLookup.rootPageURL(of: URL(string: "https://www.radio.test/?stream=1")!)?.absoluteString
                == "https://www.radio.test/")
    }

    /// A site whose station page refuses while its root page declares an
    /// icon on another host; everything else is not there.
    private actor Site {
        let page: Int
        let root: Int
        let rootHTML: String
        let icon: Data
        private(set) var asked: [String] = []
        init(page: Int, root: Int, rootHTML: String, icon: Data) {
            self.page = page
            self.root = root
            self.rootHTML = rootHTML
            self.icon = icon
        }
        func answer(_ request: URLRequest) -> (Data, HTTPURLResponse?) {
            let url = request.url!
            asked.append(url.absoluteString)
            func reply(_ status: Int, _ body: Data = Data()) -> (Data, HTTPURLResponse?) {
                (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
            }
            switch (url.host, url.path) {
            case ("www.radio.test", "/webradio/deutschrap"): return reply(page)
            case ("www.radio.test", "/"): return reply(root, Data(rootHTML.utf8))
            case ("file.radio.test", "/icon.png"): return reply(200, icon)
            default: return reply(404)
            }
        }
    }

    private func png(side: Int) -> Data {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// The station page refuses (403) and the root of the same host
    /// declares an icon: the logo comes from the root. A refusing root, or
    /// one without an icon, leaves the refusal as it was: nothing booked.
    @Test("a page that refuses takes the icon of the root of the same host, and a refusal stays without a finding")
    func aRefusingPageTakesTheIconOfItsRoot() async {
        let declared = #"<html><head><link rel="apple-touch-icon" sizes="512x512" href="https://file.radio.test/icon.png"></head></html>"#
        let icon = png(side: 512)
        #expect(RadioLogoLookup.usableLogo(icon), "the precondition: the icon clears the gate")
        let homepage = "https://www.radio.test/webradio/deutschrap"
        func audit(page: Int, root: Int, html: String) async -> (said: String, asked: [String]) {
            let site = Site(page: page, root: root, rootHTML: html, icon: icon)
            let service = RadioLogoService(wire: { await site.answer($0) }, suite: "radio-logo-root-\(UUID().uuidString)")
            let said = await service.auditChain(name: "Zzzunknownwave Rap", homepage: homepage)
            return (said, await site.asked)
        }
        let taken = await audit(page: 403, root: 200, html: declared)
        #expect(taken.said == "TREFFER stufe=wurzel datei=https://file.radio.test/icon.png", "\(taken.said)")
        #expect(taken.asked.contains("https://www.radio.test/webradio/deutschrap"), "the chain never asked the page")
        let refused = await audit(page: 403, root: 403, html: declared)
        #expect(refused.said == "FEHLSCHLAG stufe=homepage", "a refusing root: \(refused.said)")
        let bare = await audit(page: 403, root: 200, html: "<html></html>")
        #expect(bare.said == "FEHLSCHLAG stufe=homepage", "a root without an icon books a no: \(bare.said)")
        let open = await audit(page: 200, root: 200, html: declared)
        #expect(!open.asked.contains("https://www.radio.test/"), "a page that answers asks the root: \(open.asked)")
        // A page that names nothing asks the root too; a host that asked
        // for a pause or fails is not asked once more.
        for gone in [404, 410] {
            let found = await audit(page: gone, root: 200, html: declared)
            #expect(found.said == "TREFFER stufe=wurzel datei=https://file.radio.test/icon.png", "\(gone): \(found.said)")
        }
        for quiet in [429, 503] {
            let held = await audit(page: quiet, root: 200, html: declared)
            #expect(held.said == "FEHLSCHLAG stufe=homepage", "\(quiet): \(held.said)")
            #expect(!held.asked.contains("https://www.radio.test/"), "\(quiet) asks the root: \(held.asked)")
        }
    }

    /// When the root is asked, by the page's status alone.
    @Test("the root is asked after a refusal and after not found, not after a pause, a server error and no answer")
    func whenTheRootIsAsked() {
        let table: [(Int?, Bool)] = [(401, true), (403, true), (404, true), (410, true),
                                     (429, false), (500, false), (503, false), (200, false), (nil, false)]
        for (status, asks) in table {
            #expect(RadioLogoLookup.asksRoot(afterPageStatus: status) == asks, "\(String(describing: status))")
        }
    }
}

