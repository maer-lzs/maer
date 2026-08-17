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
    ///
    /// The detector reads STATEMENTS, not lines: the Apple import wrote its
    /// literal with the bracket on the next line, and the line-window version
    /// of this fence ran green at exactly its target class. The proof run
    /// below feeds that real offender back in.
    private static func rawPositionWriters(in text: String) -> [Int] {
        var offenders: [Int] = []
        var search = text.startIndex
        while let hit = text.range(of: ".set(", range: search..<text.endIndex) {
            search = hit.upperBound
            // The whole statement: from the call up to a window big enough for
            // key + value in either order, whitespace collapsed.
            let windowEnd = text.index(hit.upperBound, offsetBy: 300, limitedBy: text.endIndex) ?? text.endIndex
            let statement = text[hit.lowerBound..<windowEnd]
                .components(separatedBy: .whitespacesAndNewlines).joined()
            guard statement.hasPrefix(".set([") else { continue }
            guard statement.contains("localPosition") else { continue }
            offenders.append(text[..<hit.lowerBound].filter { $0 == "\n" }.count + 1)
        }
        return offenders
    }

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
            for line in Self.rawPositionWriters(in: text) {
                offenders.append("\(file.lastPathComponent):\(line)")
            }
        }
        #expect(offenders.isEmpty,
                "these writers build the entry themselves and lose the stored duration: \(offenders)")
    }

    /// The proof run: the fence must FIND the shape it went blind on — the
    /// import's literal, verbatim, with the bracket on its own line.
    @Test("the position fence catches the multi-line literal it once missed")
    func positionFenceCatchesTheOldImportShape() {
        let oldImport = """
                UserDefaults.standard.set(
                    [time, Date().timeIntervalSince1970 * 1000],
                    forKey: AppStorageKeys.localPosition(episode.guid)
                )
        """
        #expect(Self.rawPositionWriters(in: oldImport).count == 1)
        // The single-line spelling stays caught, and the sanctioned writers
        // stay exempt — the fence names literals, not ProgressMark calls.
        #expect(Self.rawPositionWriters(
            in: "defaults.set([pos, ts], forKey: AppStorageKeys.localPosition(id))").count == 1)
        #expect(Self.rawPositionWriters(
            in: "defaults.set(ProgressMark.advancing(a, position: p, duration: d, nowMs: t), forKey: AppStorageKeys.localPosition(id))").isEmpty)
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
    /// One line's verdict, factored so the proof run below can feed the fence
    /// the exact shapes it went blind on.
    private static func playedReimplementations(inLine line: String) -> [String] {
        let code = line.split(separator: "/").first.map(String.init) ?? line
        guard !line.contains("progress-fence:") else { return [] }
        var kinds: [String] = []
        if code.contains(">= duration - 1") || code.contains(">= currentDuration - 1")
            || code.contains(">= total - 1") {
            kinds.append("Dauer-Vergleich")
        }
        return kinds
    }

    /// `.last` on a progress entry, read as STATEMENTS like the writer fence —
    /// the eighth occurrence broke the expression between `)?` and `.last`
    /// across two lines, and the line-based read fence (and the line-based
    /// sweep that claimed the repo clean) were blind exactly like the writer
    /// fence had been before its proof run.
    ///
    /// Two spellings of the read are known: the key builder in the expression
    /// (`localPosition(`) and the snapshot form (`positions[`) — the seventh
    /// occurrence hid behind the second, the eighth behind the line break.
    private static func lastAsTimestampReads(in text: String) -> [Int] {
        var offenders: [Int] = []
        for needle in ["localPosition(", "positions["] {
            var search = text.startIndex
            while let hit = text.range(of: needle, range: search..<text.endIndex) {
                search = hit.upperBound
                let windowEnd = text.index(hit.upperBound, offsetBy: 160, limitedBy: text.endIndex) ?? text.endIndex
                let window = text[hit.lowerBound..<windowEnd]
                guard !window.contains("progress-fence:") else { continue }
                let collapsed = window.components(separatedBy: .whitespacesAndNewlines).joined()
                // `.last` as its own member — not `.lastPathComponent` etc.
                if collapsed.range(of: #"\.last($|[^A-Za-z])"#, options: .regularExpression) != nil {
                    offenders.append(text[..<hit.lowerBound].filter { $0 == "\n" }.count + 1)
                }
            }
        }
        return offenders
    }

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
                for kind in Self.playedReimplementations(inLine: line) {
                    offenders.append("\(file.lastPathComponent):\(index + 1) (\(kind))")
                }
            }
            for line in Self.lastAsTimestampReads(in: text) {
                offenders.append("\(file.lastPathComponent):\(line) (.last als Zeitstempel)")
            }
        }
        #expect(offenders.isEmpty,
                "these places reimplement the played decision instead of calling ProgressMark: \(offenders)")
    }

    /// The proof run: the read fence must FIND every shape it went blind on —
    /// the seventh occurrence (snapshot spelling), the optional chain, and the
    /// eighth (the expression broken across two lines).
    @Test("the read fence catches every shape it once missed")
    func readFenceCatchesTheOldShapes() {
        #expect(Self.lastAsTimestampReads(
            in: "            let localTs = snapshot.positions[eqId]?.last ?? 0").count == 1)
        #expect(Self.lastAsTimestampReads(
            in: "let ts = defaults.array(forKey: AppStorageKeys.localPosition(id))?.last").count == 1)
        // The eighth occurrence, verbatim: the line break between `)?` and
        // `.last` blinded the line-based fence AND the line-based sweep.
        let eighth = """
        let ts = (UserDefaults.standard.array(forKey: AppStorageKeys.localPosition(guid)) as? [Double])?
            .last ?? Date().timeIntervalSince1970 * 1000
        """
        #expect(Self.lastAsTimestampReads(in: eighth).count == 1)
        // Sanctioned reads stay exempt — the wrapper and unrelated members.
        #expect(Self.lastAsTimestampReads(
            in: "let ts = ProgressMark.timestamp(snapshot.positions[eqId]) ?? 0").isEmpty)
        #expect(Self.lastAsTimestampReads(
            in: "let name = AppStorageKeys.localPosition(id); let x = url.lastPathComponent").isEmpty)
    }
}
#endif

