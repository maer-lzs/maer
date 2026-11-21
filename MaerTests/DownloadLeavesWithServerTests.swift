// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A download held (paused or running) for a server that is left goes with
/// it: resumed, it asked the shared source, which by then speaks to the new
/// server, for the old server's paths.
struct DownloadLeavesWithServerTests {
    @Test("the held downloads of the leaving server end; the others stay")
    func heldOfTheLeavingServer() {
        let held = ["li_old-book", "subsonic:album:7", "li_other-book", "rss:feed:ep"]
        #expect(DownloadManager.heldOfLeaving(held, owns: ItemNamespace.isAudiobookshelf).sorted()
                == ["li_old-book", "li_other-book"])
        #expect(DownloadManager.heldOfLeaving([], owns: { _ in true }).isEmpty)
    }

    @Test("leaving a server ends its held downloads, through the one door every leaving takes", .needsTheSources)
    func leavingAsksTheDownloads() throws {
        let code = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Providers/ServerLeaving.swift"), encoding: .utf8))
        #expect(code.contains("forgetHeld(ownedBy: owns)"))
    }
}
#endif
