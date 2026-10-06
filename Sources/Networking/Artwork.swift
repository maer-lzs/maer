// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import UIKit
import OSLog

/// THE door for pictures. Every surface that shows, colours, persists or
/// sweeps a cover asks here; nothing outside this file, the cache behind it
/// and the byte probe decodes image bytes or calls the cover lane itself.
///
/// Behind the door: the three cache tiers (memory, purgeable disk,
/// persistent disk) with the downsample rule in `ImageCache`, the one
/// network path with the coalescer (one fetch per address at a time), the
/// service-placeholder gate, the cover trace, and the sweep. Bytes travel
/// only over the cover lane of the HTTP door.
@MainActor
enum Artwork {
    /// One answer of the picture question: the display image and the pot
    /// it came from (the tile marker names it: memo, thumb, full, net, net2).
    struct Answer {
        let image: UIImage
        let pot: String
    }

    /// What the door knows about a picture after asking: it has one, the
    /// address names none (a 404 or 410, or the archive's service
    /// placeholder), or nothing was learned (offline, a transport failure,
    /// a resting host, a status that is no answer, bytes that are no
    /// picture, a tile that left before asking). Only `absent` may be
    /// remembered as "no picture"; `unanswered` is asked again next time.
    enum Verdict {
        case picture(Answer)
        case absent
        case unanswered
    }

    /// The network's answer, coalesced per address.
    enum Fetched: Sendable {
        case picture(UIImage)
        case absent
        case unanswered
    }

    // MARK: - Reading

    /// The picture for an address, at thumbnail size when `thumbnail` names
    /// one, else the full image: memory or disk first, the network second
    /// (coalesced with every other caller of the same address, one automatic
    /// second attempt), and every exit says which pot answered.
    static func image(for url: URL, thumbnail maxPixel: CGFloat? = nil,
                      attempt known: Int? = nil) async -> Answer? {
        if case .picture(let answer) = await verdict(for: url, thumbnail: maxPixel, attempt: known) {
            return answer
        }
        return nil
    }

    /// The picture question with its verdict, for a caller that remembers
    /// "no picture": only an absence may be written down.
    static func verdict(for url: URL, thumbnail maxPixel: CGFloat? = nil,
                        attempt known: Int? = nil) async -> Verdict {
        let attempt = known ?? CoverTraceLog.attempt(for: url)
        // A cover already recognised as a service placeholder stays the
        // app placeholder; no re-download per appearance or per session.
        if ServicePlaceholderCovers.contains(url) {
            CoverTraceLog.note(pot: .memo, outcome: .servicePlaceholder, attempt: attempt, url: url)
            return .absent
        }
        // This gate goes to the network next, so an invalidated address's
        // kept copy does not answer here; it answers after a failed load.
        if let maxPixel {
            if let thumb = await tiers.thumbnail(for: url, maxPixelSize: maxPixel, allowKept: false) {
                CoverTraceLog.note(pot: .thumbnail, outcome: .hit, attempt: attempt, url: url)
                return .picture(Answer(image: thumb, pot: "thumb"))
            }
        } else if let cached = await tiers.image(for: url, allowKept: false) {
            CoverTraceLog.note(pot: .full, outcome: .hit, attempt: attempt, url: url)
            return .picture(Answer(image: cached, pot: "full"))
        }
        // Not on disk yet: a tile stays a moment first (`TileDwell`), and a
        // tile that left asks nothing. Then the network fills the disk
        // cache; the next display finds the thumbnail there.
        guard await TileDwell.stood(TileDwell.cover) else { return .unanswered }
        switch await CoverFetchCoalescer.fetch(url, work: {
            await fetch(url, retryDelay: nil, attempt: attempt)
        }) {
        case .picture(let image): return .picture(Answer(image: image, pot: "net"))
        case .absent: return .absent
        case .unanswered: break
        }
        // An automatic second attempt after a short pause covers most brief
        // network dropouts without the person doing anything. Not after an
        // absence: the address names nothing, asking twice changes nothing.
        switch await CoverFetchCoalescer.fetch(url, work: {
            await fetch(url, retryDelay: 800_000_000, attempt: attempt)
        }) {
        case .picture(let image): return .picture(Answer(image: image, pot: "net2"))
        case .absent: return .absent
        case .unanswered:
            // An invalidated downloaded cover whose fresh picture did not
            // come: the old one stays on screen, the next display asks again.
            let kept = if let maxPixel { await tiers.thumbnail(for: url, maxPixelSize: maxPixel) }
                       else { await tiers.image(for: url) }
            if let kept {
                CoverTraceLog.note(pot: .full, outcome: .hit, attempt: attempt, url: url)
                return .picture(Answer(image: kept, pot: "kept"))
            }
            return .unanswered
        }
    }

