// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

#if canImport(Testing)
import Testing
import Foundation

/// Fence against Xcode's automatic pbxproj damage: with the project open,
/// Xcode injects a reference to the project INTO ITSELF whenever the tree
/// underneath changes (measured three times in one day) — the build survives,
/// so nothing notices until it is committed. This turns the guard into the
/// evidence chain: the run goes red BEFORE the commit, not silently healed
/// afterwards.
///
/// The project file is read from the source path baked in at compile time. If
/// it is not readable (a run on a device, a copied checkout), the case reports
/// nothing rather than failing on the environment — the check has value where
/// the damage happens, on the build machine.
struct ProjectFileIntegrityTests {
    private static var projectFile: String? {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testsDir.deletingLastPathComponent()
            .appendingPathComponent("Maer.xcodeproj/project.pbxproj")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    @Test("pbxproj: no self-reference of the project (Xcode auto-injection)")
    func noSelfReference() throws {
        guard let text = Self.projectFile else { return }
        let count = text.components(separatedBy: "wrapper.pb-project").count - 1
        #expect(count == 1,
                "project references != 1 — Xcode injected a self-reference; heal with git checkout -- Maer.xcodeproj/project.pbxproj")
    }

    @Test("pbxproj: the local app-key file is never a bundle member")
    func appKeysStayOutOfTheBundle() throws {
        guard let text = Self.projectFile else { return }
        #expect(text.contains("Config/AppKeys.local.xcconfig"),
                "membershipException for Config/AppKeys.local.xcconfig is gone — the resource sweep would ship the key file inside the app")
        #expect(text.contains("Config/App.xcconfig"),
                "the app target lost its bundle-hygiene base configuration")
    }
}
#endif
