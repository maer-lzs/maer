// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing) && DEBUG
import Testing
import Foundation
@testable import Maer

/// The standby follows the fresh truth WITHOUT an app restart. The
/// transitions, not the end states (the start path was already proven).
@MainActor
struct StandbyLiveRefreshTests {

    private func item(_ id: String) -> LibraryItem {
        LibraryItem(id: id, media: media(id), addedAt: nil)
    }
    private func detail(_ id: String) -> LibraryItemDetail {
        LibraryItemDetail(id: id, media: media(id), userMediaProgress: nil)
    }
    private func media(_ title: String) -> LibraryItemMedia {
        LibraryItemMedia(
            metadata: LibraryItemMetadata(title: title, authorName: nil, narratorName: nil,
                                          seriesName: nil, genres: nil, publishedYear: nil, description: nil),
            duration: 100, chapters: nil, tracks: nil)
    }

    @Test("Das Ende der Leiter: die geholte Folge ist die Folge; die Nachbarin nimmt nur die Wiederherstellung beim Start, nie der Spiegel oder der Play auf den fremden Anspruch")
    func ladderTailNeverTakesANeighbourForTheMirror() {
        let fetched = item("rss:f:wanted")
        let newest = item("rss:f:neighbour")
        // The fetched episode wins over the neighbour on every path.
        let byFeed = PlayerCoordinator.standbyTail(fetched: fetched, showNewest: newest, allowsShowNewest: true)
        #expect(byFeed.0?.id == "rss:f:wanted" && byFeed.1 == "feed")
        // The mirror and the claim play: nothing, said as nothing (E115 red
        // probe: the old chain answered the neighbour here).
        let mirror = PlayerCoordinator.standbyTail(fetched: nil, showNewest: newest, allowsShowNewest: false)
        #expect(mirror.0 == nil && mirror.1 == "none")
        // Only the start restore keeps the rotating-feed fallback.
        let restore = PlayerCoordinator.standbyTail(fetched: nil, showNewest: newest, allowsShowNewest: true)
        #expect(restore.0?.id == "rss:f:neighbour" && restore.1 == "show-newest")
        #expect(PlayerCoordinator.standbyTail(fetched: nil, showNewest: nil, allowsShowNewest: true).1 == "none")
    }

    @Test("Der Zwilling: dieselbe Folge unter anderem Feed-Schluessel, nie sie selbst, nie eine Nachbarin")
    func twinIsTheSameEpisodeUnderAnotherKey() {
        let wanted = "rss:key-ipad:https://example.org/ep/42"
        let guids = ["rss:key-iphone:https://example.org/ep/41",
                     "rss:key-iphone:https://example.org/ep/42",
                     "rss:key-iphone:https://example.org/ep/43",
                     wanted]
        #expect(PodcastSubscriptions.twinEpisodeId(for: wanted, among: guids) == "rss:key-iphone:https://example.org/ep/42")
        #expect(PodcastSubscriptions.twinEpisodeId(for: "rss:key-ipad:https://example.org/ep/99", among: guids) == nil)
        #expect(PodcastSubscriptions.twinEpisodeId(for: "abs:book", among: guids) == nil, "not an rss id")
    }