    /// The thumbnail from memory or disk, never the network.
    static func thumbnail(for url: URL, maxPixel: CGFloat? = nil) async -> UIImage? {
        if let maxPixel { return await tiers.thumbnail(for: url, maxPixelSize: maxPixel) }
        return await tiers.thumbnail(for: url)
    }

    /// Synchronous warm peek: a display-ready thumbnail for the first frame.
    static func cachedThumbnail(for url: URL, maxPixel: CGFloat? = nil) -> UIImage? {
        tiers.cachedThumbnail(for: url, maxPixelSize: maxPixel)
    }

    /// The full image from memory or disk, never the network.
    static func full(for url: URL) async -> UIImage? {
        await tiers.image(for: url)
    }

    /// The picture WITH the size it arrived in, cache first, network second:
    /// the radio quality gate judges the source, not the thumbnail.
    static func loaded(for url: URL, maxPixel: CGFloat? = nil)
        async -> (image: UIImage, sourcePixels: CGSize)? {
        await tiers.loadedImage(for: url, maxPixelSize: maxPixel)
    }

    /// A picture as a file for a caller that hands it on whole (the
    /// LibriVox import sends the cover with the upload): streamed over the
    /// cover lane to a temporary file the caller moves. Not cached; an
    /// import package is not a display.
    static func file(for url: URL) async throws -> URL {
        let (downloaded, _) = try await HTTP.download(from: url, lane: .cover)
        return downloaded
    }

    /// Fetch a cover into the cache ahead of its first display.
    static func preload(_ url: URL) async {
        await tiers.preload(url)
    }

    // MARK: - Keeping and forgetting

    /// The one grip on the cache: every way through this door reaches it
    /// here, so the coupling to the singleton stands on one line.
    private static var tiers: ImageCache { ImageCache.shared }

    /// A downloaded item's cover leaves the purgeable tier for the
    /// persistent one (moved, or fetched once).
    static func persist(_ url: URL?) async {
        await tiers.makePersistent(coverURL: url)
    }

    /// The write half with the bytes in hand.
    static func persist(_ url: URL, data: Data) async {
        await tiers.makePersistent(coverURL: url, data: data)
    }

    /// The persistent copy goes back to the purgeable tier.
    static func forget(_ url: URL?) {
        tiers.removePersistent(coverURL: url)
    }

    /// The persistent copy takes a new address (a download moved to a new id).
    static func rename(from old: URL?, to new: URL?) {
        tiers.renamePersistent(from: old, to: new)
    }

    /// Returns once every rename, like every other disk work, queued so far
    /// has moved its files.
    static func settleDisk() async {
        await tiers.settleDisk()
    }

    /// Every cached representation of an address is dropped: the server may
    /// have replaced the artwork behind an unchanged id.
    static func invalidate(_ url: URL) {
        tiers.invalidate(url: url)
    }

    // MARK: - Sweeping

    /// The sweep: orphaned persistent covers back to the cache, files over
    /// the TTL and over the cap out; measured in the log. It also writes the
    /// session's new service placeholders, at start and on going to the
    /// background.
    static func sweep() {
        Task { await sweep(over: DownloadManager.shared, onlyWhenOverCap: false) }
        ServicePlaceholderCovers.flush()
    }

    /// The extra pass on returning to the app, for a session that has run
    /// far past the cap. It decides INSIDE the sweep's own background task
    /// whether there is anything to do, because the deciding question is a
    /// full directory enumeration and used to be asked on the main actor.
    static func sweepIfOverCap() {
        Task { await sweep(over: DownloadManager.shared, onlyWhenOverCap: true) }
    }

    /// The pass itself, awaitable. The active covers come from the downloads
    /// after their scan; when the answer is incomplete (a download whose
    /// cover address cannot be built now), the pass demotes and drops
    /// nothing, because a cover it cannot name may be one it must keep.
    static func sweep(over downloads: DownloadManager, onlyWhenOverCap: Bool) async {
        let covers = await downloads.activeCovers()
        if !covers.knowsAll {
            Logger.library.notice("COVERCACHE tiers hold: unresolved=\(covers.unresolved) idMovePending=\(covers.movePending) unreadable=\(covers.unreadable), nothing demoted, no old name moved")
        }
        await tiers.performMaintenance(activeCoverURLs: covers.urls, knowsAll: covers.knowsAll,
                                       onlyWhenOverCap: onlyWhenOverCap).value
    }

