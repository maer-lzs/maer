// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// No public log line carries an address with credentials. Measured on 29:
/// the cover trace printed a Subsonic address with user, token and
/// salt at default level. A `privacy: .public` interpolation whose
/// expression names a URL is counted; only a masked address, a host, or
/// the cover trace's own builder (host and path, never the query) pass.
/// The stock names the public catalogue streams that carry no credentials.
struct PublicLogAddressFenceTests {
    /// The interpolations `\(expr, privacy: .public)` of a file whose
    /// expression looks like an address and is not made safe.
    nonisolated static func addressInterpolations(in text: String) -> [String] {
        var out: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { continue }
            var rest = Substring(line)
            while let range = rest.range(of: ", privacy: .public") {
                let before = rest[..<range.lowerBound]
                // The interpolation's own opening, not a paren inside it.
                guard let open = before.range(of: "\\(", options: .backwards) else { break }
                let expr = String(before[open.upperBound...])
                let lower = expr.lowercased()
                let looksLikeAddress = lower.contains("url") || lower.contains("absolutestring")
                // A presence question ("none"/"server") prints no address.
                let madeSafe = lower.contains("masked") || lower.contains(".host") || lower.contains("covertrace.line(")
                    || lower.contains("== nil")
                if looksLikeAddress, !madeSafe { out.append(expr.trimmingCharacters(in: .whitespaces)) }
                rest = rest[range.upperBound...]
            }
        }
        return out
    }

    /// Public catalogue streams (Radio Browser, no account, no token).
    nonisolated static let stock: [String: (count: Int, reason: String)] = [
        "RadioProvider.swift": (1, "radio stream from the public catalogue, no credentials"),
        "PlayerViewModel.swift": (1, "radio stream from the public catalogue, no credentials"),
        "RadioComponents.swift": (1, "radio stream from the public catalogue, no credentials"),
        "RadioDiagnostics.swift": (1, "radio stream from the public catalogue, no credentials (the ICY check)"),
    ]

    @Test("Keine oeffentliche Logzeile traegt eine Adresse mit Zugangsdaten", .needsTheSources)
    func publicLinesCarryNoAddress() throws {
        var counts: [String: Int] = [:]
        var found: [String: [String]] = [:]
        for file in ProjectFileIntegrityTests.sourceFiles() {
            let sites = Self.addressInterpolations(in: try String(contentsOf: file, encoding: .utf8))
            counts[file.lastPathComponent, default: 0] += sites.count
            if !sites.isEmpty { found[file.lastPathComponent, default: []] += sites }
        }
        let drift = StockDrift.findings(counts: counts, stock: Self.stock.mapValues(\.count))
        #expect(drift.isEmpty, "addresses in public log lines, or a stock above the count: \(drift) \(found)")
        #expect(Self.addressInterpolations(in: "Logger.x.notice(\"COVER \\(url.absoluteString, privacy: .public)\")") == ["url.absoluteString"])
        #expect(Self.addressInterpolations(in: "Logger.x.notice(\"feed=\\(feedURL, privacy: .public)\")") == ["feedURL"])
        // The door's own trace must never print the address it fetched.
        #expect(Self.addressInterpolations(in: "Logger.library.notice(\"COVER net \\(coverURL.absoluteString, privacy: .public)\")") == ["coverURL.absoluteString"])
        #expect(Self.addressInterpolations(in: "Logger.x.notice(\"feed=\\(maskedFeedURL(feedURL), privacy: .public)\")").isEmpty)
        #expect(Self.addressInterpolations(in: "Logger.x.notice(\"host=\\(url.host ?? \"-\", privacy: .public)\")").isEmpty)
        #expect(Self.addressInterpolations(in: "Logger.x.notice(\"\\(CoverTrace.line(pot: p, outcome: o, attempt: 1, url: url), privacy: .public)\")").isEmpty)
        #expect(Self.addressInterpolations(in: "Logger.x.notice(\"feed=\\(feedURL, privacy: .private)\")").isEmpty)
        #expect(Self.addressInterpolations(in: "Logger.x.notice(\"source=\\(info?.imageURL == nil ? \"none\" : \"server\", privacy: .public)\")").isEmpty)
    }
}
#endif
