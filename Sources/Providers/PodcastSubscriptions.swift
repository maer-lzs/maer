// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import OSLog



/// Management of podcast subscriptions: add/remove feeds, refresh (RSS/Atom via
/// XMLParser, no third-party dependency), persistent cache. Pure source backend
/// behind the `RSSProvider`. The core talks only to the provider, never
/// directly here (only the management UI does).
/// A just-subscribed premium feed looks like an existing free
/// subscription. Offer to replace it (with progress takeover). Presented as a
/// QUESTION, never applied silently.
nonisolated struct PremiumReplacementOffer: Equatable {
    let freeShowId: String
    let premiumShowId: String
    let showTitle: String
}

@MainActor
final class PodcastSubscriptions: ObservableObject {
    static let shared = PodcastSubscriptions(
        fileURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("podcast_subscriptions.json"),
        database: .shared, defaults: .standard, isTheApp: true)

    /// Every way into the stock passes here: the shownotes leave it for the
    /// database (`PodcastNotes`) before the one assignment, so a change
    /// publishes once, rebuilds the caches once and bumps once. The index
    /// still answers for the stock before, so an unchanged text is not
    /// written again.
    private(set) var shows: [PodcastShow] {
        get { stock }
        set {
            let before = stock
            guard let split = PodcastNotes.split(newValue, stampBefore: { guid in
                episodeIndex[guid].flatMap { before.indices.contains($0.show) && before[$0.show].episodes.indices.contains($0.episode)
                    ? before[$0.show].episodes[$0.episode].notesStamp : nil }
            }) else {
                stock = newValue
                return
            }
            pendingNotes.merge(split.notes) { _, fresh in fresh }
            stock = split.shows
        }
    }

    /// Written only by the setter of `shows`.
    @Published private var stock: [PodcastShow] = [] {
        didSet {
            rebuildCaches()
            // A subscription that arrives (import, account adoption, the
            // person's own subscribe) changes what the episode rows show.
            ListeningRevision.shared.bump("subscriptions")
            // The device's search follows the shows on offer; the first
            // load from disk asks the first pass.
            if isTheApp, #available(iOS 27, *) { SpotlightIndex.showsChanged() }
        }
    }

    /// Set when a new premium subscription matches an existing free one;
    /// the sources UI presents it as an alert. Cleared on accept/decline.
    @Published var pendingPremiumReplacement: PremiumReplacementOffer?
    /// The title of a feed that was just subscribed and brought no episode.
    /// Set by `subscribe`, consumed by the ONE host that shows it. Here and
    /// not in the three subscribe surfaces, because the store is the only
    /// place that knows what the parse yielded, and because there ARE three
    /// surfaces (settings page, cards, catalog page) and the message must
    /// exist once. Same shape as `pendingPremiumReplacement` above.
    @Published var emptyFeedNotice: String?

    /// A subscription the person asked for on a surface without its own
    /// line was set out because Audiobookshelf could not be read
    /// (`LocalSubscription.setOut`); the same host says it.
    @Published var serverUnreadNotice = false

    /// A subscribe tap on such a surface that subscribed nothing (the server
    /// refused, the feed did not load): the sentence the same host says.
    @Published var tapFailureNotice: String?

    /// Feeds from the account this device could not follow yet (feed key
    /// ⇒ address and reason). The Podcasts tab shows them with the reason;
    /// the adoption skips them until the person retries, signs in or
    /// removes them.
    @Published private(set) var feedsNotFollowed: [String: FeedAdoptionPending.Entry] = [:]

    /// Test seam: replaces the network fetch of the adoption path.
    var _testFeedFetcher: ((URL) async -> FeedFetchOutcome)?

    /// Subscribed feeds whose access is lastingly refused (`FeedRefusal`):
    /// the show says so and offers a new link or a sign-in; the tile
    /// carries the mark. Feed keys; read from this device's record.
    @Published private(set) var refusedFeedKeys: Set<String> = []

    /// A set lookup, cheap enough for a cell.
    func isAccessRefused(_ show: PodcastShow) -> Bool {
        isAccessRefused(feedURL: show.feedURL)
    }

    /// The same by the feed's address.
    func isAccessRefused(feedURL: String) -> Bool {
        !refusedFeedKeys.isEmpty && refusedFeedKeys.contains(PodcastIdentity.feedKey(feedURL))
    }

    /// THE question which lock a feed's artwork carries; every surface that
    /// shows the lock asks here (show tiles, Continue card, Latest
    /// Episodes). The premium classification is a keychain and defaults
    /// lookup, so a grid asks once per render, not per cell.
    func lock(feedURL: String) -> FeedLock {
        FeedLock.of(isPremium: Self.isPremiumFeed(feedURL, defaults: defaults), isRefused: isAccessRefused(feedURL: feedURL))
    }

    /// Refusals in a row for the show's notice. A page read, not a cell's.
    func refusalCount(_ show: PodcastShow) -> Int {
        FeedRefusal.all(defaults: defaults)[PodcastIdentity.feedKey(show.feedURL)]?.count ?? 0
    }

    /// The clock of the refusal record. A test sets it to cross the day.
    var clock: () -> Double = { Date().timeIntervalSince1970 }

    // MARK: The free twin of a refused paid show

    /// The app's choice sync; nil for a store a test builds.
    private var choiceSync: UserChoiceCloudSync?
    /// Test seam: the directory the free twin is searched in.
    var _testDirectory: (any PodcastDirectory)?
    /// Bumped when an offer appears or is answered, so the page reads again.
    @Published private(set) var freeTwinRevision = 0
    /// Directory searches in flight, so one refusal never asks twice at once.
    private var freeTwinSearching: Set<String> = []

    /// What the show offers instead of its refused paid feed: the remembered
    /// free address first, else the one search's hit. None for a free show,
    /// an accepted feed or an offer the person declined here.
    func freeTwinOffer(_ show: PodcastShow) -> FreeTwin.Offer? {
        guard isAccessRefused(show), Self.isPremiumFeed(show.feedURL, defaults: defaults) else { return nil }
        let searched = defaults.dictionary(forKey: AppStorageKeys.podcastFreeTwinSearched) as? [String: [String]]
        let declined = defaults.stringArray(forKey: AppStorageKeys.podcastFreeTwinDeclined) ?? []
        return FreeTwin.offer(remembered: defaults.string(forKey: AppStorageKeys.podcastFreeTwin(show.id)),
                              searched: searched?[show.id], declined: declined.contains(show.id))
    }

    /// The person's No: the question goes, the notice stays.
    func declineFreeTwin(_ show: PodcastShow) {
        var declined = defaults.stringArray(forKey: AppStorageKeys.podcastFreeTwinDeclined) ?? []
        guard !declined.contains(show.id) else { return }
        declined.append(show.id)
        defaults.set(declined, forKey: AppStorageKeys.podcastFreeTwinDeclined)
        freeTwinRevision += 1
    }

    /// The free address, where the app sees it: it would be lost otherwise.
    /// Only the address, stripped of any user or password in it.
    private func rememberFreeTwin(_ freeURL: String, forPremium premiumId: String) {
        let key = AppStorageKeys.podcastFreeTwin(premiumId)
        let address = FreeTwin.address(freeURL)
        guard !address.isEmpty, defaults.string(forKey: key) != address else { return }
        defaults.set(address, forKey: key)
        choiceSync?.noteScalar(key: key, value: address)
    }

    /// The ONE directory search for a refused paid show that has no
    /// remembered free twin: the title goes out, nothing else. The answer is
    /// kept, "nothing found" too; a failed search keeps nothing and may ask
    /// once more at the next refresh. No directory chosen, no request.
    private func lookForFreeTwin(_ show: PodcastShow) async {
        guard isAccessRefused(show), Self.isPremiumFeed(show.feedURL, defaults: defaults),
              defaults.string(forKey: AppStorageKeys.podcastFreeTwin(show.id)) == nil,
              !freeTwinSearching.contains(show.id) else { return }
        var searched = defaults.dictionary(forKey: AppStorageKeys.podcastFreeTwinSearched) as? [String: [String]] ?? [:]
        guard searched[show.id] == nil else { return }
        guard let directory = _testDirectory ?? (isTheApp ? PodcastDirectorySelection.directory() : nil) else {
            Logger.rss.notice("PODCAST free twin show=\(show.id, privacy: .private(mask: .hash)) not searched: no directory")
            return
        }
        freeTwinSearching.insert(show.id)
        defer { freeTwinSearching.remove(show.id) }
        do {
            let hits = try await directory.search(show.title)
            let index = FreeTwin.pick(hits: hits.map { ($0.title, $0.feedURL) }, showTitle: show.title,
                                      isPremium: { Self.isPremiumFeed($0, defaults: defaults) })
            searched = defaults.dictionary(forKey: AppStorageKeys.podcastFreeTwinSearched) as? [String: [String]] ?? [:]
            searched[show.id] = index.map { [hits[$0].feedURL, hits[$0].title] } ?? []
            defaults.set(searched, forKey: AppStorageKeys.podcastFreeTwinSearched)
            freeTwinRevision += 1
            Logger.rss.notice("PODCAST free twin show=\(show.id, privacy: .private(mask: .hash)) searched hits=\(hits.count) found=\(index != nil)")
        } catch {
            Logger.rss.notice("PODCAST free twin show=\(show.id, privacy: .private(mask: .hash)) search failed reason=\(FailureReason.of(error), privacy: .public)")
        }
    }

    /// The person's Yes: the free feed is followed past the twin skip, what
    /// was heard and downloaded goes over, the paid feed leaves the account,
    /// and its address stays on this device for a way back.
    func switchToFreeTwin(showId: String, notesCloud: Bool = true) async -> Bool {
        await ensureLoaded()
        guard let paid = shows.first(where: { $0.id == showId }), let offer = freeTwinOffer(paid) else { return false }
        let before = Set(shows.map(\.id))
        let outcome = await follow(urlString: offer.feedURL, notesCloud: notesCloud, isSingleUserAct: true,
                                   allowingFreeTwinOf: paid.id)
        // A new show, or the free show that was already subscribed: then
        // the follow refreshed it and the move goes onto that one.
        let offered = PodcastIdentity.normalizeFeedURL(offer.feedURL)
        guard case .followed = outcome,
              let free = shows.first(where: { !before.contains($0.id) })
                ?? shows.first(where: { $0.id != paid.id && PodcastIdentity.normalizeFeedURL($0.feedURL) == offered }) else {
            Logger.rss.notice("SUBSCRIBE free twin for refused show: \(showId, privacy: .private(mask: .hash)) ok=false")
            return false
        }
        let carried = carryOver(from: paid, to: free)
        var paidTwins = defaults.dictionary(forKey: AppStorageKeys.podcastPaidTwin) as? [String: String] ?? [:]
        paidTwins[free.id] = paid.feedURL
        defaults.set(paidTwins, forKey: AppStorageKeys.podcastPaidTwin)
        unsubscribe(id: paid.id, notesCloud: notesCloud)
        reloadProgress()
        Logger.rss.notice("SUBSCRIBE free twin for refused show: \(showId, privacy: .private(mask: .hash)) ok=true matched=\(carried.matched) moved=\(carried.moved) adopted=\(carried.adopted)")
        return true
    }

    /// guid → (show index, episode index) for O(1) lookup instead of a linear
    /// search over all episodes (which ran per cover cell and dragged after import).
    private var episodeIndex: [String: (show: Int, episode: Int)] = [:]
    /// Cached, sorted full list (invalidated on a `shows` change).
    private var cachedAllEpisodes: [(show: PodcastShow, episode: PodcastEpisode)]?
    /// Shownotes taken from the stock and not yet in the database, keyed by
    /// guid. The next write carries them and lets go of what landed; a
    /// write that fails or is refused keeps them for the one after.
    private var pendingNotes: [String: String] = [:]

