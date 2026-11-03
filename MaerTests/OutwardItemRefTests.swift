// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// The id a title carries out of the app: built from the owner register
/// and a salt of this device, never stored, no address in it.
struct OutwardItemRefTests {
    static let saltA = Data(repeating: 1, count: OutwardServerTag.saltLength)
    static let saltB = Data(repeating: 2, count: OutwardServerTag.saltLength)
    static let serverA = "https://books.example.org"
    static let serverB = "https://other.example.net"

    static func owners(_ pairs: [String: String]) -> ItemOwners {
        var owners = ItemOwners()
        for (server, ids) in Dictionary(grouping: pairs, by: \.value) {
            owners.noteFullLoad(ids: Set(ids.map(\.key)), server: server)
        }
        return owners
    }

    @Test("hin und zurueck ist die Kennung der App, auch mit Punkt und Doppelpunkt im Rest")
    func thereAndBack() throws {
        let ids = ["li_8a7f", "0b1c2d3e-aaaa-bbbb-cccc-1234567890ab", "a.b.c", "x-1/y:z"]
        let tagOf = OutwardServerTag.tagOf(owners: Self.owners(Dictionary(uniqueKeysWithValues: ids.map { ($0, Self.serverA) })),
                                           salt: Self.saltA)
        for id in ids {
            let ref = try #require(OutwardItemRef.ref(itemId: id, serverTag: tagOf(id)))
            let parts = try #require(OutwardItemRef.parts(of: ref))
            #expect(parts.kind == "abs")
            #expect(parts.rest == id, "the rest after the first two dots is the whole id: \(ref)")
            #expect(OutwardItemRef.itemId(ref: ref, tagOf: tagOf) == id)
            #expect(OutwardItemRef.ref(itemId: id, serverTag: tagOf(id)) == ref, "the same title gives the same outward id")
        }
    }

    @Test("ohne Besitzer, mit Namensraum oder ohne Etikett gibt es keine Kennung nach aussen")
    func nothingWithoutAnOwner() {
        let tagOf = OutwardServerTag.tagOf(owners: Self.owners(["a": Self.serverA]), salt: Self.saltA)
        #expect(tagOf("unowned") == nil)
        #expect(OutwardItemRef.ref(itemId: "unowned", serverTag: tagOf("unowned")) == nil)
        #expect(OutwardItemRef.ref(itemId: "rss:feed:guid", serverTag: tagOf("a")) == nil)
        #expect(OutwardItemRef.ref(itemId: "abspod:show:ep", serverTag: tagOf("a")) == nil)
        #expect(OutwardItemRef.ref(itemId: "a", serverTag: "not-a-tag") == nil)
        #expect(OutwardItemRef.ref(itemId: "", serverTag: tagOf("a")) == nil)
    }

    @Test("zwei Server und zwei Salze geben zwei Etiketten")
    func twoServersTwoSalts() throws {
        let tagA = try #require(OutwardServerTag.tag(owner: Self.serverA, salt: Self.saltA))
        let tagB = try #require(OutwardServerTag.tag(owner: Self.serverB, salt: Self.saltA))
        let otherDevice = try #require(OutwardServerTag.tag(owner: Self.serverA, salt: Self.saltB))
        #expect(tagA != tagB, "two servers, one salt")
        #expect(tagA != otherDevice, "one server, two devices")
        #expect(OutwardItemRef.isTag(tagA) && OutwardItemRef.isTag(tagB) && OutwardItemRef.isTag(otherDevice))
        #expect(OutwardItemRef.ref(itemId: "a", serverTag: tagA) != OutwardItemRef.ref(itemId: "a", serverTag: tagB))
    }

    @Test("ein Wechsel ohne Serverwechsel behaelt das Etikett, ein Serverwechsel nicht")
    func theTagFollowsTheSwitchRule() throws {
        let tag = { (address: String) in OutwardServerTag.tag(owner: address, salt: Self.saltA) }
        let base = try #require(tag("https://books.example.org"))
        #expect(tag("http://books.example.org") == base, "the scheme is no other server")
        #expect(tag("https://books.example.org:443") == base, "the default port is no other server")
        #expect(tag("https://Books.Example.org/") == base, "case and a trailing slash are no other server")
        #expect(tag("https://books.example.com") != base, "another domain is another server")
        #expect(tag("https://books.example.org:13378") != base, "another port is another server")
        #expect(tag("https://books.example.org/abs") != base, "another path is another server")
        #expect(tag("") == nil)
    }

