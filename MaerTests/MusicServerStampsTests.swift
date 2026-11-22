// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// Two Subsonic servers of one kind can hand out the same id for two
/// titles. A row this device keeps for a title carries the server it was
/// written under; under another server it reads as absent, back on its own
/// server it is there again. A row from before the stamp reads as before.
/// A travelling list shows a title only where its server is set up.
struct MusicServerStampsTests {
    @Test("one key for a server: the port counts, the scheme, the case of the host and a trailing slash do not")
    func oneKey() {
        #expect(MusicServerStamps.key(of: "https://Music.example:4533/rest/") == MusicServerStamps.key(of: "http://music.example:4533/rest"))
        #expect(MusicServerStamps.key(of: "https://music.example:4533") != MusicServerStamps.key(of: "https://music.example:4534"))
        #expect(MusicServerStamps.key(of: "https://music.example") != nil)
        #expect(MusicServerStamps.key(of: "") == nil)
    }

    @Test("a row stamped under A reads as absent under B and is there again under A; an unstamped row and no server read as before; other ids are never stamped")
    func stamps() {
        let a = MusicServerStamps.key(of: "https://a.example")
        let b = MusicServerStamps.key(of: "https://b.example")
        var stamps = MusicServerStamps()
        stamps.stamp("sub:song:tr-1", kind: .stand, server: a)
        #expect(stamps.isElsewhere("sub:song:tr-1", kind: .stand, current: b))
        #expect(!stamps.isElsewhere("sub:song:tr-1", kind: .stand, current: a))
        #expect(!stamps.isElsewhere("sub:song:tr-1", kind: .download, current: b), "a kind of its own: no download row was written")
        #expect(!stamps.isElsewhere("sub:song:tr-2", kind: .stand, current: b), "a row from before the stamp")
        #expect(!stamps.isElsewhere("sub:song:tr-1", kind: .stand, current: nil), "no server set up: as before")
        #expect(MusicServerStamps.isStamped("sub:album:al-12"))
        #expect(!MusicServerStamps.isStamped("rss:f:e1") && !MusicServerStamps.isStamped("jf:song:1") && !MusicServerStamps.isStamped("li_1"))
        stamps.stamp("rss:f:e1", kind: .stand, server: a)
        #expect(stamps.stamps.values.allSatisfy { $0["rss:f:e1"] == nil }, "a podcast episode got a music server's stamp")
        #expect(stamps.shown(["sub:song:tr-1", "sub:song:tr-2", "rss:f:e1"], kind: .stand, current: b) == ["sub:song:tr-2", "rss:f:e1"])
        stamps.stamp("sub:song:tr-1", kind: .stand, server: b)
        #expect(stamps.isElsewhere("sub:song:tr-1", kind: .stand, current: a), "written again under B, the row is B's")
        stamps.stamp("sub:song:tr-1", kind: .queue, server: nil)
        #expect(!stamps.isElsewhere("sub:song:tr-1", kind: .queue, current: a), "written without a server: no stamp")
    }

    @Test("the move of Navidrome ids carries the stamps along")
    func rekey() {
        let a = MusicServerStamps.key(of: "https://a.example")
        var stamps = MusicServerStamps()
        stamps.stamp("sub:song:old", kind: .download, server: a)
        stamps.rekey { $0 == "sub:song:old" ? "sub:song:new" : $0 }
        #expect(stamps.isElsewhere("sub:song:new", kind: .download, current: MusicServerStamps.key(of: "https://b.example")))
        #expect(!stamps.isElsewhere("sub:song:old", kind: .download, current: MusicServerStamps.key(of: "https://b.example")))
    }

    @Test("the stand of a title written under A is absent under B and back under A; a stand written without a server stays")
    func standUnderTwoServers() {
        let name = "stamps-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("https://a.example", forKey: AppStorageKeys.subsonicServerURL)
        ListeningStore.record("sub:song:tr-1", position: 100, duration: 300, atMs: 1_000, in: defaults)
        #expect(ListeningStore.mark("sub:song:tr-1", in: defaults)?.position == 100, "the precondition: the stand is written")
        defaults.set("https://b.example", forKey: AppStorageKeys.subsonicServerURL)
        #expect(ListeningStore.mark("sub:song:tr-1", in: defaults) == nil, "A's stand reads on B")
        #expect(ListeningStore.storedEntry("sub:song:tr-1", in: defaults) == nil)
        #expect(ListeningStore.positions(in: defaults)["sub:song:tr-1"] == nil)
        #expect(!ListeningStore.hasStand("sub:song:tr-1", in: defaults))
        defaults.set("https://a.example", forKey: AppStorageKeys.subsonicServerURL)
        #expect(ListeningStore.mark("sub:song:tr-1", in: defaults)?.position == 100, "back on A the stand is there")
        defaults.removeObject(forKey: AppStorageKeys.subsonicServerURL)
        ListeningStore.record("sub:song:tr-2", position: 50, duration: 300, atMs: 2_000, in: defaults)
        defaults.set("https://b.example", forKey: AppStorageKeys.subsonicServerURL)
        #expect(ListeningStore.mark("sub:song:tr-2", in: defaults)?.position == 50, "a stand without a stamp reads as before")
    }

    @Test("a travelling list shows a title only where its server is set up; it is hidden, not removed")
    func shownEntries() {
        let reasons: [String: UnavailableReason] = ["sub:song:1": .sourceNotConfigured(source: "sub:"),
                                                    "jf:song:2": .sourceNotConfigured(source: "jf:"),
                                                    "sub:song:3": .notInLibrary,
                                                    "rule:newest:x": .routineRule]
        let ids = ["sub:song:1", "lv:7", "jf:song:2", "sub:song:3", "rule:newest:x"]
        #expect(PlaylistShown.entries(ids) { reasons[$0] } == ["lv:7", "sub:song:3", "rule:newest:x"])
    }

    @Test("Fence: every device row of a title is stamped where it is written and asked where it is read; the list page and its count show what PlaylistShown keeps", .needsTheSources)
    func doors() throws {
        func code(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let sites: [(String, String)] = [
            ("Sources/Models/ListeningStore.swift", "MusicServerStampBook.stamp("),
            ("Sources/Models/ListeningStore.swift", "MusicServerStampBook.isElsewhere("),
            ("Sources/Networking/DownloadManager.swift", "MusicServerStampBook.stamp("),
            ("Sources/Networking/DownloadManager.swift", "MusicServerStampBook.isElsewhere("),
            ("Sources/Networking/ImageCache.swift", "MusicServerStampBook.isElsewhere("),
            ("Sources/Providers/PlayQueue.swift", "MusicServerStampBook.stamp("),
            ("Sources/Providers/PlayQueue.swift", "MusicServerStampBook.shown("),
            ("Sources/Providers/PlaybackContext.swift", "MusicServerStampBook.stamp("),
            ("Sources/Providers/PlaybackContext.swift", "MusicServerStampBook.shown("),
            ("Sources/Storage/ListenHistory.swift", "MusicServerStampBook.stamp("),
            ("Sources/Storage/ListenHistory.swift", "MusicServerStampBook.isElsewhere("),
            ("Sources/Networking/NavidromeRekeyRun.swift", "MusicServerStampBook.rekey("),
            ("Sources/Views/Music/MusicLibraryPages.swift", "PlaylistShown.entries("),
            ("Sources/Views/Music/PlaylistCard.swift", "PlaylistShown.entries("),
        ]
        for (path, call) in sites {
            #expect(try code(path).contains(call), "\(path) does not call \(call)")
        }
    }
}
#endif
