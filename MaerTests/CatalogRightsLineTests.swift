// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The rights of a catalogue title, one line on every surface that names
/// them: the book page, the page of an album or a recording and the player.
/// A stated licence with the seal, else public domain by the year with the
/// seal, else the sentence on terms, else that the source states none.
/// Jamendo keeps its own line. The tiles name no rights.
struct CatalogRightsLineTests {
    @Test("a 78 from 1922 without a stated licence is public domain, without a year its rights are not stated")
    func byTheYear() {
        let id = FreeCatalog.archivePrefix + "78_example"
        #expect(CatalogRightsLine.of(itemId: id, licence: FreeCatalog.unstatedRights, year: "1922", currentYear: 2026) == .publicDomain)
        #expect(CatalogRightsLine.of(itemId: id, licence: nil, year: "1922", currentYear: 2026) == .publicDomain)
        #expect(CatalogRightsLine.of(itemId: id, licence: FreeCatalog.unstatedRights, year: nil, currentYear: 2026) == .unknown)
        #expect(CatalogRightsLine.of(itemId: id, licence: nil, year: nil, currentYear: 2026) == .unknown)
        #expect(CatalogRightsLine.of(itemId: id, licence: nil, year: "1990", currentYear: 2026) == .termsApply(year: "1990"))
    }

    @Test("a stated licence stands with the seal; Musopen names its licence; Jamendo keeps its line")
    func stated() {
        let musopen = MusopenCatalog.prefix + "1"
        #expect(CatalogRightsLine.of(itemId: musopen, licence: MusopenCatalog.Licence.cc0.label, year: nil, currentYear: 2026)
                == .stated("CC0"))
        #expect(CatalogRightsLine.of(itemId: FreeCatalog.archivePrefix + "x", licence: "CC BY-NC-ND", year: "1922", currentYear: 2026)
                == .stated("CC BY-NC-ND"))
        #expect(CatalogRightsLine.of(itemId: FreeCatalog.jamendoPrefix + "1", licence: nil, year: nil, currentYear: 2026) == .jamendo)
    }

    @Test("the seal stands on a statement and on public domain, never beside the terms or an unstated right")
    func seal() {
        #expect(CatalogRightsLine.stated("CC0").sealed)
        #expect(CatalogRightsLine.publicDomain.sealed)
        #expect(CatalogRightsLine.jamendo.sealed)
        #expect(!CatalogRightsLine.termsApply(year: "1990").sealed)
        #expect(!CatalogRightsLine.unknown.sealed)
    }

    @Test("the book page, the page of an album or a recording and the player draw the one section; no other surface builds a rights line", .needsTheSources)
    func oneSection() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let section = try source("Sources/Views/CatalogDetailExtras.swift")
        #expect(section.contains("CatalogRightsLine.of(itemId: itemId, licence: licence, year: year)"),
                "the section decides its line itself")
        let page = try source("Sources/Views/CatalogSourcePage.swift")
        #expect(page.contains("CatalogRightsSection(itemId: itemId, year: detail.media.metadata?.publishedYear?.value,"),
                "the page of an album or a recording draws another rights line")
        let player = try source("Sources/Views/PlayerView.swift")
        #expect(player.contains("CatalogRightsSection(itemId: id, year: viewModel.item?.media.metadata?.publishedYear?.value,"),
                "the player draws another rights line")
        // Stock: the seal stands in the section alone.
        var sealed: [String] = []
        for (name, text) in ProjectFileIntegrityTests.sourceTexts(in: ["Sources"])
        where !name.hasSuffix("CatalogDetailExtras.swift") && text.contains("\"checkmark.seal\"") {
            sealed.append(name)
        }
        #expect(sealed.isEmpty, "a rights line of its own in \(sealed)")
    }
}
#endif
