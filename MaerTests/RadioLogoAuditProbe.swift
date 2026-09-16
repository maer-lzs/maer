// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
import UIKit
@testable import Maer

/// The logo audit over the APP PATH. Fold → table → (store: empty
/// on a fresh run, declared) → chain, driven through the app's own code
/// (`RadioMapping.displayName`, `RadioLogoData`, `RadioLogoService.auditChain`)
/// instead of a tool-side re-implementation (the cover-saga lesson). Gated:
/// network, minutes of runtime. Never part of the routine suites.
///
/// Output goes to stdout (xcodebuild log); the run books NOTHING
/// (`auditChain` measures without caching or persisting).
@Suite struct RadioLogoAuditProbe {

    /// Gate + output: the TEST_RUNNER_ env does not reach the hosted unit
    /// process reliably, and its stdout is not in the xcodebuild log. So the
    /// gate is a marker FILE and the output goes to a file next to it (the
    /// sim shares the host filesystem; the source-scan fences rely on the
    /// same fact).
    // NOT /tmp and NOT ~: both resolve into the sim container. The host
    // path is derived from #filePath. The same fact the source-scan fences
    // stand on.
    // `nonisolated`, weil die Bedingung am Fall sie VOR dem Lauf liest und
    // eine isolierte Eigenschaft dort nicht erreichbar ist. Der Wert ist ein
    // Pfad und gehoert keinem Actor.
    nonisolated static let hostHome = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()   // repo root
        .deletingLastPathComponent().deletingLastPathComponent()   // user home
    nonisolated static let gate = hostHome.appendingPathComponent(".maer-logo-audit").path
    private static let out = hostHome.appendingPathComponent(".maer-logo-audit-out.txt").path

    private func emit(_ line: String) {
        print(line)
        let handle = FileHandle(forWritingAtPath: Self.out)
        if let handle {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            try? handle.close()
        } else {
            try? (line + "\n").write(toFile: Self.out, atomically: true, encoding: .utf8)
        }
    }

