// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import CryptoKit
import Foundation
@testable import Maer

/// Der Zaun auf den Vertrag, App-Seite.
///
/// Der Dienst wohnt seit dem Umzug in einem eigenen Repo. `CONTRACT.md`
/// liegt in beiden, Byte fuer Byte gleich, und jede Seite haelt ihn gegen
/// den EIGENEN Code. **Kein Zaun sieht das andere Repo**, und das steht so
/// im Vertrag statt verschwiegen zu werden: was die zwei Zaeune bringen,
/// ist, dass eine Aenderung am Draht, die nur eine Seite anfasst, dort beim
/// naechsten Lauf rot wird, statt still zu bleiben, bis ein Geraet aufhoert
/// zu gleichen.
struct SyncContractFenceTests {
    nonisolated static func contractText() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("docs/maer-sync-contract.md"),
                          encoding: .utf8)
    }

    /// Der maschinenlesbare Block, Name auf Werte.
    nonisolated static func declared(in text: String) -> [String: [String]] {
        guard let start = text.range(of: "<!-- maer-sync-contract"),
              let end = text.range(of: "-->", range: start.upperBound..<text.endIndex)
        else { return [:] }
        var out: [String: [String]] = [:]
        for line in text[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            out[parts[0].trimmingCharacters(in: .whitespaces)] =
                parts[1].split(separator: " ").map(String.init)
        }
        return out
    }

    /// Nicht `nonisolated`: die Datei-Aufzaehlung des Projekt-Zauns ist an
    /// den Hauptakteur gebunden, und der Sprachmodus laesst einen Aufruf von
    /// aussen nicht zu. Die zwei Helfer darueber brauchen ihn nicht.
    @MainActor
    static func sources() throws -> String {
        try ProjectFileIntegrityTests.sourceFiles()
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// Nur die zwei Dateien, die mit dem Dienst reden.
    ///
    /// Der ganze Quellbaum taugt fuer eine dreistellige Zahl nicht: `503`
    /// steht als Genre-Gewicht in `CatalogGenreAxis`, `413` und `403` finden
    /// sich in Wikidata-Kennungen. Ein Zaun, der eine Zahl irgendwo sucht,
    /// findet sie immer.
    nonisolated static func syncSources() throws -> String {
        let net = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Networking")
        // Drei Dateien, und die dritte kam vom Zaun selbst: der 403 wird in
        // der Anmeldung behandelt, nicht im Klienten, und der Fall sagte es,
        // statt gruen zu bleiben.
        return try ["MaerSyncClient.swift", "MaerSyncCarriers.swift", "MaerSyncSignIn.swift"]
            .map { try String(contentsOf: net.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// Antworten, die BEIM NAMEN behandelt werden, je mit ihrem Grund.
    nonisolated static let byName: [String: String] = [
        "200": "die einzige gelungene",
        "401": "haelt die Runden an, bis sich jemand neu anmeldet",
        "404": "kein solches Dokument, eine gewoehnliche Antwort",
        "409": "der Schrieb schrumpfte ohne Ansage, mit eigenem Satz",
        "412": "die Fassung hat sich bewegt, also neu lesen und wiederholen",
        "503": "der Dienst hat noch keine Kennung, und das kann ein Mensch beenden",
        "410": "die Sitzung ist beendet; ein Handschlag und eine Wiederholung, kein Satz an einen Menschen",
        "403": "steht mit Absicht NICHT im Vertrag: er kommt von etwas davor",
        "428": "das Passwort setzte der Betreiber; die Anmeldung fragt nach einem neuen, nichts reist",
        "429": "zu viele Fehlversuche; die Seite sagt mit Retry-After, wann, und nichts wiederholt sich selbst",
    ]

    /// Antworten, die absichtlich allgemein bleiben, je mit ihrem Grund.
    /// Sie bedeuten fuer die App dasselbe: die Anfrage war falsch oder zu
    /// gross, und daran ist zur Laufzeit nichts zu unterscheiden.
    nonisolated static let deliberatelyGeneric: [String: String] = [
        "400": "die Anfrage ist keine; die App baut sie selbst, also ist das ein Fehler bei uns",
        "405": "der Pfad gibt es und nicht fuer diese Art; ebenfalls unser Fehler",
        "413": "der Rumpf ist groesser als der Wirt annimmt; nichts, was die App zur Laufzeit anders machen kann",
        "426": "die alten Wege sind abgeschaltet; diese App spricht seit Fassung 5 nie im Klartext, also trifft sie ihn nicht",
    ]

    /// Derselbe Quelltext OHNE Kommentarzeilen.
    ///
    /// Gebaut, weil eine Rot-Probe gruen blieb: ich hatte die Behandlung des
    /// 503 aus dem Code genommen, und der Zaun fand die Zahl trotzdem, denn
    /// sie steht im KOMMENTAR daneben, der erklaert, warum es keine nackte
    /// Zahl sein soll. Ein Quell-Sucher, der Kommentare mitzaehlt, bewacht
    /// das Reden ueber die Sache statt der Sache.
    nonisolated static func stripped(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Der Abdruck des Vertrags, wie er HEUTE in BEIDEN Repos steht.
    ///
    /// **Was er bringt und was er nicht bringen kann.** Kein Zaun in einem
    /// Repo sieht das andere, also kann nichts hier ERKENNEN, dass die zwei
    /// Kopien auseinandergelaufen sind. Was er kann: eine Aenderung auf der
    /// Seite laut machen, auf der sie geschieht. Wer ein Byte anfasst, wird
    /// hier angehalten und im Fehlertext daran erinnert, dass die andere
    /// Seite mitziehen muss.
    ///
    /// **Die Fassungszahl deckt das nicht.** Sie wird von Hand erklaert, also
    /// ist jede Aenderung, die sie in Ruhe laesst, fuer jeden anderen Fall
    /// hier unsichtbar: eine umformulierte Zusage, ein Status, der still
    /// seine Bedeutung wechselt, und vor allem ein Pfad, der nur in die
    /// PROSA-TABELLE geraet statt in den Maschinen-Block, den als einziger
    /// irgendein Fall liest. Der Abdruck deckt jedes Byte.
    nonisolated static let contractDigest =
        "283761495f6fd0abc669ca30ab97fc02370addf3a7353e0fc770acfe32143b55"

    /// Dasselbe fuer die veroeffentlichten Vektoren, die ebenfalls zweimal
    /// liegen. Sie sind fremde Zahlen, wortgetreu kopiert, also hiesse ein
    /// Unterschied zwischen den Kopien, dass eine von beiden keine Kopie
    /// mehr ist.
    nonisolated static let vectorsDigest =
        "f33e06a31acb005ff39acea462a19fe02f3354a6da113abfa6febadd13d6f196"

    nonisolated static func digest(ofFileAt url: URL) throws -> String {
        try Data(contentsOf: url).sha256Hexed
    }

    @Test("der Vertrag ist die vereinbarten Bytes")
    func theContractIsTheAgreedBytes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        #expect(try Self.digest(ofFileAt: root.appendingPathComponent("docs/maer-sync-contract.md"))
                == Self.contractDigest,
                "der Vertrag hat sich geaendert. Das ist erlaubt und nie einseitig: denselben neuen Abdruck in den Zaun des Dienst-Repos schreiben und dieselbe Datei hinuebertragen, sonst beschreiben die zwei Enden still nicht mehr denselben Dienst")
    }

    @Test("die veroeffentlichten Vektoren sind die vereinbarten Bytes")
    func theVectorsAreTheAgreedBytes() throws {
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        #expect(try Self.digest(ofFileAt: here.appendingPathComponent("Fixtures/Noise/noise-nk.json"))
                == Self.vectorsDigest,
                "die veroeffentlichten Vektoren haben sich geaendert. Sie sind wortgetreu von zwei fremden Umsetzungen kopiert, eine Aenderung ist also entweder eine neue Herkunft in BEIDEN Repos oder ein Fehler")
    }

    /// Eine Gestalt mit einem Grund, und der Grund ist der Vorschalt-Server.
    ///
    /// Der Dienst wird nach seiner eigenen Anleitung durch einen erreicht,
    /// und nginx macht einen Anfrage-Kopf mit Unterstrich im Namen zuerst
    /// UNGUELTIG (`underscores_in_headers off`, die Vorgabe) und wirft
    /// Ungueltiges dann weg (`ignore_invalid_headers on`, ebenfalls Vorgabe).
    /// Zwei Richtlinien und nicht eine: wer die zweite je umstellt, aendert
    /// das Verhalten, ohne die erste anzufassen. So oder so sehen ein Kopf,
    /// den niemand gesetzt hat, und einer, den der Proxy gefressen hat, von
    /// hier aus genau gleich aus.
    ///
    /// Die zwei eigenen Koepfe, die es gibt, reisen heute durch einen echten
    /// Proxy und tun es. Daher kommt die Gestalt: am Betrieb gemessen statt
    /// begruendet. Dieser Fall haelt den naechsten in derselben Gestalt,
    /// statt es dem zu ueberlassen, der ihn hinzufuegt.
    @Test("kein erklaerter Kopfname traegt einen Unterstrich")
    func noDeclaredHeaderNameCarriesAnUnderscore() throws {
        let headers = Self.declared(in: try Self.contractText())["headers"] ?? []
        #expect(!headers.isEmpty, "ohne Koepfe misst dieser Fall nichts")
        let offenders = headers.filter { $0.contains("_") }.sorted()
        #expect(offenders.isEmpty,
                "ein Proxy vor dem Dienst darf diese wortlos verwerfen, und ein gefressener Kopf ist von einem nie gesetzten nicht zu unterscheiden: \(offenders)")
    }

    /// Die zwei Pfade der verschluesselten Sitzung tragen KEIN Zeichen, und
    /// das ist das Muster und keine Nachlaessigkeit.
    ///
    /// Der Anrufer weist sich INNERHALB der Sitzung aus. Genau das schuetzt
    /// die Anmeldung, denn die traegt das Konto-Geheimnis und findet statt,
    /// bevor es ein Zeichen gibt, mit dem man irgendetwas beweisen koennte.
    /// Wer hier ein Zeichen verlangte, schuetzte alles ausser dem einen
    /// Austausch, auf den es am meisten ankommt.
    ///
    /// Gelesen wird der RUMPF der zwei Funktionen, nicht die Datei: ein
    /// Fenster ueber die ganze Datei faende die Zeichen-Tuer der vier
    /// anderen Wege und waere immer rot.
    @Test("die zwei Sitzungs-Wege setzen kein Zeichen", .needsTheSources)
    func theTwoSessionWaysSetNoToken() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let whole = try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncClient.swift"),
                               encoding: .utf8)
        // Erst ab der Tuer: seit `serviceKey` eine ANFORDERUNG des Protokolls
        // ist, steht sein Name zweimal in der Datei, und der erste Treffer
        // war die Deklaration. Dieser Fall hat daraufhin die Zeilen zwischen
        // zwei Protokollen gelesen und gruen gemeldet, ohne die Tuer je
        // gesehen zu haben.
        let door = try #require(whole.range(of: "final class MaerSyncHTTP"), "die Tuer gibt es nicht mehr")
        let tunnel = try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncTunnel.swift"),
                                encoding: .utf8)
        // Der Handschlag wohnt seit Fassung 5 im Tunnel, nicht in der Tuer.
        for (text, name) in [(String(whole[door.upperBound...]), "func serviceKey(at baseURL: URL)"),
                             (tunnel, "static func handshake(at base: URL")] {
            let start = try #require(text.range(of: name), "\(name) gibt es nicht mehr")
            let rest = text[start.upperBound...]
            let end = rest.range(of: "\n    /// ") ?? rest.range(of: "\n    func ")
            let body = end.map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            #expect(!body.contains("authoriz"),
                    "\(name) setzt ein Zeichen; damit waere die Anmeldung der einzige ungeschuetzte Austausch")
        }
    }

    /// Die Gegenrichtung, sonst misst der Fall darueber nur, dass ein Wort
    /// fehlt: die drei Wege mit Zeichen gehen durch die EINE Stelle, die es
    /// in den Kopf legt, die Steckdose legt es in ihren ersten Rahmen, und
    /// die Anmeldung geht an beiden vorbei, weil sie noch keines hat.
    @Test("die anderen Wege setzen sehr wohl ein Zeichen, und seit Fassung 5 nur noch im Rahmen", .needsTheSources)
    func theOtherWaysDoSetATokenAfterAll() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = Self.stripped(try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncClient.swift"),
                                            encoding: .utf8))
        #expect(text.components(separatedBy: "MaerSyncHeaders.authorization(").count - 1 == 2,
                "das Zeichen wird an zwei Stellen in einen Kopf gelegt: im Helfer der drei Wege und im ersten Rahmen der Steckdose")
        #expect(text.components(separatedBy: "try await inside(access, ").count - 1 == 3,
                "drei Wege tragen das Zeichen: lesen, schreiben, auflisten")
        // Beide Dateien, die Anfragen bauen: die Tuer und der Tunnel. Ein
        // Zeichen auf der AEUSSEREN Anfrage des Tunnels waere dieselbe
        // Luecke eine Datei weiter.
        let tunnel = Self.stripped(try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncTunnel.swift"),
                                              encoding: .utf8))
        #expect(!(text + tunnel).contains("forHTTPHeaderField: \"Authorization\""),
                "kein Zeichen liegt mehr auf einer Anfrage im Klartext")
        #expect(!tunnel.contains("MaerSyncHeaders."), "der Tunnel kennt das Zeichen nicht; er versiegelt, was die Tuer ihm gibt")
    }

    @Test("die zwei Sitzungs-Wege bauen ihre Adresse ueber die eine Tuer")
    func theTwoSessionWaysBuildTheirAddressThroughTheOneDoor() {
        let base = URL(string: "https://sync.example.com")!
        #expect(MaerSyncPaths.key(base).absoluteString == "https://sync.example.com/v2/key")
        #expect(MaerSyncPaths.session(base).absoluteString == "https://sync.example.com/v1/session")
    }

    @Test("der Vertrag liegt hier und nennt seine Fassung zweimal")
    func theContractIsHereAndNamesItsVersionTwice() throws {
        let text = try Self.contractText()
        #expect(Self.declared(in: text)["version"] == ["6"])
        // Zweimal mit Absicht: einmal fuer den Leser, einmal fuer den Zaun.
        // Wer eines hochzieht und das andere nicht, reisst hier.
        #expect(text.contains("**Version: 6**"))
        #expect(MaerSyncSignIn.contractVersion == 6, "die App nennt dieselbe Fassung, die sie hier liest")
    }

    @Test("jeden Pfad, den der Vertrag verspricht, ruft diese App auch", .needsTheSources)
    func everyPromisedPathIsCalled() throws {
        let text = try Self.sources()
        for path in Self.declared(in: try Self.contractText())["paths"] ?? [] {
            // Der Vertrag schreibt den Pfad mit fuehrendem Strich, die App
            // haengt ihn an eine Grundadresse. Verglichen wird der Rumpf.
            let stem = path.hasPrefix("/") ? String(path.dropFirst()) : path
            #expect(text.contains(stem), "der Vertrag verspricht \(path), die App ruft ihn nicht")
        }
    }

    /// Die GEGENRICHTUNG, dieselbe Luecke, die frueher der Dienst hatte: bis
    /// hierher hielt der Zaun nur, dass jeder versprochene Pfad gerufen
    /// wird. Ein Pfad, den die App ruft und der Vertrag nicht nennt, blieb
    /// gruen. Beide Richtungen in einem Fall, mit dem Melder fuer das eigene
    /// Loch: sieht der Sucher weniger Pfade als erklaert, sagt er es.
    @Test("jeden Pfad, den diese App ruft, verspricht auch der Vertrag", .needsTheSources)
    func everyPathThisAppCallsIsInTheContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var text = ""
        for file in ["MaerSyncClient.swift", "MaerSyncTunnel.swift"] {
            text += Self.stripped(try String(contentsOf: root.appendingPathComponent("Sources/Networking/\(file)"),
                                             encoding: .utf8)) + "\n"
        }
        var called: Set<String> = []
        var cursor = text.startIndex
        // Jede Fassung eines Pfads, nicht nur v1: seit Fassung 6 steht
        // `/v2/key` im Vertrag, und ein Sucher nur nach v1 saehe ihn nie.
        while let range = text.range(of: "v[0-9]+/[a-z]+", options: .regularExpression, range: cursor..<text.endIndex) {
            called.insert("/" + text[range])
            cursor = range.upperBound
        }
        let declared = Set(Self.declared(in: try Self.contractText())["paths"] ?? [])
        #expect(!called.isEmpty, "ohne gefundene Pfade misst dieser Fall nichts")
        #expect(called.subtracting(declared).isEmpty,
                "diese App ruft Pfade, die der Vertrag nicht nennt: \(called.subtracting(declared).sorted())")
        #expect(declared.subtracting(called).isEmpty,
                "der Sucher sieht erklaerte Pfade nicht, also sagt sein Schweigen nichts: \(declared.subtracting(called).sorted())")
    }

    @Test("jede Kopfzeile, die diese App nennt, verspricht auch der Vertrag", .needsTheSources)
    func everyHeaderThisAppNamesIsInTheContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = Self.stripped(try Self.syncSources()) + "\n"
            + Self.stripped(try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncTunnel.swift"),
                                       encoding: .utf8))
        // Die eigenen Koepfe und die vier des Vertrags aus dem Standard
        // (`Retry-After` seit Fassung 6; der Melder unten fand ihn fehlen).
        // `Content-Type` ist keiner von ihnen: er sagt, was ein Rumpf ist,
        // und der Vertrag erklaert Bedeutungen, nicht Formate.
        var named: Set<String> = []
        var cursor = text.startIndex
        while let range = text.range(of: "\"(X-Maer-[A-Za-z-]+|If-Match|ETag|Authorization|Retry-After)\"",
                                     options: .regularExpression, range: cursor..<text.endIndex) {
            named.insert(String(text[range].dropFirst().dropLast()))
            cursor = range.upperBound
        }
        let declared = Set(Self.declared(in: try Self.contractText())["headers"] ?? [])
        #expect(!named.isEmpty, "ohne gefundene Koepfe misst dieser Fall nichts")
        #expect(named.subtracting(declared).isEmpty,
                "diese App nennt Koepfe, die der Vertrag nicht nennt: \(named.subtracting(declared).sorted())")
        #expect(declared.subtracting(named).isEmpty,
                "der Sucher sieht erklaerte Koepfe nicht: \(declared.subtracting(named).sorted())")
    }

    @Test("jede Kopfzeile des Vertrags setzt oder liest diese App", .needsTheSources)
    func everyPromisedHeaderIsUsed() throws {
        let text = try Self.sources()
        for header in Self.declared(in: try Self.contractText())["headers"] ?? [] {
            #expect(text.contains(header), "der Vertrag verspricht \(header), niemand setzt sie")
        }
    }

    @Test("jede Sorte des Vertrags kennt diese App beim Namen", .needsTheSources)
    func everyKindIsNamedHere() throws {
        // Die GEGENRICHTUNG zum Zaun auf der Dienst-Seite, und die
        // Asymmetrie ist die Sache selbst: der Dienst darf keine Sorte
        // kennen, er prueft die FORM eines Namens. Die App muss alle sechs
        // kennen, denn sie entscheidet, was in welche gehoert.
        let text = try Self.sources()
        for kind in Self.declared(in: try Self.contractText())["kinds"] ?? [] {
            #expect(text.contains("\"\(kind)\""),
                    "der Vertrag nennt die Sorte \(kind), die App kennt sie nicht")
        }
    }

    @Test("die Socket-Nachricht ist die, die im Vertrag steht", .needsTheSources)
    func theSocketMessageIsTheOneInTheContract() throws {
        // Fassung 2. Bis dahin waren sich die zwei Seiten durch Zufall der
        // Umsetzung einig, nicht durch eine geschriebene Vereinbarung: ein
        // umbenanntes Feld haette auf keiner Seite laut versagt, die App
        // haette nil gelesen, waere still auf ihren eigenen Takt gefallen
        // und die Uebernahme nur langsamer geworden.
        let text = try Self.sources()
        for field in ["\"kind\"", "\"scope\"", "\"version\""] {
            #expect(text.contains(field), "die App liest das Socket-Feld \(field) nicht")
        }
        #expect(try Self.contractText()
            .contains("{\"kind\": \"<kind>\", \"scope\": \"<scope>\", \"version\": \"<etag>\"}"))
    }

    @Test("die Antworten, auf die der Vertrag die App festlegt, behandelt sie", .needsTheSources)
    func thePromisedAnswersAreHandled() throws {
        let text = Self.stripped(try Self.sources())
        let declared = Self.declared(in: try Self.contractText())["status"] ?? []
        // 403 steht mit Absicht NICHT im Vertrag: der Dienst sendet nie
        // eine. Die App liest sie trotzdem, weil sie von etwas davor kommt,
        // und genau diese Trennung darf nicht verlorengehen.
        #expect(!declared.contains("403"), "403 gehoert nicht in den Vertrag des Dienstes")
        #expect(text.contains("403"), "die App liest den 403 des Vorgelagerten weiter")
        // Jede erklaerte Antwort ist entweder BEIM NAMEN behandelt oder
        // absichtlich allgemein, und beides steht mit Grund im Bestand. Was
        // hier vorher stand, war eine Auswahl von drei Zahlen, gesucht per
        // `contains` ueber den GANZEN Quellbaum, und das war doppelt zu
        // schwach: der Vertrag lernte 503 dazu, ohne dass der Fall es
        // bemerkte, und 403 wie 413 standen als gruen da, obwohl die App
        // sie nirgends vergleicht. Gefunden wurden sie als Ziffern in einer
        // Wikidata-Kennung und in einer Genre-Tabelle (`"fiction": 503`).
        let sync = Self.stripped(try Self.syncSources())
        for (status, grund) in Self.byName {
            #expect(declared.contains(status) || status == "403",
                    "\(status) wird beim Namen behandelt und ist nicht erklaert: \(grund)")
            #expect(sync.contains("case \(status)") || sync.contains("statusCode == \(status)"),
                    "\(status) soll beim Namen behandelt werden (\(grund)) und wird es nicht")
        }
        let benannt = Set(Self.byName.keys)
        let allgemein = Set(Self.deliberatelyGeneric.keys)
        #expect(benannt.isDisjoint(with: allgemein), "eine Antwort ist das eine oder das andere")
        #expect(Set(declared).subtracting(benannt).subtracting(allgemein).isEmpty,
                "jede erklaerte Antwort ist beim Namen behandelt oder mit Grund allgemein")
    }
}

nonisolated extension Data {
    /// Der Abdruck als Hex, ohne CryptoKit in einer Zaun-Datei: die Zaeune
    /// laufen auch dort, wo niemand ein Rahmenwerk erwartet, und SHA-256
    /// liegt hier ohnehin schon als Werkzeug vor.
    var sha256Hexed: String {
        Data(SHA256.hash(data: self)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