    @Test("der Rueckweg fragt das Register: ein fremdes Etikett findet ein Buch dieses Geraets")
    func theWayBackAsksTheRegister() throws {
        let tagOf = OutwardServerTag.tagOf(owners: Self.owners(["a": Self.serverA]), salt: Self.saltA)
        let otherDevice = try #require(OutwardServerTag.tag(owner: Self.serverA, salt: Self.saltB))
        let fromThere = try #require(OutwardItemRef.ref(itemId: "a", serverTag: otherDevice))
        #expect(OutwardItemRef.itemId(ref: fromThere, tagOf: tagOf) == "a",
                "a shortcut made on another device or before an address moved still names this book")
        let unknown = try #require(OutwardItemRef.ref(itemId: "gone", serverTag: otherDevice))
        #expect(OutwardItemRef.itemId(ref: unknown, tagOf: tagOf) == nil, "an id this device does not own")
        #expect(OutwardItemRef.itemId(ref: "a", tagOf: tagOf) == nil, "no outward id")
        #expect(OutwardItemRef.itemId(ref: "sub.\(otherDevice).a", tagOf: tagOf) == nil, "another kind")
        #expect(OutwardItemRef.itemId(ref: "abs.\(otherDevice).rss:feed:guid", tagOf: tagOf) == nil, "a rest with a namespace")
        #expect(OutwardItemRef.parts(of: "abs..a") == nil)
        #expect(OutwardItemRef.parts(of: "abs.tag.") == nil)
    }

    @Test("keine Adresse und kein Zugang in einer Kennung nach aussen")
    func noAddressGoesOut() throws {
        let server = "https://reader:secret@books.example.org:13378/abs?token=abc"
        let tag = try #require(OutwardServerTag.tag(owner: server, salt: Self.saltA))
        let ref = try #require(OutwardItemRef.ref(itemId: "li_1", serverTag: tag))
        // Words with letters beyond hex: a tag is hex and cannot carry them by chance.
        for part in ["://", "@", "books", "example", "reader", "secret", "token"] {
            #expect(!ref.contains(part), "\(part) in \(ref)")
        }
    }

    @Test("ein Salz entsteht nur, wenn der Schluesselbund keines hat")
    func aSaltOnlyWhenThereIsNone() {
        let made = Data(repeating: 7, count: OutwardServerTag.saltLength)
        var written: [String] = []
        let fresh = OutwardServerTag.salt(read: { .missing }, write: { written.append($0); return true }, random: { made })
        #expect(fresh == made)
        #expect(written == [made.base64EncodedString()])

        let again = OutwardServerTag.salt(read: { .value(made.base64EncodedString()) },
                                          write: { written.append($0); return true }, random: { Self.saltB })
        #expect(again == made, "a stored salt is read, not replaced")
        #expect(written.count == 1)

        for read in [KeychainRead.unreadable, .undecodable, .value("not base64"), .value(Data([1, 2]).base64EncodedString())] {
            let none = OutwardServerTag.salt(read: { read }, write: { written.append($0); return true }, random: { Self.saltB })
            #expect(none == nil, "\(read) gives no salt")
        }
        #expect(written.count == 1, "a keychain that cannot read writes no new salt")

        #expect(OutwardServerTag.salt(read: { .missing }, write: { _ in false }, random: { made }) == nil,
                "a salt that could not be written is not used")
    }

    @Test("das Salz bleibt auf diesem Geraet, und nur der Typ des Etiketts kennt es", .needsTheSources)
    func theSaltStaysHere() throws {
        let tagFile = try FetchAnswerTests.squeezedSource("Sources/Networking/OutwardServerTag.swift")
        #expect(tagFile.contains("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly"))
        #expect(!tagFile.contains("synchronizable"), "the salt never travels")
        var naming: [String] = []
        var building: [String] = []
        for (file, text) in ProjectFileIntegrityTests.sourceTexts() {
            let squeezed = FetchAnswerTests.squeezed(text)
            if squeezed.contains("outwardSalt") || squeezed.contains("OutwardServerTag.salt(") { naming.append(file) }
            if squeezed.contains("OutwardItemRef.ref(") || squeezed.contains("OutwardItemRef.itemId(") { building.append(file) }
        }
        #expect(naming == ["OutwardServerTag.swift"], "the salt is named elsewhere: \(naming)")
        #expect(building.sorted() == ["AppShortcuts.swift"], "an outward id is built outside the entities: \(building)")
    }
}
#endif
