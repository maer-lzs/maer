// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The map of areas. What Mär consists of and what each area needs.
///
/// It exists because the first screen used to be an Audiobookshelf login with
/// an emergency exit: nowhere did it say what Mär is, and the exit advertised
/// podcasts only, although THREE of five areas run without any account. The map
/// answers both at once, and it is the same list in two places (first run and
/// settings). One component, never two lists of the same thing.
///
/// Pure and Foundation-only on purpose: the states are derived facts, and a
/// derived fact belongs in a place a test can reach without a screen.
nonisolated enum SourceMapArea: String, CaseIterable, Identifiable, Sendable {
    case audiobooks
    case music
    case podcasts
    case radio
    case freeCatalogs

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .audiobooks: return "books.vertical"
        case .music: return "music.note"
        case .podcasts: return "mic"
        case .radio: return "dot.radiowaves.left.and.right"
        case .freeCatalogs: return "building.columns"
        }
    }

    /// True only where the area is empty without a server of the user's own.
    /// Podcasts, radio and the free catalogs are NOT in here. That is the
    /// whole point of the map.
    var requiresServer: Bool {
        self == .audiobooks || self == .music
    }
}

/// What the map knows about the user's servers. Hosts only. A display line
/// never carries credentials, the same rule the Pinchflat logging follows.
nonisolated struct SourceMapFacts: Equatable, Sendable {
    var absConnected = false
    var absServer = ""
    var subsonicConfigured = false
    var subsonicServer = ""
    var jellyfinConfigured = false
    var jellyfinServer = ""
    var gpodderConfigured = false
    var gpodderServer = ""
    /// The Mär sync service: its standing and host, from the one reader the
    /// service's page reads too. Never credentials.
    var syncStanding: MaerSyncStanding = .notInUse
    var syncHost: String?

    init() {}
}

/// The one line of the map's Mär Sync row: what the service does for this
/// device, and whether it carries (the tick). Not a media area.
nonisolated enum SourceMapSyncLine {
    static func of(_ standing: MaerSyncStanding, host: String?) -> (text: String, connected: Bool) {
        let name = host ?? "Mär Sync"
        switch standing {
        case .carrying: return (String(localized: "Connected to \(name)"), true)
        case .fromTheNextStart: return (String(localized: "Connected to \(name) · from the next start"), false)
        case .notInUse: return (String(localized: "Not set up · tap to set up"), false)
        case .tokenRefused: return (String(localized: "Sign-in refused · tap to fix"), false)
        case .serviceOlder: return (String(localized: "The service is older than this app"), false)
        case .stalledUntilRestart: return (String(localized: "Signed out · restart the app to go on"), false)
        case .switchedOff: return (String(localized: "Syncing between devices is off"), false)
        }
    }
}

nonisolated enum SourceMapState: Equatable, Sendable {
    /// A server of the user's own answers for this area.
    case connected(host: String)
    /// Works, but is empty until a server is attached.
    case needsServer
    /// Works right away, no account at all.
    case ready
    /// Works right away AND is synced with an optional server (gpodder).
    case readySynced(host: String)
}

extension SourceMapFacts {
    func state(of area: SourceMapArea) -> SourceMapState {
        switch area {
        case .audiobooks:
            let host = SourceMap.host(from: absServer)
            return absConnected && !host.isEmpty ? .connected(host: host) : .needsServer
        case .music:
            // One music server at a time, Subsonic first. The same order the
            // provider choice uses, so the line cannot claim a server that is
            // not the one being asked.
            if subsonicConfigured, case let host = SourceMap.host(from: subsonicServer), !host.isEmpty {
                return .connected(host: host)
            }
            if jellyfinConfigured, case let host = SourceMap.host(from: jellyfinServer), !host.isEmpty {
                return .connected(host: host)
            }
            return .needsServer
        case .podcasts:
            let host = SourceMap.host(from: gpodderServer)
            return gpodderConfigured && !host.isEmpty ? .readySynced(host: host) : .ready
        case .radio, .freeCatalogs:
            return .ready
        }
    }
}

nonisolated enum SourceMap {
    /// Host of a stored server address, for the "connected with …" line.
    /// Strips scheme, path and, deliberately, any `user:pass@` part: a
    /// stored address may carry credentials, and a screen line must not.
    static func host(from urlString: String) -> String {
        var rest = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }
        if let at = rest.lastIndex(of: "@") { rest = String(rest[rest.index(after: at)...]) }
        return rest
    }
}