    /// The shownotes of a subscribed episode, read when it is opened: still
    /// waiting for their write, else from the rows. nil when there are none.
    func notes(guid: String) async -> String? {
        if let waiting = pendingNotes[guid] { return waiting }
        guard let rows = await openRows() else { return nil }
        do {
            return try await rows.notes(guid: guid)
        } catch {
            Logger.rss.error("SUBROWS notes read failed reason=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func rebuildCaches() {
        cachedAllEpisodes = nil
        episodeIndex = Self.buildEpisodeIndex(shows)
        // Mirror the origin-carrying feed keys into the defaults
        // set the nonisolated premium truth reads. ONE maintenance point,
        // always in sync with the store (bootstrap heals existing stores).
        let mirrored = Set(shows.filter { $0.origin != nil }.map { PodcastIdentity.feedKey($0.feedURL) })
        if mirrored != Self.mirroredFeedKeys(defaults: defaults) {
            defaults.set(Array(mirrored).sorted(), forKey: AppStorageKeys.pinchflatMirroredFeedKeys)
        }
    }

    /// guid → (show index, episode index). Pure + static so tests can verify the
    /// index against fixtures.
    nonisolated static func buildEpisodeIndex(_ shows: [PodcastShow]) -> [String: (show: Int, episode: Int)] {
        var index: [String: (show: Int, episode: Int)] = [:]
        index.reserveCapacity(shows.reduce(0) { $0 + $1.episodes.count })
        for (s, show) in shows.enumerated() {
            for (e, ep) in show.episodes.enumerated() { index[ep.guid] = (s, e) }
        }
        return index
    }

    /// Where this store lives: its rows, its settings keys and the name its
    /// wipe note is written beside (the document's name from before the rows).
    /// The app has one store (`shared`); a test builds its own on a folder,
    /// a database and a defaults suite of its own, so it leaves nothing in
    /// the app's stock.
    private let fileURL: URL
    private let database: MaerDatabase
    private let defaults: UserDefaults
    /// Only the app's store connects to the rest of the app: the choice sync
    /// hooks and the co-listened refresh. A store built for a test does not,
    /// or it would replace the app's hooks and reach the network.
    let isTheApp: Bool

    /// Startup load. The full-store JSON decode used to run synchronously in
    /// init. On the main actor, BEFORE first paint (the singleton is created
    /// by the first observing view). The decode now runs off-main; the UI
    /// starts empty and fills one tick later. Startup callers that need the
    /// episode index (session restore, CarPlay) await `ensureLoaded()`.
    private var bootstrapTask: Task<Void, Never>?

    /// True once the bootstrap disk load finished (EVERY path).
    /// Save() refuses to persist before that, so a cold-start mutation can
    /// never wipe the good file with the still-empty in-memory state.
    private(set) var isLoaded = false

    init(fileURL: URL, database: MaerDatabase, defaults: UserDefaults, isTheApp: Bool) {
        self.fileURL = fileURL
        self.database = database
        self.defaults = defaults
        self.isTheApp = isTheApp
        feedsNotFollowed = FeedAdoptionPending.pending(defaults: defaults)
        refusedFeedKeys = FeedRefusal.lasting(defaults: defaults)
        // The subscription family of the choice sync reads the list through
        // the store and hands adopted statements back to it.
        if isTheApp {
            let choiceSync = UserChoiceCloudSync.shared
            self.choiceSync = choiceSync
            choiceSync.localSubscriptions = { [weak self] in self?.subscriptionsForCloud() }
            choiceSync.subscriptionAdopter = { [weak self] added, removed in
                self?.adoptCloudSubscriptions(added: added, removed: removed)
            }
            choiceSync.subscriptionsFollow = { [weak self] scope, previous in self?.follow(owner: scope, previous: previous) ?? true }
            accessObserver = NotificationCenter.default.addObserver(
                forName: FeedAdoptionPending.accessArrived, object: nil, queue: .main) { [weak self] note in
                    let by = note.userInfo?["by"] as? String ?? "-"
                    MainActor.assumeIsolated { self?.retryAfterAccess(by: by) }
                }
        }
        bootstrapTask = Task { [weak self] in
            // The rows are the stock.
            let rows = await self?.openRows()
            var decoded: [PodcastShow]? = nil
            // What this run had standing: the heads, then the decoded stock.
            var seen: [PodcastShow] = []
            // What the rows hold after the start: known (read), fresh (read,
            // nothing there) or unknown (could not open or read every row),
            // carrying what this run had standing: a write removes only
            // those rows of it that are gone, never one nobody read.
            var base: RowBase<[PodcastShow]> = rows == nil ? .unknown(seen: nil) : .fresh
            // Whether the read failed as a whole (nothing seen): then the
            // chain holds every write until the rows are read and adopted.
            var readFailed = rows == nil
            // Rows that did not decode, for the chain's start line.
            var skippedAtStart = 0
            if let rows {
                do {
                    // Two stages: the show list first (heads, no episodes:
                    // measured 1 ms at 300 shows), so the tab has its list
                    // while the episodes (530 ms at 75000, off the main
                    // actor) still decode. Writers wait for the whole task
                    // (`ensureLoaded`), so nothing lands between the stages.
                    let started = Date()
                    let heads = try await rows.loadHeads()
                    if !heads.isEmpty, let self {
                        // Shown, never folded: heads carry no episodes, so
                        // "the fuller twin survives" has no ground here and
                        // would decide on order alone, tell the account and
                        // write a show without episodes. The full stage
                        // below folds once, on the real stock.
                        self.shows = heads
                        seen = heads
                        let headsMs = Int(Date().timeIntervalSince(started) * 1000)
                        #if DEBUG
                        if self._testFullReadFails { throw CocoaError(.fileReadCorruptFile) }
                        #endif
                        let (loaded, skipped) = try await rows.loadAllCounted()
                        Logger.rss.notice("SUBROWS start: heads=\(heads.count) in \(headsMs) ms, episodes=\(loaded.reduce(0) { $0 + $1.episodes.count }) skipped=\(skipped) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                        skippedAtStart = skipped
                        if !loaded.isEmpty { decoded = loaded }
                        seen = loaded + heads.filter { head in !loaded.contains { $0.id == head.id } }
                        // Rows that did not decode make the rows unknown,
                        // never fresh; seen are the heads as well.
                        base = RowBase.afterLoad(rows: loaded.isEmpty ? nil : loaded, skipped: skipped)
                        if case .unknown = base { base = .unknown(seen: seen) }
                    } else {
                        // No heads: the rows may still hold rows nobody can
                        // read. Count them before calling the rows empty.
                        let (_, skipped) = try await rows.loadAllCounted()
                        skippedAtStart = skipped
                        if skipped > 0 { base = .unknown(seen: nil) }
                    }
                } catch {
                    // The heads read before the failure stand: seen.
                    base = .unknown(seen: seen.isEmpty ? nil : seen)
                    readFailed = seen.isEmpty
                    Logger.rss.error("SUBROWS load failed reason=\(String(describing: error), privacy: .public) base=unknown")
                }
            }
            // Startup diagnosis. A future loss must be READABLE
            // from the log, not reconstructed.
            Logger.rss.notice("SUBSTORE bootstrap: rows=\(rows != nil) shows=\(decoded?.count ?? 0)")
            defer { self?.isLoaded = true }   // EVERY exit path unlocks save()
            if readFailed {
                self?.rowChain.startReadFailedAsAWhole(reason: rows == nil ? "rows not open" : "start read failed")
            } else {
                self?.rowChain.started(base: base, skipped: skippedAtStart)
            }
            guard let self, let decoded, !decoded.isEmpty else { return }
            // The base stays what the rows hold: the LOADED stock, set above.
            // A fold or re-key in `migrated` is written as a diff against it,
            // and `persist` moves the base once that write landed. Setting
            // the base to the folded stock here, before the queued write read
            // it, made that diff empty: the loser stayed in the rows and was
            // folded and told to the account again at every start (measured
            // 01.10.2026, `TokenTwinTwoStageTests`).
            self.shows = self.migrated(decoded)
            // Listen log: one-time backfill so the history of the CURRENT
            // subscriptions survives later unsubscribes/rotation.
            PodcastListenLog.shared.backfillIfNeeded(shows: self.shows)
            // The stock repair also runs at START, not only after a refresh:
            // measured on a device, `refreshAll` is reached by the background
            // task and the pull gesture alone. A user who imports and only
            // looks would never trigger it. It runs HERE, inside the load
            // task after the stock is set, so it can never see an empty
            // stock and pass as a sham run.
            self.healStoredProgress()
        }
    }

    /// Waits for the initial disk load (no-op once finished).
    /// Best-effort: the feed URL of the show owning this episode guid (for
    /// the show-independent listen log).
    /// The feed address of an episode: from the subscriptions, else from
    /// the browsed halves (a listened episode of a show nobody subscribed to
    /// still has an address; the listen log used to get "" for it).
    func feedURL(forEpisodeId episodeId: String) -> String? {
        shows.first { $0.episodes.contains { $0.guid == episodeId } }?.feedURL
            ?? BrowsedEpisodes.shared.episode(guid: episodeId)?.show.feedURL
            ?? BrowsedEpisodes.shared.listened(guid: episodeId)?.feedURL
    }

    func ensureLoaded() async {
        await bootstrapTask?.value
    }

    // MARK: - Serialized row writes

    /// The row backend, opened once in the bootstrap. Nil when the database
    /// could not be opened: the stock then lives in memory for this run and
    /// the failure is in the log.
    /// The one opening of the rows: every caller awaits the same task, so a
    /// second caller never sees the flag before the store exists (measured
    /// in the simulator: the seed's save met a nil store and wrote nothing).
    private var rowsOpening: Task<PodcastRowStore?, Never>?

    private func openRows() async -> PodcastRowStore? {
        if let rowsOpening { return await rowsOpening.value }
        let opening = Task<PodcastRowStore?, Never> {
            do {
                return try await PodcastRowStore(connection: try database.connection())
            } catch {
                Logger.rss.error("SUBROWS open failed reason=\(String(describing: error), privacy: .public)")
                return nil
            }
        }
        rowsOpening = opening
        return await opening.value
    }

    /// The rows' one write chain (`RowChain`): what they hold as far as
    /// this run knows (known after a landed write, fresh, or unknown with
    /// the shows this run saw), the mark of a start read that failed as a
    /// whole, and the serial writes. Over rows the start could not read, a
    /// write reads them first and the list takes them (`adopted`).
    private lazy var rowChain: RowChain<[PodcastShow]> = {
        let chain = RowChain<[PodcastShow]>(label: "SUBROWS")
        chain.adopt = { [weak self] read in
            guard let self else { return }
            self.shows = Self.adopted(read: read, run: self.shows)
        }
        return chain
    }()

    /// The rows could not be opened; a read after a failed start holds.
    private struct RowsNotOpen: Error {}

    /// Rows read after a failed start with the list of this run: the order
    /// of the rows, a show of the run in the place of its row and its
    /// episodes joined with the row's (an episode of the run wins by guid,
    /// an episode only the row holds stays), a show only the run holds at
    /// the end. Before the read the run holds only what it added.
    nonisolated static func adopted(read: [PodcastShow], run: [PodcastShow]) -> [PodcastShow] {
        let runById = Dictionary(run.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var out: [PodcastShow] = read.map { row in
            guard var show = runById[row.id] else { return row }
            let runGuids = Set(show.episodes.map(\.guid))
            show.episodes += row.episodes.filter { !runGuids.contains($0.guid) }
            return show
        }
        let readIds = Set(read.map(\.id))
        out += run.filter { !readIds.contains($0.id) }
        return out
    }

    /// How the last refused wipe of the rows spoke (`RowChain.lastRefusal`).
    var lastWipeRefusal: WipeRefusal? { rowChain.lastRefusal }

    /// `emptying` belongs to this write: `.allowed` only where the person's
    /// own unsubscribe may empty the list, and fixed at the call (`atCall`):
    /// it covers an empty list only when the unsubscribe left it empty.
    /// `take` gives the list when the write runs in the chain (the stock of
    /// that moment, never a picture frozen at the call).
    private func persist(emptying requested: RowEmptying, also: [SQLiteConnection.Statement] = [],
                         _ take: @escaping @MainActor () -> [PodcastShow]?) {
        let emptying = requested.atCall(memoryIsEmpty: take()?.isEmpty ?? true)
        // Only the rows a change touched go to the database, in the order
        // the changes were made: each write waits for the one before it,
        // and the diff is taken against the stock of the write before.
        rowChain.write(narrowing: requested == .allowed && emptying == .refused, read: { [weak self] in
            guard let self, let rows = await self.openRows() else { throw RowsNotOpen() }
            let (loaded, skipped) = try await rows.loadAllCounted()
            return (loaded.isEmpty ? nil : loaded, skipped)
        }, take: take, apply: { [weak self] snapshot, base, refusal in
            guard let self, let rows = await self.openRows() else { return .skipped }
            // Known rows: the diff against them. Fresh rows: the diff
            // against nothing is the whole stock. Unknown rows: the diff
            // against the shows this run saw and that are gone now, so an
            // unsubscribe survives the restart, and rows nobody saw are not
            // buried. Last line of defense, the one rule of every row store
            // against the base the write really takes: an EMPTY snapshot
            // never removes rows unless the user explicitly emptied the
            // list. Refused loudly with a note, so the NEXT incident is
            // diagnosable instead of traceless; how it speaks says
            // `WipeRefusal` (a later write queued, or a removal of the
            // person's narrowed at its call: a notice and no note).
            if base.refuses(snapshot, emptying) {
                let count = base.removable?.count ?? 0
                switch refusal {
                case .laterQueued:
                    Logger.rss.notice("SUBSTORE wipe refused, a later write is queued: empty snapshot over \(count) shows")
                case .narrowedPermission:
                    Logger.rss.notice("SUBSTORE wipe refused: an unsubscribe given while shows stood does not cover this empty snapshot over \(count) shows")
                case .suspected:
                    Logger.rss.error("SUBSTORE wipe REFUSED: empty snapshot over \(count) shows without user intent plan=\(String(describing: base.plan), privacy: .public)")
                    let note = "wipe refused at \(Date()): empty snapshot, \(count) shows, isLoaded=\(self.isLoaded)\n"
                    let tombstone = self.fileURL.appendingPathExtension("wipe-refused.txt")
                    try? note.data(using: .utf8)?.write(to: tombstone)
                }
                return .refused(refusal)
            }
            let diff = PodcastRowDiff.compute(previous: base.previous(for: snapshot), current: snapshot)
            // Shownotes go with the last row that names them, unless a
            // resting stock expects them back. Read before the mark: the
            // read suspends, the mark is taken right before the write.
            let resting = also.isEmpty && (!diff.showsRemoved.isEmpty || !diff.episodesRemoved.isEmpty)
                ? await self.restingGuids() : nil
            // While a replacement is open, every write carries its mark.
            let mark = self.follower?.mark()
            // Never at a hand-over: the leaving account's notes stay for its return.
            var sweep: [SQLiteConnection.Statement] = []
            if mark == nil, let resting { sweep = [try PodcastRowStore.noteSweep(keeping: resting)] }
            // The shownotes waiting now go with this write, also when the
            // rows are unchanged; what landed is let go, a newer text taken
            // meanwhile stays.
            let notes = self.pendingNotes
            guard !diff.isEmpty || !notes.isEmpty || mark != nil || !also.isEmpty else { return .unchanged }
            let started = Date()
            // `also`: rows carried as they are at a hand-over, in the same
            // transaction as the diff and the mark.
            let counts = try await rows.apply(diff, notes: notes, also: also + sweep + (mark?.statements ?? []))
            for (guid, text) in notes where self.pendingNotes[guid] == text { self.pendingNotes[guid] = nil }
            mark?.landed()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Logger.rss.notice("SUBROWS save: shows=\(counts.shows)/-\(diff.showsRemoved.count) episodes=\(counts.episodes)/-\(diff.episodesRemoved.count) ms=\(ms) plan=\(String(describing: base.plan), privacy: .public)")
            // Only shownotes written: the rows themselves are unchanged.
            return diff.isEmpty && mark == nil && also.isEmpty ? .unchanged : .landed
        })
    }

    func awaitPendingWrites() async {
        await rowChain.awaitPendingWrites()
    }

    var hasSubscriptions: Bool { !shows.isEmpty }

    /// THE ONE playability check for episode item ids. Text-only
    /// rss: episodes (kept in the list, no enclosure) are never playable/
    /// queueable/downloadable; non-rss ids (abspod:, books, music) always are
    /// from this check's point of view.
    func isPlayableEpisode(itemId: String) -> Bool {
        Self.isPlayableEpisode(itemId: itemId, episode: episode(guid: itemId)?.episode)
    }

    /// The rule with the subscribed episode already in hand: only a kept
    /// feed episode can be text only, an unknown one plays.
    nonisolated static func isPlayableEpisode(itemId: String, episode: PodcastEpisode?) -> Bool {
        guard itemId.hasPrefix("rss:"), let episode else { return true }
        return episode.isPlayable
    }

    #if DEBUG
    /// Test seam: the full read after the heads fails. Set right after the
    /// init, before the start task first runs on the main actor.
    var _testFullReadFails = false
    /// UI-test seeding only (see UITestSeed). Injects deterministic shows.
    func _seedForUITest(_ shows: [PodcastShow]) { self.shows = shows }
    /// Drive the wipe guard + load gate deterministically.
    func _testPersist(_ snapshot: [PodcastShow]) { persist(emptying: .refused) { snapshot } }
    func _testSetLoaded(_ value: Bool) { isLoaded = value }
    /// The rows as after a start read that failed as a whole, or one that
    /// missed rows it could not decode.
    func _testRowsUnread() { rowChain.startReadFailedAsAWhole(reason: "witness") }
    func _testRowsMissed() { rowChain.noteRowsNotRead() }
    func _testSave() { save() }
    var _testFileURL: URL { fileURL }
    /// Where this store's rows and settings keys live, so a test can show
    /// that the app's store takes the app's.
    var _testDatabase: MaerDatabase { database }

    /// Whether the rows hold more than this run read (`RowChain.startIncomplete`).
    var startIncomplete: Bool { rowChain.startIncomplete }
    var _testDefaults: UserDefaults { defaults }
    /// What the rows hold, after `awaitPendingWrites`.
    func _testRowCounts() async -> PodcastRowStore.Counts? {
        guard let rows = await openRows() else { return nil }
        return try? await rows.counts()
    }
    #endif

    // MARK: - Stable ids + dedup (migration)

    /// Known members-only feed hosts (moved here from the podcast tab so the
    /// premium test has ONE home). The membership hosters whose
    /// personalised URLs carry the token in the PATH. Pure data.
    nonisolated private static let premiumHosts =
        ["patreon.com", "supercast", "supportingcast", "memberful", "acast.com/access",
         "supportingcast.fm", "supercast.com", "memberful.com", "steadyhq.com"]

    /// Feeds whose CHANNEL states `<itunes:block>`/`<podcast:block>`.
    /// The standard "do not list publicly" signal. Persisted per feed key,
    /// filled while parsing (no extra request), and read by the premium test.
    nonisolated static func blockedFeedKeys(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: AppStorageKeys.blockedFeedKeys) ?? [])
    }

    nonisolated static func noteFeedBlocked(_ feedURL: String,
                                            defaults: UserDefaults = .standard) {
        var keys = blockedFeedKeys(defaults: defaults)
        guard keys.insert(PodcastIdentity.feedKey(feedURL)).inserted else { return }
        defaults.set(Array(keys).sorted(), forKey: AppStorageKeys.blockedFeedKeys)
        Logger.rss.notice("PREMIUM feed-blocked signal: \(PodcastIdentity.maskedFeedURL(feedURL), privacy: .public)")
        // A block signal is a statement about the FEED, not about
        // this device. It travels with the choice family.
        let key = PodcastIdentity.feedKey(feedURL)
        Task { @MainActor in
            UserChoiceCloudSync.shared.noteFeedBlock(key)
        }
    }

    nonisolated static func isFeedBlocked(_ feedURL: String,
                                          defaults: UserDefaults = .standard) -> Bool {
        blockedFeedKeys(defaults: defaults).contains(PodcastIdentity.feedKey(feedURL))
    }

    /// THE premium test: stored basic-auth credentials OR the token-URL class
    /// OR a known members-only host OR a MANUAL user marking (the escape
    /// hatch for unknown patterns; one truth feeds management, tab
    /// grouping, badges, the replace dialog AND the OPML-export guard).
    /// The premium feeds among these addresses, for the podcast sections'
    /// snapshot. The snapshot is taken in `taskOnPodcastChange`, whose scope
    /// observes this store, so a changed marking recomputes it.
    nonisolated static func premiumFeeds(among feedURLs: [String],
                                         defaults: UserDefaults = .standard) -> Set<String> {
        Set(feedURLs.filter { isPremiumFeed($0, defaults: defaults) })
    }

    nonisolated static func isPremiumFeed(_ feedURL: String,
                                          defaults: UserDefaults = .standard) -> Bool {
        premiumAnswer(feedURL, defaults: defaults) ?? false
    }

    /// The premium rule with its third answer: nil while no other sign
    /// says paid and the feed's stored sign-in cannot be read now. A
    /// surface reads nil as free (the next pass after the unlock shows it
    /// right); a writer that would keep something waits.
    nonisolated static func premiumAnswer(_ feedURL: String,
                                          defaults: UserDefaults = AppStorageKeys.store) -> Bool? {
        // A mirrored feed is NEVER premium. Its host login is
        // server infrastructure, not a paywall; its marking is the origin
        // capsule. First check, so no heuristic below can override it.
        if mirroredFeedKeys(defaults: defaults).contains(PodcastIdentity.feedKey(feedURL)) { return false }
        let access = PodcastFeedAuth.access(feedKey: PodcastIdentity.feedKey(feedURL))
        if case .present = access { return true }
        if PodcastFeedAddress.isTokenFeedURL(feedURL) { return true }
        // The feed says it itself. Catches the path-token class
        // the query-param heuristic cannot see.
        if isFeedBlocked(feedURL, defaults: defaults) { return true }
        if manualPremiumFeedKeys(defaults: defaults).contains(PodcastIdentity.feedKey(feedURL)) { return true }
        let lower = feedURL.lowercased()
        if premiumHosts.contains(where: { lower.contains($0) }) { return true }
        return access == .unknown ? nil : false
    }

    /// The mirrored-group feed keys (maintained in rebuildCaches).
    nonisolated static func mirroredFeedKeys(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: AppStorageKeys.pinchflatMirroredFeedKeys) ?? [])
    }

