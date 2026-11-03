// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The id a title carries out of the app, to Siri and the system's indexes,
/// and the way back. The app keeps and carries its own ids; this one is
/// built when an id is handed out and is never stored.
///
/// A library id carries no server, so outside it names its server by a tag:
/// `abs.<tag>.<id>`. The tag stands for the server the owner register names
/// and is a keyed hash over its name (`OutwardServerTag`), so
/// no address leaves the device and another device gives another tag. An id
/// without an owner has no tag and is not handed out.
///
/// The tag keeps the ids of two servers apart where they are listed, in
/// the system's indexes; the way back asks only the register.
nonisolated enum OutwardItemRef {
    /// The kind of an Audiobookshelf library id.
    static let libraryKind = "abs"

    /// The three parts of an outward id: split at the first two dots, the
    /// rest stays whole, dots and colons included.
    struct Parts: Equatable, Sendable {
        let kind: String
        let tag: String
        let rest: String
    }

    /// The outward id of a library id on the server `serverTag` stands for;
    /// nil for an id with a namespace and for a missing or malformed tag.
    static func ref(itemId: String, serverTag: String?) -> String? {
        guard !itemId.isEmpty, ItemNamespace.of(itemId) == nil,
              let serverTag, isTag(serverTag) else { return nil }
        return "\(libraryKind).\(serverTag).\(itemId)"
    }

    static func parts(of ref: String) -> Parts? {
        guard let first = ref.firstIndex(of: ".") else { return nil }
        let afterFirst = ref.index(after: first)
        guard let second = ref[afterFirst...].firstIndex(of: ".") else { return nil }
        let parts = Parts(kind: String(ref[..<first]),
                          tag: String(ref[afterFirst..<second]),
                          rest: String(ref[ref.index(after: second)...]))
        guard !parts.kind.isEmpty, !parts.tag.isEmpty, !parts.rest.isEmpty else { return nil }
        return parts
    }

    /// The library id an outward id stands for, when that id has an owner on
    /// this device; nil for an id without an owner and for what is no
    /// outward id. The tag does not decide the way back: an outward id from
    /// another device, or from an earlier address of the server, carries
    /// another tag and still names a book this device has.
    static func itemId(ref: String, tagOf: (String) -> String?) -> String? {
        guard let parts = parts(of: ref), parts.kind == libraryKind,
              ItemNamespace.of(parts.rest) == nil,
              tagOf(parts.rest) != nil else { return nil }
        return parts.rest
    }

    /// The length of a tag in hex digits.
    static let tagLength = 12

    /// A tag is `tagLength` lowercase hex digits, the form `OutwardServerTag` makes.
    static func isTag(_ text: String) -> Bool {
        text.count == tagLength && text.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
