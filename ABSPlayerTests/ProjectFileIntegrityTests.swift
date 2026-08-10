// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// Fence against Xcode's automatic pbxproj damage: with the project open,
/// Xcode injects a reference to the project INTO ITSELF whenever the tree
/// underneath changes (measured three times in one day) — the build survives,
/// so nothing notices until it is committed. This turns the guard into the
/// evidence chain: the run goes red BEFORE the commit, not silently healed
/// afterwards.
///
/// The project file is read from the source path baked in at compile time. If
/// it is not readable (a run on a device, a copied checkout), the case reports
/// nothing rather than failing on the environment — the check has value where
/// the damage happens, on the build machine.
struct ProjectFileIntegrityTests {
    private static var projectFile: String? {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testsDir.deletingLastPathComponent()
            .appendingPathComponent("Maer.xcodeproj/project.pbxproj")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Zero, not one: the last remaining `wrapper.pb-project` entry was the
    /// ORIGINAL injection (3648644) — a full self-subproject reference (file
    /// reference + Products group + `projectReferences` entry), not the
    /// orphan line it looked like. It is gone since the root fix, so the
    /// fence now says what it means instead of tolerating one corpse.
    @Test("pbxproj: the project never references itself")
    func noSelfReference() throws {
        guard let text = Self.projectFile else { return }
        let count = text.components(separatedBy: "wrapper.pb-project").count - 1
        #expect(count == 0,
                "the project references itself — Xcode injected it; heal with git checkout -- Maer.xcodeproj/project.pbxproj")
    }

    /// Since e885a01 the app target's synchronised group carries
    /// `path = Sources`. That is the STRUCTURAL guarantee behind two things
    /// that used to need maintenance: the project file cannot reference
    /// itself (it lies outside the swept folder), and nothing from the repo
    /// root — docs, screenshots, test fixtures, tooling config, the local
    /// key file — can be swept into the app bundle. Lose the path and both
    /// problems return silently, so it is nailed down here.
    /// The app-store permission (LICENSE-ADDITIONAL-TERMS, part 1) can only be granted
    /// weil er ALLEINIGER Rechteinhaber ist — und das ist er nur, solange das
    /// Projekt keine Fremdabhängigkeit einzieht. Eine still dazugekommene
    /// SPM-Abhängigkeit brächte fremden Code (und fremde Lizenz) in dieselbe
    /// Binärdatei und würde die Ausnahme aushöhlen, ohne dass jemand es
    /// bemerkt. Deshalb ist die Zahl hier festgenagelt: 0.
    /// GPL § 7 verlangt den Hinweis auf Zusatzbedingungen ausdrücklich **in
    /// den Quelldateien** („in the relevant source files … a notice indicating
    /// where to find the applicable terms") — nicht nur in der Wurzel. Eine
    /// neue Datei ohne diese Zeile ließe die Bedingung still ausfallen, und
    /// niemand würde es merken. Derselbe Mechanismus wie beim pbxproj-Zaun.
    @Test("every source file carries copyright, SPDX and the additional-terms notice")
    func everySourceFileCarriesTheLicenceHeader() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        var checked = 0
        for folder in ["Sources", "MaerWidgets", "LiveActivityWidget"] {
            let dir = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                checked += 1
                let head = text.prefix(400)
                if !head.contains("Copyright (C)")
                    || !head.contains("SPDX-License-Identifier: GPL-3.0-or-later")
                    || !head.contains("see LICENSE-ADDITIONAL-TERMS") {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        // Not readable (device run) ⇒ nothing to say, like the other cases.
        guard checked > 0 else { return }
        #expect(offenders.isEmpty,
                "source files without the full licence header — GPL §7 requires the notice in the files")
    }

