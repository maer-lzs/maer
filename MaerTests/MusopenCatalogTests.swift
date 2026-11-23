// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The Musopen catalog on the recorded Commons answers under
/// `Fixtures/ServerAnswers/commons`: one file of each kind the category
/// holds, and the first answer of the category with its continue token.
struct MusopenCatalogTests {
    private func kinds() throws -> MusopenCatalog.Page {
        try MusopenCatalog.page(from: CorpusFixture.data("musopen_kinds", ext: "json", subdirectory: "ServerAnswers/commons"))
    }

    private func categoryAnswer() throws -> MusopenCatalog.Page {
        try MusopenCatalog.page(from: CorpusFixture.data("musopen_category_page", ext: "json", subdirectory: "ServerAnswers/commons"))
    }

    @Test("The licence per file: public domain, CC0 and the owner's Public Domain Mark stay, everything else stays out")
    func licenceTable() {
        let table: [(String?, MusopenCatalog.Licence?)] = [
            ("pd", .publicDomain), ("PD", .publicDomain), (" pd ", .publicDomain),
            ("cc0", .cc0), ("CC0", .cc0),
            ("cc-by-3.0", nil), ("cc-by-sa-4.0", nil), ("cc-by-3.0-us", nil),
            ("Public domain", nil), ("", nil), (nil, nil),
        ]
        for (stated, expected) in table {
            #expect(MusopenCatalog.Licence(stated: stated) == expected, "\(stated ?? "nil")")
        }
        // The mark leaves `License` empty and names itself in the short name.
        #expect(MusopenCatalog.Licence(stated: nil, shortName: "PDM-owner") == .publicDomainMark)
        #expect(MusopenCatalog.Licence(stated: "", shortName: " PDM-owner ") == .publicDomainMark)
        #expect(MusopenCatalog.Licence(stated: nil, shortName: "CC BY 3.0") == nil)
        // A stated licence decides before the short name.
        #expect(MusopenCatalog.Licence(stated: "cc0", shortName: "PDM-owner") == .cc0)
        // The owner's mark counts only where no other licence is stated: a
        // file that names cc-by-3.0 is not public domain, whatever its short
        // name says, and stays out.
        #expect(MusopenCatalog.Licence(stated: "cc-by-3.0", shortName: "PDM-owner") == nil)
        #expect(MusopenCatalog.Licence(stated: " cc-by-sa-4.0 ", shortName: "PDM-owner") == nil)
        // The words of archive.org's mark: one claim, one text.
        #expect(MusopenCatalog.Licence.publicDomainMark.label == String(localized: "Public domain (per source)"))
        #expect(CatalogRightsLine.of(itemId: "mso:1", licence: MusopenCatalog.Licence.publicDomainMark.label, year: nil)
                == .stated(String(localized: "Public domain (per source)")))
    }

    @Test("One file of each kind: three recordings, five counted out by their reason")
    func eachKind() throws {
        let page = try kinds()
        // In the order of the file names, as the category lists them.
        #expect(page.recordings.map(\.itemId) == ["mso:67816870", "mso:99430846", "mso:67535618", "mso:176969078"])
        #expect(page.recordings.last?.licence == .publicDomainMark)
        // A video, an Ogg video and a picture are no sound; FLAC has no MP3.
        #expect(page.dropped == [.notAudio: 3, .noPlayableForm: 1])
        #expect(page.token == nil)
    }

    @Test("A recording carries its licence, its name, its length and the form the player takes")
    func recordingFields() throws {
        let page = try kinds()
        let byId = Dictionary(uniqueKeysWithValues: page.recordings.map { ($0.pageId, $0) })
        let derived = try #require(byId[67816870])
        #expect(derived.licence == .cc0)
        #expect(derived.title == "1st violin B 02")
        #expect(derived.audioURL.absoluteString.hasSuffix("/transcoded/3/34/1st_violin_B_02.wav/1st_violin_B_02.wav.mp3"))
        #expect(derived.artistHTML?.contains("Wolfgang Amadeus Mozart") == true)
        #expect(derived.pageURL?.host == "commons.wikimedia.org")
        // An MP3 original plays as it is, without the tracking query.
        let original = try #require(byId[67535618])
        #expect(original.audioURL.absoluteString == "https://upload.wikimedia.org/wikipedia/commons/a/a0/Allegro_de_Concert_Op._46_in_A_Major.mp3")
        let ogg = try #require(byId[99430846])
        #expect(ogg.licence == .publicDomain)
        #expect(ogg.audioURL.pathExtension == "mp3")
        #expect((ogg.duration ?? 0) > 100)
    }

    @Test("The first answer of the category hands out the token of the next")
    func categoryPage() throws {
        let page = try categoryAnswer()
        #expect(page.recordings.count == 2)
        #expect(page.token == "file|3153542056494f4c494e20462030322e574156|67816866")
    }

    @Test("The addresses: a category with its token or its place of the day, one file by its number")
    func addresses() throws {
        let first = MusopenCatalog.categoryURL("Category:Musopen", token: nil)
        let query = try #require(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })
        #expect(first.host == "commons.wikimedia.org")
        #expect(values["gcmtitle"] == "Category:Musopen")
        #expect(values["gcmtype"] == "file")
        #expect(values["gcmlimit"] == "50")
        #expect(values["gcmcontinue"] == nil)
        let next = MusopenCatalog.categoryURL("Category:Musopen", token: "file|AB|1", startingAt: "M")
        let nextValues = Dictionary(uniqueKeysWithValues: (URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(nextValues["gcmcontinue"] == "file|AB|1")
        #expect(nextValues["gcmstartsortkeyprefix"] == "M")
        let file = MusopenCatalog.fileURL(pageId: 99430846)
        #expect(URLComponents(url: file, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageids" }?.value == "99430846")
    }

    @Test("The reader goes on in a category with its token, then to the next category, and ends after the last")
    func cursor() {
        let last = MusopenCatalog.categories.count - 1
        #expect(MusopenCatalog.categories.count == 2)
        #expect(MusopenCatalog.cursor(after: .init(category: 0, token: nil), token: "t1") == .init(category: 0, token: "t1"))
        #expect(MusopenCatalog.cursor(after: .init(category: 0, token: "t1"), token: nil) == .init(category: 1, token: nil))
        #expect(MusopenCatalog.cursor(after: .init(category: last, token: "t9"), token: nil) == nil)
    }

    @Test("The item id and its page id")
    func itemIds() {
        #expect(MusopenCatalog.pageId(of: "mso:99430846") == 99430846)
        #expect(MusopenCatalog.pageId(of: "jam:12") == nil)
        #expect(MusopenCatalog.pageId(of: "mso:x") == nil)
    }

    @Test("The row's place moves on by one letter a day")
    func rowLetter() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        let today = MusopenCatalog.rowLetter(on: day, calendar: calendar)
        let tomorrow = MusopenCatalog.rowLetter(on: day.addingTimeInterval(86_400), calendar: calendar)
        #expect(today != tomorrow)
        #expect(today.count == 1 && tomorrow.count == 1)
    }

    @Test("A file without an object name is named by its file name")
    func shownTitle() {
        #expect(MusopenCatalog.shownTitle(objectName: nil, fileTitle: "File:Nocturne No. 2.ogg") == "Nocturne No. 2")
        #expect(MusopenCatalog.shownTitle(objectName: "  ", fileTitle: "File:A.b.mp3") == "A.b")
        // An object name that is the markup of a template is no name.
        #expect(MusopenCatalog.shownTitle(objectName: "<div class=\"fn\"><i>Nocturne Eb major</i></div>",
                                          fileTitle: "File:Nocturne in E flat major, Op. 9 no. 2.mp3")
                == "Nocturne in E flat major, Op. 9 no. 2")
        #expect(MusopenCatalog.shownTitle(objectName: "Etude", fileTitle: "File:x.ogg") == "Etude")
    }
}
#endif
