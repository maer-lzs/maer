// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The sentence a person reads about a failure comes from one place, and it
/// never carries a type name or a code the system made up.
struct ErrorSentenceTests {
    struct Bare: Error {}
    struct Worded: LocalizedError { var errorDescription: String? { "A sentence of its own." } }
    struct Silent: LocalizedError { var errorDescription: String? { nil } }

    @Test("TF-7: ein Fehler mit Satz behaelt ihn, ein Plattformfehler seinen, alles andere heisst nach seiner Art")
    func eachErrorGetsASentence() throws {
        #expect(ErrorSentence.of(Worded()) == "A sentence of its own.")
        #expect(ErrorSentence.of(ItemNotHere.fileGone) == ItemNotHere.fileGone.errorDescription)
        #expect(ErrorSentence.of(CancellationError()) == String(localized: "The action was cancelled."))
        #expect(ErrorSentence.of(URLError(.cancelled)) == String(localized: "The action was cancelled."))
        #expect(ErrorSentence.of(URLError(.notConnectedToInternet))
                == String(localized: "No internet connection. Please check your network and try again."))
        let decoding = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
        #expect(ErrorSentence.of(decoding) == String(localized: "The server response could not be read."))
        let platform = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                               userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed"])
        #expect(ErrorSentence.of(platform) == "The operation could not be completed", "the platform's own sentence")
        for bare in [Bare() as Error, Silent(), NSError(domain: "Anything", code: 404)] {
            let sentence = ErrorSentence.of(bare)
            #expect(sentence == String(localized: "Something went wrong. Please try again."), "\(bare)")
            for word in ["Bare", "Silent", "Anything", "404", "error 1"] {
                #expect(!sentence.contains(word), "\(bare) says \(word)")
            }
        }
    }

    @Test("TF-7: offline heisst an jeder Stelle dasselbe")
    func offlineIsOneDefinition() {
        for code in NetworkReach.offlineCodes {
            #expect(NetworkStatus.isOfflineError(URLError(URLError.Code(rawValue: code))))
        }
        #expect(!NetworkStatus.isOfflineError(URLError(.badServerResponse)))
        #expect(!NetworkStatus.isOfflineError(NSError(domain: "Other", code: NSURLErrorTimedOut)))
    }

    /// TF-7b: the question is which text reaches a person, not which folder
    /// builds it. A download phase, a connection test and a sync history
    /// entry are built in Networking and Providers and shown on a page.
    @Test("TF-7b: kein Text im ganzen Quellbaum nimmt localizedDescription, ausser namentlich mit Grund", .needsTheSources)
    func noScreenReadsTheSystemsText() throws {
        // Each exception names its file and says why.
        let exceptions: [String: String] = [
            "APIClient.swift": "the reason INSIDE APIError.decoding, which has its own sentence around it",
        ]
        var found: [String: Int] = [:]
        var read = 0
        for folder in ["Sources"] {
            let root = SourceTree.root.appendingPathComponent(folder)
            let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
            read += files.count
            for file in files {
                let text = SyncContractFenceTests.stripped(try String(contentsOf: file, encoding: .utf8))
                let hits = text.components(separatedBy: ".localizedDescription").count - 1
                if hits > 0 { found[file.lastPathComponent] = hits }
            }
        }
        try #require(read > 100, "the fence did not read the views")
        #expect(Set(found.keys) == Set(exceptions.keys), "a screen reads the system's text: \(found.sorted { $0.key < $1.key })")
    }
}
#endif