// MARK: - 🔴 P1: gpodder comparison sets read ONE visibility rule

extension ProjectFileIntegrityTests {
    /// Finds hand-rolled "what does gpodder see" filters: a `.filter {` whose
    /// statement mentions `isTokenFeedURL`. The ONE sanctioned answer is
    /// `GPodderVisibleSubscriptions` — the third instance of "rule sits only
    /// where it was reported" was exactly this: two comparison sets, one of
    /// them missing the mirror half its own comment promised.
    ///
    /// Statements, not lines (same mechanic as the position fence): the
    /// offending filter spanned three lines with the condition on the second.
    static func handRolledGPodderFilters(in text: String) -> [Int] {
        var offenders: [Int] = []
        var search = text.startIndex
        while let hit = text.range(of: ".filter", range: search..<text.endIndex) {
            search = hit.upperBound
            let windowEnd = text.index(hit.upperBound, offsetBy: 240, limitedBy: text.endIndex) ?? text.endIndex
            let statement = text[hit.lowerBound..<windowEnd]
                .components(separatedBy: .whitespacesAndNewlines).joined()
            guard statement.contains("isTokenFeedURL") else { continue }
            offenders.append(text[..<hit.lowerBound].filter { $0 == "\n" }.count + 1)
        }
        return offenders
    }

