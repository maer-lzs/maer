// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The app's keys (Jamendo, Podcast Index) live outside git in
/// `Config/AppKeys.local.xcconfig`, which `#include?` takes when it is there
/// and skips silently when not. Builds 66 and 67 were archived in work
/// trees without the file and went out with empty keys. An archive of the
/// app (Release, ACTION install) stops now when one is empty; Debug, the
/// tests and the Release check build of `lauf.sh` build without.
struct ReleaseKeysFenceTests {
    @Test("the app runs the key check in a build phase of its own", .needsTheProjectFile)
    func theAppRunsTheCheck() throws {
        let project = try SourceTree.text(SourceTree.root.appendingPathComponent("Maer.xcodeproj/project.pbxproj"))
        let call = "/bin/sh \\\"${SRCROOT}/scripts/release-keys.sh\\\""
        #expect(project.components(separatedBy: call).count - 1 == 1, "the key check does not run exactly in the app")
    }

    @Test("the check stops an archive on an empty key, names file and folder and never a value", .needsTheSources)
    func theCheckStopsAndNamesNoValue() throws {
        let script = try SourceTree.text(SourceTree.root.appendingPathComponent("scripts/release-keys.sh"))
        #expect(script.contains("[ \"${CONFIGURATION}\" = \"Release\" ] && [ \"${ACTION}\" = \"install\" ] || exit 0"),
                "the check also stops a Debug build or the Release check build of a work tree")
        for name in ["MAER_JAMENDO_CLIENT_ID", "MAER_PODCASTINDEX_KEY", "MAER_PODCASTINDEX_SECRET"] {
            #expect(script.contains(name), "the check forgets \(name)")
        }
        #expect(script.contains("AppKeys.local.xcconfig") && script.contains("${SRCROOT}/Config"), "the message names no file and folder")
        let echoes = script.split(separator: "\n").filter { $0.contains("echo") }
        #expect(!echoes.contains { $0.contains("$value") || $0.contains("${value}") || $0.contains("$MAER_") || $0.contains("${MAER_") },
                "a line prints a value: \(echoes)")
    }
}
#endif