    @Test("A held pointer that turned finished clears the standby live")
    func heldFinishedClearsLive() async {
        let id = "rss:standby-test:\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            ListeningStore.clearBackup(id, in: defaults)
            defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId)
        }
        let coord = PlayerCoordinator(provider: MockProvider())
        coord._seedActivePlayerForUITest(item: item(id), detail: detail(id),
                                         chapters: [], currentChapterIndex: 0, isFallback: false)
        defaults.set(id, forKey: AppStorageKeys.lastPlayedItemId)
        // Finished by numbers arrives (adopted positions or local finish).
        ListeningStore.store(id, entry: [100.0, 1000.0, 100.0], in: defaults)

        await coord.refreshStandbyFromTruth()

        #expect(coord.activeItem == nil)
        #expect(coord.viewModel == nil)
        #expect(defaults.string(forKey: AppStorageKeys.lastPlayedItemId) == nil)
    }

    /// E83, measured on 29: the iPad's episode was adopted at t, a book
    /// was opened at t+2 s, and the mirror swapped the book against the
    /// episode in the 1.5 s before `play()` (six times in 25 s). An own
    /// open younger than the adopted pointer is this device's session.
    @Test("E83: ein eigenes Oeffnen, juenger als der adoptierte Zeiger, wird nie getauscht")
    func ownOpenYoungerThanForeignPointerIsKept() {
        let verdict = PlayerCoordinator.standbyVerdict(
            stored: "rss:ipad:episode", held: "book-8yKp", isPlaying: false,
            ownOpenedAtMs: 2_000, foreignStampMs: 1_000,
            heldFinished: false, storedFinished: false)
        #expect(verdict == .keep)
        // No stamp at all for the foreign pointer: the own open wins too.
        #expect(PlayerCoordinator.standbyVerdict(
            stored: "rss:ipad:episode", held: "book-8yKp", isPlaying: false,
            ownOpenedAtMs: 2_000, foreignStampMs: nil,
            heldFinished: false, storedFinished: false) == .keep)
    }

    /// The mirror rule stays for real rest: an own open OLDER than the
    /// foreign pointer, paused, follows the fresher truth.
    @Test("Ein aelteres eigenes Oeffnen, pausiert, folgt dem frischeren fremden Zeiger")
    func olderOwnOpenStillFollowsTheMirror() {
        let verdict = PlayerCoordinator.standbyVerdict(
            stored: "rss:ipad:episode", held: "book-8yKp", isPlaying: false,
            ownOpenedAtMs: 1_000, foreignStampMs: 2_000,
            heldFinished: false, storedFinished: false)
        #expect(verdict == .swap("rss:ipad:episode"))
        // Playing stays untouchable whatever the stamps say.
        #expect(PlayerCoordinator.standbyVerdict(
            stored: "rss:ipad:episode", held: "book-8yKp", isPlaying: true,
            ownOpenedAtMs: 1_000, foreignStampMs: 2_000,
            heldFinished: false, storedFinished: false) == .keep)
    }

    /// The coordinator itself: seeded session, own open noted, a foreign
    /// pointer adopted with an OLDER stamp, revision burst: nothing moves.
    @Test("E83 am Koordinator: nach dem eigenen Oeffnen tauscht der Stoss nichts")
    func coordinatorKeepsOwnOpenAgainstOlderForeignPointer() async {
        let own = "rss:standby-test:\(UUID().uuidString)"
        let foreign = "lv:standby-foreign-\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        let stampsBefore = defaults.dictionary(forKey: UserChoiceCloudSync.stampsKey)
        defer {
            defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId)
            if let stampsBefore { defaults.set(stampsBefore, forKey: UserChoiceCloudSync.stampsKey) }
            else { defaults.removeObject(forKey: UserChoiceCloudSync.stampsKey) }
        }
        let coord = PlayerCoordinator(provider: MockProvider())
        coord._seedActivePlayerForUITest(item: item(own), detail: detail(own),
                                         chapters: [], currentChapterIndex: 0, isFallback: false)
        coord.beginOwnSession(item(own), origin: .gesture)
        // The adoption lands after the own open, with the iPad's older event time.
        defaults.set(foreign, forKey: AppStorageKeys.lastPlayedItemId)
        var stamps = defaults.dictionary(forKey: UserChoiceCloudSync.stampsKey) as? [String: Double] ?? [:]
        stamps[AppStorageKeys.lastPlayedItemId] = (coord.ownOpenedAtMs ?? 0) - 5_000
        defaults.set(stamps, forKey: UserChoiceCloudSync.stampsKey)

        await coord.refreshStandbyFromTruth()

        #expect(coord.activeItem?.id == own)
        #expect(coord.viewModel != nil)
    }

    /// Mechanics never note: the mirror's swap and the restore take the
    /// item, leave the pointer, the stamps and `ownOpenedAtMs` alone.
    @Test("Spiegel-Tausch und Wiederherstellung notieren nicht; nur die Geste")
    func onlyAGestureNotes() {
        let foreign = "rss:standby-test:\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        let stampsBefore = defaults.dictionary(forKey: UserChoiceCloudSync.stampsKey)
        defer {
            defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId)
            if let stampsBefore { defaults.set(stampsBefore, forKey: UserChoiceCloudSync.stampsKey) }
            else { defaults.removeObject(forKey: UserChoiceCloudSync.stampsKey) }
        }
        defaults.set(foreign, forKey: AppStorageKeys.lastPlayedItemId)
        let stampsSeen = defaults.dictionary(forKey: UserChoiceCloudSync.stampsKey) as? [String: Double] ?? [:]
        let coord = PlayerCoordinator(provider: MockProvider())
        for origin in [PlayerCoordinator.OpenOrigin.mirror, .restore] {
            coord.beginOwnSession(item("rss:standby-test:own-\(UUID().uuidString)"), origin: origin)
            #expect(coord.ownOpenedAtMs == nil, "\(origin) must not stamp an own open")
            #expect(defaults.string(forKey: AppStorageKeys.lastPlayedItemId) == foreign, "\(origin) must leave the pointer")
            #expect((defaults.dictionary(forKey: UserChoiceCloudSync.stampsKey) as? [String: Double] ?? [:]) == stampsSeen)
        }
        let own = item("rss:standby-test:gesture-\(UUID().uuidString)")
        coord.beginOwnSession(own, origin: .gesture)
        #expect(coord.ownOpenedAtMs != nil)
        #expect(defaults.string(forKey: AppStorageKeys.lastPlayedItemId) == own.id)
    }

    @Test("A PLAYING session is never torn down — it claims instead")
    func playingSessionIsProtected() async {
        let id = "rss:standby-test:\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            ListeningStore.clearBackup(id, in: defaults)
            defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId)
        }
        let coord = PlayerCoordinator(provider: MockProvider())
        coord._seedActivePlayerForUITest(item: item(id), detail: detail(id),
                                         chapters: [], currentChapterIndex: 0, isFallback: false)
        coord.viewModel?.isPlaying = true
        defaults.set(id, forKey: AppStorageKeys.lastPlayedItemId)
        ListeningStore.store(id, entry: [100.0, 1000.0, 100.0], in: defaults)

        await coord.refreshStandbyFromTruth()

        #expect(coord.activeItem?.id == id)   // untouched
        #expect(coord.viewModel != nil)
    }

    @Test("MIRROR: a touched but PAUSED session follows the fresher truth (finish clears)")
    func touchedPausedSessionFollowsTheMirror() async {
        let id = "rss:standby-test:\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            ListeningStore.clearBackup(id, in: defaults)
            defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId)
        }
        let coord = PlayerCoordinator(provider: MockProvider())
        coord._seedActivePlayerForUITest(item: item(id), detail: detail(id),
                                         chapters: [], currentChapterIndex: 0, isFallback: false)
        coord.viewModel?.eventSinceLoad = true   // touched — but paused
        defaults.set(id, forKey: AppStorageKeys.lastPlayedItemId)
        ListeningStore.store(id, entry: [100.0, 1000.0, 100.0], in: defaults)

        await coord.refreshStandbyFromTruth()

        // Finished ⇒ both clear. "both empty" is also
        // "the same piece".
        #expect(coord.activeItem == nil)
        #expect(coord.viewModel == nil)
    }

    @Test("A foreign standby tombstone clears the paused standby live")
    func foreignTombstoneClearsLive() async {
        let id = "rss:standby-test:\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer { defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId) }
        let coord = PlayerCoordinator(provider: MockProvider())
        coord._seedActivePlayerForUITest(item: item(id), detail: detail(id),
                                         chapters: [], currentChapterIndex: 0, isFallback: false)
        defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId)   // adopted tombstone

        await coord.refreshStandbyFromTruth()

        #expect(coord.activeItem == nil)
        #expect(coord.viewModel == nil)
    }

    @Test("A finished FOREIGN pointer is never adopted live (guard parity)")
    func finishedForeignPointerIsNotAdopted() async {
        let id = "rss:standby-test:\(UUID().uuidString)"
        let defaults = UserDefaults.standard
        defer {
            ListeningStore.clearBackup(id, in: defaults)
            defaults.removeObject(forKey: AppStorageKeys.lastPlayedItemId)
        }
        let coord = PlayerCoordinator(provider: MockProvider())
        defaults.set(id, forKey: AppStorageKeys.lastPlayedItemId)
        ListeningStore.store(id, entry: [100.0, 1000.0, 100.0], in: defaults)

        await coord.refreshStandbyFromTruth()

        #expect(coord.activeItem == nil)   // nothing appeared
    }

    @Test("ein Oeffnen, das scheitert, nimmt den gesendeten Standby-Zeiger zurueck")
    func aFailedOpenWithdrawsTheBroadcastPointer() async {
        // Der Zeiger geht am GRIFF hinaus, vor dem Laden: die anderen
        // Geraete sollen von der Uebernahme erfahren, wenn jemand tippt,
        // nicht wenn die Bytes da sind. Scheitert das Oeffnen, zeigte der
        // Standby aller Geraete danach auf einen Titel, der nie lief.
        let before = "abspod:the-one-that-really-played"
        let restore = AppStorageKeys.lastPlayedItemIdValue
        AppStorageKeys.lastPlayedItemIdValue = before
        defer { AppStorageKeys.lastPlayedItemIdValue = restore }

        let coord = PlayerCoordinator(provider: MockProvider())
        // MockProvider wirft beim Detail-Abruf, der Fehlweg ist also der
        // echte Weg dieses Laufs und kein Nachbau.
        await coord.open(item: item("abspod:never-opens"), autoplay: false)

        #expect(coord.activeItem == nil, "der gescheiterte Titel steht nicht als aktiv")
        #expect(AppStorageKeys.lastPlayedItemIdValue == before,
                "der Zeiger sagt wieder, was er vorher sagte")
    }

    @Test("eine ueberholende Geste macht den ueberholten Titel nicht zum 'was vorher stand'")
    func anOvertakingGestureDoesNotBecomeTheFallback() {
        // A lief wirklich. Eine Geste auf B verschiebt den Zeiger, eine
        // Geste auf C ueberholt B, C scheitert. Zurueck muss A, nicht B:
        // B hat nie gespielt, es wurde nur angetippt.
        let played = "abspod:A-really-played"
        let restore = AppStorageKeys.lastPlayedItemIdValue
        AppStorageKeys.lastPlayedItemIdValue = played
        defer { AppStorageKeys.lastPlayedItemIdValue = restore }

        let coord = PlayerCoordinator(provider: MockProvider())
        coord.beginOwnSession(item("abspod:B-tapped"), origin: .gesture)
        coord.beginOwnSession(item("abspod:C-overtakes"), origin: .gesture)
        coord.withdrawOwnSession()

        #expect(AppStorageKeys.lastPlayedItemIdValue == played,
                "zurueck kommt der Titel, der wirklich lief")
    }

    @Test("der gelungene Weg ruft die Bestaetigung wirklich auf")
    func theSuccessfulPathCallsTheConfirmation() throws {
        // Der Fall darunter treibt confirmOwnSession() selbst und belegt
        // damit die METHODE, nicht ihre Verdrahtung: eine Rot-Probe, die
        // den Aufruf aus dem Erfolgsweg entfernt, blieb gruen. Fahren laesst
        // sich der Erfolgsweg hier nicht, er baut einen Spieler. Also am
        // Quelltext, und damit faellt wenigstens auf, wenn er verschwindet.
        let file = try #require(ProjectFileIntegrityTests.sourceFiles()
            .first { $0.lastPathComponent == "PlayerCoordinator.swift" })
        let calls = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("//") && trimmed == "confirmOwnSession()"
            }
        #expect(calls.count == 1, "genau ein Aufruf im Erfolgsweg, gezaehlt: \(calls.count)")
    }

    @Test("nach einem gelungenen Oeffnen gibt es nichts mehr zurueckzunehmen")
    func a_successful_open_leaves_nothing_to_withdraw() {
        let played = "abspod:A-really-played"
        let restore = AppStorageKeys.lastPlayedItemIdValue
        AppStorageKeys.lastPlayedItemIdValue = played
        defer { AppStorageKeys.lastPlayedItemIdValue = restore }

        let coord = PlayerCoordinator(provider: MockProvider())
        coord.beginOwnSession(item("abspod:B-opens"), origin: .gesture)
        coord.confirmOwnSession()
        coord.withdrawOwnSession()

        #expect(AppStorageKeys.lastPlayedItemIdValue == "abspod:B-opens",
                "der gelungene Titel bleibt stehen, die Ruecknahme greift ins Leere")
    }
}
#endif
