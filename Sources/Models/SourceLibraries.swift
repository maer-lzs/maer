// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// One library of a source, reduced to what an assignment needs. A Subsonic
/// server calls these "music folders"; the app has exactly one word for the
/// level a server separates its stock on, and this is it.
nonisolated struct SourceLibrary: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let name: String
}

/// Which library feeds which media type. Absent = not assigned yet, which is a
/// state the surface has to SHOW, never one to guess away.
///
/// One library feeds at most ONE type: a folder that is both music and
/// audiobooks would put the same album in two tabs under two mappings (albums
/// as records vs. albums as books), and no answer to "which one is the truth"
/// exists that the user did not give.
nonisolated struct SourceLibraryAssignment: Equatable, Sendable {
    var byLibrary: [String: MediaType]

    init(byLibrary: [String: MediaType] = [:]) {
        self.byLibrary = byLibrary
    }

    subscript(libraryId: String) -> MediaType? {
        get { byLibrary[libraryId] }
        set { byLibrary[libraryId] = newValue }
    }

    /// Assignments for libraries the server no longer reports are dead weight —
    /// they would keep a mode looking complete after the folder is gone.
    func pruned(toKnown known: [SourceLibrary]) -> SourceLibraryAssignment {
        let ids = Set(known.map(\.id))
        return SourceLibraryAssignment(byLibrary: byLibrary.filter { ids.contains($0.key) })
    }
}

/// THE derivation of "what does this source feed a given type" — one rule, read
/// by the provider, by the activation gate and by the settings surface, so the
/// three can never answer differently.
nonisolated enum SourceLibraries {

    /// The libraries that feed `type`.
    ///
    /// The `count <= 1` branch is the promise this whole train has to keep: a
    /// source with ONE mode behaves exactly as it did before there was such a
    /// thing as an assignment — everything it has feeds its one type, no
    /// library list is consulted, and a user who never opens the assignment
    /// surface never notices it exists. It also means the rule stays correct
    /// before any library list has been fetched, which is the state every
    /// existing installation starts its next launch in.
    static func libraries(for type: MediaType,
                          modes: SourceModes,
                          known: [SourceLibrary],
                          assignment: SourceLibraryAssignment) -> [String] {
        guard modes.serves(type) else { return [] }
        if modes.count <= 1 { return known.map(\.id) }
        return known.filter { assignment[$0.id] == type }.map(\.id)
    }

    /// May this source hold a connection at all?
    ///
    /// Deliberately NOT the same question as "does it feed a tab", and keeping
    /// them apart is the whole point: the moment a second mode is switched on,
    /// no type can be delivered yet — nothing is assigned. If that answer also
    /// governed the connection, switching the mode on would drop the client,
    /// and the library list needed to fix it could never be fetched. The source
    /// would be locked out of its own setup by the act of starting it.
    ///
    /// So: a source lives while the user wants it, has asked for at least one
    /// thing, and at least one of those things has its tab on.
    static func isLive(modes: SourceModes, enabled: Bool, enabledTabs: Set<MediaType>) -> Bool {
        guard enabled, !modes.isEmpty else { return false }
        return modes.types.contains(where: enabledTabs.contains)
    }

    /// Whether the source effectively serves `type` at all.
    ///
    /// With one mode this is the mode itself — deliberately NOT "and it has a
    /// library", because an empty library list means "not fetched yet" just as
    /// often as it means "nothing there", and reading the first as the second
    /// would switch off a working source at launch.
    static func serves(_ type: MediaType,
                       modes: SourceModes,
                       known: [SourceLibrary],
                       assignment: SourceLibraryAssignment) -> Bool {
        guard modes.serves(type) else { return false }
        if modes.count <= 1 { return true }
        return !libraries(for: type, modes: modes, known: known, assignment: assignment).isEmpty
    }

    /// Modes the user switched on that cannot deliver yet. The surface
    /// names these; it never shows a tab for one of them.
    static func incompleteModes(modes: SourceModes,
                                known: [SourceLibrary],
                                assignment: SourceLibraryAssignment) -> [MediaType] {
        guard modes.count > 1 else { return [] }
        return modes.types.filter {
            libraries(for: $0, modes: modes, known: known, assignment: assignment).isEmpty
        }
    }

    /// Why an assignment can or cannot be completed — the difference between
    /// "you still have to choose" and "this server cannot do what you asked",
    /// which are two different things to say to someone.
    enum Separability: Equatable {
        /// One mode (or none): there is nothing to separate.
        case notNeeded
        /// The library list is not in yet.
        case unknown
        /// Enough libraries to give every mode its own.
        case possible
        /// The server reports fewer libraries than the user switched on modes,
        /// so at least one mode must stay empty whatever is chosen.
        case impossible(libraryCount: Int)
    }

    static func separability(modes: SourceModes, known: [SourceLibrary]) -> Separability {
        guard modes.count > 1 else { return .notNeeded }
        if known.isEmpty { return .unknown }
        return known.count >= modes.count ? .possible : .impossible(libraryCount: known.count)
    }
}