    @Test("gpodder's visible-subscription rule lives in exactly one place")
    func gpodderVisibilityRuleIsNotCopied() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var offenders: [String] = []
        for file in files {
            // The one sanctioned home carries the rule itself.
            guard file.lastPathComponent != "GPodderVisibleSubscriptions.swift" else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in Self.handRolledGPodderFilters(in: text) {
                offenders.append("\(file.lastPathComponent):\(line)")
            }
        }
        #expect(offenders.isEmpty,
                "these build their own gpodder comparison set and will drift from the mirror rule: \(offenders)")
    }

    /// Proof run: the fence must find the shape that shipped the 🔴 — the
    /// half rule, spread over three lines exactly as it stood.
    @Test("the gpodder fence catches the half-rule filter that shipped")
    func gpodderFenceCatchesTheShippedHalfRule() {
        let shipped = """
                let localByNorm = Dictionary(subs.shows
                    .filter { !PodcastSubscriptions.isTokenFeedURL($0.feedURL) }
                    .map { (PodcastSubscriptions.normalizeFeedURL($0.feedURL), $0.feedURL) },
                    uniquingKeysWith: { a, _ in a })
        """
        #expect(Self.handRolledGPodderFilters(in: shipped).count == 1)
        // The COMPLETE hand-rolled rule is caught too — copying both halves
        // is still a copy, and the next change would touch only one of them.
        #expect(Self.handRolledGPodderFilters(
            in: ".filter { !PodcastSubscriptions.isTokenFeedURL($0.feedURL) && $0.origin == nil }").count == 1)
        // Reading the one source is not an offence.
        #expect(Self.handRolledGPodderFilters(
            in: "let visible = GPodderVisibleSubscriptions.current()").isEmpty)
    }
}

// MARK: - 🟡 P10-Nachfassung: kuratierte Picks kommen aus EINER geprobten Quelle

extension ProjectFileIntegrityTests {
    /// Finds preview rows that build their items themselves instead of going
    /// through the probed entry point. The class this fences: "the rule was
    /// built where it was reported, the sibling surface stayed unprotected"
    /// — `livePicks` covered only the audiobook picks, so "Discover · Music"
    /// kept showing withdrawn archive.org records (fourth instance).
    ///
    /// The boundary is deliberate: FULL pages and grids (CatalogSourcePage)
    /// stay unprobed — dozens of requests per visit — and heal reactively.
    /// Only the row LOADERS are fenced.
    static func unprobedPickRows(in text: String) -> [Int] {
        var offenders: [Int] = []
        var search = text.startIndex
        while let hit = text.range(of: "rows.", range: search..<text.endIndex) {
            search = hit.upperBound
            let windowEnd = text.index(hit.upperBound, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
            let statement = text[hit.lowerBound..<windowEnd]
                .components(separatedBy: .whitespacesAndNewlines).joined()
            // A row assignment that resolves docs itself is the offence.
            guard statement.contains("=docs.compactMap{provider.remember(popular:")
                    || statement.contains("=docs.compactMap{FreeCatalogProvider.shared.remember(popular:")
            else { continue }
            // The wider second cut of an already probed fetch is sanctioned
            // (cb99bf6) — it is not a preview.
            guard !statement.hasPrefix("rows.tabBooks") else { continue }
            offenders.append(text[..<hit.lowerBound].filter { $0 == "\n" }.count + 1)
        }
        return offenders
    }

    @Test("kuratierte Vorschau-Reihen beziehen ihre Picks ueber den geprobten Eintrittspunkt")
    func previewPicksComeFromTheProbedEntryPoint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = root.appendingPathComponent("Sources/Views/FreeCatalogRows.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(Self.unprobedPickRows(in: text).isEmpty,
                "diese Vorschau-Reihe umgeht die Lebend-Probe: \(Self.unprobedPickRows(in: text))")
    }

