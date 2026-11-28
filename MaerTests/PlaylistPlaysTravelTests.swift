// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// When an own list was last heard travels like the last-heard stations:
/// one statement per list, `playlistPlay.<id>`, its time the moment. Both
/// devices keep the newest fifty of both; a statement this build cannot
/// read is passed over. Start reads its rows again when a moment changes
/// here or arrives from the other device.
@MainActor
@Suite(.serialized)
struct PlaylistPlaysTravelTests {
    private func device(_ cloud: UserChoiceFakeCloud, now: Double)
        -> (sync: UserChoiceCloudSync, defaults: UserDefaults, suite: String) {
        let suite = "plays-travel-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var clock = now
        let sync = UserChoiceCloudSync(defaults: defaults, cloud: cloud, syncEnabled: { true },
                                       now: { clock += 1; return clock }, idFormSettled: { true })
        return (sync, defaults, suite)
    }

    private func cleanup(_ suite: String) {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    private func blob(_ cloud: UserChoiceFakeCloud) -> [String: Any] {
        cloud.storage[UserChoiceCloudSync.blobKey] as? [String: Any] ?? [:]
    }

    private func statement(_ cloud: UserChoiceFakeCloud, _ id: String) -> UserChoiceEntry? {
        UserChoiceEntry.from(plist: blob(cloud)[UserChoiceCatalog.playlistPlayPrefix + id])
    }

    /// What another device left in the document.
    private func put(_ cloud: UserChoiceFakeCloud, _ key: String, _ entry: UserChoiceEntry) {
        var document = blob(cloud)
        document[key] = entry.plist
        cloud.storage[UserChoiceCloudSync.blobKey] = document
    }

    private func setMoments(_ moments: [String: Double], in defaults: UserDefaults) {
        defaults.set(moments, forKey: AppStorageKeys.playlistPlays)
    }

    @Test("a moment of this device is a statement: its value and its time are the moment")
    func aMomentIsAStatement() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        defer { cleanup(a.suite) }
        setMoments(["L": 5000], in: a.defaults)
        a.sync.reconcile()
        let entry = statement(cloud, "L")
        #expect(entry?.value == .double(5000), "the document carries no moment of the list")
        #expect(entry?.t == 5000)
    }

    @Test("a moment from the other device is adopted, and the adoption names the moments")
    func aMomentFromTheOtherDeviceIsAdopted() {
        let cloud = UserChoiceFakeCloud()
        let b = device(cloud, now: 2000)
        defer { cleanup(b.suite) }
        put(cloud, UserChoiceCatalog.playlistPlayPrefix + "L", UserChoiceEntry(value: .double(7000), t: 7000))
        var named = false
        let token = NotificationCenter.default.addObserver(forName: .userChoicesAdopted, object: nil, queue: nil) { note in
            if (note.userInfo?["keys"] as? [String])?.contains("playlistPlays") == true { named = true }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        b.sync.reconcile()
        #expect(PlaylistPlaysStore.moments(defaults: b.defaults)["L"] == 7000)
        #expect(named, "the adoption does not name playlistPlays")
    }

    @Test("the newer moment wins, either way")
    func theNewerMomentWins() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        defer { cleanup(a.suite) }
        setMoments(["L": 5000, "M": 9000], in: a.defaults)
        put(cloud, UserChoiceCatalog.playlistPlayPrefix + "L", UserChoiceEntry(value: .double(7000), t: 7000))
        put(cloud, UserChoiceCatalog.playlistPlayPrefix + "M", UserChoiceEntry(value: .double(7000), t: 7000))
        a.sync.reconcile()
        #expect(PlaylistPlaysStore.moments(defaults: a.defaults)["L"] == 7000, "the newer moment of the document lost")
        #expect(PlaylistPlaysStore.moments(defaults: a.defaults)["M"] == 9000, "the newer moment of this device lost")
        #expect(statement(cloud, "M")?.value == .double(9000), "the newer moment of this device did not go out")
    }

