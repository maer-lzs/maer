// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// The app's App Transport Security declaration and the two sentences that
/// describe plain http, held as they were measured.
///
/// The key rule, measured on 19.09.2026 in five runs inside the app host:
/// `NSAllowsArbitraryLoads` does NOTHING while a finer key such as
/// `NSAllowsArbitraryLoadsForMedia` stands beside it (both in the built
/// product, mesh and public plain http still refused with URLError -1022),
/// and it covers everything once it stands alone. So the dict must hold
/// exactly the global key: a media key put back "for safety" would switch
/// the whole declaration off without a compiler noticing.
struct TransportSecurityFenceTests {
    static let plist = SourceTree.root.appendingPathComponent("Maer-Info.plist")

    /// The declaration as the plist carries it, or nil when the plist is
    /// unreadable: nil is a finding, not an empty declaration.
    static func transportSecurity() -> [String: Any]? {
        guard let data = try? Data(contentsOf: plist),
              let top = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return top["NSAppTransportSecurity"] as? [String: Any]
    }

    @Test("die Plist erlaubt plain http mit genau dem globalen Schluessel, ohne feineren daneben", .needsTheSources)
    func thePlistHoldsExactlyTheGlobalKey() throws {
        let declaration = try #require(Self.transportSecurity(), "the plist has no NSAppTransportSecurity dict")
        #expect(declaration["NSAllowsArbitraryLoads"] as? Bool == true, "the global key is missing or false")
        // Exactly one key: any finer key beside the global one makes iOS
        // ignore the global one, measured.
        #expect(declaration.keys.sorted() == ["NSAllowsArbitraryLoads"],
                "a finer key beside the global one switches it off")
        #expect(declaration["NSAllowsArbitraryLoadsForMedia"] == nil, "the media key is back beside the global one")
        #expect(declaration["NSExceptionDomains"] == nil, "exception domains cannot name a typed address")
    }

    /// The old wording said the token travels in the clear at a plain
    /// address; since the sealed session it does not. Zero hits in the
    /// sources and the catalog, and the two new sentences hang on the
    /// catalog with a German form.
    @Test("die alte Klartext-Behauptung kommt nicht mehr vor, und die zwei neuen Saetze haengen am Katalog", .needsTheSources)
    func theSentencesAreTheMeasuredOnes() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { ["swift", "xcstrings"].contains($0.pathExtension) }
        try #require(files.count > 100, "the source tree was not read")
        var oldHits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("the token in every request does not") || text.contains("the token in the header of every request does not") {
                oldHits.append(file.lastPathComponent)
            }
        }
        #expect(oldHits.isEmpty, "the old wording is back in \(oldHits)")

        let catalogURL = sources.appendingPathComponent("Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: try Data(contentsOf: catalogURL)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        for key in ["This address is plain http. Your sign-in and everything the app exchanges with the service travel sealed inside the session. Only the first fetch of the service's key and the reachability check are open on the wire; from then on the app holds that key.",
                    "iOS does not allow plain http for this address, so the service was never asked."] {
            let entry = strings[key] as? [String: Any]
            let german = ((entry?["localizations"] as? [String: Any])?["de"] as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect(german?["value"] as? String != nil, "no German form for \(key.prefix(40))")
        }
    }
}
#endif
