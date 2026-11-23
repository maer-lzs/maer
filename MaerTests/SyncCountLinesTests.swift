// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The count lines of a sync say what went to the server and what came from
/// it. "Up", "down", "in" and "out" read as moving a row in a list ("Position
/// hoch", "vers le haut"); sent and received do not.
struct SyncCountLinesTests {
    static let keys = ["%lld positions sent", "%lld positions received",
                       "%lld subscriptions sent", "%lld subscriptions received"]
    static let gone = ["%lld positions up", "%lld positions down", "%lld positions in",
                       "%lld positions out", "%lld subscriptions up", "%lld subscriptions down"]

    @Test("the six counters of the sync history and of gpodder take sent and received", .needsTheSources)
    func theCountersTakeSentAndReceived() throws {
        func code(_ path: String) throws -> String { try SourceTree.text(SourceTree.root.appendingPathComponent(path)) }
        let history = try code("Sources/Views/SyncHistoryView.swift")
        for line in ["\"\\(counter.value) subscriptions sent\"", "\"\\(counter.value) subscriptions received\"",
                     "\"\\(counter.value) positions sent\"", "\"\\(counter.value) positions received\""] {
            #expect(history.contains(line), "the sync history lacks \(line)")
        }
        let gpodder = try code("Sources/Views/GPodderSettingsView.swift")
        #expect(gpodder.components(separatedBy: "\"\\(r.historyPulled) positions received\"").count - 1 == 2)
        #expect(gpodder.components(separatedBy: "\"\\(r.historyPushed) positions sent\"").count - 1 == 2)
    }

    @Test("the old keys are gone, the new ones carry a comment", .needsTheSources)
    func theCatalogCarriesTheNewKeys() throws {
        let url = SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings")
        let strings = (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["strings"] as? [String: Any] ?? [:]
        for key in Self.gone { #expect(strings[key] == nil, "still in the catalog: \(key)") }
        for key in Self.keys {
            let comment = (strings[key] as? [String: Any])?["comment"] as? String ?? ""
            #expect(!comment.isEmpty, "no comment for translators: \(key)")
        }
    }

    /// "A state without a moment" read as an instant in time, not as the
    /// time a state was recorded; a timestamp is that. French says
    /// horodatage for it; "le moment de leur enregistrement", when they
    /// were recorded, stays (read by a native speaker).
    @Test("the two import explanations say timestamp, French horodatage", .needsTheSources)
    func theImportSaysTimestamp() throws {
        let sheet = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/ForeignImportSheet.swift"))
        #expect(sheet.contains("A state without a timestamp only fills gaps"))
        #expect(sheet.contains("An episode marked played by hand carries no timestamp"))
        let values = try CatalogValues.all().filter { $0.catalog == "Localizable" && ($0.key.hasPrefix("A plain OPML carries subscriptions only.") || $0.key.hasPrefix("AntennaPod's database carries")) }
        #expect(!values.contains { $0.key.contains("moment") }, "a key still says moment")
        let french = values.filter { $0.language == "fr" }
        #expect(french.count == 2 && french.allSatisfy { $0.text.contains("horodatage") && !$0.text.contains("sans moment") && !$0.text.contains("aucun moment") }, "\(french.map(\.text))")
    }

    @Test("the import names what it could not place as having no matching episode", .needsTheSources)
    func theImportSaysNoMatchingEpisode() throws {
        let sheet = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Views/Podcasts/ForeignImportSheet.swift"))
        #expect(sheet.contains("Text(\"No matching episode: \\(r.unmatched.count)\")"))
        let catalog = try SourceTree.text(SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        #expect(!catalog.contains("\"Not matched to any episode: %lld\""), "the old key is still in the catalog")
    }

    private func localized(_ resource: LocalizedStringResource, _ language: String) -> String {
        var resource = resource
        resource.locale = Locale(identifier: language)
        return String(localized: resource)
    }

    @Test("German says sent and received, for one and for more")
    func germanSaysSentAndReceived() {
        #expect(localized("\(1) positions sent", "de") == "1 Hörstand gesendet")
        #expect(localized("\(2) positions received", "de") == "2 Hörstände empfangen")
        #expect(localized("\(1) subscriptions received", "de") == "1 Abo empfangen")
        #expect(localized("\(3) subscriptions sent", "de") == "3 Abos gesendet")
    }
}
#endif