    /// Manual premium markings (persisted feed keys).
    nonisolated static func manualPremiumFeedKeys(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: AppStorageKeys.premiumMarkedFeeds) ?? [])
    }

    nonisolated static func isManuallyMarkedPremium(_ feedURL: String,
                                                    defaults: UserDefaults = .standard) -> Bool {
        manualPremiumFeedKeys(defaults: defaults).contains(PodcastIdentity.feedKey(feedURL))
    }

    nonisolated static func setManualPremium(_ marked: Bool, feedURL: String,
                                             defaults: UserDefaults = .standard) {
        var keys = manualPremiumFeedKeys(defaults: defaults)
        let key = PodcastIdentity.feedKey(feedURL)
        if marked { keys.insert(key) } else { keys.remove(key) }
        defaults.set(Array(keys).sorted(), forKey: AppStorageKeys.premiumMarkedFeeds)
        // The statement travels. An un-marking as its own tombstone,
        // so the other device cannot resurrect it.
        Task { @MainActor in
            UserChoiceCloudSync.shared.notePremiumMark(key, marked: marked)
            shared.objectWillChange.send()
            // And the surfaces re-read. This used to be the CALLER's duty,
            // and all four remembered it, which is luck and not a promise: a
            // fifth would change the mark and leave every row showing the old
            // one, with nothing to say so. The obligation belongs to the
            // change, not to whoever makes it.
        }
    }

    /// Bring persisted shows to stable ids/guids and merge duplicate shows (same
    /// normalised feed URL). Idempotent. Later starts change nothing. When
    /// re-keying the guids the associated `localPosition` progress moves along
    /// (old→new) so the just-imported Apple progress is preserved.
    private func migrated(_ decoded: [PodcastShow]) -> [PodcastShow] {
        // The SAME re-keying rule as everywhere else. Including the
        // comparison the old private copy lacked.
        var retiredTwins: [(loser: String, survivor: String)] = []
        let (result, changed) = PodcastIdentity.migrate(decoded, moveProgress: { old, new in
            ListeningStore.move(from: old, to: new, in: defaults)
        }, retired: { retiredTwins.append(($0, $1)) })
        if changed {
            // Write back (serialized, off-main) so the cleanup is persistent.
            // The list holds `result` by the time the chain runs (the
            // caller sets it right after this returns).
            persist(emptying: .refused) { [weak self] in self?.shows }
        }
        // The held token addresses, once per load, for the comparison with
        // another device's adoption line. Hashes only.
        for show in result where PodcastFeedAddress.isTokenFeedURL(show.feedURL) {
            // Hashes only (`addressLine`), never the address.
            let measured = PodcastIdentity.addressLine(show.feedURL)
            Logger.rss.notice("FEEDURL held \(measured, privacy: .public)")
        }
        if !retiredTwins.isEmpty {
            // Said to the account after the load, not during it: the old
            // token's statement is withdrawn, the survivor's is stated.
            Task { @MainActor in
                for twin in retiredTwins {
                    Self.stateSubscription(twin.loser, subscribed: false)
                    Self.stateSubscription(twin.survivor, subscribed: true)
                    Logger.rss.notice("PREMIUM token twin retired to the account: \(PodcastIdentity.maskedFeedURL(twin.loser), privacy: .public) -> \(PodcastIdentity.maskedFeedURL(twin.survivor), privacy: .public)")
                }
            }
        }
        return result
    }

    // MARK: - Subscriptions

    /// Subscribe to a feed (loads + parses immediately). Already-present feeds
    /// are only refreshed.
    /// `notesCloud`: a person subscribing (or importing) is a choice that
    /// travels; a server pull or a mirror is mechanics and never notes.
    /// `adopting`: the fetch serves the account's list, not the person's
    /// own request. A sign-in demand then marks the feed as needing one
    /// instead of failing silently and being retried on every reconcile.
    /// `isSingleUserAct`: did the person subscribe to THIS feed, one at a
    /// time? False for every mechanic AND for the bulk import, which reports
    /// its own summary. It is a fact of its own and not `notesCloud` in
    /// disguise: an imported subscription must still travel to the cloud.
    func subscribe(urlString: String, notesCloud: Bool = true, adopting: Bool = false,
                   isSingleUserAct: Bool = true,
                   statementT: Double? = nil) async -> Bool {
        await follow(urlString: urlString, notesCloud: notesCloud, adopting: adopting,
                     isSingleUserAct: isSingleUserAct, statementT: statementT).isHeld
    }

    /// What one subscribe did, as its own answer. A bulk run with several
    /// fetches in flight read this from a shared field before, and a twin
    /// skip could land on the wrong feed.
    enum FollowOutcome: Equatable {
        /// The show is held after the call; `wasNew` is false for a refresh.
        case followed(title: String, wasNew: Bool, episodes: Int)
        /// The free twin of a held premium show: not subscribed, its stored
        /// progress moved onto the premium episodes.
        case freeTwin(title: String, redirected: Int)
        case notFollowed(FeedAdoptionPending.Reason, status: Int?)
        /// Subscribed on Audiobookshelf and not here: an import follows it
        /// there and subscribes nothing locally.
        case onServer(title: String)
        /// Not asked now: a sign-in the answer depends on cannot be read
        /// (`PodcastFeedAuth.Access.unknown`). Nothing is held or marked,
        /// and a later round asks again.
        case notAsked

        /// What `subscribe` has always answered: yes for a held show and
        /// for a twin that was deliberately skipped.
        var isHeld: Bool {
            switch self {
            case .notFollowed, .notAsked: return false
            case .followed, .freeTwin, .onServer: return true
            }
        }
    }

    /// `subscribe` with its answer spelled out. `patience` is `.bulk` in a
    /// run over many feeds: one attempt with a short silence limit.
    func follow(urlString: String, notesCloud: Bool = true, adopting: Bool = false,
                isSingleUserAct: Bool = true, statementT: Double? = nil,
                patience: FeedFetchPatience = .patient,
                allowingFreeTwinOf paidShowId: String? = nil) async -> FollowOutcome {
        await ensureLoaded()   // No mutation before the disk load
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedFeedURL(trimmed) else { return .notFollowed(.unreadable, status: nil) }
        let outcome: FeedFetchOutcome
        if let fetcher = _testFeedFetcher {
            outcome = await fetcher(url)
        } else {
            outcome = await Self.fetchOutcome(feedURL: url, patience: patience)
        }
        if case .accessUnknown = outcome {
            Logger.rss.notice("SUBSCRIBE not asked, the sign-in cannot be read now: \(PodcastIdentity.feedKey(url.absoluteString), privacy: .private(mask: .hash))")
            return .notAsked
        }
        guard case .show(let show) = outcome else {
            let reason: FeedAdoptionPending.Reason
            var status: Int?
            switch outcome {
            case .status(let code):
                reason = FeedAdoptionPending.Reason.from(
                    meaning: StatusMeaning.from(status: code),
                    tokenAddress: PodcastFeedAddress.isTokenFeedURL(url.absoluteString),
                    hasCredentials: PodcastFeedAuth.hasCredentials(feedKey: PodcastIdentity.feedKey(url.absoluteString)))
                status = code
            case .failed(let why):
                reason = why
            case .show, .accessUnknown:
                reason = .unreadable
            }
            // Every failed adoption gets a visible reason, not a silent
            // retry on the next reconcile.
            if adopting, PodcastFeedAddress.isTokenFeedURL(url.absoluteString) {
                // Hashes only (`addressLine`), never the address.
                let measured = PodcastIdentity.addressLine(url.absoluteString)
                Logger.rss.notice("FEEDURL adopted \(measured, privacy: .public) status=\(status ?? 0) reason=\(reason.rawValue, privacy: .public)")
            }
            if adopting {
                markNotFollowed(feedURL: url.absoluteString, reason: reason, status: status,
                                statementT: statementT)
            }
            return .notFollowed(reason, status: status)
        }
        // The OTHER direction of the premium offer below: the ARRIVING feed is
        // the free twin of a show already subscribed as premium (the Apple
        // import walks Apple's list, which still carries the free feed). The
        // exact-address check cannot see that, so the import subscribed the
        // free ZEIT copy next to the paid one. Skipped here. And any stored
        // progress under the skipped feed's guids is redirected onto the
        // premium episodes first (target-empty guard, the replacement path's
        // rule), so nothing the twin knew is lost. The person switching a
        // refused paid show to its free twin passes the paid show's id, and
        // only that one act follows the twin.
        // Whether a held show is paid may wait on a sign-in the keychain
        // cannot give out now: then the twin question has no answer, and
        // following the feed would keep the free copy next to the paid one
        // for good. Not asked and not marked; the next round asks again.
        if paidShowId == nil, shows.first(where: { $0.id == show.id }) == nil,
           shows.contains(where: {
               Self.premiumAnswer($0.feedURL, defaults: defaults) == nil
                   && PodcastPremiumMatch.sameShow(titleA: $0.title, titleB: show.title)
           }) {
            Logger.rss.notice("SUBSCRIBE not asked, a twin's sign-in cannot be read now: \(show.id, privacy: .private(mask: .hash))")
            return .notAsked
        }
        if paidShowId == nil,
           shows.first(where: { $0.id == show.id }) == nil,
           !Self.isPremiumFeed(show.feedURL, defaults: defaults),
           let premium = shows.first(where: {
               Self.isPremiumFeed($0.feedURL, defaults: defaults)
                   && PodcastPremiumMatch.sameShow(titleA: $0.title, titleB: show.title)
           }) {
            let matches = PodcastPremiumMatch.episodeMatches(free: show.episodes,
                                                             premium: premium.episodes)
            // The FRESH case needs a bridge, not only the redirect below:
            // Apple's progress rows arrive AFTER this skip and carry the free
            // feed's enclosures. Without the bridge only the title fallback
            // caught some of them, the rest fell silently.
            twinEnclosureBridge.merge(
                PodcastPremiumMatch.enclosureBridge(free: show.episodes,
                                                    premium: premium.episodes)) { old, _ in old }
            var redirected = 0
            for (freeGuid, premiumGuid) in matches {
                guard let stored = ListeningStore.backup(freeGuid, in: defaults),
                      !ListeningStore.hasStand(premiumGuid, in: defaults) else { continue }
                ListeningStore.store(premiumGuid, entry: stored, in: defaults)
                redirected += 1
            }
            Logger.rss.notice("SUBSCRIBE skipped free twin of premium \(show.title, privacy: .public): progress redirected=\(redirected)")
            if redirected > 0 { reloadProgress() }
            rememberFreeTwin(show.feedURL, forPremium: premium.id)
            return .freeTwin(title: show.title, redirected: redirected)
        }
        let wasNew = !shows.contains { $0.id == show.id }
        if let idx = shows.firstIndex(where: { $0.id == show.id }) {
            // Re-subscribe must not blindly replace: a weak parse (valid title,
            // few/zero episodes) would drop the cached episodes. Union instead.
            shows[idx] = PodcastIdentity.merge(shows[idx], show)
        } else {
            shows.insert(show, at: 0)
            if PodcastSubscribeNotice.shouldTell(episodeCount: show.episodes.count,
                                                 isSingleUserAct: isSingleUserAct,
                                                 isFirstSubscribe: true) {
                emptyFeedNotice = show.title
            }
            // A NEW premium feed of ANY class (credentials, token URL,
            // members host, manual mark) that looks like an existing free
            // subscription → offer the replacement.
            // Conservative same-show test; the user decides.
            if Self.isPremiumFeed(show.feedURL, defaults: defaults),
               let free = shows.first(where: {
                   $0.id != show.id
                       && !Self.isPremiumFeed($0.feedURL, defaults: defaults)
                       && PodcastPremiumMatch.sameShow(titleA: $0.title, titleB: show.title)
               }) {
                pendingPremiumReplacement = PremiumReplacementOffer(
                    freeShowId: free.id, premiumShowId: show.id, showTitle: show.title)
            }
        }
        save()
        if notesCloud {
            Self.stateSubscription(show.feedURL, subscribed: true)
        }
        return .followed(title: show.title, wasNew: wasNew, episodes: show.episodes.count)
    }

    /// Move the matched episodes' local progress free→premium
    /// (the migrateLocalPosition pattern: target-empty guard), adopt their
    /// downloads, then unsubscribe the free show. Unmatched free episodes keep
    /// nothing to lose. Their progress keys simply become orphaned history.
    @discardableResult
    func replaceFreeWithPremium(_ offer: PremiumReplacementOffer,
                                notesCloud: Bool = true) -> (progressMoved: Int, downloadsAdopted: Int) {
        defer { pendingPremiumReplacement = nil }
        guard let free = shows.first(where: { $0.id == offer.freeShowId }),
              let premium = shows.first(where: { $0.id == offer.premiumShowId }) else { return (0, 0) }
        let carried = carryOver(from: free, to: premium)
        rememberFreeTwin(free.feedURL, forPremium: premium.id)
        unsubscribe(id: free.id, notesCloud: notesCloud)
        reloadProgress()
        // The takeover is visible in the log (titles only, no URLs.
        // Premium URLs can carry secrets).
        Logger.rss.notice("premium replacement: \(offer.showTitle, privacy: .public) — \(carried.matched) matched, \(carried.moved) progress moved, \(carried.adopted) downloads adopted")
        return (carried.moved, carried.adopted)
    }

    /// THE move from one show to the show that replaces it (free to
    /// premium, a new link for a refused feed): matched episodes carry their
    /// stand and their download over. An episode that keeps its guid needs
    /// no move; skipping it spares the announcement, the store itself
    /// already refuses a move onto itself.
    private func carryOver(from old: PodcastShow, to new: PodcastShow) -> (matched: Int, moved: Int, adopted: Int) {
        let matches = PodcastPremiumMatch.episodeMatches(free: old.episodes, premium: new.episodes)
            .filter { $0.key != $0.value }
        var moved = 0
        var adopted = 0
        for (oldGuid, newGuid) in matches {
            if ListeningStore.hasStand(oldGuid, in: defaults) {
                // ONE re-keying, one rule. This used to be a second
                // implementation beside the stock's: it SKIPPED any occupied
                // target, so an OLDER stand there was never healed. The same
                // defect as the unconditional overwrite, turned the other way.
                ListeningStore.move(from: oldGuid, to: newGuid, in: defaults)
                moved += 1
            }
            if DownloadManager.shared.adoptDownload(from: oldGuid, to: newGuid) {
                adopted += 1
            }
        }
        return (matches.count, moved, adopted)
    }

    /// A new link for a subscribed show whose access is refused: the
    /// new address is followed, what was heard and downloaded goes over,
    /// and the old address leaves the account as the person's unsubscribe.
    /// The same address typed again only asks the feed once more.
    func replaceShowLink(showId: String, newURL: String, notesCloud: Bool = true) async -> Bool {
        await ensureLoaded()
        guard let old = shows.first(where: { $0.id == showId }) else { return false }
        let before = Set(shows.map(\.id))
        let outcome = await follow(urlString: newURL, notesCloud: notesCloud, isSingleUserAct: true)
        guard case .followed = outcome else {
            Logger.rss.notice("SUBSCRIBE new link for refused show: \(showId, privacy: .private(mask: .hash)) ok=false")
            return false
        }
        guard let new = shows.first(where: { !before.contains($0.id) }), new.id != old.id else {
            // The same feed: the fetch above was the fresh answer.
            await recheckAccess(showId: showId)
            return true
        }
        let carried = carryOver(from: old, to: new)
        // The unsubscribe also clears the old address's refusal record.
        unsubscribe(id: old.id, notesCloud: notesCloud)
        reloadProgress()
        Logger.rss.notice("SUBSCRIBE new link for refused show: \(showId, privacy: .private(mask: .hash)) ok=true matched=\(carried.matched) moved=\(carried.moved) adopted=\(carried.adopted)")
        return true
    }

    /// Tag a mirrored feed's provenance.
    func setOrigin(_ origin: String?, forFeedURL feedURL: String) {
        guard let index = shows.firstIndex(where: { $0.feedURL == feedURL }) else { return }
        shows[index].origin = origin
        save()
    }

    /// Every episode guid of the mirrored group. Hosts resolve
    /// membership ONCE per render and hand rows a Bool (cell-cost rule:
    /// no per-row shows×episodes scan).
    func mirroredEpisodeGuids() -> Set<String> {
        Set(shows.filter { $0.origin != nil }.flatMap { $0.episodes.map(\.guid) })
    }

    /// Does this feed belong to a mirrored group? Carried by the
    /// `origin` field only. Never a URL heuristic. Drives the
    /// "YouTube" origin capsule on surfaces OUTSIDE the group row.
    func isMirrored(feedURL: String) -> Bool {
        let normalized = PodcastIdentity.normalizeFeedURL(feedURL)
        return shows.contains {
            $0.origin != nil && PodcastIdentity.normalizeFeedURL($0.feedURL) == normalized
        }
    }

    /// A SERVER-driven remove (channel left the mirror).
    /// Deliberately NOT the user-unsubscribe: it must not join the gpodder
    /// user-intent set. The mirrored group is no subscription set of the
    /// user's, and progress stays like any unsubscribe.
    func removeMirrored(feedURL: String) {
        shows.removeAll { $0.feedURL == feedURL }
        save()
    }

    /// `notesCloud: false` for removals a MECHANISM performs (a gpodder
    /// server drop): the account's family carries the person's decisions
    /// only, and a tombstone written by mechanics would bury the feed on
    /// every device of the account.
    func unsubscribe(id: String, notesCloud: Bool = true) {
        // A user unsubscribe may legitimately empty the
        // store; the normalized URL joins the user-intent set so the gpodder
        // sync may propagate THIS single remove immediately (derived removes
        // wait for the two-sync confirmation instead).
        var removedFeedURL: String?
        if let show = shows.first(where: { $0.id == id }) {
            Self.recordUserRemovedFeed(PodcastIdentity.normalizeFeedURL(show.feedURL), defaults: defaults)
            removedFeedURL = show.feedURL
        }
        shows.removeAll { $0.id == id }
        // ONLY the person's own unsubscribe may empty the list.
        save(emptying: .allowed)
        if let removedFeedURL {
            FeedRefusal.forget(feedKey: PodcastIdentity.feedKey(removedFeedURL), defaults: defaults)
            // Published only on a change: an unsubscribe announces once.
            let lasting = FeedRefusal.lasting(defaults: defaults)
            if lasting != refusedFeedKeys { refusedFeedKeys = lasting }
        }
        // The person's unsubscribe travels as a tombstone.
        if notesCloud, let removedFeedURL {
            Self.stateSubscription(removedFeedURL, subscribed: false)
        }
    }

    /// Subscriptions adopted from the account (a device without a podcast
    /// server follows the account's list): leave what the others left,
    /// follow what they follow. Following fetches the feeds one by one in
    /// the background, throttled like a refresh; no automatic download and
    /// no "new episode" notification for what merely arrives. The states
    /// already in the pot then apply to the episodes.
    func adoptCloudSubscriptions(added: [(feedURL: String, t: Double)], removed: [String]) {
        Task { [weak self] in
            guard let self else { return }
            await self.ensureLoaded()
            var removedTitles: [String] = []
            for feedKey in removed {
                if let show = self.shows.first(where: { PodcastIdentity.feedKey($0.feedURL) == feedKey }),
                   show.origin == nil {
                    // The family carries the person's decisions only, so a
                    // tombstone is the person's unsubscribe made elsewhere:
                    // it joins the user-intent set, and the next gpodder
                    // round pushes THIS single remove at once instead of
                    // holding it as a derived one. Stands stay, here and on
                    // the server: an unsubscribe removes the feed, never
                    // what was heard. Being the person's unsubscribe, it
                    // may empty the list like `unsubscribe` does; refused,
                    // every write would take the same empty list and the
                    // shows came back at the next start.
                    Self.recordUserRemovedFeed(PodcastIdentity.normalizeFeedURL(show.feedURL), defaults: defaults)
                    self.shows.removeAll { $0.id == show.id }
                    self.save(emptying: .allowed)
                    removedTitles.append(show.title)
                    Logger.rss.notice("SUBSCRIBE cloud tombstone applied: \(feedKey, privacy: .private(mask: .hash))")
                }
            }
            let pendingBefore = Set(self.feedsNotFollowed.keys)
            var followed = 0
            for entry in added.sorted(by: { $0.t < $1.t }) {
                let key = PodcastIdentity.feedKey(entry.feedURL)
                guard !self.shows.contains(where: { PodcastIdentity.feedKey($0.feedURL) == key }) else { continue }
                // The account offers an unfollowed feed on EVERY reconcile
                // (the statement stays open until this device holds it), so
                // a run that is still fetching must not fetch it twice.
                guard !self.adoptingFeedKeys.contains(key) else {
                    Logger.rss.notice("SUBSCRIBE cloud adoption skipped, already fetching: \(key, privacy: .private(mask: .hash))")
                    continue
                }
                // A feed that failed or was dismissed here is not fetched
                // again until the person retries, signs in, or the account
                // brings a newer statement (no endless retry).
                guard FeedAdoptionPending.shouldAttempt(feedKey: key, statementT: entry.t, defaults: defaults) else {
                    let reason = self.feedsNotFollowed[key]?.reason.rawValue ?? "none"
                    Logger.rss.notice("SUBSCRIBE cloud adoption skipped, not followed reason=\(reason, privacy: .public): \(key, privacy: .private(mask: .hash))")
                    continue
                }
                self.adoptingFeedKeys.insert(key)
                let answer = await self.subscribeUnlessOnServer(urlString: entry.feedURL, notesCloud: false,
                                                                adopting: true, isSingleUserAct: false,
                                                                statementT: entry.t)
                self.adoptingFeedKeys.remove(key)
                let ok = answer == .subscribed
                if ok { followed += 1 }
                // Held on Audiobookshelf the statement is followed there; set
                // out, it stays open and unmarked, and a later round asks again.
                let outcome: String
                switch answer {
                case .onServer: outcome = "onServer"
                case .setOut: outcome = "setOut"
                case .subscribedUnchecked: outcome = "subscribedUnchecked"
                case .subscribed, .notSubscribed:
                    outcome = FeedAdoptionPending.outcome(
                        ok: ok, held: self.shows.contains { PodcastIdentity.feedKey($0.feedURL) == key },
                        reason: self.feedsNotFollowed[key]?.reason)
                }
                Logger.rss.notice("SUBSCRIBE cloud adopted: \(key, privacy: .private(mask: .hash)) ok=\(ok) outcome=\(outcome, privacy: .public)")
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            // The history says what iCloud DID here: feeds followed, feeds
            // removed by name (a removal is a possible loss and must be
            // inspectable), feeds waiting for a login. Nothing for a run
            // that changed nothing. The history is the app's; a test
            // instance must not write the host's file.
            let newlyPending = Set(self.feedsNotFollowed.keys).subtracting(pendingBefore)
            let needSignIn = newlyPending.filter { self.feedsNotFollowed[$0]?.reason == .signIn }.count
            let otherFailures = newlyPending.count - needSignIn
            if followed + removedTitles.count + newlyPending.count > 0, self === Self.shared {
                SyncHistoryStore.shared.append(SyncHistory.entry(
                    service: .iCloud, direction: .down,
                    counters: [.init(key: .subscriptionsDown, value: followed),
                               .init(key: .subscriptionsRemovedLocally, value: removedTitles.count),
                               .init(key: .subscriptionsNeedingSignIn, value: needSignIn),
                               .init(key: .subscriptionsNotFollowed, value: otherFailures)],
                    duration: 0, removedFeeds: removedTitles,
                    deviceId: SyncHistoryStore.entryDeviceId))
            }
        }
    }

    /// Feed keys an adoption run is fetching right now.
    private var adoptingFeedKeys: Set<String> = []

    // MARK: - Feeds not followed yet (adoption failed, with its reason)

    private func markNotFollowed(feedURL: String, reason: FeedAdoptionPending.Reason, status: Int? = nil,
                                 statementT: Double? = nil) {
        let key = PodcastIdentity.feedKey(feedURL)
        FeedAdoptionPending.mark(feedKey: key, feedURL: feedURL, reason: reason, status: status,
                                 statementT: statementT, defaults: defaults)
        feedsNotFollowed = FeedAdoptionPending.pending(defaults: defaults)
        // Adoption and import both mark here, so the line names neither.
        Logger.rss.notice("SUBSCRIBE marked not followed: \(key, privacy: .private(mask: .hash)) reason=\(reason.rawValue, privacy: .public) status=\(status ?? 0)")
    }

    /// A retry (the button, or a saved login) reopens the way: one fresh
    /// attempt, in the background. A second failure marks the feed again.
    /// No-op for unmarked feeds, so the login form may call this for every
    /// save.
    func retryAdoption(feedKey: String) {
        guard let entry = feedsNotFollowed[feedKey] else { return }
        FeedAdoptionPending.clear(feedKey: feedKey, defaults: defaults)
        feedsNotFollowed = FeedAdoptionPending.pending(defaults: defaults)
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.subscribeUnlessOnServer(urlString: entry.feedURL, notesCloud: false, adopting: true,
                                                            isSingleUserAct: false)
            Logger.rss.notice("SUBSCRIBE cloud adoption retried: \(feedKey, privacy: .private(mask: .hash)) answer=\(answer.logName, privacy: .public)")
        }
    }

    /// The ONE place a statement about a subscription goes to the account:
    /// subscribing, unsubscribing, a retired token twin, a new link.
    static func stateSubscription(_ feedURL: String, subscribed: Bool) {
        UserChoiceCloudSync.shared.noteSubscription(feedURL: feedURL, subscribed: subscribed)
    }

    /// Whether following a new link withdraws the old address from the
    /// account: only when the two are different feeds. The key is the
    /// subscription's identity, so the same link in another spelling is the
    /// same subscription.
    nonisolated static func withdrawsOldAddress(oldFeedURL: String, newURL: String) -> Bool {
        PodcastIdentity.feedKey(oldFeedURL) != PodcastIdentity.feedKey(newURL)
    }

    /// A refused feed gets a new link from the person: the new address is
    /// followed and stated, the old statement withdrawn. A new link that
    /// fails too marks the old one again, so nothing silently disappears.
    func replaceAdoption(feedKey: String, newURL: String) {
        guard let entry = feedsNotFollowed[feedKey] else { return }
        FeedAdoptionPending.clear(feedKey: feedKey, defaults: defaults)
        feedsNotFollowed = FeedAdoptionPending.pending(defaults: defaults)
        Task { [weak self] in
            guard let self else { return }
            let answer = await self.subscribeUnlessOnServer(urlString: newURL, notesCloud: true, adopting: false,
                                                            isSingleUserAct: true)
            switch answer {
            case .subscribed, .subscribedUnchecked:
                // The same feed under the same key (the same link, other
                // case, tracking parameters): withdrawing the old address
                // would withdraw the subscription just stated.
                if Self.withdrawsOldAddress(oldFeedURL: entry.feedURL, newURL: newURL) {
                    Self.stateSubscription(entry.feedURL, subscribed: false)
                }
            case .onServer:
                // Held on Audiobookshelf: nothing was stated here, so the old
                // address is not withdrawn either, and nothing waits.
                break
            case .notSubscribed, .setOut:
                self.markNotFollowed(feedURL: entry.feedURL, reason: entry.reason, status: entry.status,
                                     statementT: entry.statementT)
            }
            Logger.rss.notice("SUBSCRIBE new link for refused feed: \(feedKey, privacy: .private(mask: .hash)) answer=\(answer.logName, privacy: .public)")
        }
    }

    /// Access may have arrived: every feed waiting for a sign-in gets its
    /// one fresh attempt (a second failure marks it again).
    func retryAfterAccess(by occasion: String) {
        let keys = FeedAdoptionPending.retryOnNewAccess(feedsNotFollowed)
        Logger.rss.notice("SUBSCRIBE retry after access by=\(occasion, privacy: .public) feeds=\(keys.count)")
        for key in keys { retryAdoption(feedKey: key) }
    }

    private var accessObserver: NSObjectProtocol?

    /// The person dismisses the placeholder: a LOCAL choice. The account
    /// keeps the subscription (unsubscribing lives at the show, on a device
    /// that holds it); this device stops offering the feed until the
    /// account brings a newer statement than the one dismissed.
    func removeNotFollowed(feedKey: String) {
        guard let entry = feedsNotFollowed[feedKey] else { return }
        FeedAdoptionPending.mark(feedKey: feedKey, feedURL: entry.feedURL, reason: .dismissed,
                                 statementT: entry.statementT, defaults: defaults)
        feedsNotFollowed = FeedAdoptionPending.pending(defaults: defaults)
        Logger.rss.notice("SUBSCRIBE cloud adoption dismissed here: \(feedKey, privacy: .private(mask: .hash))")
    }

    /// A placeholder show for the surfaces that take a `PodcastShow` (the
    /// login form): host as title, no episodes, nothing persisted.
    nonisolated static func placeholderShow(feedKey: String, feedURL: String) -> PodcastShow {
        let host = PodcastIdentity.feedHost(feedURL)
        return PodcastShow(id: feedKey, title: host.isEmpty ? feedURL : host, author: nil,
                    artworkURL: nil, description: nil, feedURL: feedURL, episodes: [])
    }

    /// The family's view of the local list: feed key ⇒ address, mirrors
    /// excluded (a mirror is the server's list, not a choice); nil until
    /// the store has loaded, so nothing reads an unloaded store as empty.
    func subscriptionsForCloud() -> [String: String]? {
        guard isLoaded else { return nil }
        var out: [String: String] = [:]
        for show in shows where show.origin == nil {
            out[PodcastIdentity.feedKey(show.feedURL)] = show.feedURL
        }
        return out
    }

    // MARK: - The owner of the subscriptions

    static let shelfFamily = "subscriptions"
    /// The subscriptions' way through the shelf (`ShelfFollower`); nil
    /// without a shelf.
    private lazy var follower: ShelfFollower? = database.restingShelf.map {
        ShelfFollower(family: Self.shelfFamily, shelf: $0, label: "SUBSTORE")
    }

    /// What rests for an account: its whole shows with their episodes (the
    /// way back needs no feed), and the feeds of its account still waiting
    /// for a sign-in, as stored. Downloads are files of the device and stay.
    nonisolated struct Resting: Codable, Equatable {
        var shows: [PodcastShow]
        var waiting: Data?
        /// Rows of the account this build could not decode, as stored. They
        /// rest with the account and come back to its rows unread.
        var unread: PodcastRowStore.RawRows? = nil
    }

    /// The guids a resting stock of this family expects back; empty without
    /// a shelf, nil when a rest cannot be read (then no shownotes go).
    private func restingGuids() async -> Set<String>? {
        guard let shelf = database.restingShelf else { return [] }
        let found = await Self.restingGuids(on: shelf, family: Self.shelfFamily)
        if found == nil { Logger.rss.error("SUBROWS notes kept: a resting stock could not be read") }
        return found
    }

    /// Reads every rest of `family` off the main actor: a rest holds whole
    /// shows with their episodes. The holder's own rest is skipped: it stays
    /// on the shelf after a way back, and its stock is the one in the rows.
    @concurrent
    private nonisolated static func restingGuids(on shelf: RestingShelf, family: String) async -> Set<String>? {
        do {
            var guids: Set<String> = []
            let holder = try shelf.holding(of: family)?.owner
            for owner in try shelf.owners(of: family) where owner != holder {
                guard let rest = try shelf.rest(Resting.self, of: family, owner: owner) else { continue }
                for show in rest.shows { guids.formUnion(show.episodes.map(\.guid)) }
                guids.formUnion(rest.unread?.episodes.map(\.guid) ?? [])
            }
            return guids
        } catch {
            return nil
        }
    }

    /// The rows this build cannot decode, as stored; nil when there are
    /// none. Only a start that missed rows, or rows that came back, can
    /// leave such rows. Reading them decodes every episode, so it runs off
    /// the main actor: until it has run, this throws and the hand-over
    /// holds, and the next round finds them read.
    private func undecodedRows() throws -> PodcastRowStore.RawRows? {
        guard rowChain.startIncomplete else { return nil }
        if let rawRows { return rawRows.isEmpty ? nil : rawRows }
        if rawReading == nil {
            let database = self.database
            rawReading = Task { [weak self] in
                // Read after the chain, never beside it (the chain's one
                // rule): a hand-over right after a replacement would see the
                // rows before its write landed. A write handed over meanwhile
                // makes the read stale, and the next question reads again.
                guard let chain = self?.rowChain else { return }
                let read = await chain.readAfterTheChain { await Self.readUndecoded(database) }
                guard let self else { return }
                self.rawReading = nil
                guard let read else {
                    Logger.rss.notice("SUBSTORE unread rows read beside a write; read again at the next question")
                    return
                }
                switch read {
                case .success(let raw): self.rawRows = raw
                case .failure(let error):
                    Logger.rss.error("SUBSTORE unread rows not read: \(FailureReason.of(error), privacy: .public)")
                }
            }
        }
        Logger.rss.notice("SUBSTORE owner held: the unread rows are being read")
        throw RawRowsNotReadYet()
    }

    /// The read itself, off the caller's executor (`@concurrent`): it
    /// decodes every episode.
    @concurrent nonisolated private static func readUndecoded(_ database: MaerDatabase) async -> Result<PodcastRowStore.RawRows, Error> {
        do {
            guard let reader = try database.readerNow() else { return .success(.init()) }
            return .success(try PodcastRowStore.undecodedNow(reader: reader))
        } catch {
            return .failure(error)
        }
    }

    /// The undecodable rows as read off the main actor; nil until read.
    private var rawRows: PodcastRowStore.RawRows?
    private var rawReading: Task<Void, Never>?
    private struct RawRowsNotReadYet: Error {}

    /// Hands the subscriptions to the account signed in now (`scope`) by the
    /// shelf's one rule (`RestingShelf.handOver`). False while that cannot
    /// happen (the stock not loaded or its rows unread, a rest not laid);
    /// the choice runner then holds its round, since the round would carry
    /// the holder's shows to `scope`. The replacement unsubscribes nothing:
    /// no removal is told to the account, a gpodder server or the history.
    func follow(owner scope: String, previous: String? = nil) -> Bool {
        guard let follower else { return true }
        let rested = shows.count
        guard let step = follower.follow(
            to: scope, previous: previous, unread: !isLoaded || rowChain.startReadFailed, landing: .marked,
            landed: { [database] name in
                try OwnerMark.stands(family: Self.shelfFamily, replacement: name, database: database)
            },
            current: {
                // The picture of the holder's stock is taken here, at the
                // lay, with the rows this build cannot read.
                // An unread episode whose show was unsubscribed since left
                // the rows with it (cascade); the rows read before still name
                // it, and it does not rest.
                let read = try undecodedRows()
                let unread = read?.standing(under: Set(shows.map(\.id)))
                let gone = (read?.episodes.count ?? 0) - (unread?.episodes.count ?? 0)
                Logger.rss.notice("SUBSTORE owner rest taken at=\(Date().timeIntervalSince1970, privacy: .public) shows=\(self.shows.count) unreadShows=\(unread?.shows.count ?? 0) unreadEpisodes=\(unread?.episodes.count ?? 0) gone=\(gone)")
                return Resting(shows: shows, waiting: try waitingFeeds(), unread: unread)
            },
            replace: { rest, _, _ in try replace(with: rest) }) else { return false }
        switch step {
        case .kept: return true
        case .first: Logger.rss.notice("SUBSTORE owner first shows=\(rested)")
        case .unread: Logger.rss.notice("SUBSTORE owner held: stock not loaded")
        case .moved: Logger.rss.notice("SUBSTORE owner moved rested=\(rested) shows=\(self.shows.count)")
        }
        return step != .unread
    }

    /// The feeds waiting for a sign-in, as stored.
    private func waitingFeeds() throws -> Data? {
        try defaults.object(forKey: AppStorageKeys.podcastFeedsNeedingSignIn).map {
            try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
        }
    }

    /// The shows of the new owner replace the ones here; the holding settles
    /// once the rows hold them.
    private func replace(with incoming: Resting?) throws {
        // Everything that can throw comes first: a replacement that throws
        // touches nothing (the hand-over of an unfinished replacement asks
        // here without asking `current()` before, so the read of the unread
        // rows may start only now).
        let leaving = try undecodedRows() ?? .init()
        let waiting = try incoming?.waiting.map { try PropertyListSerialization.propertyList(from: $0, format: nil) }
        defaults.set(waiting, forKey: AppStorageKeys.podcastFeedsNeedingSignIn)
        feedsNotFollowed = FeedAdoptionPending.pending(defaults: defaults)
        shows = incoming?.shows ?? []
        // The owner changed, and the shows before rest on the shelf, the
        // rows this build cannot read with them. In the same transaction as
        // the new shows and the mark: those rows leave the tables, and the
        // unread rows of the incoming account come back as they are.
        let carried = PodcastRowStore.carriedRows(leaving: leaving, coming: incoming?.unread ?? .init(),
                                                  keptShows: Set(shows.map(\.id)),
                                                  keptEpisodes: Set(shows.flatMap { $0.episodes.map(\.guid) }))
        save(emptying: .allowed, also: carried)
        // What stands unread in the rows now follows the write that lands,
        // never its intent: the write may fail or be refused. So the memo
        // goes, and the next question reads the table again.
        rawRows = nil
        if !(incoming?.unread?.isEmpty ?? true) { rowChain.noteRowsNotRead() }
    }

    /// Normalized URLs the USER unsubscribed. The only removes the
    /// gpodder sync may push to the server without the two-sync confirmation.
    nonisolated static func userRemovedFeeds(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: AppStorageKeys.gpodderUserRemovedFeeds) ?? [])
    }

    nonisolated static func recordUserRemovedFeed(_ norm: String, defaults: UserDefaults = .standard) {
        var set = userRemovedFeeds(defaults: defaults)
        set.insert(norm)
        defaults.set(Array(set).sorted(), forKey: AppStorageKeys.gpodderUserRemovedFeeds)
    }

    nonisolated static func consumeUserRemovedFeeds(_ applied: Set<String>, defaults: UserDefaults = .standard) {
        let rest = userRemovedFeeds(defaults: defaults).subtracting(applied)
        defaults.set(Array(rest).sorted(), forKey: AppStorageKeys.gpodderUserRemovedFeeds)
    }

    /// Folds a fresh parse of a followed show into its stock, the same merge
    /// a refresh does (a union, the store facts survive). For whoever fetched
    /// the feed for one episode: the episode is then in the stock the
    /// resolver reads, and opening it asks the network no second time. The
    /// per-show limit is left to the next refresh, so the episode that was
    /// just looked for is not cut again in the same breath. Returns the
    /// number of episodes the stock gained, nil for a show not followed here.
    @discardableResult
    func absorb(_ fresh: PodcastShow, showId: String) async -> Int? {
        await ensureLoaded()
        guard let idx = shows.firstIndex(where: { $0.id == showId }) else { return nil }
        let before = shows[idx].episodes.count
        shows[idx] = PodcastIdentity.merge(shows[idx], fresh)
        save()
        return shows[idx].episodes.count - before
    }

    /// Load a show's full history via PodcastIndex (if a key is set) and merge
    /// it into the persisted episodes. Same `rss:<feedKey>:<guid>` ids as the
    /// feed → dedup + shared progress key. Returns: number of NEW episodes added.
    /// The number of episodes added, or nil when the history could not be
    /// asked for: a failed lookup is no finding, and "no further episodes"
    /// would say one. The same holds when nobody may be asked (the
    /// directory is off in the sources, or no key) and when the show is not
    /// followed here: each says its reason, and none of them is a zero.
    func loadFullHistory(showId: String) async -> Int? {
        await ensureLoaded()
        guard AppStorageKeys.podcastIndexActive else {
            Logger.library.notice("PODCAST full history not asked reason=directoryOff show=\(showId, privacy: .private(mask: .hash))")
            return nil
        }
        guard let show = shows.first(where: { $0.id == showId }) else {
            Logger.library.notice("PODCAST full history not asked reason=notFollowed show=\(showId, privacy: .private(mask: .hash))")
            return nil
        }
        guard let added = await Self.historyAdditions(of: show, browsed: false) else { return nil }
        guard !added.isEmpty else { return 0 }
        // Looked up again: the store may have changed while the directory answered.
        guard let idx = shows.firstIndex(where: { $0.id == showId }) else { return nil }
        let known = Set(shows[idx].episodes.map(\.guid))
        let fresh = added.filter { !known.contains($0.guid) }
        guard !fresh.isEmpty else { return 0 }
        shows[idx].episodes = (shows[idx].episodes + fresh).sorted { $0.pubDate > $1.pubDate }
        save()
        return fresh.count
    }

    /// The full history of a show browsed without a subscription: the show
    /// with the directory's episodes merged in, for the page to hold during
    /// the visit, and how many came. Nothing is stored. Nil under the same
    /// conditions as for a followed show: the directory is off, or it failed.
    static func browsedHistory(of show: PodcastShow) async -> (show: PodcastShow, added: Int)? {
        guard AppStorageKeys.podcastIndexActive else {
            Logger.library.notice("PODCAST full history not asked reason=directoryOff browsed show=\(show.id, privacy: .private(mask: .hash))")
            return nil
        }
        guard let added = await historyAdditions(of: show, browsed: true) else { return nil }
        var grown = show
        grown.episodes = (show.episodes + added).sorted { $0.pubDate > $1.pubDate }
        return (grown, added.count)
    }

    /// The directory's episodes of `show` that the show does not hold yet,
    /// newest first, or nil when the directory failed. Writes nothing: a
    /// followed show merges them into the store, a browsed one into the page
    /// for the visit. Same `rss:<feedKey>:<guid>` ids as the feed, so they
    /// dedup and share the progress key. `ask` is the directory; a witness
    /// answers it without the network.
    static func historyAdditions(
        of show: PodcastShow, browsed: Bool,
        ask: (String) async throws -> [PodcastIndexEpisode] = { feedURL in
            try await PodcastIndexDirectory(key: AppStorageKeys.podcastIndexEffectiveKey,
                                            secret: AppStorageKeys.podcastIndexEffectiveSecret)
                .episodes(feedURL: feedURL)
        }
    ) async -> [PodcastEpisode]? {
        let indexEpisodes: [PodcastIndexEpisode]
        do {
            indexEpisodes = try await ask(show.feedURL)
        } catch {
            Logger.library.notice("PODCAST full history failed reason=\(FailureReason.of(error), privacy: .public)\(browsed ? " browsed" : "", privacy: .public)")
            return nil
        }
        let key = PodcastIdentity.feedKey(show.feedURL)
        var seen = Set(show.episodes.map { $0.guid })
        var added: [PodcastEpisode] = []
        for pi in indexEpisodes {
            guard let audio = pi.enclosureUrl, !audio.isEmpty else { continue }
            let guid = "rss:\(key):\(pi.guid ?? audio)"   // like RSSFeedParser
            guard seen.insert(guid).inserted else { continue }
            added.append(PodcastEpisode(
                guid: guid,
                title: pi.title ?? String(localized: "Untitled Episode"),
                audioURL: audio,
                pubDate: (pi.datePublished ?? 0) * 1000,
                duration: pi.duration ?? 0,
                description: pi.description,
                // PodcastIndex answers "" for an episode without a picture.
                imageURL: PodcastCover.present(pi.image)
            ))
        }
        // The same counts as the refresh line, for the other way episodes
        // reach the stock; a browsed show says so, it is not in the store.
        Logger.rss.notice("PODCAST full history\(browsed ? " browsed" : "", privacy: .public) show=\(show.id, privacy: .private(mask: .hash)) stock=\(show.episodes.count) directory=\(indexEpisodes.count) added=\(added.count)")
        return added.sorted { $0.pubDate > $1.pubDate }
    }

    // MARK: - Import (OPML / Apple Podcasts)

    /// Result of an import for UI feedback.
    struct ImportResult {
        var subscribed = 0        // newly/refreshed subscribed
        var failed = 0            // feed not loadable
        var progressApplied = 0   // episodes with applied progress/played
        var paidSkipped = 0       // paid/exclusive subs without a public feed
        /// Free twins of an already-subscribed premium feed. Skipped, their
        /// stored progress redirected onto the premium episodes.
        var freeTwinsSkipped = 0
        /// Shows the import named that this device already followed.
        var alreadySubscribed = 0
        /// Shows the import named that are subscribed on Audiobookshelf and
        /// not here; none of them was subscribed locally.
        var onServer = 0
        /// Audiobookshelf could not be read, so the import set out: which
        /// show lies there was unknown, and nothing was subscribed.
        var serverUnread = false
        var onServerTitles: [String] = []
        /// Of the states of those shows: sent to the server, of them the
        /// finished ones, and kept because the server knew as much or more.
        var sentToServer = 0
        var sentFinished = 0
        var keptOnServer = 0
        /// States the server did not take (its progress could not be read,
        /// or the write failed), by the source's show. A second run sends
        /// them again; what was sent is then the server's and stays out.
        var notSent: [NotSentGroup] = []
        /// Feeds that parsed into a valid show but brought no episode. They
        /// ARE subscribed. Counted here instead of raising an alert per feed:
        /// a run over hundreds would have shown the last empty one by name
        /// and hidden the rest.
        var emptyFeeds = 0
        /// Titles of the shows that are new through this import.
        var subscribedTitles: [String] = []
        /// Of `progressApplied`, the states that mark an episode finished.
        var finishedApplied = 0
        /// States that met a newer or finished local entry and stayed out.
        var keptLocal = 0
        /// Of `keptLocal`: states this device already knew (finished here,
        /// known from iCloud or an earlier import, or newer here).
        var keptKnown = 0
        /// Of `keptLocal`: states with nothing to take over (under a second
        /// played, not finished). On a fresh device this is the whole count.
        var nothingToAdopt = 0
        /// Titles of the states no episode claimed. Named, not only
        /// counted, so a half success is visible.
        var unmatched: [String] = []
        /// The same states, grouped by the show the SOURCE named, with the
        /// ladder's reasons: the surface reports itself.
        var unmatchedGroups: [UnmatchedGroup] = []
        /// States the ladder placed only because the source was asked for
        /// the episode by itself, grouped by show. Pocket Casts only.
        var lookupGroups: [LookupGroup] = []
        var lookupAsked = 0
        var lookupAnswered = 0
        /// Feeds that did not answer in this run, by the source's title.
        /// Each is marked for "Not followed yet" and can be asked again.
        var unreached: [Unreached] = []
        /// Set when the system ended the background time: shows asked by
        /// then. The run stopped there; a second run continues.
        var stoppedAt: Int?
        /// Feeds never asked because the run stopped first.
        var notAsked = 0
    }

    struct Unreached: Identifiable, Equatable {
        var title: String
        var reason: FeedAdoptionPending.Reason
        var status: Int?
        /// Two feeds can carry the same title in one source.
        let id = UUID()
    }

    struct LookupGroup: Identifiable {
        var show: String
        var id: String { show }
        var count = 0
    }

    struct NotSentGroup: Identifiable, Equatable {
        var show: String
        var id: String { show }
        var count = 0
    }

    struct UnmatchedGroup: Identifiable {
        /// The show as the source calls it, else the feed's host.
        var show: String
        var id: String { show }
        var count = 0
        var reasons: [ForeignStateMatcher.UnmatchedReason: Int] = [:]
        /// What the feed carries here: episode count and oldest date (ms).
        var feedEpisodes = 0
        var oldestInFeed: Double?
        var titles: [String] = []
    }

    /// Follows every feed of a bulk run: up to `FeedFetchPatience.bulkWidth`
    /// in flight, one attempt each with a short silence limit. A dead feed
    /// costs seconds instead of a minute, and four of them do not wait for
    /// each other. Each answer comes back as its own value, in source order.
    /// A bulk run is the person acting, but not on THIS feed. A show held
    /// here already is answered without a fetch: a second run after an
    /// abort gets to its states without asking the network again.
    /// `answered` hears each feed as it is done, on the main actor.
    /// `shouldStop` is asked before each new fetch: once it says yes, the
    /// feeds in flight finish and no new one starts. A feed never asked
    /// stays nil, which is not an answer. A show subscribed on
    /// Audiobookshelf and not here (`onServer`, by feed key) is answered
    /// as such without a fetch and is not subscribed locally: the two
    /// sources hold a show exclusively.
    private func followAll(_ feeds: [String],
                           onServer: [String: PodcastShow] = [:],
                           shouldStop: @MainActor () -> Bool = { false },
                           answered: @MainActor (Int, FollowOutcome) -> Void) async -> [FollowOutcome?] {
        var outcomes = [FollowOutcome?](repeating: nil, count: feeds.count)
        var toFetch: [Int] = []
        for (index, feed) in feeds.enumerated() {
            let key = PodcastIdentity.feedKey(feed)
            if let held = shows.first(where: { PodcastIdentity.feedKey($0.feedURL) == key }) {
                let outcome = FollowOutcome.followed(title: held.title, wasNew: false, episodes: held.episodes.count)
                outcomes[index] = outcome
                answered(index, outcome)
            } else if let server = onServer[key] {
                let outcome = FollowOutcome.onServer(title: server.title)
                outcomes[index] = outcome
                answered(index, outcome)
            } else {
                toFetch.append(index)
            }
        }
        await withTaskGroup(of: (Int, FollowOutcome).self) { group in
            var next = 0
            while next < min(FeedFetchPatience.bulkWidth, toFetch.count), !shouldStop() {
                let index = toFetch[next]
                group.addTask { (index, await self.follow(urlString: feeds[index], isSingleUserAct: false, patience: .bulk)) }
                next += 1
            }
            for await (index, outcome) in group {
                outcomes[index] = outcome
                answered(index, outcome)
                guard next < toFetch.count, !shouldStop() else { continue }
                let following = toFetch[next]
                group.addTask { (following, await self.follow(urlString: feeds[following], isSingleUserAct: false, patience: .bulk)) }
                next += 1
            }
        }
        return outcomes
    }

    /// Normalized free enclosure → premium guid, collected while an import
    /// skips free twins. The matcher reads it as its twin rung. Cleared at
    /// the start of each import.
    private var twinEnclosureBridge: [String: String] = [:]

    /// Every episode this device holds a state for, in the seam the export
    /// writes and the import reads back. A finished episode without a
    /// duration carries the sentinel; it goes out as finished with no
    /// position, which is what the reader turns back into the sentinel.
    func exportableStates() -> [ForeignListeningState] {
        var states: [ForeignListeningState] = []
        for show in shows {
            for episode in show.episodes {
                guard let entry = ListeningStore.backup(episode.guid, in: defaults),
                      let state = OPMLExport.exportedState(
                        entry: entry, feedURL: show.feedURL,
                        guid: ForeignStateMatcher.rawGUID(storedGUID: episode.guid),
                        enclosureURL: episode.audioURL, link: episode.link, title: episode.title,
                        duration: episode.duration,
                        archived: ForeignMarks.isArchived(episode.guid, in: defaults)) else { continue }
                states.append(state)
            }
        }
        return states
    }

    /// Where an import stands, for the sheet that started it.
    struct ImportProgress: Equatable, Sendable {
        /// Shows asked so far, of `total`.
        var done: Int
        var total: Int
        /// True once every show is asked and the remaining states are matched.
        var matching = false
    }

    /// What one import run holds while its shows are followed: the states
    /// already decided, by their place in the source, and the counts.
    private final class ForeignRun {
        var decided = Set<Int>()
        var tally = ForeignTally()
        var done = 0
        /// Set when the system ends the background time: no new show starts.
        var stopped = false
    }

    /// The progress store re-reads what this store wrote: after a twin's
    /// redirect, a premium replacement and an import.
    private func reloadProgress() { PodcastProgressStore.shared.reload() }

    /// Where an import asks for time to finish after the app leaves the
    /// screen. The system's in the app; a witness hands in one that can say
    /// "over" when it chooses.
    var backgroundWork: any BackgroundWork = SystemBackgroundWork.app

    /// The shows subscribed on Audiobookshelf as this device holds them
    /// (source switch on, not archived). An import subscribes none of them
    /// locally. A witness hands in its own.
    var serverShows: () -> [PodcastShow] = { PodcastShowSources.absShows() }

    /// Whether `serverShows` answers for this session, and the read that
    /// makes it answer. A witness hands in its own.
    var serverShowsRead: () -> Bool = { PodcastShowSources.absShowsRead() }
    var readServerShows: () async -> Void = { await PodcastShowSources.readAbsShows() }

    /// The server those shows live on, for their states. A witness hands
    /// in its own.
    var serverSide: () -> any ForeignServerSide = { ABSPodcastProvider.shared }

    /// Whether Audiobookshelf holds the show of `feedKey`, as this device
    /// can answer it now (`ServerHolding`).
    func serverHolding(feedKey: String) -> ServerHolding {
        var titles: [String: String] = [:]
        for show in serverShows() where !show.feedURL.isEmpty {
            let key = PodcastIdentity.feedKey(show.feedURL)
            if titles[key] == nil { titles[key] = show.title }
        }
        return .of(feedKey: feedKey, read: serverShowsRead(), serverTitles: titles)
    }

    /// What the door of a local subscription did.
    enum LocalSubscription: Equatable {
        case subscribed
        case notSubscribed
        /// Audiobookshelf holds the show: no local subscription.
        case onServer(title: String)
        /// Audiobookshelf could not be read: nothing subscribed, a later
        /// attempt asks again. Only for a mechanism.
        case setOut
        /// Audiobookshelf could not be read and the person asked: subscribed
        /// here, noted, and settled against the server on its next read.
        case subscribedUnchecked

        /// The answer in a log line, without the show's title.
        var logName: String {
            switch self {
            case .subscribed: "subscribed"
            case .notSubscribed: "notSubscribed"
            case .onServer: "onServer"
            case .setOut: "setOut"
            case .subscribedUnchecked: "subscribedUnchecked"
            }
        }
    }

    /// THE door of every local subscription: a show held on Audiobookshelf
    /// is not subscribed here (the two sources hold a show exclusively),
    /// and an Audiobookshelf that was not read is read first. Still unread,
    /// a mechanism subscribes nothing rather than reading "not there" into
    /// no answer, while the person's own tap subscribes here with a note
    /// that the next read settles (`settleUnchecked`). A show already held
    /// here is refreshed as before. The parameters are those of `subscribe`.
    func subscribeUnlessOnServer(urlString: String, notesCloud: Bool = true, adopting: Bool = false,
                                 isSingleUserAct: Bool = true,
                                 statementT: Double? = nil) async -> LocalSubscription {
        let key = PodcastIdentity.feedKey(urlString)
        var noted = false
        if !shows.contains(where: { PodcastIdentity.feedKey($0.feedURL) == key }) {
            var holding = serverHolding(feedKey: key)
            if holding == .unread {
                await readServerShows()
                holding = serverHolding(feedKey: key)
            }
            switch holding {
            case .held(let title):
                Logger.rss.notice("SUBSCRIBE held on Audiobookshelf, not here: \(key, privacy: .private(mask: .hash))")
                return .onServer(title: title)
            case .unread:
                guard ServerHolding.whileUnread(byPerson: isSingleUserAct) == .subscribeNoted else {
                    Logger.rss.notice("SUBSCRIBE set out, Audiobookshelf unread: \(key, privacy: .private(mask: .hash))")
                    return .setOut
                }
                noted = true
            case .notThere:
                break
            }
        }
        let held = await subscribe(urlString: urlString, notesCloud: notesCloud, adopting: adopting,
                                   isSingleUserAct: isSingleUserAct, statementT: statementT)
        guard held else { return .notSubscribed }
        guard noted else { return .subscribed }
        noteUnchecked(key, true)
        Logger.rss.notice("SUBSCRIBE here, Audiobookshelf unread, noted: \(key, privacy: .private(mask: .hash))")
        return .subscribedUnchecked
    }

    /// The feed keys subscribed here by the person while Audiobookshelf
    /// could not be read.
    func uncheckedFeedKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: AppStorageKeys.podcastServerUncheckedFeeds) ?? [])
    }

    private func noteUnchecked(_ key: String, _ noted: Bool) {
        var keys = uncheckedFeedKeys()
        if noted { keys.insert(key) } else { keys.remove(key) }
        if keys.isEmpty {
            defaults.removeObject(forKey: AppStorageKeys.podcastServerUncheckedFeeds)
        } else {
            defaults.set(keys.sorted(), forKey: AppStorageKeys.podcastServerUncheckedFeeds)
        }
    }

    /// The shows subscribed here while Audiobookshelf could not be read,
    /// settled against it after a read. Held there, their heard states go
    /// to the server's episodes over the one bridge of the import (guid,
    /// then enclosure; the newer state wins) and the local subscription
    /// goes like a mechanism removes one: no tombstone for the cloud, no
    /// gpodder intent, the local states stay. A state without an episode
    /// there keeps the local subscription, so nothing heard is lost.
    func settleUnchecked() async {
        for key in uncheckedFeedKeys().sorted() {
            // Asked per show: the hand-over of a show before awaits the server.
            let stock: ServerHolding.StockRead = !isLoaded || rowChain.startReadFailed ? .unread
                : rowChain.startIncomplete ? .incomplete : .whole
            let show = shows.first(where: { PodcastIdentity.feedKey($0.feedURL) == key })
            let holding = serverHolding(feedKey: key)
            var bridged = true
            if stock == .whole, let show, case .held = holding,
               let serverShow = serverShows().first(where: { PodcastIdentity.feedKey($0.feedURL) == key }) {
                bridged = await handOverStates(of: show, to: serverShow)
            }
            switch ServerHolding.settle(holding, everyStateBridged: bridged, stock: stock, showHere: show != nil) {
            case .noteGoes:
                noteUnchecked(key, false)
                if show == nil {
                    Logger.rss.notice("SETTLE no longer subscribed here, note goes: \(key, privacy: .private(mask: .hash))")
                } else {
                    Logger.rss.notice("SETTLE not on Audiobookshelf, stays here: \(key, privacy: .private(mask: .hash))")
                }
            case .waits:
                if stock != .whole {
                    Logger.rss.notice("SETTLE waits: the subscriptions here are not read whole stock=\(String(describing: stock), privacy: .public) key=\(key, privacy: .private(mask: .hash))")
                }
            case .handOver:
                shows.removeAll { PodcastIdentity.feedKey($0.feedURL) == key }
                // Handed over means gone here, also when it was the only one:
                // the removal is the action of this write.
                save(emptying: .allowed)
                noteUnchecked(key, false)
                Logger.rss.notice("SETTLE held on Audiobookshelf, states handed over, local removed: \(key, privacy: .private(mask: .hash))")
            case .keepsLocal:
                Logger.rss.notice("SETTLE held on Audiobookshelf, a state found no episode there, local kept: \(key, privacy: .private(mask: .hash))")
            }
        }
    }

    /// The local states of `show` handed to the server's episodes of
    /// `serverShow` through the import's bridge. True when every state found
    /// its episode and was decided there (written or kept as newer).
    private func handOverStates(of show: PodcastShow, to serverShow: PodcastShow) async -> Bool {
        let states: [ForeignListeningState] = show.episodes.compactMap { episode in
            guard let entry = ListeningStore.backup(episode.guid, in: defaults) else { return nil }
            let duration = episode.duration > 0 ? episode.duration : nil
            let write = ForeignServerProgress.write(entry, duration: episode.duration)
            return ForeignListeningState(feedURL: show.feedURL, showTitle: show.title,
                                         episodeGUID: PodcastIdentity.originalGuid(episode.guid),
                                         enclosureURL: episode.audioURL.isEmpty ? nil : episode.audioURL,
                                         episodeLink: nil, episodeTitle: episode.title,
                                         position: write.time, duration: duration, finished: write.finished,
                                         stampedAt: entry.count > 1 ? entry[1] : nil)
        }
        guard !states.isEmpty else { return true }
        var result = ImportResult()
        let plan = await applyToServer(ForeignLibrary(feedURLs: [show.feedURL], states: states),
                                       onServer: [PodcastIdentity.feedKey(show.feedURL): serverShow],
                                       run: ForeignRun(), into: &result)
        return plan.unmatched.isEmpty && result.notSent.isEmpty
    }

    /// The shows of `serverShows` that are not subscribed here, by feed key.
    func serverOnlyShows() -> [String: PodcastShow] {
        let local = Set(shows.map { PodcastIdentity.feedKey($0.feedURL) })
        var byKey: [String: PodcastShow] = [:]
        for show in serverShows() where !show.feedURL.isEmpty {
            let key = PodcastIdentity.feedKey(show.feedURL)
            if !local.contains(key), byKey[key] == nil { byKey[key] = show }
        }
        return byKey
    }

    /// The one import for every foreign source: subscribe to each feed,
    /// then hand the states to the one adopter. The caller has already
    /// read and previewed the library.
    ///
    /// A show's states are applied the moment the show is followed, over
    /// the rungs on its own handles; the rest (title, twin, a state without
    /// a show, a show followed only as a twin) waits for the plan over
    /// everything at the end. An abort in between keeps what is done, and a
    /// second run does not fetch the shows it already holds.
    func importForeignLibrary(_ library: ForeignLibrary,
                              progress: @escaping @MainActor (ImportProgress) -> Void = { _ in }) async -> ImportResult {
        var result = ImportResult()
        twinEnclosureBridge = [:]
        let feeds = library.feedURLs
        var statesByFeed: [String: [Int]] = [:]
        for (index, state) in library.states.enumerated() {
            if let feed = state.feedURL { statesByFeed[PodcastIdentity.feedKey(feed), default: []].append(index) }
        }
        let run = ForeignRun()
        // Time to finish if the app leaves the screen. When it runs out, the
        // shows in flight finish, no new one starts, and the summary says
        // where it stopped; a second run continues from there.
        let work = backgroundWork.begin("Podcast import") { run.stopped = true }
        defer { backgroundWork.end(work) }
        // Which show lies on Audiobookshelf must be known before any is
        // subscribed here; an unread server is read first, and still
        // unread the import sets out instead of reading "nothing there".
        if !serverShowsRead() { await readServerShows() }
        guard serverShowsRead() else {
            Logger.rss.notice("FOREIGN import set out: Audiobookshelf unread")
            result.serverUnread = true
            return result
        }
        progress(ImportProgress(done: 0, total: feeds.count))
        let onServer = serverOnlyShows()
        let outcomes = await followAll(feeds, onServer: onServer, shouldStop: { run.stopped }) { [self] index, outcome in
            run.done += 1
            progress(ImportProgress(done: run.done, total: feeds.count))
            guard case .followed = outcome else { return }
            let key = PodcastIdentity.feedKey(feeds[index])
            let own = (statesByFeed[key] ?? []).filter { !run.decided.contains($0) }
            guard !own.isEmpty else { return }
            let plan = applyForeignStates(own.map { library.states[$0] }, titleStates: library.states,
                                          steps: [.guid, .enclosure, .link], onlyFeedKey: key,
                                          tally: &run.tally)
            // Decided: every state of this show the plan placed, or reduced
            // onto a placed one. Only what found nothing waits for the end.
            for index in own where !plan.unmatched.contains(library.states[index]) {
                run.decided.insert(index)
            }
        }
        // The summary in source order, each feed by its own answer.
        for (index, feed) in feeds.enumerated() {
            switch outcomes[index] {
            case nil, .notAsked?:
                // Never asked: the system ended the time first, or a sign-in
                // the answer depends on cannot be read now. Not a feed that
                // failed, and not marked; the next run asks it.
                result.notAsked += 1
            case .freeTwin?:
                result.freeTwinsSkipped += 1
            case .onServer(let title)?:
                result.onServer += 1
                result.onServerTitles.append(title)
            case .followed(let title, let wasNew, let episodes)?:
                // A show already followed is refreshed, not imported: the
                // summary must not count it as new. The empty ones are
                // counted here and reported in this summary.
                if episodes == 0 { result.emptyFeeds += 1 }
                if wasNew {
                    result.subscribed += 1
                    result.subscribedTitles.append(title)
                } else {
                    result.alreadySubscribed += 1
                }
            case .notFollowed(let reason, let status)?:
                result.failed += 1
                // Named by the source's title and kept for a retry in "Not
                // followed yet": a feed that did not answer here is not
                // lost, and a later tap asks it again with the full ladder.
                let name = library.feedTitles[feed] ?? URL(string: feed)?.host ?? feed
                result.unreached.append(.init(title: name, reason: reason, status: status))
                let address = normalizedFeedURL(feed)?.absoluteString ?? feed
                markNotFollowed(feedURL: address, reason: reason, status: status)
                Logger.rss.notice("FOREIGN feed not reached reason=\(reason.rawValue, privacy: .public) status=\(status.map(String.init) ?? "-", privacy: .public) feed=\(PodcastIdentity.feedKey(feed), privacy: .private(mask: .hash))")
            }
        }
        result.paidSkipped = library.unimportablePaidCount
        if run.stopped {
            // The plan over everything waits for the run that finishes: it
            // needs every show, and the time is over. What each followed
            // show brought is applied already.
            result.stoppedAt = run.done
            result.progressApplied = run.tally.applied
            result.finishedApplied = run.tally.finished
            result.keptLocal = run.tally.keptLocal
            Logger.rss.notice("FOREIGN import stopped by the system at=\(run.done) of=\(feeds.count) notAsked=\(result.notAsked) applied=\(run.tally.applied)")
        } else {
            guard !library.states.isEmpty else { return result }
            progress(ImportProgress(done: feeds.count, total: feeds.count, matching: true))
            let serverPlan = await applyToServer(library, onServer: onServer, run: run, into: &result)
            applyTheRest(library, run: run, serverPlan: serverPlan, into: &result)
        }
        // Listen log: the import wrote positions past the played threshold.
        // Re-scan the (now-subscribed) shows with full metadata. A
        // targeted rescan, not the one-time backfill flag.
        PodcastListenLog.shared.rescan(shows: shows)
        // The imported states are local truth now; iCloud learns of them
        // here, not at the next launch. Measured on two devices: without
        // this the second device saw nothing until the first was restarted.
        PodcastCloudSync.shared.reconcile()
        return result
    }

    /// The states of the shows subscribed on Audiobookshelf go to its
    /// progress. Matched on the feed's guid and enclosure alone, where a
    /// handle names exactly one episode of the show (the ladder's rule on
    /// every rung); judged by the one conflict rule against the progress
    /// read now; written where the import wins. Every one of these states
    /// is decided here; the returned plan names what found no episode.
    private func applyToServer(_ library: ForeignLibrary, onServer: [String: PodcastShow],
                               run: ForeignRun, into result: inout ImportResult) async -> ForeignStateMatcher.Plan {
        let indices = library.states.indices.filter { index in
            guard !run.decided.contains(index), let feed = library.states[index].feedURL else { return false }
            return onServer[PodcastIdentity.feedKey(feed)] != nil
        }
        guard !indices.isEmpty else {
            Logger.rss.notice("FOREIGN server: no state of a show on Audiobookshelf, shows=\(onServer.count)")
            return .init()
        }
        for index in indices { run.decided.insert(index) }
        // An empty handle is no handle: it would meet every episode
        // without one.
        let states = indices.map { index -> ForeignListeningState in
            var state = library.states[index]
            if state.episodeGUID?.isEmpty == true { state.episodeGUID = nil }
            if state.enclosureURL?.isEmpty == true { state.enclosureURL = nil }
            return state
        }
        let server = serverSide()
        let targets = ForeignServerProgress.targets(shows: Array(onServer.values), handles: server.episodeHandles,
                                                    feedKeyOf: PodcastIdentity.feedKey)
        let plan = ForeignStateMatcher.plan(states: states, targets: targets, steps: [.guid, .enclosure],
                                            feedKeyOf: PodcastIdentity.feedKey)
        guard !plan.matches.isEmpty else { return plan }
        var notSent: [String: Int] = [:]
        var order: [String] = []
        func missed(_ state: ForeignListeningState) {
            let name = state.showTitle ?? state.feedURL.map(PodcastIdentity.feedHost) ?? "?"
            if notSent[name] == nil { order.append(name) }
            notSent[name, default: 0] += 1
        }
        defer { result.notSent = order.map { NotSentGroup(show: $0, count: notSent[$0] ?? 0) } }
        guard let progress = await server.freshEpisodeProgress() else {
            plan.matches.forEach { missed($0.state) }
            Logger.rss.notice("FOREIGN server progress not read, not sent=\(plan.matches.count)")
            return plan
        }
        var durations: [String: Double] = [:]
        for show in onServer.values { for episode in show.episodes { durations[episode.guid] = episode.duration } }
        for match in plan.matches {
            let held = durations[match.targetID] ?? 0
            let duration = held > 0 ? held : (match.state.duration ?? 0)
            let local = progress[match.targetID].map { ForeignServerProgress.entry($0, duration: duration) }
            switch ForeignStateMerge.verdict(local: local, foreign: match.state, duration: duration) {
            case .keep:
                result.keptOnServer += 1
            case .adopt(let entry, _):
                let write = ForeignServerProgress.write(entry, duration: duration)
                do {
                    try await server.writeEpisodeProgress(match.targetID, time: write.time, duration: duration,
                                                          finished: write.finished)
                    result.sentToServer += 1
                    if write.finished { result.sentFinished += 1 }
                } catch {
                    missed(match.state)
                    Logger.rss.error("FOREIGN server write failed: \(FailureReason.of(error), privacy: .public)")
                }
            }
        }
        if result.sentToServer > 0 { _ = await server.freshEpisodeProgress() }
        let (sent, finished, kept) = (result.sentToServer, result.sentFinished, result.keptOnServer)
        Logger.rss.notice("FOREIGN server sent=\(sent) finished=\(finished) kept=\(kept) notSent=\(notSent.values.reduce(0, +)) unmatched=\(plan.unmatched.count)")
        return plan
    }

    /// The plan over everything the per-show steps left, and the summary.
    /// `serverPlan` adds what the server's shows left unplaced.
    private func applyTheRest(_ library: ForeignLibrary, run: ForeignRun, serverPlan: ForeignStateMatcher.Plan,
                              into result: inout ImportResult) {
        let rest = library.states.indices.filter { !run.decided.contains($0) }.map { library.states[$0] }
        var finalPlan = applyForeignStates(rest, titleStates: library.states, tally: &run.tally)
        finalPlan.unmatched += serverPlan.unmatched
        finalPlan.whyUnmatched += serverPlan.whyUnmatched
        let outcome = summarizeForeignStates(final: finalPlan, tally: run.tally)
        result.progressApplied = outcome.applied
        result.finishedApplied = outcome.finished
        result.keptLocal = outcome.keptLocal
        result.nothingToAdopt = outcome.nothingToAdopt
        result.keptKnown = outcome.keptLocal - outcome.nothingToAdopt
        result.unmatched = outcome.unmatched
        result.unmatchedGroups = outcome.unmatchedGroups
        result.lookupGroups = outcome.lookupGroups
        result.lookupAsked = library.lookupAsked
        result.lookupAnswered = library.lookupAnswered
        if library.lookupAsked > 0 {
            let matched = outcome.lookupGroups.reduce(0) { $0 + $1.count }
            Logger.rss.notice("FOREIGN lookup total asked=\(library.lookupAsked) answered=\(library.lookupAnswered) matched=\(matched)")
        }
    }

    /// What an import applied so far, over every call of the adopter.
    struct ForeignTally {
        var applied = 0
        var finished = 0
        var keptLocal = 0
        var steps: [ForeignStateMatcher.Step: Int] = [:]
        var reasons: [ForeignStateMerge.Reason: Int] = [:]
        var keeps: [ForeignStateMerge.Keep: Int] = [:]
        /// The placed states whose handle came from asking the source.
        var lookedUp: [ForeignListeningState] = []
    }

    /// Maps foreign states onto our episodes through the ladder and writes
    /// what the conflict rule admits into `localPosition`, the store the
    /// player uses. The plan carries one state per episode; duplicates in
    /// the source were reduced before the rule, so the file order cannot
    /// change where an episode ends.
    ///
    /// An import calls it in two ways: once per show the moment it
    /// is followed, narrowed to that show and to the rungs on its own
    /// handles, so an abort keeps what was done; and once at the end over
    /// what is left, with every rung. `titleStates` is always the whole
    /// source, so a title the source carries twice never looks unique in a
    /// remainder. The counts run on in `tally`; the caller summarizes.
    private func applyForeignStates(_ states: [ForeignListeningState],
                                    titleStates: [ForeignListeningState],
                                    steps allowed: Set<ForeignStateMatcher.Step> = Set(ForeignStateMatcher.Step.allCases),
                                    onlyFeedKey: String? = nil,
                                    tally: inout ForeignTally) -> ForeignStateMatcher.Plan {
        var targets: [ForeignMatchTarget] = []
        for show in shows {
            let feedKey = PodcastIdentity.feedKey(show.feedURL)
            if let onlyFeedKey, feedKey != onlyFeedKey { continue }
            for episode in show.episodes {
                targets.append(ForeignMatchTarget(
                    id: episode.guid,
                    rawGUID: ForeignStateMatcher.rawGUID(storedGUID: episode.guid),
                    enclosureURL: episode.audioURL,
                    link: episode.link,
                    title: episode.title,
                    feedKey: feedKey))
            }
        }
        let plan = ForeignStateMatcher.plan(states: states, targets: targets,
                                            twinBridge: twinEnclosureBridge,
                                            steps: allowed, titleStates: titleStates,
                                            feedKeyOf: PodcastIdentity.feedKey)
        var updated = shows
        let appliedBefore = tally.applied
        var importedMarks: [String] = []
        var archivedMarks: [String] = []
        // Every local entry is read before the first write. Each position
        // is its own defaults key, and a read right after a write on a
        // domain of tens of thousands of keys cost about 11 ms in the
        // simulator, so
        // alternating the two held the main actor for minutes on a large
        // import. The plan carries one match per episode, so no write
        // below changes an entry read here.
        var locals: [String: [Double]] = [:]
        for match in plan.matches {
            if let entry = ListeningStore.backup(match.targetID, in: defaults) { locals[match.targetID] = entry }
        }
        for match in plan.matches {
            guard let idx = episodeIndex[match.targetID] else { continue }
            tally.steps[match.step, default: 0] += 1
            // A feed without a duration takes the source's, otherwise a
            // finished mark could never be read back as finished.
            if updated[idx.show].episodes[idx.episode].duration <= 0,
               let known = match.state.duration, known > 0 {
                updated[idx.show].episodes[idx.episode].duration = known
            }
            let duration = updated[idx.show].episodes[idx.episode].duration
            let local = locals[match.targetID]
            let adoption: (entry: [Double], reason: ForeignStateMerge.Reason)
            switch ForeignStateMerge.verdict(local: local, foreign: match.state, duration: duration) {
            case .keep(let why):
                tally.keptLocal += 1
                tally.keeps[why, default: 0] += 1
                continue
            case .adopt(let entry, let reason):
                adoption = (entry, reason)
            }
            ListeningStore.store(match.targetID, entry: adoption.entry, in: defaults)
            // The marks: imported keeps it out of the listening time until
            // it is heard here; archived travels back out with an export.
            // Written together after the loop, one write per list.
            importedMarks.append(match.targetID)
            if match.state.archived { archivedMarks.append(match.targetID) }
            tally.applied += 1
            if match.state.finished { tally.finished += 1 }
            tally.reasons[adoption.reason, default: 0] += 1
            #if DEBUG
            // One line per adoption, so a run that adopts where it should
            // not shows the two entries it decided between.
            Logger.rss.debug("FOREIGN adopt \(match.targetID, privacy: .public) reason=\(adoption.reason.rawValue, privacy: .public) local=\(String(describing: local), privacy: .public) foreign=\(match.state.position)/\(match.state.finished)/\(String(describing: match.state.stampedAt), privacy: .public)")
            #endif
        }
        ForeignMarks.markImported(importedMarks, in: defaults)
        ForeignMarks.markArchived(archivedMarks, in: defaults)
        tally.lookedUp += plan.matches.filter(\.state.handleFromLookup).map(\.state)
        if tally.applied > appliedBefore {
            shows = updated
            save()
            reloadProgress()
        }
        return plan
    }

    /// The summary of a whole import: what the final plan left unplaced,
    /// grouped by show, what asking the source gained, and the one log line
    /// over every call of the adopter.
    private func summarizeForeignStates(final plan: ForeignStateMatcher.Plan, tally: ForeignTally)
        -> (applied: Int, finished: Int, keptLocal: Int, nothingToAdopt: Int,
            unmatched: [String], unmatchedGroups: [UnmatchedGroup], lookupGroups: [LookupGroup]) {
        let steps = tally.steps
        let reasons = tally.reasons
        let keeps = tally.keeps
        // What the asking gained: the placed states whose handle came from
        // asking the source for the episode, by show, in match order.
        var lookupCounts: [String: Int] = [:]
        var lookupOrder: [String] = []
        for state in tally.lookedUp {
            let name = state.showTitle ?? state.feedURL.map(PodcastIdentity.feedHost) ?? "?"
            if lookupCounts[name] == nil { lookupOrder.append(name) }
            lookupCounts[name, default: 0] += 1
        }
        let lookupGroups = lookupOrder.map { LookupGroup(show: $0, count: lookupCounts[$0] ?? 0) }
        let unmatched = plan.unmatched.map { $0.episodeTitle ?? $0.enclosureURL ?? $0.episodeLink ?? "?" }
        // The unmatched, grouped by the show the source named, with the
        // ladder's reasons and what the feed carries here. One log line
        // per show, so a preview screenshot and the log tell the same.
        var groups: [String: UnmatchedGroup] = [:]
        var groupOrder: [String] = []
        for (state, why) in zip(plan.unmatched, plan.whyUnmatched) {
            let name = state.showTitle ?? state.feedURL.map(PodcastIdentity.feedHost) ?? "?"
            if groups[name] == nil {
                var group = UnmatchedGroup(show: name)
                if let feedURL = state.feedURL,
                   let show = shows.first(where: { PodcastIdentity.feedKey($0.feedURL) == PodcastIdentity.feedKey(feedURL) }) {
                    group.feedEpisodes = show.episodes.count
                    group.oldestInFeed = show.episodes.map(\.pubDate).filter { $0 > 0 }.min()
                }
                groups[name] = group
                groupOrder.append(name)
            }
            groups[name]?.count += 1
            groups[name]?.reasons[why, default: 0] += 1
            if let title = state.episodeTitle, (groups[name]?.titles.count ?? 0) < 40 {
                groups[name]?.titles.append(title)
            }
        }
        let unmatchedGroups = groupOrder.compactMap { groups[$0] }
        for group in unmatchedGroups {
            let reasonLine = ForeignStateMatcher.UnmatchedReason.allCases
                .map { "\($0.rawValue)=\(group.reasons[$0] ?? 0)" }.joined(separator: " ")
            let oldest = group.oldestInFeed.map { Date(timeIntervalSince1970: $0 / 1000).formatted(.iso8601.year().month().day()) } ?? "none"
            Logger.rss.notice("FOREIGN unmatched show=\(PodcastIdentity.stableHash(group.show), privacy: .public) states=\(group.count) feedEpisodes=\(group.feedEpisodes) oldestInFeed=\(oldest, privacy: .public) \(reasonLine, privacy: .public) title=\(group.show, privacy: .private)")
        }
        let rungs = ForeignStateMatcher.Step.allCases.map { "\($0.rawValue)=\(steps[$0] ?? 0)" }.joined(separator: " ")
        let why = ForeignStateMerge.Reason.allCases.map { "\($0.rawValue)=\(reasons[$0] ?? 0)" }.joined(separator: " ")
        // The kept states by reason: "knew better" is only three of the
        // four, and on a fresh device those three must read zero.
        let keptWhy = ForeignStateMerge.Keep.allCases.map { "\($0.rawValue)=\(keeps[$0] ?? 0)" }.joined(separator: " ")
        Logger.rss.notice("FOREIGN import: applied=\(tally.applied) finished=\(tally.finished) \(rungs, privacy: .public) \(why, privacy: .public) localKept=\(tally.keptLocal) \(keptWhy, privacy: .public) unmatched=\(unmatched.count)")
        return (tally.applied, tally.finished, tally.keptLocal, keeps[.nothingToAdopt] ?? 0,
                unmatched, unmatchedGroups, lookupGroups)
    }

    /// Make enclosure URLs comparable: drop query & scheme, lowercase, trim /.
    nonisolated static func normalizeEnclosure(_ raw: String) -> String {
        ForeignStateMatcher.normalizeEnclosure(raw)
    }

    /// Adopt the real asset duration measured by the player. Feeds often omit
    /// or round `itunes:duration`, and without a duration the played/remaining
    /// state cannot be derived. Persisted so lists and play-state math work
    /// from then on.
    /// The latest known length of an episode. After playback the one MEASURED
    /// from the asset, otherwise the one the feed claims. The two diverge when
    /// ad slots are announced but left empty, so whoever writes "played" takes
    /// the same number as whoever reads it later.
    func episodeDuration(guid: String) -> Double? {
        guard let idx = episodeIndex[guid] else { return nil }
        let value = shows[idx.show].episodes[idx.episode].duration
        return value > 0 ? value : nil
    }

    func updateEpisodeDuration(guid: String, duration: Double) {
        guard duration > 0, duration.isFinite, let idx = episodeIndex[guid] else { return }
        guard abs(shows[idx.show].episodes[idx.episode].duration - duration) > 1
                || shows[idx.show].episodes[idx.episode].measuredDuration == nil else { return }
        // Into BOTH fields: `duration` stays the best known length for every
        // reader, `measuredDuration` is the store fact the merge carries
        // across the next refresh.
        shows[idx.show].episodes[idx.episode].duration = duration
        shows[idx.show].episodes[idx.episode].measuredDuration = duration
        save()
    }

    /// Reload all feeds (pull-to-refresh). Failed ones keep their cached state.
    func refreshAll() async {
        // NEVER mutate before the disk load. The BGAppRefresh
        // cold start hit exactly this window and wiped the store.
        await ensureLoaded()
        // TF bib-toggles: RSS source off (podcast tab ∧ RSS toggle) → no feed
        // fetches from any caller (background refresh, tab load, pull-to-refresh).
        // THE one gate for the bulk RSS refresh; deliberate user actions
        // (subscribe/preview) stay ungated.
        guard AppStorageKeys.rssActive else { return }
        var updated = shows
        for (index, show) in shows.enumerated() {
            var feedCount: Int?
            var status: Int?
            let url = PodcastFeedAddress.requestURL(show.feedURL)
            let outcome: FeedFetchOutcome? = if let url { await fetchForRefresh(url) } else { nil }
            if let outcome { noteRefusal(show, outcome) }
            if case .status(let code)? = outcome { status = code }
            if case .show(let fresh)? = outcome {
                feedCount = fresh.episodes.count
                // Never shrink on a single weak fetch: a parse that returns a
                // valid title but far fewer episodes (server hiccup, empty but
                // valid <channel>) would otherwise wipe the cached episode list.
                // Union keeps everything; more episodes still add normally.
                #if DEBUG
                if fresh.episodes.count * 2 < show.episodes.count {
                    Logger.rss.debug("RSS refresh shrank \(show.title, privacy: .public): cached=\(show.episodes.count) fresh=\(fresh.episodes.count) → union keeps the cache")
                }
                #endif
                updated[index] = PodcastIdentity.merge(show, fresh)
            }
            // Counted per show, so two devices holding a different number of
            // episodes of one show can be read side by side: what the stock
            // held, what the feed carried, what the union made. No count
            // takes an episode out of a show. Numbers and the show's hash,
            // never an address.
            let unasked = if case .accessUnknown? = outcome { true } else { false }
            Logger.rss.notice("PODCAST refresh show=\(show.id, privacy: .private(mask: .hash)) stock=\(show.episodes.count) feed=\(feedCount.map(String.init) ?? (unasked ? "unasked" : "failed"), privacy: .public) status=\(status ?? 0) merged=\(updated[index].episodes.count)")
        }
        shows = updated
        save()
        healStoredProgress()
        // A paid show whose refusal is now lasting looks for its free twin,
        // once; the notice asks the person only when one is known.
        for show in shows where isAccessRefused(show) {
            await lookForFreeTwin(show)
        }
        // The co-listened feeds ride in the same refresh, after the
        // subscriptions, under the same gate; never persisted like one.
        // Only for the app's store: they are the app's, and a store built
        // for a test must not reach the network.
        if isTheApp { await CoListenedShows.refresh() }
    }

    /// The refresh's fetch. A test replaces the network with
    /// `_testFeedFetcher`, the same seam `subscribe` uses, so a refresh can be
    /// driven and its publishes counted without a server.
    private func fetchForRefresh(_ url: URL) async -> FeedFetchOutcome {
        if let fetcher = _testFeedFetcher { return await fetcher(url) }
        return await Self.fetchOutcome(feedURL: url)
    }

    /// One refresh answer into the feed's refusal record. The status
    /// is read through the one table of meanings; the show learns of a
    /// lasting refusal only through `refusedFeedKeys`.
    private func noteRefusal(_ show: PodcastShow, _ outcome: FeedFetchOutcome) {
        let answer: FeedRefusal.Answer
        switch outcome {
        case .show: answer = .success
        case .status(let code): answer = FeedRefusal.answer(status: code)
        case .failed, .accessUnknown: answer = .other
        }
        let key = PodcastIdentity.feedKey(show.feedURL)
        let wasRecorded = FeedRefusal.all(defaults: defaults)[key] != nil
        let record = FeedRefusal.note(feedKey: key, answer, now: clock(), defaults: defaults)
        // The feed answers again: the search and the No belonged to that
        // refusal, a later one starts clean.
        if wasRecorded, record == nil { forgetFreeTwinSearch(show.id) }
        if case .refused = answer {
            Logger.rss.notice("PODCAST refused show=\(show.id, privacy: .private(mask: .hash)) status=\(record?.status ?? 0) inRow=\(record?.count ?? 0) lasting=\(FeedRefusal.isLasting(record))")
        }
        let lasting = FeedRefusal.lasting(defaults: defaults)
        if lasting != refusedFeedKeys { refusedFeedKeys = lasting }
    }

    private func forgetFreeTwinSearch(_ showId: String) {
        var searched = defaults.dictionary(forKey: AppStorageKeys.podcastFreeTwinSearched) as? [String: [String]] ?? [:]
        var declined = defaults.stringArray(forKey: AppStorageKeys.podcastFreeTwinDeclined) ?? []
        guard searched[showId] != nil || declined.contains(showId) else { return }
        searched[showId] = nil
        declined.removeAll { $0 == showId }
        defaults.set(searched, forKey: AppStorageKeys.podcastFreeTwinSearched)
        defaults.set(declined, forKey: AppStorageKeys.podcastFreeTwinDeclined)
        freeTwinRevision += 1
    }

    /// One fresh fetch of ONE show, after the person gave it a new sign-in:
    /// a success clears the refusal at once instead of at the next refresh.
    func recheckAccess(showId: String) async {
        await ensureLoaded()
        guard let show = shows.first(where: { $0.id == showId }),
              let url = PodcastFeedAddress.requestURL(show.feedURL) else { return }
        let outcome = await fetchForRefresh(url)
        noteRefusal(show, outcome)
        if case .show(let fresh) = outcome, let index = shows.firstIndex(where: { $0.id == showId }) {
            shows[index] = PodcastIdentity.merge(shows[index], fresh)
            save()
        }
    }

    /// Give the EXISTING stock the reference point it was written without.
    ///
    /// The repair rode inside the gpodder pull. And that pull is incremental:
    /// it only sees episodes with a fresh server action. A stock that was
    /// imported once and never touched again carries a timestamp far older
    /// than any `since`, so the repair never reached a single one of those
    /// entries. Measured on a real device: about eighty finished episodes, not
    /// one of them with a reference point. They read correctly today only
    /// because no duration has grown yet. The day one does, they all fall
    /// back to "started" at once, and then nobody can heal them any more.
    ///
    /// So the pass runs over the LOCAL stock, where the feed durations already
    /// are, and it runs after every refresh: it is a few reads per episode, it
    /// is a no-op on entries that already carry their duration, and a marker
    /// would miss the episodes whose duration only appears in the feed later.
    private func healStoredProgress() {
        let writes = PodcastProgressHealing.writes(
            for: allEpisodes().map {
                PodcastProgressHealing.Episode(guid: $0.episode.guid, duration: $0.episode.duration)
            },
            stored: { ListeningStore.backup($0, in: self.defaults) })
        for (guid, entry) in writes {
            ListeningStore.store(guid, entry: entry, in: defaults)
        }
        if !writes.isEmpty {
            Logger.rss.notice("PODCAST healed \(writes.count) stored entries with the duration they were written against")
        }
    }

    // MARK: - Queries for the provider

    /// All episodes of all shows, newest first (cached. Otherwise re-sorted
    /// several times per render).
    func allEpisodes() -> [(show: PodcastShow, episode: PodcastEpisode)] {
        if let cached = cachedAllEpisodes { return cached }
        let all = shows.flatMap { show in show.episodes.map { (show: show, episode: $0) } }
            .sorted { $0.episode.pubDate > $1.episode.pubDate }
        cachedAllEpisodes = all
        return all
    }

    /// O(1) lookup via the guid index.
    func episode(guid: String) -> (show: PodcastShow, episode: PodcastEpisode)? {
        guard let (s, e) = episodeIndex[guid],
              s < shows.count, e < shows[s].episodes.count else { return nil }
        return (shows[s], shows[s].episodes[e])
    }

    // MARK: - Persistenz

    /// Persist the current store (serialized, off-main. See `persist`). The
    /// old implementation encoded and wrote the whole JSON synchronously on the
    /// main actor: a visible hitch on subscribe/refresh/import.
    /// `emptying` is `.refused` for every path but the person's own
    /// unsubscribe and a show handed over to Audiobookshelf.
    private func save(emptying: RowEmptying = .refused, also: [SQLiteConnection.Statement] = []) {
        // The central funnel. Persisting before the bootstrap
        // finished would write the still-empty RAM state over the good file
        // (the cold-start BGAppRefresh race). The mutation stays in RAM; the
        // callers below additionally await ensureLoaded() so this stays a
        // last-resort trap, not the working path.
        guard isLoaded else {
            Logger.rss.error("SUBSTORE save SKIPPED before bootstrap (cold-start race trapped)")
            return
        }
        persist(emptying: emptying, also: also) { [weak self] in self?.shows }
    }

    private func normalizedFeedURL(_ raw: String) -> URL? {
        PodcastFeedAddress.requestURL(raw)
    }

    // MARK: - Loading + Parsing

    // `@concurrent`: force this off the caller's executor. Under the project's
    // default MainActor isolation + NonisolatedNonsendingByDefault a plain
    // `nonisolated async` would run the network wait AND the XML parse on the
    // calling MainActor (callers at :284/:436 are main-actor). The parse is CPU
    // work that must not block the UI.
    /// Fetch + parse a feed WITHOUT persisting anything. The temporary
    /// show preview uses this; `subscribe` persists the result.
    @concurrent nonisolated static func fetchAndParse(feedURL rawURL: URL) async -> PodcastShow? {
        guard case .show(let show) = await fetchOutcome(feedURL: rawURL) else { return nil }
        return show
    }

    /// The same fetch, with the reason for a miss: the adoption path
    /// tells a sign-in demand from an outage. A channel block it finds is
    /// noted in the app's domain: this runs off the main actor without a
    /// store (`UserDefaults` cannot be sent here), and a store built for a
    /// test fetches through `_testFeedFetcher`, never through this.
    @concurrent nonisolated static func fetchOutcome(feedURL rawURL: URL,
                                                     patience: FeedFetchPatience = .patient) async -> FeedFetchOutcome {
        // THE funnel for every feed request. The rule sits here so a call
        // site that builds its own URL cannot get cleartext past it.
        let feedURL = PodcastFeedAddress.upgraded(rawURL)
        // Private/premium feeds: send the Basic auth header if stored. A
        // stored sign-in that cannot be read now is not asked without it:
        // the feed would refuse, and the refusal would count against an
        // access that is there.
        var request = URLRequest(url: feedURL)
        switch PodcastFeedAuth.access(feedKey: PodcastIdentity.feedKey(feedURL.absoluteString)) {
        case .unknown:
            return .accessUnknown
        case .present(let user, let password):
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        case .absent:
            break
        }
        // A bulk run waits a short silence, once. The value on the request
        // beats the session's 20 s.
        if let silence = patience.silenceLimit { request.timeoutInterval = silence }
        // Feed pulls ride the same retry policy as the ABS/Subsonic
        // clients (transient backoff, 401 probe for private feeds); a non-2xx
        // that survives the policy stays a miss like before, with its status.
        let data: Data
        let http: HTTPURLResponse?
        do {
            (data, http) = try await RequestRetryPolicy.fetch(request, once: patience.asksOnce)
        } catch let error as URLError where error.code == .timedOut {
            return .failed(.timeout)
        } catch {
            return .failed(.unreachable)
        }
        if let status = http?.statusCode, !(200...299).contains(status) { return .status(status) }
        // The channel-level block tag travels with the feed.
        // Record it while we hold the bytes (no second request). Only a
        // POSITIVE finding is stored; an unreadable/short body must not
        // clear an earlier one.
        let head = String(decoding: data.prefix(FeedArtworkLookup.headByteCount), as: UTF8.self)
        if PodcastFeedBlock.isBlocked(feedHead: head) {
            noteFeedBlocked(feedURL.absoluteString)
        }
        let parser = RSSFeedParser(feedURL: feedURL.absoluteString)
        guard let show = parser.parse(data) else { return .failed(.unreadable) }
        return .show(show)
    }
}

