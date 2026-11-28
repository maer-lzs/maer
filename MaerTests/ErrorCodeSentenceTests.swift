// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import AVFoundation
import Foundation
import Testing
@testable import Maer

/// A failure sentence with a technical cause ends with the number the
/// system or the server reported, in parentheses, after the sentence and
/// its full stop; without a number there are no parentheses. One place puts
/// sentence and code together (`ErrorSentence.with`), on every platform
/// against the same vectors.
struct ErrorCodeSentenceTests {
    @Test("a sentence with a code: the code stands behind the full stop")
    func aSentenceWithACode() {
        #expect(ErrorSentence.with("Die Zugangsdaten konnten nicht im Schlüsselbund gespeichert werden.", code: -25308)
                == "Die Zugangsdaten konnten nicht im Schlüsselbund gespeichert werden. (-25308)")
    }

    @Test("without a number there is no bracket")
    func noNumberNoBracket() {
        #expect(ErrorSentence.with("The action was cancelled.", code: nil) == "The action was cancelled.")
    }

    @Test("every line of the vectors, taken byte for byte from the shared file", .needsTheSources)
    func theVectorsHold() throws {
        let url = SourceTree.root.appendingPathComponent("MaerTests/Fixtures/ErrorCodes/fehlercode-vektoren.json")
        let table = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(table["cases"] as? [[String: Any]])
        #expect(cases.count == 10)
        for item in cases {
            let sentence = try #require(item["sentence"] as? String)
            let line = try #require(item["line"] as? String)
            #expect(ErrorSentence.with(sentence, code: item["code"] as? Int) == line, "\(item)")
        }
    }

    @Test("a server status stands behind the sentence, never as HTTP inside it")
    func aServerStatusStandsBehindTheSentence() {
        let errors: [(Error, Int)] = [
            (APIError.http(503, ""), 503),
            (JellyfinClient.JellyfinError.http(500), 500),
            (GPodderError.status(502), 502),
            (GPodderError.signIn(401), 401),
            (SubsonicClient.SubsonicError.http(504), 504),
        ]
        for (error, status) in errors {
            let line = ErrorSentence.of(error)
            #expect(line.hasSuffix(". (\(status))"), "\(line)")
            #expect(!line.contains("HTTP"), "\(line)")
            #expect(ErrorSentence.code(of: error) == status)
        }
    }

    @Test("the refused token is two sentences and the status behind them")
    func theRefusedTokenStandsBehind() {
        #expect(ErrorSentence.of(APIError.http(401, ""))
                == "The server rejected the token. Please check the token. (401)")
    }

    @Test("the number of a Subsonic answer without a sentence of its own stands behind the sentence")
    func theSubsonicCodeStandsBehindTheSentence() {
        let line = ErrorSentence.of(SubsonicClient.SubsonicError.api(code: 70, message: nil))
        #expect(line == "Server error. (70)", "\(line)")
    }

    @Test("a refusal of the podcast server names its status")
    func thePodcastRefusalNamesItsStatus() {
        #expect(ABSPodcastProvider.serverSentence(APIError.http(403, "")) == "The server refused the request. (403)")
    }

    @Test("a network code stands behind its sentence; a cancel has none")
    func aNetworkCodeStandsBehindTheSentence() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(ErrorSentence.of(offline)
                == "No internet connection. Please check your network and try again. (-1009)")
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(ErrorSentence.of(cancelled) == "The action was cancelled.")
    }

    @Test("a platform error keeps its framework's sentence and gets its number")
    func aPlatformErrorGetsItsNumber() {
        let error = NSError(domain: AVFoundationErrorDomain, code: -11800,
                            userInfo: [NSLocalizedDescriptionKey: "This title cannot be played."])
        #expect(ErrorSentence.of(error) == "This title cannot be played. (-11800)")
    }

    @Test("the keychain's status reaches the sentence of the sign-in")
    func aKeychainStatusReachesTheSentence() {
        let status = KeychainStore.write("x", forKey: "witness-\(UUID().uuidString)",
                                         adding: { _ in errSecInteractionNotAllowed })
        #expect(status == errSecInteractionNotAllowed, "the write does not hand out the keychain's status")
        #expect(AuthViewModel.notStoredSentence(status: -25308).hasSuffix(". (-25308)"))
        #expect(!AuthViewModel.notStoredSentence(status: nil).contains("("))
    }

    @Test("a Swift error without a number has no bracket")
    func aSwiftErrorHasNoBracket() {
        struct Plain: Error {}
        for error: Error in [CancellationError(), Plain()] {
            #expect(!ErrorSentence.of(error).contains("("), "\(ErrorSentence.of(error))")
            #expect(ErrorSentence.code(of: error) == nil)
        }
    }

    @Test("a name never stands in a bracket")
    func noNameInABracket() {
        let line = ErrorSentence.of(PocketCastsError.changed("episodes/sync"))
        #expect(!line.contains("("), "\(line)")
        #expect(!line.contains("episodes/sync"))
    }

    /// No sentence in the sources sets a number in brackets or behind
    /// "HTTP" by hand; counters such as "Show All (3)" are no codes.
    @Test("no sentence sets a code by hand", .needsTheSources)
    func noSentenceSetsACodeByHand() throws {
        var found: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"]) {
            for line in text.split(separator: "\n") where line.contains("String(localized:") {
                let byHand = ["HTTP \\(", "(\\(code))", "(\\(c))", "(\\(status))", "(\\(door))", "error \\(code)"]
                if byHand.contains(where: { line.contains($0) }) { found.append("\(name): \(line.trimmingCharacters(in: .whitespaces))") }
            }
        }
        #expect(found.isEmpty, "a sentence sets a code by hand: \(found)")
    }

    @Test("the one place says it puts the code, and no other place hangs a bracket on a failure sentence", .needsTheSources)
    func theOnePlaceSaysIt() throws {
        let text = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Models/ErrorSentence.swift"))
        #expect(!text.contains("never a code"), "the comment still says never a code")
        #expect(text.components(separatedBy: "\"\\(sentence) (\\(").count - 1 == 1, "with does not build the line")
    }
}
#endif
