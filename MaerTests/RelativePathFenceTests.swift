// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// A test that cuts a root off a walked file's path resolves BOTH sides.
/// The file walker hands out /private/tmp where the root says /tmp; a
/// bare replace then keeps the whole path, and the fence counted nothing
/// in a tree under /tmp while it counted right in the home directory.
struct RelativePathFenceTests {
    /// Lines that cut a path prefix off a path without resolving it.
    static func unresolvedCuts(in code: String) -> [String] {
        code.split(separator: "\n").map(String.init).filter { line in
            line.contains(".path.replacingOccurrences(of:") && line.contains(".path +")
                && !line.contains("resolvingSymlinksInPath")
        }
    }

    @Test("ein Test schneidet einen Pfad nur von aufgeloesten Pfaden ab", .needsTheSources)
    func pathsAreCutOnlyWhenResolved() throws {
        let tests = SourceTree.root.appendingPathComponent("MaerTests")
        let walker = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var read = 0
        for case let url as URL in walker where url.pathExtension == "swift"
            && url.lastPathComponent != "RelativePathFenceTests.swift" {
            read += 1
            let code = SyncContractFenceTests.stripped(try String(contentsOf: url, encoding: .utf8))
            offenders += Self.unresolvedCuts(in: code).map { "\(url.lastPathComponent): \($0.trimmingCharacters(in: .whitespaces))" }
        }
        #expect(read > 100, "the fence read only \(read) test files")
        #expect(offenders.isEmpty, "a path cut that breaks under /tmp: \(offenders)")
        // Calibration: the broken form is caught, the resolved forms are not.
        #expect(Self.unresolvedCuts(in: #"let p = url.path.replacingOccurrences(of: root.path + "/", with: "")"#).count == 1)
        #expect(Self.unresolvedCuts(in: #"let p = url.resolvingSymlinksInPath().path.replacingOccurrences(of: root.resolvingSymlinksInPath().path + "/", with: "")"#).isEmpty)
    }
}
#endif
