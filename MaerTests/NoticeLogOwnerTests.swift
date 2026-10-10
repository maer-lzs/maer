// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The notice log follows the account like every family on the shelf: what
/// this device said before any account goes to the first one; a sign out
/// changes nothing; another account sees nothing of the one before, whose
/// lines rest and come back with it; nothing is deleted.
@MainActor
@Suite(.serialized)
struct NoticeLogOwnerTests {
    private struct Rig {
        let directory: URL
        var ablage: Ablage { Ablage(directory: directory.appendingPathComponent("documents", isDirectory: true)) }
        var shelf: RestingShelf { RestingShelf(directory: directory.appendingPathComponent("resting", isDirectory: true)) }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private func rig() throws -> Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notice-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Rig(directory: directory)
    }

    /// A line that only goes to the log, named by its title.
    private func say(_ notices: PlaybackNotices, _ title: String) {
        notices.show(.saved, title: title)
    }

    private func said(_ notices: PlaybackNotices) -> [String] {
        notices.log.compactMap(\.title)
    }

    private func resting(_ rig: Rig, _ owner: String) throws -> [String] {
        try rig.shelf.rest([NoticeLogEntry].self, of: PlaybackNotices.shelfFamily, owner: owner)?.compactMap(\.title) ?? []
    }

    @Test("Meldungen ohne Konto, das erste Konto A sieht alles; A abgemeldet weiter, wieder A sieht alles; B sieht nichts von A; zurueck zu A, dann B: B's Zeilen wieder da, keine von A; ueber einen Neustart")
    func theLogFollowsTheAccount() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        var signedIn: String?
        let notices = PlaybackNotices(ablage: rig.ablage, shelf: rig.shelf, identity: { signedIn })

        say(notices, "device")
        #expect(said(notices) == ["device"], "the precondition: the device said it before any account")

        signedIn = "account-a"
        #expect(notices.follow(owner: "account-a", previous: nil))
        await notices.awaitPendingSave()
        #expect(said(notices) == ["device"], "the first account does not take what this device said")

        signedIn = nil
        say(notices, "whileOut")
        signedIn = "account-a"
        #expect(notices.follow(owner: "account-a", previous: "account-a"))
        #expect(said(notices) == ["device", "whileOut"], "a sign out and A again lost a line")

        signedIn = "account-b"
        #expect(notices.follow(owner: "account-b", previous: "account-a"))
        await notices.awaitPendingSave()
        let underB = said(notices)
        #expect(underB.isEmpty, "B sees what A said: \(underB)")
        say(notices, "ofB")

        signedIn = "account-a"
        #expect(notices.follow(owner: "account-a", previous: "account-b"))
        await notices.awaitPendingSave()
        #expect(said(notices) == ["device", "whileOut"], "A's own lines did not come back as they were: \(said(notices))")
        say(notices, "ofA")

        signedIn = "account-b"
        #expect(notices.follow(owner: "account-b", previous: "account-a"))
        await notices.awaitPendingSave()
        #expect(said(notices) == ["ofB"], "B's lines did not come back, or A's came along: \(said(notices))")