    static func cacheSizeBytes() -> Int64 {
        tiers.cacheSizeBytes()
    }

    static func clearCache() {
        tiers.clearCache()
        ServicePlaceholderCovers.forgetAll()
    }

    // MARK: - The one network path

    private static func fetch(_ url: URL, retryDelay: UInt64?, attempt: Int) async -> Fetched {
        // Offline there is nothing to fetch. Per-cell attempts during
        // scrolling would only burn cycles.
        guard await Reachability.isConnected() else {
            CoverTraceLog.note(pot: .network, outcome: .offline, attempt: attempt, url: url)
            return .unanswered
        }
        if let retryDelay {
            // bearable, because a cancelled sleep only drops the second attempt
            try? await Task.sleep(nanoseconds: retryDelay)
        }
        // The invalidation count when this request leaves; `set` keeps the
        // answer only when no invalidation came in between.
        let startedAt = tiers.invalidationCount(for: url)
        // bearable, because the HTTP door logs the failure with its reason and the trace names it as transport
        guard let (data, http) = try? await HTTP.data(from: url, lane: .cover) else {
            CoverTraceLog.note(pot: .network, outcome: .transport, attempt: attempt, url: url)
            return .unanswered
        }
        // The status is read BEFORE the bytes: a 404 body is JSON at the
        // Cover Art Archive and an HTML page elsewhere, and neither is
        // "bytes that do not decode". Only an absence says the address
        // names no picture; every other status says nothing about it.
        if let status = http?.statusCode, !(200...299).contains(status) {
            let absent = StatusMeaning.from(status: status).isAbsence
            CoverTraceLog.note(pot: .network, outcome: absent ? .absent : .status, attempt: attempt,
                               url: url, bytes: data.count)
            return absent ? .absent : .unanswered
        }
        // The archive item-image service never says "no picture"; it
        // answers with its pillar logo or a waveform strip. Recognised here,
        // where the bytes already are, never cached as a picture, and
        // remembered as "none" for good.
        if ArchiveServicePlaceholder.isPlaceholder(data: data, url: url) {
            ServicePlaceholderCovers.insert(url)
            CoverTraceLog.note(pot: .network, outcome: .servicePlaceholder, attempt: attempt, url: url)
            return .absent
        }
        // A server can answer a cover address with a JSON error body under
        // a 2xx (Funkwhale). `UIImage(data:)` reads what UIKit knows;
        // ImageIO reads more, among them the `.ico` a station's own site
        // serves as its icon. Bytes that are no picture say nothing about
        // the picture, and nothing non-image is ever cached.
        guard let image = UIImage(data: data) ?? ImageCache.decoded(data) else {
            CoverTraceLog.note(pot: .network, outcome: .undecodable, attempt: attempt,
                               url: url, bytes: data.count)
            return .unanswered
        }
        tiers.set(image, data: data, for: url, startedAt: startedAt)
        CoverTraceLog.note(pot: .network, outcome: .hit, attempt: attempt, url: url)
        return .picture(image)
    }
}

/// Cover addresses whose answer turned out to be a service placeholder
/// (archive's pillar logo, a derived waveform strip), kept across sessions
/// like a found picture. Measured on a scroll run: 94 of 229 cover fetches
/// at archive.org came back as such a placeholder, the same items many
/// times over, because the memory lasted one session.
///
/// The list grows with every archive title scrolled past, so it has a cap
/// and drops its oldest entries past it. It lives under a key of its own,
/// written as ONE list under the rule stamp: a list made under another
/// rule is not read and goes with the next write. An entry costs a set
/// insert on the main actor; the list is written only where the app
/// already tidies up (the sweep at start and on going to the background),
/// never per entry. A session that ends without either loses its new
/// entries, which costs one more question each. Measured on a Mac for 2000
/// addresses: 133 kB, 0.55 ms to encode, 1.47 ms to decode.
@MainActor
enum ServicePlaceholderCovers {
    nonisolated static let storeKey = "servicePlaceholderCovers"
    static let cap = 2000

    private struct Stored: Codable {
        var rule: String
        /// Oldest first.
        var urls: [String]
    }

