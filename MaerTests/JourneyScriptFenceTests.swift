// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The journey runner gives every server journey an app that never signed
/// in: each runs on its own, on the freshly erased template.
struct JourneyScriptFenceTests {
    @Test("Journeys: a server run drives every server journey individually on a freshly erased template", .needsTheSources)
    func eachServerJourneyRunsOnAFreshTemplate() throws {
        let script = try String(contentsOf: SourceTree.root.appendingPathComponent("scripts/journeys.sh"), encoding: .utf8)
        let lines = script.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let code = lines.joined(separator: "\n")
        // The one place that erases the template and silences it again.
        let fresh = try #require(code.range(of: "fresh_template() {"), "the template is erased in another way")
        let body = code[fresh.upperBound...].prefix(while: { $0 != "}" })
        #expect(body.contains("xcrun simctl erase \"$udid\""), "fresh_template does not erase the template")
        #expect(code.components(separatedBy: "simctl erase").count - 1 == 1, "the template is erased past fresh_template")
        // A server run takes each journey of ServerJourneys on its own,
        // every one after the first on a template erased again.
        #expect(code.contains("runs+=(\"-only-testing:MaerUITests/ServerJourneys/$name\")"), "a server run takes its journeys together")
        #expect(code.contains("for one in \"${runs[@]}\"; do"))
        #expect(code.contains("[[ $n -gt 1 ]] && fresh_template"), "a later server journey runs on the app the first one signed in")
        // The summary names the result bundles the run wrote, one per
        // server journey, not one that a server run never writes.
        #expect(code.contains("bundle=\"${RESULT%.xcresult}-$n.xcresult\""), "a server journey has no bundle of its own")
        #expect(code.contains("-resultBundlePath \"$bundle\" \"$one\""), "a server journey's bundle is not the one the summary names")
        #expect(code.contains("[[ -e \"$bundle\" ]] && bundles+=(\"$bundle\")"), "the summary names a bundle the run never wrote")
        #expect(code.contains("Ergebnis: ${(j: · :)bundles}"), "the summary names a bundle of its own")
    }
}
#endif
