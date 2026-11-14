// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// The timestamps of the music servers, read as the pair of
/// `ISO8601DateFormatter`s read them before (fractional first, then the
/// plain internet form). Every expected value in the table is what that
/// pair gave, measured on 27.09.2026 over the same strings, so the switch to
/// `Date.ISO8601FormatStyle` moves no sort.
struct ServerTimestampTests {
    static let table: [(String, Double?)] = [
        ("2024-03-10T18:22:05Z", 1_710_094_925_000),
        ("2024-03-10T18:22:05.000Z", 1_710_094_925_000),
        ("2024-03-10T18:22:05.8Z", 1_710_094_925_800),
        ("2024-03-10T18:22:05.891Z", 1_710_094_925_891),
        // More digits than milliseconds: Navidrome (Go) sends up to nine,
        // .NET servers seven. The old pair cut them; so does the rule.
        ("2024-03-10T18:22:05.891231Z", 1_710_094_925_891),
        ("2024-03-10T18:22:05.8912310Z", 1_710_094_925_891),
        ("2024-03-10T18:22:05.123456789Z", 1_710_094_925_123),
        ("2024-03-10T18:22:05.9999Z", 1_710_094_925_999),
        ("2024-03-10T18:22:05.9995Z", 1_710_094_925_999),
        ("2024-03-10T18:22:05.0001Z", 1_710_094_925_000),
        ("2024-03-10T20:22:05+02:00", 1_710_094_925_000),
        ("2024-03-10T20:22:05.5+02:00", 1_710_094_925_500),
        ("2024-03-10T20:22:05+0200", 1_710_094_925_000),
        ("1970-01-01T00:00:00Z", 0),
        ("2038-01-19T03:14:08Z", 2_147_483_648_000),
        // No zone, a date alone, a space, lower case, nothing: no timestamp.
        ("2024-03-10T18:22:05", nil),
        ("2024-03-10T18:22:05.891", nil),
        ("2024-03-10", nil),
        ("2024-03-10 18:22:05Z", nil),
        ("2024-03-10t18:22:05z", nil),
        ("", nil),
        ("not a date", nil),
    ]

    @Test("Server timestamps: the same milliseconds as before, also with more than three decimal places")
    func sameMomentsAsBefore() {
        for (raw, expected) in Self.table {
            #expect(ServerTimestamp.milliseconds(raw) == expected, "\(raw)")
            // The date carries the same millisecond; a division by 1000 is not
            // exact in binary, so the way back rounds to the millisecond.
            #expect(ServerTimestamp.date(raw).map { ($0.timeIntervalSince1970 * 1000).rounded() } == expected, "\(raw) as a date")
        }
    }

    @Test("Both readers of the server timestamps ask the one rule", .needsTheSources)
    func bothReadersAskTheRule() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let subsonic = try String(contentsOf: root.appendingPathComponent("Sources/Providers/SubsonicProvider.swift"), encoding: .utf8)
        let playlists = try String(contentsOf: root.appendingPathComponent("Sources/Models/PlaylistPresentation.swift"), encoding: .utf8)
        #expect(subsonic.contains("return ServerTimestamp.milliseconds(raw)"), "Subsonic created")
        #expect(playlists.contains("return ServerTimestamp.date(iso)"), "playlist changed")
        #expect(!subsonic.contains("ISO8601DateFormatter") && !playlists.contains("ISO8601DateFormatter"),
                "no second parser beside the rule")
    }
}
#endif
