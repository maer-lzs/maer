// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Every file that reads an HTTP status is one of two things: a CALLER of
/// the one rule (`StatusMeaning.from(status:)`), or a client that keeps its
/// own sentence, with the reason why the shared meaning would say the wrong
/// thing there. Both stocks name every file with its reason, a file that is
/// gone is red (a stock naming a ghost is a claim about nothing), and a
/// file in neither stock that reads a status is red. The retry ladder
/// stands in the second stock: there 429 means "wait", and the meaning is
/// made only behind it, so the ladder must never call the rule.
/// Comment lines do not count.
struct StatusMeaningFenceTests {
    nonisolated static let ruleHome = "StatusMeaning.swift"

    /// The files that read the meaning, each with what the meaning decides there.
    nonisolated static let callers: [String: String] = [
        "FeedAdoptionPending.swift": "the feed's reason is read off the meaning (a pause is a server answer there)",
        "PodcastSubscriptions.swift": "a feed pull that survived the ladder is marked with the meaning, the number beside it",
        "GPodderClient.swift": "a refusal that survived the login retry gets its own sentence, every other answer keeps its number",
        "RadioLogoService.swift": "only an absence is a clean no for the logo chain; a refusal books nothing for 14 days",
        "RadioBrowserClient.swift": "a pause that survived the ladder stops the walk over the mirrors, every other answer tries the next",
        "RadioArtworkService.swift": "only an absence is remembered as no cover for the session",
        "ArtistPortraitService.swift": "only an absence is remembered as no portrait for the session",
        "FeedArtworkService.swift": "only an absence is booked as no image for 7 days",
    ]

    /// The files that read the number themselves, each with the reason the
    /// shared meaning would be wrong there.
    nonisolated static let ownSentence: [String: String] = [
        "Retry.swift": "the ladder: 401 means one probe, 429 and 5xx mean wait; a meaning here would sit before the ladder",
        "JellyfinClient.swift": "403 is blockedHere, not the same as 401; the client's sentences are richer than the meaning",
        "APIClient.swift": "the probe reads 403 and 5xx as the proxy still coming up, and only a confirmed 401 logs out",
        "SubsonicClient.swift": "the errors ride in the body as API codes inside a 200; the status is not the meaning",
        "PinchflatClient.swift": "only 401 is read; an absent mesh-only server is a normal state, not a defect",
        "PocketCastsClient.swift": "the number travels to the callers, which keep their own sentences (loginRejected, changed)",
        "MaerSyncClient.swift": "the translation MaerSyncAnswer: 404 is not yet, 412 stale, 409 refused, 410 session ended, 503 with a sentence",
        "CatalogStockFetch.swift": "416 is the end of a range and 200 the whole file; both are meanings the rule has no word for",
        "FreeCatalogClients.swift": "a decode failure keeps the status as evidence, the dead-item ladder needs the body, a 429 must be measurable with Retry-After",
        "PodcastRecommendationsStore.swift": "a HEAD probe reduced to a Bool that orders tiles; a transport failure keeps the tile usable",
        "FileDownloader.swift": "non-2xx bytes are not a track; there is no reader for a meaning on that path",
        "RadioLogoReport.swift": "the diagnosis label names the status on purpose, for the clipboard",
        "RadioView.swift": "the diagnosis probe hands the status to the label and books nothing",
        "Lyrics.swift": "everything but 200 is a failed outcome that the lyrics cache already refuses to remember",
    ]

    /// Non-comment lines that read a status.
    nonisolated static func statusSites(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains("statusCode")
            }.count
    }

    /// Whether the text names the rule outside comments.
    nonisolated static func namesTheRule(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed.contains("StatusMeaning")
            }
    }

    /// Whether the text calls the rule. Comment lines go first (a comment
    /// about the rule is not a call), then whitespace is pulled together,
    /// so a call broken over lines still counts as one.
    nonisolated static func callsTheRule(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .contains("StatusMeaning.from(status:")
    }

    @Test("wer einen Status liest, ruft die Regel oder steht mit Grund im Bestand; die Leiter ruft sie nie")
    func everyStatusReaderIsAccountedFor() throws {
        var offenders: [String] = []
        var seen: Set<String> = []
        for file in ProjectFileIntegrityTests.sourceFiles() where file.lastPathComponent != Self.ruleHome {
            let name = file.lastPathComponent
            seen.insert(name)
            let text = try String(contentsOf: file, encoding: .utf8)
            if Self.callers[name] != nil {
                if !Self.callsTheRule(text) { offenders.append("\(name): in the callers, but does not call the rule") }
            } else if Self.ownSentence[name] != nil {
                if Self.statusSites(in: text) == 0 { offenders.append("\(name): in the sentence stock, but reads no status") }
                if Self.namesTheRule(text) { offenders.append("\(name): keeps its own sentence, but names the rule") }
            } else {
                if Self.statusSites(in: text) > 0 { offenders.append("\(name): reads a status past the fence") }
                if Self.namesTheRule(text) { offenders.append("\(name): calls the rule without standing in the callers") }
            }
        }
        for ghost in (Array(Self.callers.keys) + Array(Self.ownSentence.keys)).filter({ !seen.contains($0) }).sorted() {
            offenders.append("\(ghost): named in a stock, but gone")
        }
        #expect(offenders.isEmpty, "status readers past the fence: \(offenders)")
        #expect(Set(Self.callers.keys).isDisjoint(with: Self.ownSentence.keys))
        #expect(Self.callers.values.allSatisfy { !$0.isEmpty } && Self.ownSentence.values.allSatisfy { !$0.isEmpty })
        // The helpers themselves, in both directions.
        #expect(Self.statusSites(in: "if http.statusCode == 401 {\n// statusCode in a comment") == 1)
        #expect(Self.callsTheRule("let m = StatusMeaning\n    .from(status:\n code)"))
        #expect(!Self.callsTheRule("// StatusMeaning.from(status: 404) in prose only"))
        #expect(Self.namesTheRule("let m = StatusMeaning.notFound"))
        #expect(!Self.namesTheRule("// StatusMeaning in a comment"))
    }
}
#endif