    /// The same target set as the generator: every name in the core tables,
    /// read from the app's own sources (identical regex to `core_names()`).
    private func coreNames() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var out = ["Deutschlandfunk Kultur", "Deutschlandfunk Nova"]   // EXTRA_NAMES
        for file in ["RadioListenerCores.swift", "RadioWikidataCores.swift"] {
            let text = try String(
                contentsOf: root.appendingPathComponent("Sources/Models/\(file)"),
                encoding: .utf8)
            let regex = try NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)*)\"")
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let hit = String(text[range])
                if hit.count >= 2, !hit.hasSuffix(":"), !out.contains(hit) { out.append(hit) }
            }
        }
        return out
    }

    /// The station record behind a core name. The chain needs homepage and
    /// favicon, and the catalog is where the app itself gets them.
    private func catalogRecord(name: String) async
        -> (homepage: String?, favicon: String?, votes: Int)? {
        guard let mirror = RadioBrowserClient.mirrors.first,
              let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(mirror)/json/stations/byname/\(encoded)?limit=20&hidebroken=true")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Maer/audit", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        // The best witness for THIS station: fold-equal name, most votes.
        let folded = RadioMapping.displayName(name)
        let kin = list.filter {
            RadioMapping.displayName(($0["name"] as? String) ?? "") == folded
        }
        let best = kin.max { (($0["votes"] as? Int) ?? 0) < (($1["votes"] as? Int) ?? 0) }
        guard let best else { return nil }
        return (homepage: best["homepage"] as? String,
                favicon: (best["favicon"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                votes: (best["votes"] as? Int) ?? 0)
    }

    /// Does the table's Commons thumb actually RENDER at the width the app
    /// requests? Status alone was blind: MediaWiki serves rasters
    /// `thumbnail_unscaled`, so a 256×37 wordmark answers 200 and then dies
    /// at the app's 48-px gate. A gate corpse, not a live thumb.
    private func thumbLoads(file: String) async -> Bool {
        guard let url = ArtistPortraitLookup.commonsThumbURL(fileName: file, width: 800)
        else { return false }
        var request = URLRequest(url: url)
        request.setValue("Maer/audit", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let image = UIImage(data: data) else { return false }
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        return min(pixelWidth, pixelHeight) >= 48
    }

    /// Der Lauf haengt an einer Marke auf dem Wirt, und die Bedingung steht
    /// jetzt VOR dem Lauf: ohne Marke erscheint er als uebersprungen statt als
    /// bestanden. Vorher stand hier ein Wachposten mit dem Satz, Swift Testing
    /// habe kein Ueberspringen. Es hat eines, es heisst nur nicht so.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: RadioLogoAuditProbe.gate),
                   "die Marke fuer den Bild-Lauf liegt nicht auf dem Wirt"))
    func auditRun() async throws {
        let names = try coreNames()
        emit("AUDIT beginn: \(names.count) Kern-Namen")

        var tableHits = 0, deadThumbs: [String] = []
        var gaps: [(name: String, verdict: String)] = []
        var faviconOnly: [String] = []

        for (index, name) in names.enumerated() {
            let folded = RadioMapping.displayName(name)
            if let file = RadioLogoData.commonsFile(forName: folded) {
                tableHits += 1
                if await !thumbLoads(file: file) {
                    deadThumbs.append("\(name) → \(file)")
                    emit("AUDIT TOT: \(name) → \(file)")
                }
                continue
            }
            // Table miss → what the app would do: favicon first (tile), the
            // chain for the real logo.
            let record = await catalogRecord(name: name)
            let verdict = await RadioLogoService.shared.auditChain(
                name: name, homepage: record?.homepage)
            if verdict.hasPrefix("TREFFER") {
                gaps.append((name, verdict))   // chain covers it — not initial
            } else if record?.favicon != nil {
                faviconOnly.append("\(name) · Kette: \(verdict)")
            } else {
                gaps.append((name, "INITIALEN — kein Favicon · Kette: \(verdict)"))
            }
            emit("AUDIT [\(index + 1)/\(names.count)] \(name): \(verdict)")
        }

        emit("""

        AUDIT SUMME
        Kern-Namen:      \(names.count)
        Tabelle deckt:   \(tableHits)
        tote Tabellen-Thumbs: \(deadThumbs.count)
        Ketten-/Lücken-Kandidaten: \(gaps.count)
        nur Favicon (Kachel zeigt Bild, kein Logo): \(faviconOnly.count)
        """)
        for line in deadThumbs { emit("TOT: \(line)") }
        for gap in gaps { emit("LUECKE: \(gap.name) · \(gap.verdict)") }
        for line in faviconOnly { emit("FAVICON-NUR: \(line)") }
    }

    /// The validity probe demanded by the order: ONE station measured through
    /// the full chain, verbosely. If the audit cannot explain the NDR Info
    /// result, it measured past the app path.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: RadioLogoAuditProbe.gate),
                   "die Marke fuer den Bild-Lauf liegt nicht auf dem Wirt"))
    func ndrInfoSingleChain() async throws {
        let name = "NDR Info"
        let folded = RadioMapping.displayName(name)
        emit("NDR-PROBE Faltung: \(name) → \(folded)")
        emit("NDR-PROBE Tabelle: \(RadioLogoData.commonsFile(forName: folded) ?? "kein Eintrag")")
        let record = await catalogRecord(name: name)
        emit("NDR-PROBE Katalog: homepage=\(record?.homepage ?? "—") "
              + "favicon=\(record?.favicon ?? "—") votes=\(record?.votes ?? 0)")
        let verdict = await RadioLogoService.shared.auditChain(
            name: name, homepage: record?.homepage)
        emit("NDR-PROBE Kette: \(verdict)")
    }
}

#endif
