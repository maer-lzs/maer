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
        "AccessGuard.swift": "a refusal by sign-in that comes back as a web page is a guard in front of the server, not the server",
        "FeedAdoptionPending.swift":"the feed's reason is read off the meaning (a pause is a server answer there)",
        "SyncRules.swift": "a progress write refused for its content (an absence, or 403 apart from the access) is neither queued nor kept in the queue",
        "PodcastSubscriptions.swift": "a feed pull that survived the ladder is marked with the meaning, the number beside it",
        "GPodderClient.swift": "a refusal that survived the login retry gets its own sentence, every other answer keeps its number",
        "RadioLogoService.swift": "only an absence is a clean no for the logo chain; a refusal books nothing for 14 days",
        "RadioLogoLookup.swift": "the root of the host is asked after a refusal or an absence of the page, never after a pause or a failing host",
        "RadioBrowserClient.swift": "a pause that survived the ladder stops the walk over the mirrors, every other answer tries the next",
        "RadioArtworkService.swift": "only an absence is remembered as no cover for the session",
        "Artwork.swift": "only an absence is the one clean no for a picture; every other status leaves it unanswered",
        "ArtistPortraitService.swift": "only an absence is remembered as no portrait for the session",
        "FeedArtworkService.swift": "only an absence is booked as no image for 7 days",
        "FeedRefusal.swift": "a subscribed feed's refresh counts only what means sign in; every other answer says nothing about the access",
        "GutenbergWorks.swift": "only an absence is kept as no record of the work; a refusal, a pause or a server error keeps nothing",
        "PodcastTranscript.swift": "a document or an absence stands for the session as the transcript's answer; a failure is asked again",
        "ABSPlayedWriteRetry.swift": "a played mark stays queued on a sign-in problem, a pause or a failing host; an absence or another refusal answers the same every time",
        "FreeCatalog.swift": "only an absence marks a catalog item as gone, every other answer is no verdict; a page says absence and pause in their own sentences",
        "ABSPodcastProvider.swift": "a refused subscribe or episode download is worded by the meaning (sign in apart), the number goes to the log line",
        "DeadCatalogItems.swift": "an absence is a dead item; the body of a 200 is read on its own (a withdrawn item answers 200 with an error), any other answer is unknown",
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
        "HostCourtesyRule.swift": "429 and 503 both tell the whole host to rest; for the rule 503 is a failing server, here it is a pause",
        "HostCourtesy.swift": "any answer below 400 ends a host's rest; a range of the courtesy, not a meaning of a refusal",
        "PodcastFeedLiveness.swift": "the status a directory saw last, not an answer to us: 0 never reached and 400 up stuck are gone, which only orders a row",
        "MaerSyncFrame.swift": "a frame's status is checked to be a status at all (100 to 599) before the answer reads it",
        "MaerSyncSignIn.swift": "the sign-in probe of the service: 200 reached, 403 blocked on this network, the service's own sentences",
    ]

    /// Non-comment lines that read a status: the word `statusCode`, or a
    /// status number compared, whatever the value is called (a name with
    /// status in it, `code`, `$0`), a range of status numbers asked, or a
    /// status number as a switch case. The question, not the word.
    nonisolated static func statusSites(in text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//")
                    && (trimmed.contains("statusCode") || trimmed.contains(Self.statusComparison))
            }.count
    }

    nonisolated static var statusComparison: Regex<Substring> {
        #/(?:\b\w*[sS]tatus\w*|\bcode|\$0)\s*(?:==|!=|>=|<=|>|<)\s*[1-5]\d\d\b|\(\s*[1-5]\d\d\s*\.\.[.<]\s*[1-5]\d\d\s*\)\.contains\(|^case\s+[1-5]\d\d\b/#
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

    @Test("wer einen Status liest, ruft die Regel oder steht mit Grund im Bestand; die Leiter ruft sie nie", .needsTheSources)
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
        // The question without the word, as it stood in the played-mark queue,
        // the courtesy and the clients; numbers that are no status stay out.
        #expect(Self.statusSites(in: "return status == 401 || status >= 500") == 1)
        #expect(Self.statusSites(in: "if httpStatus == 404 { return .dead }") == 1)
        #expect(Self.statusSites(in: "case .http(let code, _) = api { return code == 404 }") == 1)
        #expect(Self.statusSites(in: "status.map { $0 == 429 || (500...599).contains($0) }") == 1)
        #expect(Self.statusSites(in: "guard (200...299).contains(status) else {") == 1)
        #expect(Self.statusSites(in: "    case 404: return nil") == 1)
        #expect(Self.statusSites(in: "if frames % 300 == 0 {\nuseThumbnail: size <= 200\nif items.count > 256 {\ncase ..<120: return") == 0)
        #expect(Self.callsTheRule("let m = StatusMeaning\n    .from(status:\n code)"))
        #expect(!Self.callsTheRule("// StatusMeaning.from(status: 404) in prose only"))
        #expect(Self.namesTheRule("let m = StatusMeaning.notFound"))
        #expect(!Self.namesTheRule("// StatusMeaning in a comment"))
    }
}
#endif
