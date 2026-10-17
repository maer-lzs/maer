// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import UIKit
import ImageIO
import OSLog
import CryptoKit

/// Two-tier cache for cover images: memory + disk. Disk in TWO tiers:
/// - `Caches/CoverCache`: normal library. iOS may purge it under memory pressure.
/// - `Application Support/Covers`: covers of DOWNLOADED books. Persistent, so
///   the offline promise does not depend on iOS cleanup runs.
///
/// A cover larger than the display size is stored reduced to it (JPEG at
/// 0.9); a smaller one keeps the server's original bytes.
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    /// Is a prefetch running for this cover? Prevents loading the same cover
    /// multiple times in parallel (prefetch + visible cell).
    private var inFlight = Set<URL>()
    /// Small tier derived from the full covers for grid/row cells: decoding
    /// the full ~2000 px cover for a ~150 pt cell costs ~16 MB RAM per image
    /// and stutters scrolling with large libraries. Memory-only. Always
    /// derivable from the disk tiers.
    private let thumbCache = NSCache<NSString, UIImage>()
    /// The one default thumbnail size, for the cache and for every cell that
    /// asks the door without naming a size.
    nonisolated static let defaultThumbnailPixel: CGFloat = 400
    private let thumbPixelSize: CGFloat = ImageCache.defaultThumbnailPixel
    /// The preview sizes an invalidation removes. They are ours, not the
    /// server's. So an invalidation can name them instead of emptying the
    /// whole store. The bound: the list holds the sizes of the surfaces
    /// that show an address something invalidates (the music tab's grid and
    /// album page, the default of CarPlay and the widget). The 800 px
    /// Continue card is not in it because music never stands in Continue
    /// (`HomeSections.continueAccepts`). A surface that invalidates the
    /// covers it shows at another size adds that size here; the fence only
    /// holds the list as written, not this question.
    nonisolated static let thumbnailVariants: [CGFloat] = [400, 600]

    /// How many images each cache is MEANT to hold. The cost limit is
    /// derived from this instead of written down beside it, because two
    /// limits stating different numbers let the smaller one bind invisibly.
    /// Previews get the larger share, because they are what every row and
    /// every grid needs; full images stand on screen once or twice.
    nonisolated static let thumbBudget = 240
    nonisolated static let fullCoverBudget = 6

    private let diskDirectory: URL
    private let persistentDirectory: URL
    /// Keys invalidated this session whose persistent copy must not answer a
    /// gate that goes to the network before the network replaced it
    /// (`invalidate`). The copy stays on disk and stays the last candidate
    /// of every read path (`readCandidates`).
    private var refreshing: Set<String> = []
    /// How often each key was invalidated this session. A load takes the
    /// count when it starts (`invalidationCount`); `set` keeps its bytes only
    /// when no invalidation came in between, so an answer to a request sent
    /// before the invalidation never becomes the new picture.
    private var invalidations: [String: Int] = [:]
    /// The disk work of each address, one after the other in the order the
    /// main actor asked for it (`onDisk`). A write and an invalidation's
    /// removal were two unordered background tasks, and a write that landed
    /// after the removal left the picture from before the invalidation in
    /// the cache file, where the network gate found it for the session.
    private var diskTail: [String: (turn: Int, task: Task<Void, Never>)] = [:]
    private var diskTurns = 0

    /// Device-adaptive storage size (longest side): screen short side in
    /// pixels × 1.6 headroom. Plain 1× turned out visibly soft on modern
    /// iPhones. Clamped to 1500 (older, low-res devices don't need more)
    /// … 2200 (above the iPad-Pro hero width is invisible overhead).
    /// Modern iPhones land at ~1900–2100, iPads at 2200.
    private let maxPixelSize: CGFloat

    private init() {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }.first
        let shortSidePixels = screen.map { min($0.bounds.width, $0.bounds.height) * $0.scale } ?? 1500
        maxPixelSize = min(2200, max(1500, shortSidePixels * 1.6))
        // Tile rows threw their images away again as soon as one scrolled
        // sideways. Both caches carried TWO limits meaning different numbers,
        // and the smaller one bound without the larger one showing it. Worked
        // out:
        //
        //   preview  400 x 400 x 4  =   640 kB  →  40 MB held ~62 images,
        //                                          NOT the stated 600.
        //   full    ~2000 x 2000 x 4 = ~16 MB   → 150 MB held ~9 images,
        //                                          NOT the stated 300.
        //
        // A SINGLE row shows twelve tiles and the start surface carries six
        // rows, so the cache was full after two or three rows and every
        // returning tile found nothing. Exactly the symptom.
        //
        // The split was also the inverse of the use: the rendering every row
        // and every grid needs had a quarter of the budget of the rendering
        // that stands on screen once or twice. Now both limits state the same
        // number PER cache, so neither is decoration.
        //
        // The limit IS the arithmetic, so it cannot drift from the count
        // written beside it.
        memoryCache.countLimit = Self.fullCoverBudget
        memoryCache.totalCostLimit = Self.fullCoverBudget * Int(maxPixelSize * maxPixelSize) * 4
        thumbCache.countLimit = Self.thumbBudget
        thumbCache.totalCostLimit = Self.thumbBudget * Int(thumbPixelSize * thumbPixelSize) * 4
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDirectory = caches.appendingPathComponent("CoverCache", isDirectory: true)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        persistentDirectory = support.appendingPathComponent("Covers", isDirectory: true)
        for dir in [diskDirectory, persistentDirectory]
        where !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Keep persistent covers out of backups (can be re-downloaded anytime).
        BackupExclusion.mark(persistentDirectory, label: "covers")
        // The budget answers memory pressure: the full covers go at once.
        // The cache lives as long as the app, so the observer does too.
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseFullCovers() }
        }
    }

    /// How often memory pressure released the full covers.
    private(set) var fullCoverReleases = 0

    /// The query names that sign a request in or describe the client, never
    /// the picture: none of them enters a cover's file name. Each sign-in form
    /// declares its own names where it writes them, and this set is their
    /// union, so a new sign-in part cannot be missed by a second list kept by
    /// hand (Subsonic's `apiKey` once was, and every cover name in that mode
    /// carried the key in clear text). Subsonic rotates `t`/`s` per request,
    /// Audiobookshelf carries its session `token`, Jellyfin its `ApiKey`. A
    /// key that carried the token missed on every login AND, at roughly 300
    /// characters, exceeded the file system's 255-byte name limit.
    nonisolated static let signInQueryNames: Set<String> = SubsonicSignIn.queryNames
        .union(SubsonicClient.clientQueryNames)
        .union([APIClient.mediaTokenName, JellyfinClient.mediaAuthQueryName])
        .union(retiredQueryNames)

    /// Sign-in names no build writes any more, kept out of a name as well:
    /// Jellyfin's legacy `api_key` (covers cached before `ApiKey`) and
    /// Subsonic's password form `p`.
    nonisolated static let retiredQueryNames: Set<String> = ["api_key", "p"]

    /// The sign-in names that name nothing else, every one longer than one
    /// letter (`token`, `apiKey`, `api_key`, `ApiKey`): they stay out of the
    /// name at ANY address. A one-letter name (`t`, `s`, `u`, `v`, `c`, `f`,
    /// `p`) names the picture itself on many foreign hosts (a cache-buster
    /// `t`, a version `v`, a size `s`), so it is a sign-in part only at an
    /// address one of our clients built (`isClientImage`).
    nonisolated static let unambiguousSignInNames: Set<String> = signInQueryNames.filter { $0.count > 1 }

    /// Whether one of our clients built this image address, from the path
    /// shapes each client declares where it builds them.
    nonisolated static func isClientImage(_ url: URL) -> Bool {
        let path = url.path
        return SubsonicClient.buildsImage(path: path) || APIClient.buildsImage(path: path)
            || JellyfinClient.buildsImage(path: path)
    }

    /// Whether a query name stays out of the file name of an address.
    nonisolated static func dropsFromName(_ name: String, clientImage: Bool) -> Bool {
        unambiguousSignInNames.contains(name) || (clientImage && signInQueryNames.contains(name))
    }

    /// A cover's file name as a build that kept a sign-in part in it wrote it,
    /// without that part, or nil when the name carries none. The parts of a
    /// clear name are joined by `_`, a query part reads `name=value`, and the
    /// query parts follow the path parts. A value holding `_`, `/` or `:`
    /// (all written as `_`) leaves parts without `=` behind its sign-in part;
    /// they belong to its value and go with it. The limit: a value piece that
    /// carries `=` itself (`p=ab_cd=ef`) reads like a query part and stays in
    /// the name, so that name differs from today's and its cover loads once
    /// more; a name gives no way to tell such a piece from a query part. A
    /// digest name cannot be read and stays (its cover loads again). Only
    /// the unambiguous names are dropped: a one-letter part stays, because
    /// today's rule keeps it at a foreign address, and no build ever wrote
    /// one into the name of an address of our clients.
    nonisolated static func nameWithoutSignIn(_ name: String) -> String? {
        let parts = name.components(separatedBy: "_")
        var kept: [String] = []
        var inSignInValue = false
        for part in parts {
            if unambiguousSignInNames.contains(where: { part.hasPrefix("\($0)=") }) {
                inSignInValue = true
                continue
            }
            if inSignInValue && !part.contains("=") { continue }
            inSignInValue = false
            kept.append(part)
        }
        return kept.count == parts.count ? nil : kept.joined(separator: "_")
    }

    /// Renames every file whose name carries a sign-in part to the name
    /// without; a file already standing under that name wins.
    nonisolated private static func dropSignInFromNames(in directories: [URL], listing: (URL) -> Set<String>,
                                                        holds: (URL) -> Bool) -> [URL] {
        rename(in: directories, listing: listing, what: "sign-in dropped from names", holds: holds) { nameWithoutSignIn($0) }
    }

    /// The kept covers of foreign addresses under the name the earlier rule
    /// gave them (it dropped one-letter query parts that name the picture):
    /// old name to today's name, for every active address where they differ.
    /// An old name that is today's name of an active address is that
    /// address's cover and never moves; an old name two active addresses
    /// lead to different names from does not move either. Such a cover loads
    /// once more instead of handing one address the bytes of another.
    /// Only when `activeURLs` names every download's cover (`knowsAll`): a
    /// download that could not be resolved (an episode of a show no longer
    /// followed) is missing from the list, and its kept cover could stand
    /// under the old name of an active neighbour. Without it nothing moves;
    /// an old name waits for the next complete pass. On a device whose list
    /// stays incomplete, it stays in the kept folder, outside the cap, and
    /// its address loads once more under today's name: safety over clearing
    /// up.
    nonisolated static func legacyMoves(for activeURLs: [URL], knowsAll: Bool,
                                        name: (URL) -> String) -> [String: String] {
        guard knowsAll else { return [:] }
        let todays = activeURLs.map { ($0, name($0)) }
        let activeNames = Set(todays.map(\.1))
        var targets: [String: Set<String>] = [:]
        for (url, new) in todays {
            let old = legacyName(for: url)
            if old != new, !activeNames.contains(old) { targets[old, default: []].insert(new) }
        }
        return targets.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    /// Whether the network gate of a waiting address reads `target`: it reads
    /// the purgeable tier alone (`readCandidates`), so a file landing there
    /// under a waiting name is what that gate answers instead of the network.
    nonisolated static func gateOfWaitingReads(_ target: URL, cache: URL, waiting: Set<String>) -> Bool {
        stands(target, in: cache) && waiting.contains(target.lastPathComponent)
    }

    /// The one answer to "which tier holds this file": its folder, compared
    /// as standardized paths (a trailing slash or a dot segment makes no
    /// other folder). Path against path, where two of the three askers
    /// compared URLs before: a folder named without its trailing slash is
    /// now the same folder (`theFolderQuestionHasOneAnswer`).
    nonisolated static func stands(_ file: URL, in directory: URL) -> Bool {
        file.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
    }

    /// The file names in a cover directory.
    nonisolated private static func fileNames(in directory: URL) -> Set<String> {
        // bearable, because a missing directory holds no cover
        Set(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []))
    }

    /// Moves the kept covers of foreign addresses to today's name (`legacyMoves`).
    nonisolated private static func moveLegacyNames(in directories: [URL], listing: (URL) -> Set<String>,
                                                    moves: [String: String], holds: (URL) -> Bool) -> [URL] {
        rename(in: directories, listing: listing, what: "foreign names moved", holds: holds) { moves[$0] }
    }

    /// Renames every file `newName` gives a new name for; a file already
    /// standing under the new name wins. A target `holds` names stays as it
    /// is and the file keeps its old name: under that name the network gate
    /// of a waiting address would answer with bytes from before its
    /// invalidation. Returns the targets a file was moved to. Logged when
    /// anything was renamed, held or failed.
    nonisolated private static func rename(in directories: [URL], listing: (URL) -> Set<String>, what: String,
                                           holds: (URL) -> Bool, newName: (String) -> String?) -> [URL] {
        let fm = FileManager.default
        var renamed = 0
        var failed = 0
        var firstFailure: String?
        var held = 0
        var placed: [URL] = []
        for directory in directories {
            for name in listing(directory).sorted() {
                guard let clean = newName(name) else { continue }
                let source = directory.appendingPathComponent(name)
                let target = directory.appendingPathComponent(clean)
                if holds(target) {
                    held += 1
                    continue
                }
                do {
                    if fm.fileExists(atPath: target.path) {
                        try fm.removeItem(at: source)
                    } else {
                        try fm.moveItem(at: source, to: target)
                        placed.append(target)
                    }
                    renamed += 1
                } catch {
                    failed += 1
                    if firstFailure == nil { firstFailure = FailureReason.of(error) }
                }
            }
        }
        if let line = renameLine(what, renamed: renamed, failed: failed, held: held, firstFailure: firstFailure) {
            if failed > 0 {
                Logger.library.error("\(line, privacy: .public)")
            } else {
                Logger.library.notice("\(line, privacy: .public)")
            }
        }
        return placed
    }

    /// APFS refuses names over 255 bytes. A key beyond `keyByteCeiling`
    /// becomes its digest, so no future long query can silently disable
    /// the disk cache the way the token did.
    nonisolated private static let keyByteCeiling = 200

    /// Host + path + the STABLE query params (e.g. Subsonic `id`/`size`). Path
    /// alone collided every Subsonic cover onto one key. Their identifying
    /// `id` lives in the query, so all albums shared a single cached file.
    nonisolated private func key(for url: URL) -> String {
        let clientImage = Self.isClientImage(url)
        return Self.fileName(for: url) { Self.dropsFromName($0, clientImage: clientImage) }
    }

    /// The name an address had under the earlier rule, which dropped every
    /// sign-in name at every address. Only for moving kept covers of foreign
    /// addresses to their new name (`legacyMoves`).
    nonisolated static func legacyName(for url: URL) -> String {
        fileName(for: url) { signInQueryNames.contains($0) }
    }

    /// The file name of an address with the query names `drops` names left
    /// out.
    nonisolated private static func fileName(for url: URL, drops: (String) -> Bool) -> String {
        var parts = [url.host ?? "", url.path]
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            let stable = items
                .filter { !drops($0.name) }
                .sorted { $0.name < $1.name }
                .map { "\($0.name)=\($0.value ?? "")" }
            parts.append(contentsOf: stable)
        }
        let raw = parts.joined(separator: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        guard raw.utf8.count > Self.keyByteCeiling else { return raw }
        return SHA256.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// The ONE file name for a cover, in the cache and in the persistent
    /// store alike. A second derivation from the item id (without host)
    /// once wrote persistent covers under a name no read path looked up,
    /// so the offline cover of a downloaded book never existed.
    nonisolated func fileKey(for url: URL) -> String { key(for: url) }

    #if DEBUG
    /// Test seam for the pure key derivation.
    nonisolated func testKey(for url: URL) -> String { key(for: url) }

    /// Test seam: whether a cover stands in the persistent tier (the read
    /// paths find both tiers and cannot tell them apart).
    func testIsPersistent(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: persistentDirectory.appendingPathComponent(key(for: url)).path)
    }

    /// Test seam: a picture written straight into the purgeable tier, the
    /// way a tile's fetch leaves it.
    func testPlaceInCache(_ data: Data, for url: URL, modified: Date? = nil) -> Bool {
        let path = diskDirectory.appendingPathComponent(key(for: url)).path
        guard FileManager.default.createFile(atPath: path, contents: data) else { return false }
        guard let modified else { return true }
        // bearable, because a test seam answers a failure with false, which the witness asserts
        return (try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)) != nil
    }

    /// Test seam: a file under a literal name in the persistent tier, the way
    /// an older build named it.
    func testPlacePersistent(_ data: Data, named name: String) -> Bool {
        FileManager.default.createFile(atPath: persistentDirectory.appendingPathComponent(name).path, contents: data)
    }

    /// Test seam: a file under a literal name in the purgeable tier, the way
    /// an older build named it.
    func testPlaceInCache(_ data: Data, named name: String) -> Bool {
        FileManager.default.createFile(atPath: diskDirectory.appendingPathComponent(name).path, contents: data)
    }

    /// Test seam: whether a literal name stands in the purgeable tier.
    func testIsInCache(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: diskDirectory.appendingPathComponent(name).path)
    }

    /// Test seam: whether a literal name stands in the persistent tier.
    func testIsPersistent(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: persistentDirectory.appendingPathComponent(name).path)
    }

    /// Test seam: step 0 as a complete pass runs it, through the sweep's own
    /// `renameStep`, without demoting the covers of neighbouring witnesses.
    /// `waitingAtStart` stands in for the waiting names as the step begins
    /// (an invalidation that comes during the step is not among them).
    func testMoveLegacyNames(activeCoverURLs: [URL], waitingAtStart: Set<String>? = nil) async {
        let moves = Self.legacyMoves(for: activeCoverURLs, knowsAll: true) { key(for: $0) }
        await renameStep(persistent: persistentDirectory, cache: diskDirectory, moves: moves, waitingAtStart: waitingAtStart)
    }

    /// Test seam: the moves between the tiers for the given moves alone, as
    /// the sweep runs them, without the moves of neighbouring witnesses.
    func testApplyTierMoves(_ moves: [TierMove]) async {
        await Self.applyTierMoves(moves, persistent: persistentDirectory, cache: diskDirectory) { name in
            await MainActor.run { self.refreshing.contains(name) }
        }
    }

    /// Test seam: removes a literal name from the persistent tier; false when
    /// nothing stood there.
    @discardableResult
    func testRemovePersistent(named name: String) -> Bool {
        do {
            try FileManager.default.removeItem(at: persistentDirectory.appendingPathComponent(name))
            return true
        } catch {
            return false
        }
    }

    /// Test seam: a picture written straight into the persistent tier.
    func testPlacePersistent(_ data: Data, for url: URL) -> Bool {
        FileManager.default.createFile(atPath: persistentDirectory.appendingPathComponent(key(for: url)).path,
                                       contents: data)
    }

    /// Test seam: the bytes of the persistent copy, nil without one.
    func testPersistentBytes(_ url: URL) -> Data? {
        FileManager.default.contents(atPath: persistentDirectory.appendingPathComponent(key(for: url)).path)
    }

    /// Test seam: whether an address waits for the network to replace its
    /// persistent copy.
    func testIsRefreshing(_ url: URL) -> Bool { refreshing.contains(key(for: url)) }

    /// Test seam: the bytes of the purgeable cache file, nil without one.
    func testCacheBytes(_ url: URL) -> Data? {
        FileManager.default.contents(atPath: diskDirectory.appendingPathComponent(key(for: url)).path)
    }

    /// Test seam: returns once every disk work the main actor ordered for
    /// this address so far has run.
    func testDiskSettled(_ url: URL) async {
        await diskTail[key(for: url)]?.task.value
    }

    /// Test seam: holds the disk chain of an address until the returned
    /// release is called, so work queued for it after this stays queued.
    func testHoldDisk(_ url: URL) -> @Sendable () -> Void {
        let (gate, open) = AsyncStream<Void>.makeStream()
        onDisk(key(for: url)) { for await _ in gate {} }
        return { open.finish() }
    }

    /// Test seam: awaited with the stage and the file name by a write after
    /// its look at the invalidation count and before its first byte
    /// ("write"), by the same write after its last step ("written"), and by
    /// a read after its disk read and before it stores the picture in memory
    /// ("read"). A witness holds a stage there and invalidates in between;
    /// "written" lets it wait for the write without relying on the order
    /// `onDisk` is meant to give.
    var testDiskHold: (@Sendable (_ stage: String, _ fileKey: String) async -> Void)?
    #endif

    /// The files a read path tries, in order. For an address waiting for the
    /// network after an invalidation the persistent copy is the LAST
    /// candidate: a gate that goes to the network asks first without it
    /// (`allowKept: false`), so the next display asks the server, and every
    /// other reader (CarPlay, the widget) and the network gate after a failed
    /// load still find it.
    private func readCandidates(_ fileKey: String, allowKept: Bool) -> [URL] {
        let tiers: [URL]
        if !refreshing.contains(fileKey) {
            tiers = [persistentDirectory, diskDirectory]
        } else {
            tiers = allowKept ? [diskDirectory, persistentDirectory] : [diskDirectory]
        }
        return tiers.map { $0.appendingPathComponent(fileKey) }
    }

    /// The memory name of a picture read while its address waits for the
    /// network. It may be the persistent copy, so it shares the budget of
    /// its cache under its own name: a reader that may show the kept copy
    /// finds it there, and a gate that goes to the network next never does.
    /// Without it nothing read during the wait stayed in memory, and every
    /// look decoded from disk again with the placeholder in between.
    private nonisolated static func waitingName(_ memoryKey: String) -> NSString {
        "\(memoryKey)#waiting" as NSString
    }

    /// Removes the waiting entries of an address from both memory caches.
    private func dropWaiting(_ fileKey: String) {
        memoryCache.removeObject(forKey: Self.waitingName(fileKey))
        for size in Self.thumbnailVariants {
            thumbCache.removeObject(forKey: Self.waitingName("\(fileKey)@\(Int(size))"))
        }
    }

    /// Runs `work` off the main actor after every disk work this address
    /// already has, so a write and an invalidation's removal land in the
    /// order the main actor asked for them.
    private func onDisk(_ fileKey: String, _ work: @escaping @Sendable () async -> Void) {
        onDisk([fileKey], work)
    }

    /// The same for work that touches several addresses (a rename moves a
    /// file from one name to another): it waits for the disk work of each,
    /// and each later work of any of them waits for it.
    private func onDisk(_ fileKeys: [String], _ work: @escaping @Sendable () async -> Void) {
        diskTurns += 1
        let turn = diskTurns
        let keys = Array(Set(fileKeys))
        let previous = keys.compactMap { diskTail[$0]?.task }
        // detached because the work is disk and CPU work off the MainActor and must finish once started
        let task = Task.detached(priority: .utility) {
            for earlier in previous { await earlier.value }
            await work()
            for key in keys { await ImageCache.shared.leaveDisk(key, turn: turn) }
        }
        for key in keys { diskTail[key] = (turn, task) }
    }

    /// Returns once every disk work queued so far has run. A rename has not
    /// moved its file when `renamePersistent` returns; whoever relies on the
    /// files standing under their new names (the id move's marker, after
    /// which the sweep demotes by those names) waits here first. Work queued
    /// after the call is not waited for.
    func settleDisk() async {
        let queued = diskTail.values.map(\.task)
        for task in queued { await task.value }
    }

    /// The last disk work of an address ended: its entry goes, unless newer
    /// work was queued behind it.
    private func leaveDisk(_ fileKey: String, turn: Int) {
        if diskTail[fileKey]?.turn == turn { diskTail[fileKey] = nil }
    }

    /// The invalidation count of an address, taken by a load when it starts
    /// and handed to `set`.
    func invalidationCount(for url: URL) -> Int { invalidations[key(for: url), default: 0] }

    /// Decoded bytes as NSCache cost (pixels × 4).
    private func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.width * cg.height * 4
    }

    /// A fetched cover at display size and the bytes to keep for it, reduced
    /// off the caller's executor before anything holds it: the original of a
    /// large cover is never decoded in full (a 3000 px cover is 36 MB
    /// decoded). `@concurrent`: a plain nonisolated async function would run
    /// on the caller's actor under the project's default. Through `sizing`:
    /// throws `CancellationError` when the caller left before its turn, and
    /// then decodes nothing; nil when ImageIO can not reduce the bytes.
    @concurrent
    nonisolated static func displaySized(_ data: Data, maxPixelSize: CGFloat) async throws -> (UIImage, Data)? {
        try await sizing.enter()
        let sized = downsampled(data, maxPixelSize: maxPixelSize)
        await sizing.leave()
        return sized
    }

    /// At most two covers are brought to size at once (`displaySized`,
    /// `reduced`).
    nonisolated static let sizing = SizingGate(width: 2)

    /// The size a full cover is held at (`displaySized`).
    var displayPixelSize: CGFloat { maxPixelSize }

    /// A cover reduced to `maxPixelSize` on its longer side, off the
    /// caller's executor; one already as small stays. For a cell that asked
    /// for a thumbnail and got a cover fresh from the network. Through
    /// `sizing`; a cell that left before its turn gets the picture as it
    /// came, reduced nowhere, and shows nothing of it.
    @concurrent
    nonisolated static func reduced(_ image: UIImage, maxPixelSize: CGFloat) async -> UIImage {
        let width = image.size.width * image.scale, height = image.size.height * image.scale
        guard max(width, height) > maxPixelSize else { return image }
        let factor = maxPixelSize / max(width, height)
        let size = CGSize(width: (width * factor).rounded(), height: (height * factor).rounded())
        do { try await sizing.enter() } catch { return image }
        let thumb = image.preparingThumbnail(of: size) ?? image
        await sizing.leave()
        return thumb
    }

    /// Downsample images > maxPixelSize at high quality (ImageIO); leave smaller
    /// originals untouched. nonisolated + static: runs on a background thread,
    /// NOT on the MainActor (ImageIO decodes of large covers would otherwise
    /// stutter the UI).
    private nonisolated static func downsampled(_ data: Data, maxPixelSize: CGFloat) -> (UIImage, Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        if max(w, h) <= maxPixelSize {
            guard let image = UIImage(data: data) else { return nil }
            return (image, data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            guard let image = UIImage(data: data) else { return nil }
            return (image, data)
        }
        let image = UIImage(cgImage: cg)
        guard let jpeg = image.jpegData(compressionQuality: 0.9) else { return (image, data) }
        return (image, jpeg)
    }

    /// Thumbnail (≤ thumbPixelSize) for grid/row cells, derived on demand
    /// from the disk tiers. Returns nil when the cover is not on disk yet.
    /// The caller then fetches the full image from the network as usual.
    func thumbnail(for url: URL) async -> UIImage? {
        await thumbnail(for: url, maxPixelSize: thumbPixelSize)
    }

    /// Synchronous memory-cache peek (no disk, no decode). Lets a cell show
    /// a WARM, already display-ready thumbnail on its very first frame instead of
    /// flashing the placeholder and awaiting a round-trip each time it re-enters
    /// the viewport. Takes the warm-cover cost fully out of the scroll path.
    func cachedThumbnail(for url: URL, maxPixelSize: CGFloat? = nil) -> UIImage? {
        let fileKey = key(for: url)
        let cacheKey = "\(fileKey)@\(Int(maxPixelSize ?? thumbPixelSize))"
        if let warm = thumbCache.object(forKey: cacheKey as NSString) { return warm }
        // The first frame may show the kept copy of a waiting address; the
        // cell's load still asks the network gate, which never reads it.
        guard refreshing.contains(fileKey) else { return nil }
        return thumbCache.object(forKey: Self.waitingName(cacheKey))
    }

    /// As above, but with a freely chosen target size (e.g. 800 px for the large
    /// "Up Next" cards). The cache is size-aware keyed so 400- and 800-px
    /// variants of the same cover do not overwrite each other.
    /// `allowKept: false` is for a gate that goes to the network next: an
    /// address waiting after an invalidation then skips its persistent copy.
    func thumbnail(for url: URL, maxPixelSize: CGFloat, allowKept: Bool = true) async -> UIImage? {
        let fileKey = key(for: url)
        let cacheKey = "\(fileKey)@\(Int(maxPixelSize))"
        if let cached = thumbCache.object(forKey: cacheKey as NSString) {
            // A warm hit returns a display-ready image (see decodedThumbnail).
            // No main-thread decode at draw time.
            PerfSignpost.thumbnailHit()
            return cached
        }
        let waiting = refreshing.contains(fileKey)
        if waiting, allowKept, let kept = thumbCache.object(forKey: Self.waitingName(cacheKey)) {
            PerfSignpost.thumbnailHit()
            return kept
        }
        let startedAt = invalidations[fileKey, default: 0]
        let candidates = readCandidates(fileKey, allowKept: allowKept)
        guard let (thumb, source) = await diskThumbnail(candidates, maxPixelSize: maxPixelSize) else { return nil }
        #if DEBUG
        await testDiskHold?("read", fileKey)
        #endif
        if let name = memoryName(cacheKey, fileKey: fileKey, waitingAtStart: waiting, startedAt: startedAt, source: source) {
            thumbCache.setObject(thumb, forKey: name, cost: cost(of: thumb))
        }
        return thumb
    }

    /// Where a picture a read path took from `source` may stand in memory;
    /// nil = nowhere, the caller still gets it. The one rule of both read
    /// paths: nothing read across an invalidation (the bytes may be the
    /// picture from before it); nothing when the wait ended during the read
    /// (a `set` landed, and these may be the kept bytes it replaced, which
    /// the network gate would then find under the plain name); while the
    /// address waits, only bytes of the persistent copy, under the waiting
    /// name (a cache file read then may be the one the invalidation's
    /// removal has not reached yet).
    private func memoryName(_ name: String, fileKey: String, waitingAtStart: Bool,
                            startedAt: Int, source: URL) -> NSString? {
        guard invalidations[fileKey, default: 0] == startedAt,
              refreshing.contains(fileKey) == waitingAtStart else { return nil }
        guard waitingAtStart else { return name as NSString }
        return Self.stands(source, in: persistentDirectory) ? Self.waitingName(name) : nil
    }

    /// The first of `candidates` that holds a picture, as a thumbnail, with
    /// the file that answered. Disk read and decode run off the MainActor;
    /// nothing is cached here.
    private func diskThumbnail(_ candidates: [URL], maxPixelSize: CGFloat) async -> (UIImage, URL)? {
        // Disk read + decode off the MainActor. This runs per visible cell.
        // detached because disk read and decode run per visible cell, off the MainActor
        await Task.detached(priority: .userInitiated) { () -> (UIImage, URL)? in
            // Regression guard: disk read + image decode stay off the main actor.
            #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(.main))
            #endif
            for file in candidates {
                if let data = try? Data(contentsOf: file) {
                    return Self.decodedThumbnail(data, maxPixelSize: maxPixelSize).map { ($0, file) }
                }
            }
            return nil
        }.value
    }

    /// Cache first, NETWORK second. And it reports the SOURCE size alongside
    /// the display image.
    ///
    /// Both read methods above deliberately never fetch: they are the read side
    /// of a cache that other surfaces fill. Radio artwork had no such filling
    /// surface. It resolved a logo URL and then asked a cache that could only
    /// ever answer for pictures something ELSE had downloaded. That is why a
    /// station logo appeared only after the station had been played once: the
    /// player's cover view is what fetched it.
    ///
    /// The source size travels with the image because the quality gate has to
    /// judge the picture that ARRIVED. Judging the 400-px thumbnail instead
    /// rejects exactly the wide wordmarks the 800-px render exists for. A
    /// 800×92 logo becomes 400×46 and falls under the 48-px floor.
    func loadedImage(for url: URL, maxPixelSize: CGFloat? = nil)
        async -> (image: UIImage, sourcePixels: CGSize)? {
        let target = maxPixelSize ?? thumbPixelSize
        if let found = await storedImage(for: url, maxPixelSize: target, allowKept: false) { return found }
        // A tile stays a moment before the network is asked (`TileDwell`);
        // a tile that left asks nothing.
        guard await TileDwell.stood(TileDwell.cover) else { return nil }
        let startedAt = invalidationCount(for: url)
        guard let (data, _) = try? await HTTP.data(from: url, lane: .cover),
              let full = UIImage(data: data) else {
            // A failed load still shows a kept picture of an invalidated address.
            return await storedImage(for: url, maxPixelSize: target, allowKept: true)
        }
        // Held and stored at display size like every fetched cover; the
        // quality gate still judges the size that arrived.
        let source = CGSize(width: full.size.width * full.scale, height: full.size.height * full.scale)
        // A tile that left before its turn stores nothing.
        let reduced: (UIImage, Data)?
        do { reduced = try await Self.displaySized(data, maxPixelSize: displayPixelSize) } catch { return nil }
        let (shown, kept) = reduced ?? (full, data)
        set(shown, data: kept, for: url, startedAt: startedAt)
        let display = Self.decodedThumbnail(data, maxPixelSize: target) ?? shown
        return (display, source)
    }

    /// The display image and the source size from disk, nil when either is
    /// missing.
    private func storedImage(for url: URL, maxPixelSize: CGFloat, allowKept: Bool)
        async -> (image: UIImage, sourcePixels: CGSize)? {
        guard let cached = await thumbnail(for: url, maxPixelSize: maxPixelSize, allowKept: allowKept),
              let full = await image(for: url, allowKept: allowKept) else { return nil }
        return (cached, CGSize(width: full.size.width * full.scale, height: full.size.height * full.scale))
    }

    /// What ImageIO makes of these bytes. The door's second try when
    /// UIKit's reader says no: ImageIO reads formats UIKit does not,
    /// `.ico` among them, which is what a station's own site serves as its
    /// icon. The same decoder the thumbnails use, at the ceiling of a full
    /// cover, so this is one mechanic with a parameter, not a second one.
    nonisolated static func decoded(_ data: Data) -> UIImage? {
        decodedThumbnail(data, maxPixelSize: thumbnailVariants.max() ?? defaultThumbnailPixel)
    }

    /// Pure decode-to-size without the re-encode `downsampled` does. Thumbs
    /// never touch the disk.
    private nonisolated static func decodedThumbnail(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let signpost = PerfSignpost.coverDecode()
        defer { signpost.end() }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Force the pixel decode NOW, off the main actor, into a
        // display-ready bitmap. `CGImageSourceCreateThumbnailAtIndex` returns a
        // lazily-decoded image; without this the render server decodes it on the
        // MAIN thread at first draw. The exact hitch when the Downloaded rows
        // (and any thumbnail cell) enter the viewport and rebuild. Runs here
        // inside the detached decode task, so it stays off the main thread.
        return UIImage(cgImage: cg).preparingForDisplay() ?? UIImage(cgImage: cg)
    }

    /// Full-size cached image. Memory-cache hits return immediately; the disk
    /// read + full decode run off-main (a ~2000 px decode on the main actor was
    /// a visible hitch right when pushing the detail screen / full player).
    func image(for url: URL, allowKept: Bool = true) async -> UIImage? {
        let cacheKey = key(for: url)
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        let waiting = refreshing.contains(cacheKey)
        if waiting, allowKept, let kept = memoryCache.object(forKey: Self.waitingName(cacheKey)) {
            return kept
        }
        let startedAt = invalidations[cacheKey, default: 0]
        guard let (image, source) = await diskImage(readCandidates(cacheKey, allowKept: allowKept)) else { return nil }
        if let name = memoryName(cacheKey, fileKey: cacheKey, waitingAtStart: waiting, startedAt: startedAt, source: source) {
            memoryCache.setObject(image, forKey: name, cost: cost(of: image))
        }
        return image
    }

    /// The first of `candidates` that holds a picture, full size, with the
    /// file that answered. Disk read and decode run off the MainActor;
    /// nothing is cached here.
    private func diskImage(_ candidates: [URL]) async -> (UIImage, URL)? {
        // detached because disk read and decode belong off the MainActor
        await Task.detached(priority: .userInitiated) { () -> (UIImage, URL)? in
            for fileURL in candidates {
                if let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
                    return (image, fileURL)
                }
            }
            return nil
        }.value
    }

    /// Stores a cover the load already reduced to display size
    /// (`displaySized`): into memory at once, and its bytes to disk in the
    /// background. The original is never held.
    /// `startedAt` is the address's invalidation count when the load began
    /// (`invalidationCount`). An answer to a request sent before an
    /// invalidation is the old picture: it is not stored at all, the address
    /// keeps waiting, and the next display asks again. The same holds for an
    /// invalidation that comes while the write runs: the write looks at the
    /// count once more before its first byte, and an invalidation after that
    /// look removes the cache file after the write (`onDisk`), as if it had
    /// come after a finished write.
    func set(_ image: UIImage, data: Data, for url: URL, startedAt: Int) {
        let cacheKey = key(for: url)
        guard invalidations[cacheKey, default: 0] == startedAt else {
            Logger.library.notice("COVERCACHE answer older than its invalidation, not stored")
            return
        }
        // Available at once, at display size: the load reduced it before it
        // came here (`displaySized`), so the original is never held. The
        // measuring point names the pixels that are held.
        memoryCache.setObject(image, forKey: cacheKey as NSString, cost: cost(of: image))
        PerfSignpost.coverOriginalCached(pixelWidth: Int(image.size.width * image.scale),
                                         pixelHeight: Int(image.size.height * image.scale))
        let target = diskDirectory.appendingPathComponent(cacheKey)
        let kept = persistentDirectory.appendingPathComponent(cacheKey)
        #if DEBUG
        let hold = testDiskHold
        #endif
        onDisk(cacheKey) {
            // Already at display size, the bytes to write with it.
            let stored = (image, data)
            let stillCurrent = await MainActor.run {
                ImageCache.shared.invalidations[cacheKey, default: 0] == startedAt
            }
            guard stillCurrent else {
                Logger.library.notice("COVERCACHE answer overtaken by an invalidation, not written")
                return
            }
            #if DEBUG
            await hold?("write", cacheKey)
            #endif
            do {
                try stored.1.write(to: target, options: .atomic)
            } catch {
                // A cover that cannot be written is fetched again on
                // every appearance; a swallowed error here hides exactly
                // that. Path stays out of the log, the name is the key.
                Logger.library.error("COVERCACHE write failed: \(FailureReason.of(error), privacy: .public)")
            }
            // A persistent copy (a downloaded item's cover) is replaced by
            // the fresh cache file in one step, never deleted first: until
            // the replacement lands the old picture stays available offline.
            var keptReplaced = true
            if FileManager.default.fileExists(atPath: kept.path) {
                let fresh = kept.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
                do {
                    try FileManager.default.copyItem(at: target, to: fresh)
                    _ = try FileManager.default.replaceItemAt(kept, withItemAt: fresh)
                } catch {
                    if FileManager.default.fileExists(atPath: fresh.path) {
                        do { try FileManager.default.removeItem(at: fresh) } catch {
                            Logger.library.error("COVERCACHE replace leftover not removed: \(FailureReason.of(error), privacy: .public)")
                        }
                    }
                    keptReplaced = false
                    Logger.library.error("COVERCACHE persistent replace failed: \(FailureReason.of(error), privacy: .public)")
                }
            }
            await MainActor.run {
                let cache = ImageCache.shared
                // An invalidation that came while this write ran keeps the
                // address waiting and its memory empty; its removal of the
                // cache file runs after this work.
                guard cache.invalidations[cacheKey, default: 0] == startedAt else { return }
                cache.memoryCache.setObject(stored.0, forKey: cacheKey as NSString, cost: cache.cost(of: stored.0))
                if keptReplaced {
                    cache.refreshing.remove(cacheKey)
                    cache.dropWaiting(cacheKey)
                }
            }
            #if DEBUG
            await hold?("written", cacheKey)
            #endif
        }
    }

    /// Drop every cached representation (memory, thumbnails, cache file) of a
    /// cover URL, and let a persistent copy wait for the network. Used when
    /// the server may have replaced the artwork behind an UNCHANGED id (e.g.
    /// a Navidrome re-tag). The URL then still matches the old bytes, so a
    /// manual invalidation on refresh is the only way to pull the new cover.
    /// The persistent copy of a downloaded item is not deleted: it becomes
    /// the last candidate of every read path until `set` replaced it with the
    /// server's picture, so a gate that goes to the network asks first, and
    /// every other reader and a failed load still find it.
    func invalidate(url: URL) {
        let cacheKey = key(for: url)
        refreshing.insert(cacheKey)
        invalidations[cacheKey, default: 0] += 1
        memoryCache.removeObject(forKey: cacheKey as NSString)
        // This used to be `removeAllObjects()`. ONE url emptied EVERY
        // preview in the app. Its only caller runs in a loop over hundreds of
        // entries on pull-to-refresh, so one pull cleared the previews of
        // every tab, several hundred times over. The size variants are known
        // (they are OUR parameter, not the server's), so they are removed by
        // name: the invalidation now costs what it claims to cost.
        for size in Self.thumbnailVariants {
            thumbCache.removeObject(forKey: "\(cacheKey)@\(Int(size))" as NSString)
        }
        // The waiting entries may hold a copy an overtaken write replaced
        // on disk since; the next read takes the copy that stands there now.
        dropWaiting(cacheKey)
        let target = diskDirectory.appendingPathComponent(cacheKey)
        // Behind a write that is still running, so it removes what that
        // write left instead of running before it.
        onDisk(cacheKey) {
            // No file is the common case and no failure; a file that stays
            // would answer the network gate with the picture from before.
            guard FileManager.default.fileExists(atPath: target.path) else { return }
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                Logger.library.error("COVERCACHE invalidated file not removed: \(FailureReason.of(error), privacy: .public)")
            }
        }
    }

    /// Lift a downloaded book's cover into the persistent folder (move it out of
    /// the cache or fetch it fresh).
    /// Keeps the cover of a downloaded item outside the purgeable cache,
    /// under the SAME name the read paths use. A cached copy is moved,
    /// otherwise the bytes are fetched once.
    func makePersistent(coverURL: URL?) async {
        guard let coverURL else { return }
        let cacheKey = key(for: coverURL)
        let target = persistentDirectory.appendingPathComponent(cacheKey)
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        let cached = diskDirectory.appendingPathComponent(cacheKey)
        // A waiting address's cache file may be the picture from before its
        // invalidation, with the removal still queued; it never goes up, the
        // bytes come fresh from the network instead.
        if !refreshing.contains(cacheKey), FileManager.default.fileExists(atPath: cached.path) {
            do {
                try FileManager.default.moveItem(at: cached, to: target)
                return
            } catch {
                Logger.library.error("COVERCACHE persist move failed: \(FailureReason.of(error), privacy: .public)")
            }
        }
        guard let (data, _) = try? await HTTP.data(from: coverURL, lane: .cover) else { return }
        await makePersistent(coverURL: coverURL, data: data)
    }

    /// The write half, with the bytes in hand. Separate so a test can
    /// hand in a picture without a network.
    func makePersistent(coverURL: URL, data: Data) async {
        let target = persistentDirectory.appendingPathComponent(key(for: coverURL))
        let maxSize = maxPixelSize
        // Downsampling + write in the background, await completion (the caller
        // relies on the cover being persistent afterwards).
        // detached because downsample and write are CPU and disk work off the MainActor and must finish once started
        await Task.detached(priority: .utility) {
            guard let stored = Self.downsampled(data, maxPixelSize: maxSize) else { return }
            do {
                try stored.1.write(to: target, options: .atomic)
            } catch {
                // Silence here would mean an offline book without its
                // cover and nobody knowing why.
                Logger.library.error("COVERCACHE persist write failed: \(FailureReason.of(error), privacy: .public)")
            }
        }.value
    }

    /// On deleting a download: move the persistent cover back into the purgeable
    /// cache (stays visible, but is now reclaimable).
    /// The persistent copy goes back into the cache when the download
    /// goes; the picture stays available until the cache lets it go. The
    /// copy of an address that waits for the network stays where it is: in
    /// the cache its network gate would answer with the picture from before
    /// the invalidation; the load that answers replaces it, and a later
    /// sweep moves it down.
    func removePersistent(coverURL: URL?) {
        guard let coverURL else { return }
        let cacheKey = key(for: coverURL)
        let source = persistentDirectory.appendingPathComponent(cacheKey)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        if refreshing.contains(cacheKey) {
            Logger.library.notice("COVERCACHE unpersist held: the address waits for the network")
            return
        }
        let target = diskDirectory.appendingPathComponent(cacheKey)
        do {
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.moveItem(at: source, to: target)
            } else {
                try FileManager.default.removeItem(at: source)
            }
        } catch {
            Logger.library.error("COVERCACHE unpersist failed: \(FailureReason.of(error), privacy: .public)")
        }
    }

    /// A download moved to a new id and its cover address with it: the
    /// persistent copy takes the new name, without the network, so the next
    /// sweep finds it under the active name instead of demoting it. A copy
    /// already standing under the new name wins; the old one goes. A cover an
    /// earlier sweep already demoted stands in the cache; it is found there
    /// too and goes up under the new name, or it would fall after the TTL.
    /// When the old address waits for the network, so does the new one: its
    /// kept copy is the picture from before the invalidation, and under a
    /// name that does not wait the network gate would answer with it.
    ///
    /// The files are asked and moved in the disk chain of both addresses,
    /// after every disk work either already has (a removal an invalidation
    /// queued lands first), never on the main actor: a server move renames
    /// every moved download in one go. Waiting is asked at the move, as the
    /// sweep asks it; an invalidation after that look ends as if it came
    /// after the move.
    func renamePersistent(from old: URL?, to new: URL?) {
        guard let old, let new else { return }
        let oldKey = key(for: old)
        let newKey = key(for: new)
        let kept = persistentDirectory.appendingPathComponent(oldKey)
        let demoted = diskDirectory.appendingPathComponent(oldKey)
        let target = persistentDirectory.appendingPathComponent(newKey)
        let newCached = diskDirectory.appendingPathComponent(newKey)
        onDisk([oldKey, newKey]) { [self] in
            let fm = FileManager.default
            let (oldWaits, newWaits) = await MainActor.run {
                (self.refreshing.contains(oldKey), self.refreshing.contains(newKey))
            }
            // The demoted cache file of a waiting address may be the picture
            // from before its invalidation; it does not go up (`makePersistent`).
            let source = fm.fileExists(atPath: kept.path) ? kept : demoted
            guard source != target, fm.fileExists(atPath: source.path),
                  source == kept || !oldWaits else { return }
            // Fresh bytes of the new address in the cache make the carried
            // copy from before the old address's invalidation the one too
            // many: it goes, and the new address does not wait (`invalidate`
            // would remove exactly those bytes). The fresh file goes up under
            // the new name in the same step, so the moved download keeps a
            // persistent copy; the new address does not wait, so its gate
            // reads that tier too. Were the new address waiting itself, its
            // cache file stays down.
            do {
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: source)
                } else if oldWaits && fm.fileExists(atPath: newCached.path) {
                    try fm.removeItem(at: source)
                    if !newWaits {
                        try fm.moveItem(at: newCached, to: target)
                    }
                } else {
                    try fm.moveItem(at: source, to: target)
                    if oldWaits {
                        // Its removal queues behind this work, in the chain of the new address.
                        await MainActor.run { self.invalidate(url: new) }
                        Logger.library.notice("COVERCACHE rename: the new address waits for the network like the old one")
                    }
                }
            } catch {
                Logger.library.error("COVERCACHE rename failed: \(FailureReason.of(error), privacy: .public)")
            }
        }
    }

    /// What one sweep does between the two tiers, by file name. An active
    /// cover (one of a download) that stands only in the cache goes up, so a
    /// cover that was demoted once is protected again; a persistent cover
    /// without a download goes down, or is dropped when the cache already
    /// holds the same name. Down only when the active set is complete
    /// (`knowsAll`): a sweep that could not name every download's cover
    /// cannot tell an orphan from a cover it must keep, so it only lifts.
    nonisolated enum TierMove: Equatable, Sendable {
        case promote(String)
        case demote(String)
        case drop(String)
    }

    /// Step 0 of a sweep, run by the sweep and by its seam alike. A name an
    /// older build wrote with a sign-in part in it takes the name without, in
    /// both tiers and before anything compares names, so a kept cover stays
    /// kept (a name already stored as a digest cannot be read; that cover
    /// loads once more). A kept cover of a foreign address stands under the
    /// name the earlier rule gave it; it takes today's name without the
    /// network, so no offline cover of a downloaded episode is demoted. No
    /// rename puts a file into the purgeable tier under the name of an
    /// address that waits (`gateOfWaitingReads`, the names as the step
    /// begins); an invalidation during the renames is met after them: of the
    /// names the renames put into the purgeable tier, each one that waits by
    /// then goes (`clearWaitingFromCache`), so the rule holds when the sweep
    /// is done. `waitingAtStart` stands in for the names at the start (a
    /// witness of an invalidation during the step); nil asks the cache.
    nonisolated func renameStep(persistent: URL, cache: URL, moves: [String: String],
                                waitingAtStart: Set<String>? = nil) async {
        let names: (URL) -> Set<String> = Self.fileNames
        let waiting: Set<String>
        if let waitingAtStart { waiting = waitingAtStart } else { waiting = await MainActor.run { self.refreshing } }
        let holds: (URL) -> Bool = { Self.gateOfWaitingReads($0, cache: cache, waiting: waiting) }
        let placed = Self.dropSignInFromNames(in: [persistent, cache], listing: names, holds: holds)
            + Self.moveLegacyNames(in: [persistent, cache], listing: names, moves: moves, holds: holds)
        let intoCache = placed.filter { Self.stands($0, in: cache) }.map(\.lastPathComponent)
        guard !intoCache.isEmpty else { return }
        await MainActor.run { self.clearWaitingFromCache(names: intoCache) }
    }

    /// Of the names a rename of step 0 put into the purgeable tier, each one
    /// whose address waits now goes, behind the disk work of that address
    /// and only if it still waits then: a load that landed meanwhile ended
    /// the wait, and its fresh bytes stay. On the main actor only the set of
    /// waiting names is asked; the file is asked in the disk chain.
    private func clearWaitingFromCache(names: [String]) {
        for name in names where refreshing.contains(name) {
            let target = diskDirectory.appendingPathComponent(name)
            onDisk(name) { [self] in
                guard await MainActor.run(body: { self.refreshing.contains(name) }),
                      FileManager.default.fileExists(atPath: target.path) else { return }
                do {
                    try FileManager.default.removeItem(at: target)
                    Logger.library.notice("COVERCACHE waiting name cleared from the cache after the renames")
                } catch {
                    Logger.library.error("COVERCACHE waiting name not cleared: \(FailureReason.of(error), privacy: .public)")
                }
            }
        }
    }

    /// Runs the moves between the tiers. Neither way moves the name of an
    /// address that waits for the network (`isWaiting`, asked per name at
    /// the move): its cache file may be the picture from before its
    /// invalidation with the removal still queued, so it stays down, and its
    /// persistent copy stays up, because in the cache its network gate would
    /// answer with it instead of asking the server. An invalidation after
    /// the look ends as if it came after the move. Logged when anything
    /// moved, waited or failed.
    /// What one pass between the folders did, in all four directions plus
    /// the waits. The line speaks as soon as any of them is not zero.
    /// A failure is counted and the first reason kept: a full disk fails
    /// every move for the same reason, and one line with the count says it
    /// without a line per file.
    nonisolated struct TierTally: Equatable, Sendable {
        var promoted = 0
        var demoted = 0
        var dropped = 0
        var failed = 0
        var waiting = 0
        var firstFailure: String?

        mutating func fail(_ reason: String) {
            failed += 1
            if firstFailure == nil { firstFailure = reason }
        }

        var line: String? {
            guard promoted + demoted + dropped + failed + waiting > 0 else { return nil }
            return "COVERCACHE tiers promoted=\(promoted) demoted=\(demoted) dropped=\(dropped) failed=\(failed) waiting=\(waiting)"
                + (firstFailure.map { " first=\($0)" } ?? "")
        }
    }

    /// The one line of a renaming pass, the first reason beside the count of
    /// failures; nil when nothing was renamed, held or failed.
    nonisolated static func renameLine(_ what: String, renamed: Int, failed: Int, held: Int, firstFailure: String?) -> String? {
        guard renamed > 0 || failed > 0 || held > 0 else { return nil }
        return "COVERCACHE \(what)=\(renamed) failed=\(failed) waiting=\(held)" + (firstFailure.map { " first=\($0)" } ?? "")
    }

    @discardableResult
    nonisolated static func applyTierMoves(_ moves: [TierMove], persistent: URL, cache: URL,
                                           isWaiting: (String) async -> Bool) async -> TierTally {
        let fm = FileManager.default
        var tally = TierTally()
        for move in moves {
            do {
                switch move {
                case .promote(let name):
                    guard await !isWaiting(name) else {
                        tally.waiting += 1
                        continue
                    }
                    try fm.moveItem(at: cache.appendingPathComponent(name), to: persistent.appendingPathComponent(name))
                    tally.promoted += 1
                case .demote(let name):
                    guard await !isWaiting(name) else {
                        tally.waiting += 1
                        continue
                    }
                    try fm.moveItem(at: persistent.appendingPathComponent(name), to: cache.appendingPathComponent(name))
                    tally.demoted += 1
                case .drop(let name):
                    // The kept copy of a waiting address stays until the
                    // load that answers replaces it (`removePersistent`).
                    guard await !isWaiting(name) else {
                        tally.waiting += 1
                        continue
                    }
                    try fm.removeItem(at: persistent.appendingPathComponent(name))
                    tally.dropped += 1
                }
            } catch {
                tally.fail(FailureReason.of(error))
            }
        }
        if let line = tally.line {
            if tally.failed > 0 {
                Logger.library.error("\(line, privacy: .public)")
            } else {
                Logger.library.notice("\(line, privacy: .public)")
            }
        }
        return tally
    }

    nonisolated static func tierMoves(persistent: Set<String>, cache: Set<String>,
                                      active: Set<String>, knowsAll: Bool) -> [TierMove] {
        let up = active.intersection(cache).subtracting(persistent).sorted().map(TierMove.promote)
        guard knowsAll else { return up }
        let down = persistent.subtracting(active).sorted().map { name in
            cache.contains(name) ? TierMove.drop(name) : TierMove.demote(name)
        }
        return up + down
    }

    /// Cache files older than this are deleted. So a server-side CHANGED cover
    /// is re-fetched after this time at the latest (the cache key is
    /// deliberately path-stable and otherwise never invalidates).
    private let cacheTTL: TimeInterval = 30 * 24 * 3600
    /// Upper bound for the purgeable cover cache.
    /// The fixed 200 MB cap became adaptive. Reasoning behind the
    /// numbers, and why the risk is asymmetric: the cache lives in Caches,
    /// is excluded from backup and gets purged by iOS under pressure. Too
    /// large costs practically nothing, too small costs permanently (evict →
    /// re-download → the reload stutter over uncached areas). At ~300–600 KB
    /// per cover, 200 MB held only 400–600 covers: plenty for audiobooks,
    /// too tight for a four-digit music library.
    ///
    /// Pure so it is testable without a device: the smaller of an upper
    /// bound and a small share of the FREE space, never below the floor (a
    /// full device must not shrink the cache to nothing).
    nonisolated static func cacheCapBytes(freeBytes: Int64) -> Int64 {
        let upper: Int64 = 500 * 1024 * 1024
        let floor: Int64 = 150 * 1024 * 1024
        let share = Int64(Double(max(freeBytes, 0)) * 0.05)
        return max(floor, min(upper, share))
    }

    nonisolated static func freeDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Enforcement no longer waits for the next app start when the
    /// cache has run far past the cap. This is the factor that triggers an
    /// extra pass at the next calm moment.
    nonisolated static let enforcementOvershoot = 1.5

    /// Maintenance pass, once per app start:
    /// 1) Persistent covers without an associated download back into the cache.
    /// 2) Delete cache files over TTL (cover refresh).
    /// 3) Cap the cache at `cacheCapBytes(freeBytes:)`, oldest first.
    /// `activeCoverURLs`: the covers of everything still downloaded. Any
    /// other file in the persistent store is an orphan and goes back to
    /// the cache. Membership is decided by the file NAME the covers would
    /// carry, so a digest key and a plain key are treated alike.
    /// `onlyWhenOverCap`: the extra pass that used to be gated by a
    /// separate check on the caller's side. It asked `cacheSizeBytes()`,
    /// which enumerates the whole cache directory and reads a size per
    /// file, ON THE MAIN ACTOR, at every return to the app. Measured: 3 ms
    /// at a thousand covers, 6.6 ms at two thousand (the size the device
    /// log showed), 13.8 ms at four thousand, against a frame of 16.7 ms.
    /// **The guard cost more than what it guarded, and it was paid on the
    /// more expensive thread**, to answer a question whose answer is almost
    /// always no (the device log shows `evicted=0` over and over).
    ///
    /// So the question moved in here, where a sweep runs off the main actor
    /// anyway, and the directory is now enumerated ONCE instead of twice.
    /// `knowsAll`: whether `activeCoverURLs` names every download's cover;
    /// without it nothing is demoted (`tierMoves`) and no cover moves from
    /// an old name (`legacyMoves`), which then stays in the kept folder.
    /// Returns the pass, so a caller can wait for it.
    @discardableResult
    func performMaintenance(activeCoverURLs: [URL], knowsAll: Bool,
                            onlyWhenOverCap: Bool = false) -> Task<Void, Never> {
        // Pure file-system work. Entirely in the background, not on the
        // MainActor (may touch hundreds of files with large libraries).
        let persistent = persistentDirectory
        let cache = diskDirectory
        let ttl = cacheTTL
        let free = Self.freeDiskBytes()
        let maxBytes = Int(Self.cacheCapBytes(freeBytes: free))
        let activeNames = Set(activeCoverURLs.map { key(for: $0) })
        let moves = Self.legacyMoves(for: activeCoverURLs, knowsAll: knowsAll) { key(for: $0) }
        let started = Date()
        // detached because the sweep is disk work off the MainActor and must not die with the caller
        return Task.detached(priority: .utility) {
            if onlyWhenOverCap,
               Self.directoryBytes(cache) <= Int64(Double(maxBytes) * Self.enforcementOvershoot) {
                return
            }
            let fm = FileManager.default
            let names: (URL) -> Set<String> = Self.fileNames

            // 0) The renames within a tier (`renameStep`).
            await self.renameStep(persistent: persistent, cache: cache, moves: moves)

            // 1) Between the tiers (`tierMoves`): an active cover found only
            //    in the cache goes up, a persistent one without a download
            //    goes down.
            let moved = Self.tierMoves(persistent: names(persistent), cache: names(cache), active: activeNames,
                                       knowsAll: knowsAll)
            await Self.applyTierMoves(moved, persistent: persistent, cache: cache) { name in
                await MainActor.run { self.refreshing.contains(name) }
            }

            // 2) TTL + 3) size cap.
            guard let files = try? fm.contentsOfDirectory(
                at: cache,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { return }
            var kept: [(url: URL, date: Date, size: Int)] = []
            var sweptPlaceholders = 0
            for file in files {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let date = values?.contentModificationDate ?? .distantPast
                // Service placeholders CACHED before the fetch gate
                // existed: a pillar logo or waveform strip that was
                // stored as a cover keeps serving from here until the
                // TTL. Judged with the same probe as the gate, scoped
                // by file name to the item image service, so no
                // foreign cover pays a read.
                if file.lastPathComponent.contains("_services_img_"),
                   let data = try? Data(contentsOf: file),
                   ArchiveServicePlaceholder.isPlaceholderBody(data) {
                    try? fm.removeItem(at: file)
                    sweptPlaceholders += 1
                    continue
                }
                if Date().timeIntervalSince(date) > ttl {
                    try? fm.removeItem(at: file)
                } else {
                    kept.append((file, date, values?.fileSize ?? 0))
                }
            }
            if sweptPlaceholders > 0 {
                Logger.library.notice("COVERCACHE swept \(sweptPlaceholders) service placeholder(s)")
            }
            var total = kept.reduce(0) { $0 + $1.size }
            let startTotal = total
            var evicted = 0
            if total > maxBytes {
                for entry in kept.sorted(by: { $0.date < $1.date }) {
                    try? fm.removeItem(at: entry.url)
                    total -= entry.size
                    evicted += 1
                    if total <= maxBytes { break }
                }
            }
            // Measurable instead of guessed. How many covers, their bytes,
            // the cap, free space, how many went and how long the sweep
            // took: the numbers a directory-as-rows decision needs.
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Logger.library.notice("COVERCACHE sweep covers=\(kept.count) size=\(startTotal / 1_048_576)MB cap=\(maxBytes / 1_048_576)MB free=\(free / 1_048_576)MB evicted=\(evicted) ms=\(ms)")
        }
    }

    /// Bytes in a directory. A full enumeration with a size read per file,
    /// so it belongs off the main actor; `nonisolated` so the sweep's own
    /// task can call it without hopping back.
    nonisolated static func directoryBytes(_ dir: URL) -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return files.reduce(0) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    /// Size of the purgeable cover cache in bytes. The SETTINGS ask this,
    /// and there it is the answer being shown, so paying for it is the
    /// point. Nothing on a render path may ask it.
    func cacheSizeBytes() -> Int64 { Self.directoryBytes(diskDirectory) }

    /// Clears the purgeable cover cache (persistent download covers stay).
    func clearCache() {
        memoryCache.removeAllObjects()
        thumbCache.removeAllObjects()
        guard let files = try? FileManager.default.contentsOfDirectory(at: diskDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Whether a cover exists in the memory cache or on disk (no decode).
    private func isCached(_ url: URL) -> Bool {
        let cacheKey = key(for: url)
        if memoryCache.object(forKey: cacheKey as NSString) != nil { return true }
        return [persistentDirectory, diskDirectory].contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(cacheKey).path)
        }
    }

    /// Prefetches a cover in the background if it is not cached yet. Uses the
    /// timeouted Maer session (no forever-hanging request) and deduplicates
    /// parallel requests for the same cover.
    func preload(_ url: URL) async {
        // Existence check only. No need to decode the image just to know the
        // cover is already cached.
        guard !isCached(url), !inFlight.contains(url) else { return }
        inFlight.insert(url)
        defer { inFlight.remove(url) }
        let startedAt = invalidationCount(for: url)
        guard let (data, _) = try? await HTTP.data(from: url, lane: .cover),
              let image = UIImage(data: data) else { return }
        // Held at display size like every fetched cover, never the original.
        let reduced: (UIImage, Data)?
        do { reduced = try await Self.displaySized(data, maxPixelSize: maxPixelSize) } catch { return }
        let (shown, kept) = reduced ?? (image, data)
        set(shown, data: kept, for: url, startedAt: startedAt)
    }

    /// Under memory pressure the full covers go; the thumbnails stay, so the
    /// cells on screen stay warm. A full cover is read from disk again on its
    /// next display. Counted for the witness.
    func releaseFullCovers() {
        memoryCache.removeAllObjects()
        fullCoverReleases += 1
        Logger.library.notice("COVERCACHE memory pressure: full covers released")
    }

    /// Whether a full cover for `url` stands in memory now.
    func holdsFullCover(for url: URL) -> Bool {
        memoryCache.object(forKey: key(for: url) as NSString) != nil
    }
}