    /// Beweislauf: der Zaun muss die Form finden, die ausgeliefert war.
    @Test("der Pick-Zaun faengt die ungeprobte Zuweisung, die ausgeliefert war")
    func pickFenceCatchesTheShippedShape() {
        let shipped = """
                        rows.netlabels = docs.compactMap { provider.remember(popular: $0) }
        """
        #expect(Self.unprobedPickRows(in: shipped).count == 1)
        // Der geprobte Eintrittspunkt ist kein Verstoss …
        #expect(Self.unprobedPickRows(
            in: "rows.netlabels = await Self.picks(docs, cap: 6, provider: provider)").isEmpty)
        // … und der breitere Zweitschnitt bleibt ausdruecklich erlaubt.
        #expect(Self.unprobedPickRows(
            in: "rows.tabBooks = docs.compactMap { provider.remember(popular: $0) }").isEmpty)
    }
}

// MARK: - e32454e: das Instrument fragt die Regel, es kopiert sie nicht

extension ProjectFileIntegrityTests {
    @Test("die Fortschritts-Diagnose vergleicht nicht selbst")
    func diagnosisAsksTheSharedRule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/Models/ProgressDiagnosis.swift"), encoding: .utf8)
        // Sie MUSS die geteilte Regel rufen …
        #expect(text.contains("SyncRules.shouldRestoreLocalPosition"))
        // … und darf den Vergleich nicht danebenstellen (die Form, die
        // ausgeliefert war: `localAt > serverAt && abs(...) > 5`).
        let collapsed = text.replacingOccurrences(of: " ", with: "")
        #expect(!collapsed.contains("localAt>serverAt&&abs("),
                "die Startregel ist wieder kopiert statt gefragt")
    }

    /// c59e96e: the start path decides where a book begins. Both witnesses are
    /// judged by the SHARED rules — the same reason as above, and the same
    /// failure mode: identical today, silently divergent the day a tolerance
    /// moves.
    @Test("der Start fragt beide Zeugen-Regeln, statt selbst zu vergleichen")
    func startAsksTheSharedWitnessRules() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8)
        #expect(text.contains("SyncRules.shouldRestoreLocalPosition"))
        #expect(text.contains("SyncRules.shouldPreferFlushedWitness"),
                "der geflusht-Zeuge wird nicht mehr ueber die geteilte Regel entschieden")
        let collapsed = text.replacingOccurrences(of: " ", with: "")
        #expect(!collapsed.contains("flushed[1]>serverUpdateMs&&"),
                "die Zeugen-Regel ist neben die geteilte kopiert")
    }

    /// The witness only helps if it SURVIVES the sync. The deletion is the
    /// shipped shape that caused the null start; it may not come back without
    /// the tombstone beside it.
    @Test("der Sync loescht den Zeugen nicht ersatzlos")
    func syncKeepsAWitness() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/ViewModels/PlayerViewModel+Sync.swift"), encoding: .utf8)
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(collapsed.contains("AppStorageKeys.flushedPosition(item.id))"),
                "der Sync schreibt keinen geflusht-Zeugen mehr")
    }

    /// 2a993f6 (Glied 4): the cached detail is the start source of a
    /// downloaded book. Written only at download time it freezes — the
    /// cb8bac1 class. It must keep a SECOND writer, the one that carries the
    /// server's answer into it.
    @Test("das gecachte Detail wird nicht nur beim Herunterladen geschrieben")
    func cachedDetailIsKeptCurrent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let manager = try String(contentsOf: root.appendingPathComponent(
            "Sources/Networking/DownloadManager.swift"), encoding: .utf8)
        #expect(manager.contains("func updateCachedProgress(itemId:"),
                "der Fortschreibe-Weg ins gecachte Detail fehlt")
        let sync = try String(contentsOf: root.appendingPathComponent(
            "Sources/ViewModels/PlayerViewModel+Sync.swift"), encoding: .utf8)
        #expect(sync.contains("updateCachedProgress(itemId:"),
                "der Server-Abgleich schreibt seinen Stand nicht mehr ins Detail")
    }
}


// MARK: - 973a38a: one precondition, one scroll helper

