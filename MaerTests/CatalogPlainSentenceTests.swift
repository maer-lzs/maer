// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A page says a plain sentence, never a measured code or a step name; the
/// code and the step go to the log line.
struct CatalogPlainSentenceTests {
    private func code(_ path: String) throws -> String {
        SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
    }

    /// Every catalog page reaches the sentence through the one door that
    /// also writes the log line; nobody asks the bare sentence beside it.
    @Test("jede Katalog-Seite nimmt den Satz ueber die eine Tuer, die auch die Logzeile schreibt", .needsTheSources)
    func everyPageGoesThroughTheDoor() throws {
        var beside: [String] = []
        var doors = 0
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            let code = SyncContractFenceTests.stripped(text)
            if name != "FreeCatalog.swift", name != "CatalogPageFailure.swift", code.contains("FreeCatalog.failureReason(") {
                beside.append(name)
            }
            doors += code.components(separatedBy: "CatalogPageFailure.sentence(for:").count - 1
        }
        #expect(beside.isEmpty, "a page asks the sentence without the log line: \(beside.sorted())")
        #expect(doors == 10, "the pages that show a catalog failure are not the ten measured: \(doors)")
        let door = try code("Sources/ViewModels/CatalogPageFailure.swift")
        #expect(door.contains("FreeCatalog.failureReason(error, online: online)") && door.contains("FreeCatalog.logReason(error)"),
                "the door does not give the sentence and log the measured reason")
        #expect(door.contains("await Reachability.isConnected()"), "the door does not ask the device's reach")
        // The cell that only logs asks the log reason.
        let cell = try code("Sources/Views/CatalogTrackCell.swift")
        #expect(cell.contains("FreeCatalog.logReason(error)"), "the cell logs the page sentence")
    }

    @Test("die Tuer gibt den Satz der Seite und schweigt bei einem Abbruch")
    func theDoorGivesTheSentence() async {
        let error = APIError.http(429, "slow down")
        #expect(await CatalogPageFailure.sentence(for: error, at: "witness") == FreeCatalog.failureReason(error, online: true))
        #expect(await CatalogPageFailure.sentence(for: CancellationError(), at: "witness") == nil)
    }

    /// A transport failure is worded by the device's reach, not by its
    /// code: online, a timeout or an unknown host is the source not
    /// answering; offline, every transport failure is the network.
    @Test("Zeitueberschreitung und unbekannter Host: online antwortet die Quelle nicht, offline fehlt das Netz", arguments: [
        URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
    ])
    func aTransportFailureIsWordedByTheReach(code: URLError.Code) async {
        let noNetwork = String(localized: "No internet connection. Please check your network and try again.")
        #expect(FreeCatalog.failureReason(URLError(code), online: true) == String(localized: "The source did not answer."))
        #expect(FreeCatalog.failureReason(URLError(code), online: false) == noNetwork)
        // The door asks the reach itself.
        let offline = await Reachability.$assumed.withValue(false) {
            await CatalogPageFailure.sentence(for: URLError(code), at: "witness")
        }
        #expect(offline == noNetwork)
    }

    /// The one transport code that is a verdict: what `isGone` writes down
    /// as dead says on the page that it is gone, online and offline, and
    /// does not invite another try.
    @Test("eine Quelle, die den Titel als entfernt meldet, sagt auf der Seite, dass er weg ist, wie der Vermerk als tot")
    func aGoneItemSaysItIsGone() {
        let error = URLError(.resourceUnavailable)
        #expect(FreeCatalog.isGone(error), "the precondition: the dead-item rule reads it as gone")
        for online in [true, false] {
            #expect(FreeCatalog.failureReason(error, online: online) == String(localized: "No longer available at the source"))
        }
    }

    @Test("Drosselung: eine Quelle, die um eine Pause bittet, sagt das in eigenen Worten")
    func aThrottledSourceSaysItIsBusy() {
        let busy = String(localized: "The source is busy. Please try again later.")
        #expect(FreeCatalog.failureReason(APIError.http(429, "slow down"), online: true) == busy)
        #expect(FreeCatalog.failureReason(APIError.http(503, ""), online: true) == String(localized: "The source did not answer."),
                "only the pause is busy, a failing host is not")
    }

    /// The server side of a subscribe: a refusal is worded by its meaning,
    /// the status goes to the log line; a missing podcast library has its
    /// own sentence.
    @Test("Abo auf dem Server: kein Status im Satz, der Status in der Logzeile, eigener Satz ohne Podcast-Bibliothek", .needsTheSources)
    func theServerRefusalCarriesNoStatus() throws {
        for status in [400, 403, 404, 409, 429, 500, 503] {
            let sentence = ABSPodcastProvider.serverSentence(APIError.http(status, "detail"))
            #expect(!sentence.contains(String(status)) && !sentence.contains("detail"), "the sentence carries the refusal: \(sentence)")
            #expect(ABSPodcastProvider.logReason(APIError.http(status, "detail")) == "HTTP \(status)")
        }
        #expect(ABSPodcastProvider.serverSentence(APIError.http(401, "")) == String(localized: "Your server rejected the saved sign-in."))
        #expect(ABSPodcastProvider.serverSentence(APIError.http(500, "")) == String(localized: "The server refused the request."))
        #expect(ABSPodcastProvider.serverSentence(APIError.http(409, "")) == String(localized: "The server refused the request."))
        let offline = URLError(.notConnectedToInternet)
        #expect(ABSPodcastProvider.serverSentence(offline) == ErrorSentence.of(offline), "a failure without an answer keeps its sentence")
        #expect(ABSPodcastProvider.logReason(offline) == FailureReason.of(offline))
        let provider = try code("Sources/Providers/ABSPodcastProvider.swift")
        #expect(provider.contains("return String(localized: \"This server has no podcast library.\")"),
                "a server without a podcast library is not said in its own sentence")
    }

    /// The server branch of a subscribe hands back the sentence alone; the
    /// step and the measured reason are in its log lines.
    @Test("das Abo auf dem Server gibt nur den Satz zurueck, Schritt und Grund stehen in der Logzeile", .needsTheSources)
    func theServerSubscribeSaysASentence() throws {
        let provider = try code("Sources/Providers/ABSPodcastProvider.swift")
        let start = try #require(provider.range(of: "func subscribeOnServer("), "the server subscribe is gone")
        let end = try #require(provider.range(of: "func updateShowCover(", range: start.upperBound..<provider.endIndex))
        let body = String(provider[start.upperBound..<end.lowerBound])
        #expect(!body.contains("return \""), "a step or a raw text reaches the person")
        for step in ["step=libraries", "step=podcasts/feed", "step=libraries/id", "step=folders", "step=POST podcasts"] {
            #expect(body.contains(step), "the log line does not name the step \(step)")
        }
    }
}
#endif