/// What a feed fetch came back with. The reason of a miss matters to the
/// adoption path only; every other caller reads it as "no show".
nonisolated enum FeedFetchOutcome {
    case show(PodcastShow)
    /// A non-2xx answer that survived the retry policy.
    case status(Int)
    /// Transport failure (timeout, unreachable) or an unparseable body.
    case failed(FeedAdoptionPending.Reason)
    /// Not asked: the feed's stored sign-in cannot be read now
    /// (`PodcastFeedAuth.Access.unknown`). Says nothing about the feed.
    case accessUnknown
}

/// How long a feed fetch may wait. A person asking for ONE feed waits the
/// whole ladder. A run over many feeds asks once, briefly, and names the
/// feeds that stay silent: dead feeds held a hundred-show import for
/// minutes, about a minute each, one after the other.
nonisolated enum FeedFetchPatience: Equatable, Sendable {
    case patient
    case bulk

    /// Silence between two packets that ends a bulk fetch. Chosen, not
    /// measured. It measures silence, not the whole transfer, so a large
    /// live feed that keeps sending still arrives.
    static let bulkSilence: TimeInterval = 8
    /// How many feeds a bulk run fetches at the same time.
    static let bulkWidth = 4

    var silenceLimit: TimeInterval? { self == .bulk ? Self.bulkSilence : nil }
    var asksOnce: Bool { self == .bulk }
}