    @Test("no third-party dependency sneaks in (the licence exception rests on it)")
    func noExternalDependencies() throws {
        guard let text = Self.projectFile else { return }
        #expect(!text.contains("XCRemoteSwiftPackageReference"),
                "a new SPM dependency changes the licence situation — see LICENSE-ADDITIONAL-TERMS")
        #expect(!text.contains("XCLocalSwiftPackageReference"))
        #expect(!text.contains("packageProductDependencies = (\n\t\t\t\tXC"),
                "a package product was linked into a target")
        // Both licence documents ship with the app (same reason LICENSE does).
        #expect(text.contains("LICENSE-ADDITIONAL-TERMS in Resources"),
                "the additional terms must travel with the binary they apply to")
    }

    /// Auftrag afd452a: ein vollstaendiges JWT stand im Klartext in einer
    /// gewoehnlichen View-Datei (`SetupView`, Demo-Zugang) — also im
    /// oeffentlichen Spiegel und dauerhaft in der Historie. Der Zugang ist
    /// zurueckgebaut; dieser Zaun sorgt dafuer, dass so etwas nicht als
    /// „nur kurz zum Testen" wiederkommt. JWTs haben eine erkennbare Form
    /// (`eyJ` = base64 von `{"`), das genuegt als Muster.
    @Test("no access token is hard-coded in the sources")
    func noHardCodedTokens() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        var checked = 0
        for folder in ["Sources", "MaerWidgets", "LiveActivityWidget"] {
            let dir = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                checked += 1
                // Ein JWT im Quelltext: "eyJ" gefolgt von base64 und einem Punkt.
                if text.range(of: #""eyJ[A-Za-z0-9_-]{8,}\."#, options: .regularExpression) != nil {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        guard checked > 0 else { return }
        #expect(offenders.isEmpty,
                "a JWT is hard-coded in the sources — credentials belong in App Store Connect's review notes, never in a shipped file")
    }

    /// Befund 09.08.: SECHS handgepflegte User-Agent-Zeichenketten mit vier
    /// Versionswerten und zwei Adressen — eine davon nannte die private Forge und
    /// ging bei jedem Kuenstlerbild-Abruf nach draussen. Jetzt gibt es genau
    /// eine, aus der Bundle-Version abgeleitet. Der Zaun haelt das: kein
    /// hartkodiertes `Maer/<Ziffer>` mehr in den Quellen, und die eine
    /// Definition steht in `AppUserAgent`.
    @Test("exactly one User-Agent, and no hard-coded version literal")
    func oneUserAgent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return }
        var literals: [String] = []
        var definitions = 0
        var checked = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            if url.lastPathComponent == "AppUserAgent.swift" {
                definitions += text.components(separatedBy: "\"Maer/\\(").count - 1
                continue
            }
            if text.range(of: #""Maer/[0-9]"#, options: .regularExpression) != nil {
                literals.append(url.lastPathComponent)
            }
        }
        guard checked > 0 else { return }
        #expect(literals.isEmpty,
                "a hard-coded User-Agent version — it drifts, and one of them once carried the private forge")
        #expect(definitions == 1, "the identification is defined exactly once")
    }

    /// Architektur-Befund 09.08.: die acht Katalogquellen hatten ein zweites,
    /// handgeschriebenes Aktivierungssystem — die Vorgabe „an" stand 35× in
    /// elf Dateien. Heute stimmten alle 35 überein; erzwungen hat das
    /// niemand, ein `bool(forKey:)` an einer Stelle hätte sie gekippt.
    /// Jetzt steht sie einmal je Quelle in `AppStorageKeys`. Ohne diesen Zaun
    /// ist der Aufräumtag in drei Monaten rückgängig gemacht.
    @Test("the default 'on' lives in exactly one file")
    func noScatteredDefaults() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else { return }
        var offenders: [String] = []
        var checked = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            if url.lastPathComponent == "AppStorageKeys.swift" { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            if text.contains("as? Bool ?? true") { offenders.append(url.lastPathComponent) }
        }
        guard checked > 0 else { return }
        #expect(offenders.isEmpty,
                "a default value composed outside AppStorageKeys — that is how 35 copies grew")
    }

    @Test("pbxproj: the app target syncs Sources, not the repo root")
    func appTargetSyncsSourcesOnly() throws {
        guard let text = Self.projectFile else { return }
        #expect(text.contains("path = Sources;"),
                "the synchronised app group lost `path = Sources` — the repo root would be swept again (self-reference + bundle pollution)")
        #expect(text.contains("Config/App.xcconfig"),
                "the app target lost its base configuration")
        // What the app genuinely needs from the root is explicit now.
        #expect(text.contains("Assets.xcassets in Resources"),
                "the asset catalogue lives in the repo root and must stay explicitly referenced")
        #expect(text.contains("LICENSE in Resources"),
                "the licence is shipped on purpose (GPL) and must stay explicitly referenced")
    }

    /// The listening mark is `[position, timestamp, duration at the time]` —
    /// an entry with a third value is VALID. Anything checking `count == 2`
    /// discards it silently; that happened three times (the iCloud sync would
    /// have stopped played episodes from travelling, the player would have lost
    /// resume, and the measuring instrument filtered out exactly the entries it
    /// was built to measure).
    ///
    /// The fence knows the KEY, not the number: `count == 2` is perfectly
    /// correct elsewhere (byte frames in the download manager, URL parts, lyric
    /// timestamps) and must not be caught with it.
    @Test("no reader of localPosition checks for count == 2")
    func noPositionReaderChecksForExactlyTwo() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var offenders: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("localPosition") {
                // Read and shape check often sit on consecutive lines (a
                // multi-line guard), so a small window catches both.
                let window = lines[index..<min(index + 4, lines.count)].joined(separator: " ")
                if window.contains("count == 2") {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty,
                "these readers silently discard entries that carry a stored duration: \(offenders)")
    }

    /// The reader fence alone was not enough: a writer that stores a raw
    /// `[position, ts]` drops the reference point just as silently — the
    /// five-second writer in the player did it on every playback. So
    /// `localPosition` is only written through `ProgressMark`
    /// (`entry`/`advancing`/`supplementing`) or by moving an existing value
    /// unchanged. Never an array literal.
    @Test("no array literal is written to a localPosition key")
    func noRawArrayIsWrittenToAPositionKey() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var offenders: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("set([") {
                // Key and value often sit in one statement across several
                // lines — a window catches both spellings.
                let start = max(0, index - 2)
                let window = lines[start..<min(index + 3, lines.count)].joined(separator: " ")
                if window.contains("localPosition") {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty,
                "these writers build the entry themselves and lose the stored duration: \(offenders)")
    }

    /// **Whoever answers "played" calls `ProgressMark`.**
    ///
    /// The pattern behind five occurrences was not sloppiness: the rule lived
    /// at the places where it had been reported, and nowhere did it say that it
    /// applies everywhere. Two forms are expressible and both fail silently, so
    /// the test fails instead of the user:
    ///  * a comparison against a duration outside `ProgressMark`
    ///  * `.last` used as a timestamp on a `localPosition` entry (since the
    ///    third value exists, `.last` is the DURATION)
    ///
    /// An exemption is bound to the LINE, not to a file: a marker
    /// `// progress-fence: server payload` next to the comparison. A file name
    /// in a list at the other end of the project exempts everything in it
    /// forever — a 700-line provider went blind that way, and the tenth
    /// occurrence of this very class hid behind it.
    @Test("the played decision is not reimplemented anywhere")
    func playedDecisionIsNotReimplemented() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var offenders: [String] = []
        for file in files where file.lastPathComponent != "ProgressMark.swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.split(separator: "/").first.map(String.init) ?? line
                if line.contains("progress-fence:") { continue }
                if code.contains(">= duration - 1") || code.contains(">= currentDuration - 1")
                    || code.contains(">= total - 1") {
                    offenders.append("\(file.lastPathComponent):\(index + 1) (Dauer-Vergleich)")
                }
                if code.contains("localPosition(") && code.contains(").last") {
                    offenders.append("\(file.lastPathComponent):\(index + 1) (.last als Zeitstempel)")
                }
            }
        }
        #expect(offenders.isEmpty,
                "these places reimplement the played decision instead of calling ProgressMark: \(offenders)")
    }
}
#endif