    /// The session's copy, read once: the order for the cap, the set for
    /// the question. Live entries are `order[head...]`; dropping the oldest
    /// moves `head`, and the dead front is cut once it is as long as the
    /// cap, so an entry costs a constant amount on average.
    private static var order: [String]?
    private static var head = 0
    private static var members: Set<String> = []
    /// Whether the session holds entries the store does not.
    private static var unwritten = false

    /// How many addresses are remembered now.
    static func count(defaults: UserDefaults = AppStorageKeys.store) -> Int {
        load(defaults)
        return members.count
    }

    static func contains(_ url: URL, defaults: UserDefaults = AppStorageKeys.store) -> Bool {
        load(defaults)
        return members.contains(url.absoluteString)
    }

    static func insert(_ url: URL, defaults: UserDefaults = AppStorageKeys.store) {
        load(defaults)
        let address = url.absoluteString
        guard members.insert(address).inserted else { return }
        order?.append(address)
        if members.count > cap, let oldest = order?[head] {
            members.remove(oldest)
            head += 1
            if head >= cap {
                order?.removeFirst(head)
                head = 0
            }
        }
        unwritten = true
    }

    /// The person cleared the cover cache: every placeholder is asked again.
    static func forgetAll(defaults: UserDefaults = AppStorageKeys.store) {
        order = []
        head = 0
        members = []
        unwritten = false
        defaults.removeObject(forKey: storeKey)
    }

    /// Writes the session's entries if it holds new ones. Called by the
    /// sweep, and by the witness.
    static func flush(defaults: UserDefaults = AppStorageKeys.store) {
        guard unwritten, let order else { return }
        unwritten = false
        let live = Array(order[head...])
        // bearable, because a list of text always encodes; a failure would only keep the older list
        guard let data = try? JSONEncoder().encode(Stored(rule: ArchiveServicePlaceholder.rule, urls: live))
        else { return }
        defaults.set(data, forKey: storeKey)
    }

    /// The start of a new session, for a witness that proves the memory
    /// outlives it.
    static func dropSessionCopy() {
        unwritten = false
        order = nil
        head = 0
        members = []
    }

    private static func load(_ defaults: UserDefaults) {
        guard order == nil else { return }
        var read: [String] = []
        if let data = defaults.data(forKey: storeKey),
           // bearable, because an unreadable list only costs placeholders asked once more; the next write replaces it
           let stored = try? JSONDecoder().decode(Stored.self, from: data),
           stored.rule == ArchiveServicePlaceholder.rule {
            read = Array(stored.urls.suffix(cap))
        }
        order = read
        head = 0
        members = Set(read)
    }
}

/// One network fetch per cover URL at a time. Two surfaces showing the
/// same show raced each other to the first cache write and BOTH paid the
/// download (measured: 8 of 56 fetches in a cold scroll pass were such
/// twins). The second caller now awaits the first one's task instead.
@MainActor
enum CoverFetchCoalescer {
    static var inFlight: [URL: Task<Artwork.Fetched, Never>] = [:]

    static func fetch(_ url: URL, work: @escaping () async -> Artwork.Fetched) async -> Artwork.Fetched {
        if let running = inFlight[url] { return await running.value }
        let task = Task { await work() }
        inFlight[url] = task
        let fetched = await task.value
        inFlight[url] = nil
        return fetched
    }
}

/// The chain's own voice. Main-actor bound because every caller sits on
/// the view; a lock would buy nothing and cost a hop in the scroll path.
///
/// The line is `notice`: a device archive keeps `notice` and above,
/// while `debug` stays in the ring buffer and never reaches
/// `log collect`. The line exists to be read from exactly such an
/// archive, so any lower level would make it silent where it matters.
@MainActor
enum CoverTraceLog {
    private static var counter = CoverTrace.Counter()

    /// The attempt number for this address, counted before the chain
    /// picks an exit so every exit can name it.
    static func attempt(for url: URL) -> Int {
        if counter.trackedAddresses >= CoverTrace.addressCeiling { counter.reset() }
        return counter.next(for: url)
    }

    static func note(pot: CoverTrace.Pot, outcome: CoverTrace.Outcome,
                     attempt: Int, url: URL, bytes: Int? = nil) {
        Logger.library.notice(
            "\(CoverTrace.line(pot: pot, outcome: outcome, attempt: attempt, url: url, bytes: bytes), privacy: .public)")
    }
}