/// Minimal RSS/Atom parser based on `XMLParser`. Covers the iTunes podcast
/// fields; unknown tags are ignored, broken items skipped. Internal (not
/// private). Covered by unit tests. `nonisolated`: pure CPU parsing, driven
/// off the main actor from `fetchAndParse` (@concurrent) and from tests.
nonisolated final class RSSFeedParser: NSObject, XMLParserDelegate {
    private let feedURL: String
    /// Stable, deterministic feed key (NOT `String.hashValue`, which is
    /// re-seeded per app start). Basis for show id and guids.
    private let feedKey: String
    init(feedURL: String) {
        self.feedURL = feedURL
        self.feedKey = PodcastIdentity.feedKey(feedURL)
    }

    private var showTitle = ""
    private var showAuthor: String?
    private var showImage: String?
    private var showDescription: String?
    // Show-Metadaten (Podcasting 2.0 / iTunes)
    private var showCategories: [String] = []
    private var showLink: String?
    private var showLanguage: String?
    private var showExplicit: Bool?
    private var showFunding: [PodcastFunding] = []
    private var showOwner: String?
    private var showType: String?
    private var pendingFundingURL: String?

    private var episodes: [PodcastEpisode] = []
    /// Guids already emitted. Duplicate-guid items are dropped in-parse.
    private var seenGuids: Set<String> = []
    private var inItem = false
    /// Whether the parser is inside the RSS channel image right now (`<image><url>…</url></image>`).
    private var inChannelImage = false
    private var text = ""
    /// The FIRST element of the document. A server can answer
    /// HTTP 200 with well-formed XML that is not a feed at all. Measured:
    /// podcastle.org/feed/podcast/ returned `<error><title>Database Error`,
    /// out of which this parser happily built a subscribable "show". Well-
    /// formedness is not feed-ness, so the root decides.
    private var rootElement: String?

    // The current item
    private var iTitle = "", iGuid = "", iAudio = "", iDuration = "", iDesc = "", iImage = "", iPubDate = "", iChapters = ""
    /// `dc:date`/`updated` of the current item. Only used when the item has no `pubDate`.
    private var iDateFallback = ""
    private var iSeason: Int?, iEpisodeNum: Int?, iEpisodeType = "", iExplicit: Bool?, iLink = "", iTranscript = ""
    private var iPersons: [PodcastPerson] = []
    private var pendingPersonAttrs: [String: String]?

    /// Roots a feed may legitimately have: RSS 2.0, Atom, RDF-flavoured RSS 1.0.
    private static let feedRoots: Set<String> = ["rss", "feed", "rdf:RDF", "RDF"]

    func parse(_ data: Data) -> PodcastShow? {
        let signpost = PerfSignpost.feedParse()
        defer { signpost.end() }
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        // Not a feed root ⇒ not a feed. No show is constructed from an
        // error page, however well-formed it is.
        guard let root = rootElement, Self.feedRoots.contains(root) else { return nil }
        // A "show" without a single episode AND without
        // artwork is not a show. Other 200-with-garbage shapes exist that a
        // root check alone would pass.
        guard !episodes.isEmpty || showImage != nil else { return nil }
        guard !showTitle.isEmpty || !episodes.isEmpty else { return nil }
        return PodcastShow(
            id: "feed:\(feedKey)",
            title: showTitle.isEmpty ? feedURL : showTitle,
            author: showAuthor,
            artworkURL: showImage,
            description: showDescription,
            feedURL: feedURL,
            episodes: episodes,
            categories: showCategories.isEmpty ? nil : showCategories,
            link: showLink,
            language: showLanguage,
            explicit: showExplicit,
            funding: showFunding.isEmpty ? nil : showFunding,
            owner: showOwner,
            showType: showType
        )
    }

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attrs: [String: String]) {
        if rootElement == nil { rootElement = qName ?? el }
        text = ""
        if el == "item" || el == "entry" {
            inItem = true
            iTitle = ""; iGuid = ""; iAudio = ""; iDuration = ""; iDesc = ""; iImage = ""; iPubDate = ""; iChapters = ""; iDateFallback = ""
            iSeason = nil; iEpisodeNum = nil; iEpisodeType = ""; iExplicit = nil; iLink = ""; iTranscript = ""
            iPersons = []
        }
        // Podcasting 2.0 chapters: JSON URL in the item (use JSON type only).
        if el == "podcast:chapters", let url = attrs["url"],
           (attrs["type"]?.contains("json") ?? true) {
            iChapters = url
        }
        // Transcript (the first URL is enough).
        if el == "podcast:transcript", inItem, iTranscript.isEmpty, let url = attrs["url"] {
            iTranscript = url
        }
        // Person (name follows as text content). Remember the attributes now.
        if el == "podcast:person" { pendingPersonAttrs = attrs }
        // Funding (label follows as text). Remember the URL.
        if el == "podcast:funding" { pendingFundingURL = attrs["url"] }
        // Categories (also nested: parent + child both fire).
        if el == "itunes:category", !inItem, let cat = attrs["text"], !showCategories.contains(cat) {
            showCategories.append(cat)
        }
        // Enclosure (RSS). Acceptance incl. video/octet-stream, see
        // `acceptsEnclosure`. Without it Podsync feeds parse empty.
        if el == "enclosure", let url = attrs["url"],
           Self.acceptsEnclosure(type: attrs["type"], url: url) {
            iAudio = Self.resolved(url, against: feedURL)
        }
        // itunes:image / channel image via href attribute, resolved against
        // the feed base. Relative artwork URLs occur in the wild.
        if el == "itunes:image", let href = attrs["href"] {
            let resolved = Self.resolved(href, against: feedURL)
            if inItem { iImage = resolved } else if showImage == nil { showImage = resolved }
        }
        // A feed can name its image TWICE and this reader found neither. It
        // did not read the RSS form `<image><url>…</url></image>` at all, and
        // the itunes form WITHOUT `href` (the URL as element text) fell
        // through because the attribute is empty. `FeedArtworkLookup` already
        // understood the RSS form: two readers, one spelling, one of them
        // knows more.
        //
        // INVARIANT: a spelling the app understands in ONE place, it
        // understands everywhere.
        if el == "image", !inItem { inChannelImage = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The two spellings this reader did not know.
        if el == "image", !inItem { inChannelImage = false }
        if el == "url", inChannelImage, !inItem, showImage == nil, !value.isEmpty {
            showImage = Self.resolved(value, against: feedURL)
        }
        if el == "itunes:image", !value.isEmpty {
            let resolved = Self.resolved(value, against: feedURL)
            if inItem { if iImage.isEmpty { iImage = resolved } }
            else if showImage == nil { showImage = resolved }
        }
        // Closing a person (name = text content). Possible in item and channel.
        if el == "podcast:person", let a = pendingPersonAttrs, !value.isEmpty {
            let person = PodcastPerson(name: value, role: a["role"], img: a["img"], href: a["href"])
            if inItem { iPersons.append(person) }
            pendingPersonAttrs = nil
        }
        if el == "podcast:funding", !inItem, let url = pendingFundingURL {
            showFunding.append(PodcastFunding(url: url, label: value.isEmpty ? nil : value))
            pendingFundingURL = nil
        }
        if inItem {
            switch el {
            case "title": iTitle = value
            case "guid", "id": if iGuid.isEmpty { iGuid = value }
            case "itunes:duration": iDuration = value
            case "description", "itunes:summary", "content:encoded": if iDesc.isEmpty { iDesc = value }
            // `dc:date` (Dublin Core) and Atom's `updated` carry the date in
            // feeds that never write `pubDate`. Without them every episode of
            // such a feed got date 0. `pubDate`/`published` still WIN: the
            // first non-empty one stays, so a feed carrying both keeps its
            // publication date instead of its last edit.
            case "pubDate", "published": iPubDate = value
            // `dc:date` (Dublin Core) and Atom's `updated` carry the date in
            // feeds that never write `pubDate`. Kept APART instead of into the
            // same slot: the order of elements inside an item is not
            // guaranteed, so „first one wins" would let the edit date beat the
            // publication date in a feed that carries both. The choice is made
            // where the episode is built, not where the text arrives.
            case "dc:date", "updated": iDateFallback = value
            case "itunes:season": iSeason = Int(value)
            case "itunes:episode": iEpisodeNum = Int(value)
            case "itunes:episodeType": iEpisodeType = value.lowercased()
            case "itunes:explicit": iExplicit = Self.parseExplicit(value)
            case "link": if iLink.isEmpty { iLink = value }
            case "item", "entry":
                inItem = false
                // Duplicate guids collapse HERE (first item wins. Feeds
                // list newest first); duplicates used to survive the first
                // subscribe and collide as SwiftUI ids.
                // Items WITHOUT an audio
                // enclosure are KEPT. Dimmed, no play affordance, tap opens
                // the show notes (Apple-Podcasts behaviour). Text-only feeds
                // no longer look empty/broken. Identity falls back to the
                // link, then the title (an item with none of guid/audio/link/
                // title has no stable identity and is skipped).
                let fallbackId = iGuid.isEmpty ? (iAudio.isEmpty ? (iLink.isEmpty ? iTitle : iLink) : iAudio) : iGuid
                let guid = "rss:\(feedKey):\(fallbackId)"
                if !fallbackId.isEmpty, seenGuids.insert(guid).inserted {
                    episodes.append(PodcastEpisode(
                        guid: guid,
                        title: iTitle.isEmpty ? String(localized: "Untitled Episode") : iTitle,
                        audioURL: iAudio,
                        pubDate: Self.parseDate(iPubDate.isEmpty ? iDateFallback : iPubDate),
                        duration: Self.parseDuration(iDuration),
                        description: iDesc.isEmpty ? nil : iDesc,
                        imageURL: iImage.isEmpty ? nil : iImage,
                        chaptersURL: iChapters.isEmpty ? nil : iChapters,
                        season: iSeason,
                        episodeNumber: iEpisodeNum,
                        episodeType: iEpisodeType.isEmpty ? nil : iEpisodeType,
                        explicit: iExplicit,
                        link: iLink.isEmpty ? nil : iLink,
                        transcriptURL: iTranscript.isEmpty ? nil : iTranscript,
                        persons: iPersons.isEmpty ? nil : iPersons
                    ))
                }
            default: break
            }
        } else {
            switch el {
            case "title": if showTitle.isEmpty { showTitle = value }
            case "itunes:author": showAuthor = value
            case "description", "itunes:summary": if showDescription == nil { showDescription = value }
            case "link": if showLink == nil, !value.isEmpty { showLink = value }
            case "language": if showLanguage == nil { showLanguage = value }
            case "itunes:explicit": if showExplicit == nil { showExplicit = Self.parseExplicit(value) }
            case "itunes:type": showType = value.lowercased()
            case "itunes:name": if showOwner == nil, !value.isEmpty { showOwner = value }
            default: break
            }
        }
        text = ""
    }

    // MARK: - Pure helpers (unit-tested)

    /// Which enclosures carry playable media. `audio/*` and `video/*`
    /// play directly (AVPlayer takes the audio track of a video enclosure.
    /// Podsync's YouTube→RSS feeds ship `video/mp4`); the very common
    /// `application/octet-stream` lie is accepted when the file extension
    /// looks like media. Missing type keeps counting as audio (prior
    /// behaviour). Everything else (text/html, image/…) is rejected.
    static let mediaExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "ogg", "oga", "opus", "wav", "flac",
        "mp4", "m4v", "mov", "webm",
    ]
    nonisolated static func acceptsEnclosure(type: String?, url: String) -> Bool {
        guard let type, !type.isEmpty else { return true }
        let lower = type.lowercased()
        if lower.hasPrefix("audio") || lower.hasPrefix("video") { return true }
        if lower == "application/octet-stream" {
            let ext = (URL(string: url)?.pathExtension ?? (url as NSString).pathExtension).lowercased()
            return mediaExtensions.contains(ext)
        }
        return false
    }

    /// Resolve a possibly-relative media/artwork URL against the feed
    /// URL. Absolute URLs pass through untouched; unresolvable input is
    /// returned as-is (never worse than before).
    nonisolated static func resolved(_ raw: String, against base: String) -> String {
        guard URL(string: raw)?.scheme == nil else { return raw }
        guard let baseURL = URL(string: base),
              let resolved = URL(string: raw, relativeTo: baseURL) else { return raw }
        return resolved.absoluteString
    }

    // RFC822-Datum → ms epoch (Fallback: 0). The wild also ships the
    // weekday-less form and zone NAMES (EST/GMT). One formatter chain,
    // built once (DateFormatter creation is expensive).
    //
    // The seconds are OPTIONAL in RFC 822, and feeds ship both. A date the
    // chain cannot read falls back to 0, and a zero date is not a cosmetic
    // loss: the podcast tab admits a show only when its newest episode has a
    // date, so a feed whose dates are unreadable becomes a subscription that
    // stands in the settings list and is invisible in the tab, WITH its
    // episode count. That is why this chain is wider than it looks.
    private static let dateFormatters: [DateFormatter] = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss zzz",
        "EEE, dd MMM yyyy HH:mm Z",
        "dd MMM yyyy HH:mm Z",
        "EEE, dd MMM yyyy HH:mm zzz",
        "dd MMM yyyy HH:mm zzz",
    ].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static func parseDate(_ s: String) -> Double {
        for f in dateFormatters {
            if let d = f.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        }
        if let d = ISO8601DateFormatter().date(from: s) { return d.timeIntervalSince1970 * 1000 }
        return 0
    }

    /// `itunes:explicit`: true/yes/explicit → true, false/no/clean → false, else nil.
    private static func parseExplicit(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "yes", "explicit": return true
        case "false", "no", "clean": return false
        default: return nil
        }
    }

    // "HH:MM:SS", "MM:SS" or plain seconds → seconds.
    private static func parseDuration(_ s: String) -> Double {
        if s.contains(":") {
            let parts = s.split(separator: ":").compactMap { Double($0) }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        return Double(s) ?? 0
    }
}
