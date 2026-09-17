// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A host that answers every question with the one status it was given,
/// and counts how often it was asked, so a leg of a witness cannot pass
/// by never reaching the host.
actor StatusHost {
    let status: Int
    let body: Data
    private(set) var asked = 0
    init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }
    func answer(_ request: URLRequest) -> (Data, HTTPURLResponse?) {
        asked += 1
        return (body, HTTPURLResponse(url: request.url!, statusCode: status,
                                      httpVersion: nil, headerFields: nil))
    }
}

/// The one rule that turns a non-2xx status into a meaning, at its edges.
/// Every caller that books or words a refusal reads this, so a wrong edge
/// here is a wrong edge everywhere; that is the point of having one.
struct StatusMeaningTests {
    @Test("401 and 403 are a sign-in, 404 and 410 an absence, 429 a pause, the rest the server")
    func theEdges() {
        #expect(StatusMeaning.from(status: 401) == .signIn)
        #expect(StatusMeaning.from(status: 403) == .signIn)
        #expect(StatusMeaning.from(status: 404) == .notFound)
        #expect(StatusMeaning.from(status: 410) == .notFound)
        #expect(StatusMeaning.from(status: 429) == .throttled)
        for other in [400, 402, 408, 418, 500, 502, 503, 504] {
            #expect(StatusMeaning.from(status: other) == .server, "\(other) is the server's problem")
        }
    }

    @Test("only an absence may be written down as a clean no")
    func onlyAbsenceIsBookable() {
        #expect(StatusMeaning.notFound.isAbsence)
        #expect(!StatusMeaning.signIn.isAbsence)
        #expect(!StatusMeaning.throttled.isAbsence)
        #expect(!StatusMeaning.server.isAbsence)
    }

    /// The feed's reading keeps its three reasons; a pause after the ladder
    /// is a server answer there, with the number beside it.
    @Test("the feed adoption reads the shared meaning, a pause as a server answer")
    func theFeedReading() {
        #expect(FeedAdoptionPending.Reason(.signIn) == .signIn)
        #expect(FeedAdoptionPending.Reason(.notFound) == .notFound)
        #expect(FeedAdoptionPending.Reason(.throttled) == .server)
        #expect(FeedAdoptionPending.Reason(.server) == .server)
        #expect(FeedAdoptionPending.Reason.from(status: 429) == .server)
        #expect(FeedAdoptionPending.Reason.from(status: 403) == .signIn)
    }

    /// The gpodder client words a refusal that survived its login retry
    /// and keeps the number for everything else.
    @Test("gpodder: a refusal has its own sentence, every other answer keeps its number")
    func theGpodderSentence() {
        let refused = GPodderError.signIn(401).errorDescription ?? ""
        #expect(refused.contains("401"))
        #expect(refused != GPodderError.status(401).errorDescription)
        #expect(GPodderError.status(503).errorDescription?.contains("503") == true)
    }
}

/// The feed artwork over the carrier: the whole way from the request to
/// the store, against a host that answers with one status. A clean no is
/// booked for seven days; a refusal, a pause and a server error book
/// nothing, so the next appearance asks again.
struct FeedArtworkRefusalTests {
    @Test("over the carrier: 404 and an image-less head book a no, 429 and 500 book nothing")
    @MainActor func aRefusalLeavesNoNegativeMemo() async {
        let suite = "feed-artwork-refusal-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // The source switch is a global default: set it, then put it back.
        let key = ExternalSources.feedArtwork.storageKey
        let was = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let was { UserDefaults.standard.set(was, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        func run(status: Int, body: String = "") async -> (booked: Bool, asked: Int) {
            let host = StatusHost(status: status, body: Data(body.utf8))
            let service = FeedArtworkService(suite: suite)
            let feed = "https://example.org/feed-\(status).xml"
            _ = await service.artworkURL(feedURL: feed, fetch: { await host.answer($0) })
            // The store lists its entries without the namespace prefix.
            let entry = Artwork.Memo.entries(prefix: "feed|", defaults: defaults)[feed]
            return (entry != nil, await host.asked)
        }
        // The clean way first: a head that names no image is a no, and it
        // proves the way reaches the host and the store.
        let imageless = await run(status: 200, body: "<rss><channel><title>x</title></channel></rss>")
        #expect(imageless.asked == 1, "the service must have asked the host")
        #expect(imageless.booked, "a head without an image is a clean no")
        let gone = await run(status: 404)
        #expect(gone.asked == 1)
        #expect(gone.booked, "a feed that is gone has no picture, booked")
        let throttled = await run(status: 429)
        #expect(throttled.asked == 1)
        #expect(!throttled.booked, "a pause leaves no negative memo")
        let broken = await run(status: 500)
        #expect(broken.asked == 1)
        #expect(!broken.booked, "a server error leaves no negative memo")
    }
}
#endif