    @Test("both devices keep the newest fifty of both")
    func bothDevicesKeepTheNewestFifty() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        defer { cleanup(a.suite) }
        var local: [String: Double] = [:]
        for i in 0..<30 { local["a\(i)"] = Double(10_000 + 2 * i) }
        setMoments(local, in: a.defaults)
        var other: [String: Double] = [:]
        for i in 0..<30 {
            other["b\(i)"] = Double(10_001 + 2 * i)
            put(cloud, UserChoiceCatalog.playlistPlayPrefix + "b\(i)",
                UserChoiceEntry(value: .double(10_001 + 2 * Double(i)), t: 10_001 + 2 * Double(i)))
        }
        a.sync.reconcile()
        let all = local.merging(other) { first, _ in first }
        let newest = Set(all.sorted { $0.value > $1.value }.prefix(PlaylistPlays.keep).map(\.key))
        #expect(Set(PlaylistPlaysStore.moments(defaults: a.defaults).keys) == newest)
    }

    @Test("a list past the fifty is no longer stated, and its old moment does not beat a newer one")
    func aMomentPastTheCapIsNoLongerStated() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 1000)
        let b = device(cloud, now: 40_000)
        defer { cleanup(a.suite); cleanup(b.suite) }
        setMoments(["L": 1001], in: a.defaults)
        a.sync.notePlaylistPlay(id: "L")
        a.sync.reconcile()
        var moments = PlaylistPlaysStore.moments(defaults: a.defaults)
        for i in 0..<PlaylistPlays.keep { moments = PlaylistPlays.noting("n\(i)", atMs: Double(2000 + i), in: moments) }
        #expect(moments["L"] == nil, "the list did not fall out of the fifty")
        setMoments(moments, in: a.defaults)
        a.sync.reconcile()
        #expect(statement(cloud, "L")?.value == nil, "the list that fell out is still stated")
        #expect(statement(cloud, "L") != nil, "the list that fell out left no tombstone")

        setMoments(["L": 30_000], in: b.defaults)
        b.sync.reconcile()
        #expect(PlaylistPlaysStore.moments(defaults: b.defaults)["L"] == 30_000, "the old tombstone took a newer moment")
        #expect(statement(cloud, "L")?.value == .double(30_000))
    }

    @Test("a statement that is no moment is passed over, the others stand")
    func aStatementThatIsNoNumberIsSkipped() {
        let cloud = UserChoiceFakeCloud()
        let b = device(cloud, now: 2000)
        defer { cleanup(b.suite) }
        setMoments(["K": 4000], in: b.defaults)
        put(cloud, UserChoiceCatalog.playlistPlayPrefix + "L", UserChoiceEntry(value: .string("later"), t: 5000))
        put(cloud, UserChoiceCatalog.playlistPlayPrefix + "M", UserChoiceEntry(value: .double(6000), t: 6000))
        put(cloud, UserChoiceCatalog.playlistPlayPrefix + "N", UserChoiceEntry(value: .data(Data([1, 2])), t: 6500))
        b.sync.reconcile()
        #expect(PlaylistPlaysStore.moments(defaults: b.defaults) == ["K": 4000, "M": 6000])
    }

    @Test("noting a moment tells the rows, once")
    func notingAMomentTellsTheRows() {
        let suite = "plays-note-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { cleanup(suite) }
        var told = 0
        let token = NotificationCenter.default.addObserver(forName: .continueHiddenChanged, object: defaults, queue: nil) { _ in
            told += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        PlaylistPlaysStore.note("L", atMs: 5000, defaults: defaults)
        #expect(told == 1)
    }

    @Test("an adopted moment tells the rows")
    func anAdoptedMomentTellsTheRows() {
        let cloud = UserChoiceFakeCloud()
        let b = device(cloud, now: 2000)
        defer { cleanup(b.suite) }
        put(cloud, UserChoiceCatalog.playlistPlayPrefix + "L", UserChoiceEntry(value: .double(7000), t: 7000))
        var told = 0
        let token = NotificationCenter.default.addObserver(forName: .continueHiddenChanged, object: b.sync, queue: nil) { _ in
            told += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        b.sync.reconcile()
        #expect(told == 1)
    }

    @Test("Start builds its rows again on the signal, and Listen Again reads the moments at each build", .needsTheSources)
    func startReadsTheMomentsAgain() throws {
        let home = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Views/HomeView.swift"))
        #expect(home.contains("""
        .onReceive(NotificationCenter.default.publisher(for: .continueHiddenChanged)) { _ in
                    hiddenRevision += 1
        """))
        #expect(home.contains("SharedRows.listenAgain(albums: recentMusicItems"))
        let rows = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/ViewModels/SharedRows.swift"))
        let body = rows.components(separatedBy: "static func listenAgain(").dropFirst().first ?? ""
        let own = body.components(separatedBy: "\n    }\n").first ?? ""
        #expect(own.contains("PlaylistPlaysStore.moments("), "Listen Again does not read the moments at each build")
    }

    /// A client up to 3.10 knows no `playlistPlay.` prefix. It takes such a
    /// statement as a plain value into its settings and never states it
    /// back: the newer moment of the other device stays in the document.
    /// Measured with a prefix this build does not know, the same path.
    @Test("a statement of a family this build does not know is kept in its settings and never sent back")
    func anUnknownFamilyIsNeverSentBack() {
        let cloud = UserChoiceFakeCloud()
        let old = device(cloud, now: 2000)
        defer { cleanup(old.suite) }
        let key = "laterFamily.L"
        put(cloud, key, UserChoiceEntry(value: .double(7000), t: 7000))
        old.sync.reconcile()
        old.defaults.set(30.0, forKey: "playedTailSeconds")
        old.sync.noteScalar(key: "playedTailSeconds", value: 30.0)
        // The other device: a newer moment, and an older value of a choice
        // the old client holds newer, so its round writes the document.
        put(cloud, key, UserChoiceEntry(value: .double(9000), t: 9000))
        put(cloud, "playedTailSeconds", UserChoiceEntry(value: .double(20), t: 1))
        old.sync.reconcile()
        #expect(UserChoiceEntry.from(plist: blob(cloud)[key]) == UserChoiceEntry(value: .double(9000), t: 9000),
                "the old client sent its old value back: \(String(describing: blob(cloud)[key]))")
        #expect(UserChoiceEntry.from(plist: blob(cloud)["playedTailSeconds"])?.value == .double(30),
                "the round did not write the document")
        #expect(old.defaults.object(forKey: key) as? Double == 9000, "it is no longer kept silently: \(String(describing: old.defaults.object(forKey: key)))")
    }

    /// A note writes the whole document from the view of the last round. A
    /// device whose view is older (any build, an old client too) can so
    /// leave an older moment in the document. The device that heard the
    /// list later still holds its moment and its stamp: its next round
    /// states it again, and the newer moment wins.
    @Test("an older moment left by a stale view loses to the device that heard the list later")
    func anOlderMomentLeftByAStaleViewLoses() {
        let cloud = UserChoiceFakeCloud()
        let a = device(cloud, now: 9000)
        defer { cleanup(a.suite) }
        setMoments(["L": 9001], in: a.defaults)
        a.sync.notePlaylistPlay(id: "L")
        a.sync.reconcile()
        #expect(statement(cloud, "L")?.value == .double(9001))
        // What a stale whole document of another device leaves behind.
        put(cloud, UserChoiceCatalog.playlistPlayPrefix + "L", UserChoiceEntry(value: .double(7000), t: 7000))
        a.sync.reconcile()
        #expect(statement(cloud, "L")?.value == .double(9001), "the older moment stayed in the document")
        #expect(PlaylistPlaysStore.moments(defaults: a.defaults)["L"] == 9001, "the older moment took this device's")
    }
}
#endif