extension ProjectFileIntegrityTests {
    /// The journey file as text — the fences here measure its SHAPE, because a
    /// UI test cannot measure itself.
    private static func journeyText() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(
            "ABSPlayerUITests/MaerUITests.swift"), encoding: .utf8)
    }

    /// Every hand-rolled loop of the shape
    /// `while !x.exists/.isHittable && n < N { app.swipeUp(); n += 1 }`.
    /// Whitespace-collapsed, so a line break cannot hide one.
    static func handRolledScrollLoops(in text: String) -> Int {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).joined()
        let pattern = #"while!\w+(\.firstMatch)?\.(exists|isHittable)&&\w+<\d+\{app\.swipeUp\(\)"#
        let re = try? NSRegularExpression(pattern: pattern)
        return re?.numberOfMatches(in: collapsed,
                                   range: NSRange(collapsed.startIndex..., in: collapsed)) ?? 0
    }

    @Test("die Journeys rollen die Scroll-Suche nicht selbst")
    func journeysUseTheSharedScrollHelper() throws {
        #expect(Self.handRolledScrollLoops(in: try Self.journeyText()) == 0,
                "a journey searches with its own swipe loop again instead of waitScrollingTo")
    }

    /// Proof run: the fence must catch the shape that shipped — single-line as
    /// well as multi-line, with both predicates.
    @Test("der Scroll-Zaun faengt die ausgelieferten Formen")
    func scrollFenceCatchesTheShippedShapes() {
        #expect(Self.handRolledScrollLoops(
            in: "while !toggle.isHittable && swipes < 6 { app.swipeUp(); swipes += 1 }") == 1)
        #expect(Self.handRolledScrollLoops(in: """
                while !album.exists && albumSwipes < 4 {
                    app.swipeUp()
                    albumSwipes += 1
                }
        """) == 1)
        // The shared helper itself is no violation.
        #expect(Self.handRolledScrollLoops(
            in: "for _ in 0..<swipes { app.swipeUp() }") == 0)
    }

    /// Blind waits on the seed book. NOTE the collapse eats the spaces INSIDE
    /// the string literal too, so the needle is the spaceless form — that is
    /// what the proof run below pins down.
    static func blindSeedBookWaits(in text: String) -> Int {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).joined()
        return collapsed.components(
            separatedBy: #"staticTexts["SeedBookOne"].waitForExistence"#).count - 1
    }

    static func appBuildSites(in text: String) -> Int {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).joined()
        return collapsed.components(separatedBy: "XCUIApplication()").count - 1
    }

    /// The start precondition belongs in `launchSeeded` — one place, not
    /// twelve copies, and none that bets on an element below the fold.
    @Test("die Start-Vorbedingung steht genau einmal, im geteilten Start")
    func launchPreconditionLivesInLaunchSeeded() throws {
        let text = try Self.journeyText()
        #expect(Self.blindSeedBookWaits(in: text) == 0,
                "a journey bets on the seed book being in the first viewport again")
        #expect(text.contains(#"app.buttons["open-settings"].firstMatch.waitForExistence"#),
                "the shared launch lost its precondition")
    }

    /// Proof run on the form that shipped — twelve times, word for word.
    @Test("der Vorbedingungs-Zaun faengt die ausgelieferte Form")
    func preconditionFenceCatchesTheShippedShape() {
        #expect(Self.blindSeedBookWaits(
            in: #"XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 10))"#) == 1)
        // The multi-line variant with a message counted too.
        #expect(Self.blindSeedBookWaits(in: """
                XCTAssertTrue(app.staticTexts["Seed Book One"].waitForExistence(timeout: 20),
                              "the seeded library must render")
        """) == 1)
        // Scrolling to the book is exactly what the fence wants instead.
        #expect(Self.blindSeedBookWaits(
            in: #"XCTAssertTrue(waitScrollingTo(app, text: "Seed Book One"))"#) == 0)
    }

    /// Exactly ONE place may build the app — the shared `launch`. Everything
    /// else forgot the foreground wait once already, which is why the radio
    /// journeys tapped into a launch animation.
    @Test("nur der geteilte Start baut die App auf")
    func journeysLaunchThroughTheSharedEntry() throws {
        let builds = Self.appBuildSites(in: try Self.journeyText())
        #expect(builds == 1, "a journey builds the app itself again (\(builds) places)")
    }

    /// Proof run on the form that shipped: thirteen journeys built their own
    /// app, two of them without ever waiting for the foreground.
    @Test("der Start-Zaun faengt die ausgelieferte Form")
    func launchFenceCatchesTheShippedShape() {
        #expect(Self.appBuildSites(in: """
                let app = XCUIApplication()
                app.launchArguments += ["-uitest", "-radioEnabled", "1"]
                app.launch()
                app.buttons["tab-radio"].firstMatch.tap()
        """) == 1)
        #expect(Self.appBuildSites(in: """
                var app = XCUIApplication()
                app.launch()
                app = XCUIApplication()
                app.launch()
        """) == 2)
        #expect(Self.appBuildSites(in: "let app = launchSeeded(extra: [\"-uitest-huge\"])") == 0)
    }
}

// MARK: - 88c4eb6: the size class is not a caller's question

extension ProjectFileIntegrityTests {
    /// Every place that spans a horizontal tile slot itself instead of asking
    /// the shared `cardRowSlot`. Whitespace-collapsed, so the usual line break
    /// after `.horizontal,` hides nothing.
    static func ownSlotSites(in text: String) -> Int {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).joined()
        let pattern = #"\.containerRelativeFrame\(\.horizontal,"#
        let re = try? NSRegularExpression(pattern: pattern)
        return re?.numberOfMatches(in: collapsed,
                                   range: NSRange(collapsed.startIndex..., in: collapsed)) ?? 0
    }

    @Test("nur der geteilte Schlitz spannt eine Kachelreihe auf")
    func cardRowsAskTheSharedSlot() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!sources.isEmpty)
        var offenders: [String] = []
        for file in sources where file.lastPathComponent != "TabContentLayout.swift" {
            if Self.ownSlotSites(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these surfaces span the tile slot themselves: \(offenders)")
    }

    /// Proof run on the shape that shipped: fifteen places passed the literal
    /// `false`, which on an iPad meant full width ÷ 3.
    @Test("der Schlitz-Zaun faengt die ausgelieferte Form")
    func slotFenceCatchesTheShippedShape() {
        #expect(Self.ownSlotSites(in: """
                    .containerRelativeFrame(.horizontal,
                        count: CardMetrics.recommendationColumns(regularWidth: false),
                        spacing: 14)
        """) == 1)
        // The honest variant is a violation too: it copies the slot, and the
        // next copy drifts again.
        #expect(Self.ownSlotSites(in:
            ".containerRelativeFrame(.horizontal, count: 6, span: 1, spacing: 12)") == 1)
        #expect(Self.ownSlotSites(in: ".cardRowSlot(spacing: 14)") == 0)
    }

    // MARK: - Playlisten: ein Weg hinein, ein Ort der Anlage

    /// Every source file, so a sweep sees the whole class instead of the
    /// files someone remembered.
    static func sourceFiles() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    }

    /// The surfaces that used to carry their own way into the playlists: a
    /// server-only sheet with its own binding, a device-only menu, a target
    /// type per call site. Statement-based, because the calls span lines.
    static func ownPlaylistRoutes(in text: String) -> Int {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).joined()
        return ["MaerPlaylistMenu(", "AddToPlaylistTarget(", ".addToPlaylistSheet(",
                "MaerPlaylistPresenter."]
            .reduce(0) { $0 + collapsed.components(separatedBy: $1).count - 1 }
    }

    @Test("keine Flaeche haelt sich einen eigenen Playlist-Weg")
    func playlistRoutesAreShared() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() {
            if Self.ownPlaylistRoutes(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these surfaces carry their own playlist route again: \(offenders)")
    }

    /// Proof run on the three shapes that shipped — the server-only sheet, its
    /// target type and the device-only menu.
    @Test("der Playlist-Weg-Zaun faengt die ausgelieferten Formen")
    func playlistRouteFenceCatchesTheShippedShapes() {
        #expect(Self.ownPlaylistRoutes(in: """
                    MaerPlaylistMenu(itemId: item.id,
                                     knownTitles: [item.id: item.title])
        """) == 1)
        #expect(Self.ownPlaylistRoutes(
            in: "addTarget = AddToPlaylistTarget(itemId: music.itemId(songId: songId))") == 1)
        #expect(Self.ownPlaylistRoutes(in: ".addToPlaylistSheet(target: $addTarget)") == 1)
        // The shared action is no violation.
        #expect(Self.ownPlaylistRoutes(
            in: "AddToPlaylistButton(itemId: item.id, knownTitles: [item.id: item.title])") == 0)
    }

    /// A list is created in ONE place. Four dialogs used to do it, and which
    /// world you landed in depended on which one you found.
    static func directListCreations(in text: String) -> Int {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).joined()
        return ["MaerPlaylists.shared.create(", "musicProvider.createPlaylist("]
            .reduce(0) { $0 + collapsed.components(separatedBy: $1).count - 1 }
    }

    @Test("angelegt wird an genau einer Stelle")
    func creatingHappensInOnePlace() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() where file.lastPathComponent != "AddToPlaylistSheet.swift" {
            if Self.directListCreations(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these surfaces create a playlist past the one dialog: \(offenders)")
    }

    /// Proof run: both worlds' shipped create calls are caught, the routing
    /// through the shared dialog is not.
    @Test("der Anlage-Zaun faengt die ausgelieferten Formen")
    func creationFenceCatchesTheShippedShapes() {
        #expect(Self.directListCreations(
            in: "MaerPlaylists.shared.create(name: name, itemIds: PlayQueue.shared.ids)") == 1)
        #expect(Self.directListCreations(in: """
                    _ = try? await AppSession.shared.musicProvider.createPlaylist(name: name)
        """) == 1)
        #expect(Self.directListCreations(
            in: "PlaylistPresenter.shared.askToCreate(place: .device, host: playlistHost)") == 0)
    }

    // MARK: - Feed-Anfragen gehen nie im Klartext raus

    /// A feed request built straight from a stored/directory address. ATS
    /// allows cleartext for MEDIA only, so such a request can never succeed —
    /// it just makes a living feed look dead. Statement-based, because the
    /// guards span lines.
    static func rawFeedRequestSites(in text: String) -> Int {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).joined()
        return ["URL(string:feedURL)", "URL(string:show.feedURL)", "URL(string:urlString)"]
            .reduce(0) { $0 + collapsed.components(separatedBy: $1).count - 1 }
    }

    @Test("keine Feed-Anfrage baut ihre Adresse selbst")
    func feedRequestsAskTheSharedAddress() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() where file.lastPathComponent != "PodcastFeedAddress.swift" {
            if Self.rawFeedRequestSites(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these surfaces build a feed request URL themselves: \(offenders)")
    }

    /// Proof run on the three shapes that shipped — the preview, the refresh
    /// loop and the artwork probe each built their own URL.
    @Test("der Feed-Adress-Zaun faengt die ausgelieferten Formen")
    func feedAddressFenceCatchesTheShippedShapes() {
        #expect(Self.rawFeedRequestSites(
            in: "guard let url = URL(string: feedURL) else { failed = true; return }") == 1)
        #expect(Self.rawFeedRequestSites(in: """
                    if let url = URL(string: show.feedURL),
                       let fresh = await Self.fetchAndParse(feedURL: url) {
        """) == 1)
        // The shared rule is no violation.
        #expect(Self.rawFeedRequestSites(
            in: "guard let url = PodcastFeedAddress.requestURL(feedURL) else { return nil }") == 0)
    }
}