        // A restart reads B's document and keeps it.
        let again = PlaybackNotices(ablage: rig.ablage, shelf: rig.shelf, identity: { signedIn })
        #expect(again.follow(owner: "account-b", previous: "account-b"))
        #expect(said(again) == ["ofB"], "a restart under B shows another log: \(said(again))")
        let restOfA = try resting(rig, "account-a")
        #expect(restOfA == ["device", "whileOut", "ofA"], "A's lines do not rest under A: \(restOfA)")
    }

    /// The shelf does not take A's rest at the switch (no rights on its
    /// folder at that moment), afterwards it does: the hand-over holds, and
    /// it is tried again before B's first line is written, so B's line
    /// stands with B and none with A, also after a restart.
    @Test("ein gehaltener Wechsel wird vor der naechsten Zeile wiederholt: B's Zeile bei B, keine bei A, ueber einen Neustart")
    func aHeldSwitchIsTriedAgainBeforeTheNextLine() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        var signedIn: String? = "account-a"
        let notices = PlaybackNotices(ablage: rig.ablage, shelf: rig.shelf, identity: { signedIn })
        #expect(notices.follow(owner: "account-a", previous: nil))
        say(notices, "ofA")
        await notices.awaitPendingSave()

        let family = rig.directory.appendingPathComponent("resting/\(PlaybackNotices.shelfFamily)").path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: family)
        signedIn = "account-b"
        let handed = notices.follow(owner: "account-b", previous: "account-a")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: family)
        #expect(!handed, "the precondition: the shelf did not take A's rest")
        let holder = try rig.shelf.holding(of: PlaybackNotices.shelfFamily)?.owner
        #expect(holder == "account-a", "the precondition: A still holds: \(String(describing: holder))")

        say(notices, "ofB")
        await notices.awaitPendingSave()
        #expect(said(notices) == ["ofB"], "B's line joined A's log: \(said(notices))")
        let settled = try rig.shelf.holding(of: PlaybackNotices.shelfFamily)
        #expect(settled?.owner == "account-b" && settled?.replacing == false,
                "the hand-over was not tried again, or did not settle: \(String(describing: settled))")

        let again = PlaybackNotices(ablage: rig.ablage, shelf: rig.shelf, identity: { signedIn })
        #expect(again.follow(owner: "account-b", previous: "account-b"))
        #expect(said(again) == ["ofB"], "a restart under B lost B's line: \(said(again))")
        let restOfA = try resting(rig, "account-a")
        #expect(restOfA == ["ofA"], "B's line rests under A, or A's was lost: \(restOfA)")
    }

    /// The document stands but cannot be read at the start and at the switch
    /// (no rights on it): the hand-over holds, nothing is saved over A's
    /// lines, and B's lines wait. Readable again, B's next line tries the
    /// hand-over first: A's lines rest under A, B's stand with B.
    @Test("ein Wechsel, waehrend das Protokoll unlesbar dasteht, haelt: nichts wird darueber gespeichert, B's Zeilen warten, A's ruhen ganz")
    func aSwitchOverAnUnreadDocumentHolds() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let before = PlaybackNotices(ablage: rig.ablage, shelf: rig.shelf, identity: { "account-a" })
        #expect(before.follow(owner: "account-a", previous: nil))
        say(before, "ofA")
        await before.awaitPendingSave()

        let file = rig.ablage.url(for: PlaybackNotices.documentName).path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file)
        let notices = PlaybackNotices(ablage: rig.ablage, shelf: rig.shelf, identity: { "account-b" })
        let seen = said(notices)
        let handed = notices.follow(owner: "account-b", previous: "account-a")
        say(notices, "firstOfB")
        await notices.awaitPendingSave()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        #expect(seen.isEmpty, "the precondition: the start read nothing")
        #expect(!handed, "a switch over an unread document went on")
        let holder = try rig.shelf.holding(of: PlaybackNotices.shelfFamily)?.owner
        #expect(holder == "account-a", "the holder moved over an unread document: \(String(describing: holder))")
        let early = try resting(rig, "account-a")
        #expect(early.isEmpty, "a rest was laid for A from a document nobody read: \(early)")

        say(notices, "secondOfB")
        await notices.awaitPendingSave()
        #expect(said(notices) == ["firstOfB", "secondOfB"], "B's lines and A's mixed: \(said(notices))")

        let again = PlaybackNotices(ablage: rig.ablage, shelf: rig.shelf, identity: { "account-b" })
        #expect(again.follow(owner: "account-b", previous: "account-b"))
        #expect(said(again) == ["firstOfB", "secondOfB"], "a restart under B shows another log: \(said(again))")
        let restOfA = try resting(rig, "account-a")
        #expect(restOfA == ["ofA"], "A's line was lost or B's rests under A: \(restOfA)")
    }

    /// The document stands but cannot be read, and no account changes: a
    /// line said meanwhile is not saved over it, the file keeps its lines;
    /// once it reads again, its lines and the new ones stand in the log.
    @Test("ein Protokoll, das unlesbar dasteht, wird ohne Wechsel nicht ueberschrieben: die Datei behaelt ihre Zeilen, danach stehen alte und neue")
    func anUnreadDocumentIsNotSavedOver() async throws {
        let rig = try rig()
        defer { rig.cleanup() }
        let before = PlaybackNotices(ablage: rig.ablage, shelf: rig.shelf, identity: { "account-a" })
        #expect(before.follow(owner: "account-a", previous: nil))
        say(before, "old")
        await before.awaitPendingSave()

        let file = rig.ablage.url(for: PlaybackNotices.documentName).path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file)
        let notices = PlaybackNotices(ablage: rig.ablage, shelf: rig.shelf, identity: { "account-a" })
        let seen = said(notices)
        say(notices, "new")
        await notices.awaitPendingSave()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
        #expect(seen.isEmpty, "the precondition: the start read nothing")
        let onDisk = rig.ablage.loadNow([NoticeLogEntry].self, name: PlaybackNotices.documentName).value?.compactMap(\.title)
        #expect(onDisk == ["old"], "a line was saved over the unread document: \(String(describing: onDisk))")

        say(notices, "newer")
        await notices.awaitPendingSave()
        #expect(said(notices) == ["old", "new", "newer"], "the read lines and this run's did not meet: \(said(notices))")
        let again = PlaybackNotices(ablage: rig.ablage, shelf: rig.shelf, identity: { "account-a" })
        #expect(said(again) == ["old", "new", "newer"], "a restart shows another log: \(said(again))")
    }

    @Test("der Meldungs-Kanal der App traegt sich als Laeufer ein und folgt beim Start", .needsTheSources)
    func theChannelIsEnrolledAndFollowsAtStart() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/ViewModels/PlayerCoordinator.swift"), encoding: .utf8))
        #expect(code.contains("AccessFollowers.enrolled(PlaybackNotices(shelf: MaerDatabase.restingShelf))"),
                "the app's channel hears no change of account")
        #expect(code.contains("own.followAtStart()"), "the app's channel is not followed at start")
    }
}
#endif
