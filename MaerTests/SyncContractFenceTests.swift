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
        "403": "steht mit Absicht NICHT im Vertrag: er kommt von etwas davor",
    ]

    /// Antworten, die absichtlich allgemein bleiben, je mit ihrem Grund.
    /// Sie bedeuten fuer die App dasselbe: die Anfrage war falsch oder zu
    /// gross, und daran ist zur Laufzeit nichts zu unterscheiden.
    nonisolated static let deliberatelyGeneric: [String: String] = [
        "400": "die Anfrage ist keine; die App baut sie selbst, also ist das ein Fehler bei uns",
        "405": "der Pfad gibt es und nicht fuer diese Art; ebenfalls unser Fehler",
        "413": "der Rumpf ist groesser als der Wirt annimmt; nichts, was die App zur Laufzeit anders machen kann",
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
        "4ff277396fec10a1f9726f66511c7edf0a9927882371ddeb0de5340896191b9e"

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
    @Test("die zwei Sitzungs-Wege setzen kein Zeichen")
    func theTwoSessionWaysSetNoToken() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncClient.swift"),
                              encoding: .utf8)
        for name in ["func serviceKey(at baseURL: URL)", "func openSession(firstMessage: Data"] {
            let start = try #require(text.range(of: name), "\(name) gibt es nicht mehr")
            let rest = text[start.upperBound...]
            let end = rest.range(of: "\n    /// ") ?? rest.range(of: "\n    func ")
            let body = end.map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            #expect(!body.contains("authorize"),
                    "\(name) setzt ein Zeichen; damit waere die Anmeldung der einzige ungeschuetzte Austausch")
        }
    }

    /// Die Gegenrichtung, sonst misst der Fall darueber nur, dass ein Wort
    /// fehlt: die vier anderen Wege MUESSEN das Zeichen setzen.
    @Test("die anderen Wege setzen sehr wohl ein Zeichen")
    func theOtherWaysDoSetATokenAfterAll() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/Networking/MaerSyncClient.swift"),
                              encoding: .utf8)
        let uses = text.components(separatedBy: "MaerSyncHeaders.authorize(").count - 1
        #expect(uses == 4,
                "vier Wege tragen das Zeichen: lesen, schreiben, auflisten, die Steckdose")
    }

    @Test("die zwei Sitzungs-Wege bauen ihre Adresse ueber die eine Tuer")
    func theTwoSessionWaysBuildTheirAddressThroughTheOneDoor() {
        let base = URL(string: "https://sync.example.com")!
        #expect(MaerSyncPaths.key(base).absoluteString == "https://sync.example.com/v1/key")
        #expect(MaerSyncPaths.session(base).absoluteString == "https://sync.example.com/v1/session")
    }

    @Test("der Vertrag liegt hier und nennt seine Fassung zweimal")
    func theContractIsHereAndNamesItsVersionTwice() throws {
        let text = try Self.contractText()
        #expect(Self.declared(in: text)["version"] == ["4"])
        // Zweimal mit Absicht: einmal fuer den Leser, einmal fuer den Zaun.
        // Wer eines hochzieht und das andere nicht, reisst hier.
        #expect(text.contains("**Version: 4**"))
    }

    @Test("jeden Pfad, den der Vertrag verspricht, ruft diese App auch")
    func everyPromisedPathIsCalled() throws {
        let text = try Self.sources()
        for path in Self.declared(in: try Self.contractText())["paths"] ?? [] {
            // Der Vertrag schreibt den Pfad mit fuehrendem Strich, die App
            // haengt ihn an eine Grundadresse. Verglichen wird der Rumpf.
            let stem = path.hasPrefix("/") ? String(path.dropFirst()) : path
            #expect(text.contains(stem), "der Vertrag verspricht \(path), die App ruft ihn nicht")
        }
    }

    @Test("jede Kopfzeile des Vertrags setzt oder liest diese App")
    func everyPromisedHeaderIsUsed() throws {
        let text = try Self.sources()
        for header in Self.declared(in: try Self.contractText())["headers"] ?? [] {
            #expect(text.contains(header), "der Vertrag verspricht \(header), niemand setzt sie")
        }
    }

    @Test("jede Sorte des Vertrags kennt diese App beim Namen")
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

    @Test("die Socket-Nachricht ist die, die im Vertrag steht")
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

    @Test("die Antworten, auf die der Vertrag die App festlegt, behandelt sie")
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
