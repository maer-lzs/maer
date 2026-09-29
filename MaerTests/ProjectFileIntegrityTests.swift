// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// Fence against Xcode's automatic pbxproj damage: with the project open,
/// Xcode injects a reference to the project INTO ITSELF whenever the tree
/// underneath changes (measured three times in one day). The build survives,
/// so nothing notices until it is committed. This turns the guard into the
/// evidence chain: the run goes red BEFORE the commit, not silently healed
/// afterwards.
///
/// The project file is read from the source path baked in at compile time. If
/// it is not readable (a run on a device, a copied checkout), the case reports
/// nothing rather than failing on the environment. The check has value where
/// the damage happens, on the build machine.
struct ProjectFileIntegrityTests {
    private static var projectFile: String? {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testsDir.deletingLastPathComponent()
            .appendingPathComponent("Maer.xcodeproj/project.pbxproj")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Zero, not one: the last remaining `wrapper.pb-project` entry was the
    /// ORIGINAL injection. A full self-subproject reference (file
    /// reference + Products group + `projectReferences` entry), not the
    /// orphan line it looked like. It is gone since the root fix, so the
    /// fence now says what it means instead of tolerating one corpse.
    /// A player or sync call in a view's body EXPRESSION runs as often as
    /// the body is evaluated. Measured: a stop and three whole-pot writes
    /// named "body" as their caller. Calls belong in handlers (.task,
    /// .onChange, .onAppear, .onDisappear, Button, .refreshable, Task).
    /// The scan walks back from each call to the nearest enclosing marker:
    /// a handler passes, `var body` is the offender.
    static func bodyLevelPlayerOrSyncCalls(in text: String) -> [Int] {
        let lines = text.components(separatedBy: "\n")
        let calls = [".stop(", ".pause(", ".play(", "reconcile("]
        // A local binding is not a handler, and a computed view property is
        // a body expression with the same behaviour as `body` itself.
        let handlers = [".task", ".onChange", ".onAppear", ".onDisappear", ".onReceive",
                        ".refreshable", "Button", "Task {", "Task.detached", "func ",
                        ".onTapGesture", ".onSubmit", ".confirmationDialog", ".alert(",
                        ".sheet(", ".swipeActions", ".contextMenu", "Menu", ".toolbar",
                        "init("]
        var offenders: [Int] = []
        for (index, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//"), calls.contains(where: { line.contains($0) }) else { continue }
            var cursor = index - 1
            while cursor >= 0 {
                let above = lines[cursor].trimmingCharacters(in: .whitespaces)
                if above.hasPrefix("var body") || Self.isComputedViewProperty(above) {
                    offenders.append(index + 1); break
                }
                if handlers.contains(where: { above.contains($0) }) { break }
                cursor -= 1
            }
        }
        return offenders
    }

    /// `var content: some View {`, with or without access modifiers and
    /// a `@ViewBuilder`. Stored properties and non-view computeds pass.
    static func isComputedViewProperty(_ line: String) -> Bool {
        guard line.contains("var "), line.contains("some View"), line.hasSuffix("{") else { return false }
        return !line.contains("=")
    }

    @Test("no player or sync call in a view body expression")
    func viewBodiesDoNotDrivePlayerOrSync() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() where file.path.contains("/Sources/Views/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in Self.bodyLevelPlayerOrSyncCalls(in: text) {
                offenders.append("\(file.lastPathComponent):\(line)")
            }
        }
        #expect(offenders.isEmpty, "these views drive the player or the sync from body: \(offenders)")
        // Rot-Probe in both directions: a call right under `var body` is
        // caught, the same call inside a handler is not.
        let bad = "struct V: View {\n    var body: some View {\n        Text(\"x\")\n        coordinator.viewModel?.stop()\n    }\n}"
        #expect(Self.bodyLevelPlayerOrSyncCalls(in: bad) == [4])
        let good = "struct V: View {\n    var body: some View {\n        Text(\"x\").onDisappear {\n            coordinator.viewModel?.stop()\n        }\n    }\n}"
        #expect(Self.bodyLevelPlayerOrSyncCalls(in: good).isEmpty)
        // A local binding between body and the call is no handler.
        let letBefore = "struct V: View {\n    var body: some View {\n        let x = 1\n        coordinator.viewModel?.stop()\n    }\n}"
        #expect(Self.bodyLevelPlayerOrSyncCalls(in: letBefore) == [4])
        // A computed view property is a body expression too.
        let computed = "struct V: View {\n    @ViewBuilder private var content: some View {\n        PodcastCloudSync.shared.reconcile()\n    }\n}"
        #expect(Self.bodyLevelPlayerOrSyncCalls(in: computed) == [3])
    }

    @Test("pbxproj: the project never references itself", .needsTheProjectFile)
    func noSelfReference() throws {
        // Die Bedingung am Fall hat schon entschieden, dass die Datei da
        // ist. Fehlt sie hier trotzdem, ist sie unlesbar, und das ist ein
        // Befund und keine Enthaltung.
        let text = try #require(Self.projectFile, "die Projektdatei liegt da und ist nicht lesbar")
        let count = text.components(separatedBy: "wrapper.pb-project").count - 1
        #expect(count == 0,
                "the project references itself — Xcode injected it; heal with git checkout -- Maer.xcodeproj/project.pbxproj")
    }

    /// The app target's synchronised group carries
    /// `path = Sources`. That is the STRUCTURAL guarantee behind two things
    /// that used to need maintenance: the project file cannot reference
    /// itself (it lies outside the swept folder), and nothing from the repo
    /// root. Docs, screenshots, test fixtures, tooling config, the local
    /// key file. Can be swept into the app bundle. Lose the path and both
    /// problems return silently, so it is nailed down here.
    /// The app-store permission (LICENSE-ADDITIONAL-TERMS, part 1) can only be granted
    /// weil er ALLEINIGER Rechteinhaber ist. Und das ist er nur, solange das
    /// Projekt keine Fremdabhängigkeit einzieht. Eine still dazugekommene
    /// SPM-Abhängigkeit brächte fremden Code (und fremde Lizenz) in dieselbe
    /// Binärdatei und würde die Ausnahme aushöhlen, ohne dass jemand es
    /// bemerkt. Deshalb ist die Zahl hier festgenagelt: 0.
    /// GPL § 7 verlangt den Hinweis auf Zusatzbedingungen ausdrücklich **in
    /// den Quelldateien**. Nicht nur in der Wurzel. Eine
    /// neue Datei ohne diese Zeile ließe die Bedingung still ausfallen, und
    /// niemand würde es merken. Derselbe Mechanismus wie beim pbxproj-Zaun.
    @Test("every source file carries copyright, SPDX and the additional-terms notice", .needsTheSources)
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
        #expect(checked > 0, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        #expect(offenders.isEmpty,
                "source files without the full licence header — GPL §7 requires the notice in the files")
    }

    @Test("no third-party dependency sneaks in (the licence exception rests on it)", .needsTheProjectFile)
    func noExternalDependencies() throws {
        // Die Bedingung am Fall hat schon entschieden, dass die Datei da
        // ist. Fehlt sie hier trotzdem, ist sie unlesbar, und das ist ein
        // Befund und keine Enthaltung.
        let text = try #require(Self.projectFile, "die Projektdatei liegt da und ist nicht lesbar")
        #expect(!text.contains("XCRemoteSwiftPackageReference"),
                "a new SPM dependency changes the licence situation — see LICENSE-ADDITIONAL-TERMS")
        #expect(!text.contains("XCLocalSwiftPackageReference"))
        #expect(!text.contains("packageProductDependencies = (\n\t\t\t\tXC"),
                "a package product was linked into a target")
        // Both licence documents ship with the app (same reason LICENSE does).
        #expect(text.contains("LICENSE-ADDITIONAL-TERMS in Resources"),
                "the additional terms must travel with the binary they apply to")
    }

    /// Ein vollstaendiges JWT stand im Klartext in einer gewoehnlichen
    /// View-Datei. Also im oeffentlichen Spiegel und dauerhaft in der
    /// Historie. Der Zugang ist zurueckgebaut; dieser Zaun sorgt dafuer, dass
    /// so etwas nicht zum Testen wiederkommt. JWTs haben eine erkennbare Form
    /// (`eyJ` = base64 von `{"`), das genuegt als Muster.
    @Test("no access token is hard-coded in the sources", .needsTheSources)
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
        #expect(checked > 0, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        #expect(offenders.isEmpty,
                "a JWT is hard-coded in the sources — credentials belong in App Store Connect's review notes, never in a shipped file")
    }

    /// SECHS handgepflegte User-Agent-Zeichenketten mit vier
    /// Versionswerten und zwei Adressen. Eine davon nannte die private Forge und
    /// ging bei jedem Kuenstlerbild-Abruf nach draussen. Jetzt gibt es genau
    /// eine, aus der Bundle-Version abgeleitet. Der Zaun haelt das: kein
    /// hartkodiertes `Maer/<Ziffer>` mehr in den Quellen, und die eine
    /// Definition steht in `AppUserAgent`.
    @Test("exactly one User-Agent, and no hard-coded version literal", .needsTheSources)
    func oneUserAgent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else {
            Issue.record("the fence could not walk \(dir.lastPathComponent), so it measured nothing")
            return
        }
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
        #expect(checked > 0, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        #expect(literals.isEmpty,
                "a hard-coded User-Agent version — it drifts, and one of them once carried the private forge")
        #expect(definitions == 1, "the identification is defined exactly once")
    }

    /// Eine Kennung auf dem CONTAINER faltet den Teilbaum zu einem
    /// Element. Die Playlist-Karte trug ihren Namen von aussen, und damit
    /// meldeten Karte, Details-Pille und Zufalls-Ecke denselben: drei
    /// Bedienelemente, ein Name, fuer VoiceOver dreimal dasselbe. Der Zaun
    /// haelt die Form, nicht die eine Fundstelle — eine Kennung gehoert an
    /// das Element, das sie meint. Rot-Probe steht im Test selbst.
    @Test("no accessibility identifier sits on a card container", .needsTheSources)
    func identifiersNameTheElementNotTheContainer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/Views")
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else {
            Issue.record("the fence could not walk \(dir.lastPathComponent), so it measured nothing")
            return
        }
        var offenders: [String] = []
        var checked = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains(".accessibilityIdentifier(") {
                guard let previous = Self.constructedComponent(before: index, in: lines) else { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1) \(previous)")
            }
        }
        #expect(checked > 0, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        #expect(offenders.isEmpty,
                "the name lands on the container and swallows the names of the controls inside")
        // Rot-Probe: die alte Form wird erkannt.
        let old = ["ForEach(sources) { source in",
                   "    PlaylistCard(source: source, playerCoordinator: playerCoordinator)",
                   "        .accessibilityIdentifier(\"server-playlist-\\(source.id)\")"]
        #expect(Self.constructedComponent(before: 2, in: old) == "PlaylistCard")
        // …und die richtige Form nicht: die Karte benennt sich selbst.
        let now = ["Button { open() } label: { … }",
                   "    .buttonStyle(.plain)",
                   "    .accessibilityIdentifier(Self.identifier(for: source))"]
        #expect(Self.constructedComponent(before: 2, in: now) == nil)
    }

    /// Der Bauteil-Aufruf ueber einer Kennungs-Zeile, falls es einen gibt.
    /// Nur die naechste tragende Zeile zaehlt: steht dazwischen ein
    /// Modifizierer, haengt die Kennung an ihm und nicht am Bauteil.
    private static func constructedComponent(before index: Int, in lines: [String]) -> String? {
        var cursor = index - 1
        while cursor >= 0 {
            let line = lines[cursor].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { cursor -= 1; continue }
            guard !line.hasPrefix(".") else { return nil }
            let pattern = #"\b([A-Z][A-Za-z0-9]*(?:Card|Cell|Tile|Grid|Stage))\s*\("#
            guard let range = line.range(of: pattern, options: .regularExpression) else { return nil }
            return String(line[range].dropLast().trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Die acht Katalogquellen hatten ein zweites, handgeschriebenes
    /// Aktivierungssystem. Die Vorgabe stand 35× in elf Dateien. Alle 35
    /// stimmten überein; erzwungen hat das
    /// niemand, ein `bool(forKey:)` an einer Stelle hätte sie gekippt.
    /// Jetzt steht sie einmal je Quelle in `AppStorageKeys`. Ohne diesen Zaun
    /// ist der Aufräumtag in drei Monaten rückgängig gemacht.
    @Test("the default 'on' lives in exactly one file", .needsTheSources)
    func noScatteredDefaults() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else {
            Issue.record("the fence could not walk \(dir.lastPathComponent), so it measured nothing")
            return
        }
        var offenders: [String] = []
        var checked = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            if url.lastPathComponent == "AppStorageKeys.swift" { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            if text.contains("as? Bool ?? true") { offenders.append(url.lastPathComponent) }
        }
        #expect(checked > 0, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        #expect(offenders.isEmpty,
                "a default value composed outside AppStorageKeys — that is how 35 copies grew")
    }

    @Test("pbxproj: the app target syncs Sources, not the repo root", .needsTheProjectFile)
    func appTargetSyncsSourcesOnly() throws {
        // Die Bedingung am Fall hat schon entschieden, dass die Datei da
        // ist. Fehlt sie hier trotzdem, ist sie unlesbar, und das ist ein
        // Befund und keine Enthaltung.
        let text = try #require(Self.projectFile, "die Projektdatei liegt da und ist nicht lesbar")
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

    /// The listening mark is `[position, timestamp, duration at the time]`.
    /// An entry with a third value is VALID. Anything checking `count == 2`
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
    /// `[position, ts]` drops the reference point just as silently. The
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
            // The statement ends at the parenthesis that CLOSES the call. A
            // fixed-size window read past it into the next function and
            // condemned an innocent writer for its neighbour's key.
            guard let end = Self.matchingParen(in: text, openAfter: hit.upperBound) else { continue }
            let statement = text[hit.lowerBound..<end]
                .components(separatedBy: .whitespacesAndNewlines).joined()
            guard statement.hasPrefix(".set([") else { continue }
            guard statement.contains("localPosition") else { continue }
            offenders.append(text[..<hit.lowerBound].filter { $0 == "\n" }.count + 1)
        }
        return offenders
    }

    /// Index just past the `)` that closes an already-open parenthesis.
    private static func matchingParen(in text: String,
                                      openAfter index: String.Index) -> String.Index? {
        var depth = 1
        var i = index
        while i < text.endIndex {
            if text[i] == "(" { depth += 1 }
            if text[i] == ")" {
                depth -= 1
                if depth == 0 { return text.index(after: i) }
            }
            i = text.index(after: i)
        }
        return nil
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

    /// Second proof run, from the day the fence condemned an innocent writer:
    /// a fixed window read past the closing parenthesis into the NEXT
    /// function and borrowed its key. The two statements below are the real
    /// pair. The flushed witness (legitimate, two values, its own key) and
    /// the backup removal that follows it.
    @Test("der Schreiber-Zaun endet an der Klammer, nicht am Zeichenfenster")
    func writerFenceStopsAtTheStatementEnd() {
        #expect(Self.rawPositionWriters(in: """
                defaults.set([position, atMs], forKey: AppStorageKeys.flushedPosition(itemId))
            }

            static func clearBackup(_ itemId: String) {
                defaults.removeObject(forKey: AppStorageKeys.localPosition(itemId))
            }
        """).isEmpty, "ein Schreiber wird fuer den Schluessel seines Nachbarn verurteilt")
    }

    /// The proof run: the fence must FIND the shape it went blind on. The
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
        // stay exempt. The fence names literals, not ProgressMark calls.
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
    /// forever. A 700-line provider went blind that way, and the tenth
    /// occurrence of this very class hid behind it.
    /// One line's verdict, factored so the proof run below can feed the fence
    /// the exact shapes it went blind on.
    private static func playedReimplementations(inLine line: String) -> [String] {
        let code = line.split(separator: "/").first.map(String.init) ?? line
        guard !line.contains("progress-fence:") else { return [] }
        var kinds: [String] = []
        // The FORM, not three names: a position held against "a length minus
        // a number" is the played threshold, whatever the length is called
        // (`dur - 1` and `marked - 1` slipped past a list of names).
        if code.range(of: #">=\s*[A-Za-z_][A-Za-z0-9_.]*\s*-\s*[0-9]"#, options: .regularExpression) != nil {
            kinds.append("Dauer-Vergleich")
        }
        // The book's numeric "complete" has one home, `BookProgress.completeFraction`.
        if code.contains("0.9999") { kinds.append("Fertig-Anteil") }
        return kinds
    }

    /// `.last` on a progress entry, read as STATEMENTS like the writer fence.
    /// The eighth occurrence broke the expression between `)?` and `.last`
    /// across two lines, and the line-based read fence (and the line-based
    /// sweep that claimed the repo clean) were blind exactly like the writer
    /// fence had been before its proof run.
    ///
    /// Two spellings of the read are known: the key builder in the expression
    /// (`localPosition(`) and the snapshot form (`positions[`). The seventh
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
                // `.last` as its own member. Not `.lastPathComponent` etc.
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

    /// The proof run for the played fence: the spellings it missed before it
    /// read the form (`dur - 1` wrote `isFinished` to Audiobookshelf,
    /// `marked - 1` and `feedDuration - 1` judged the diagnosis) and the
    /// copied "complete" fraction.
    @Test("the played fence finds the form, whatever the length is called")
    func playedFenceFindsTheForm() {
        for line in ["isFinished: dur > 0 && position >= dur - 1",
                     "return entry.position >= marked - 1 ? .played : .unplayed",
                     "if entry.position >= entry.feedDuration - 1 { return .played }",
                     "let done = fraction >= 0.9999"] {
            #expect(!Self.playedReimplementations(inLine: line).isEmpty, "missed: \(line)")
        }
        #expect(Self.playedReimplementations(inLine: "let finished = ProgressMark.reachedEnd(position: p, duration: d)").isEmpty)
        #expect(Self.playedReimplementations(inLine: "static let x = 0.9999   // progress-fence: the one home").isEmpty)
    }

    /// The proof run: the read fence must FIND every shape it went blind on.
    /// The seventh occurrence (snapshot spelling), the optional chain, and the
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
        // Sanctioned reads stay exempt. The wrapper and unrelated members.
        #expect(Self.lastAsTimestampReads(
            in: "let ts = ProgressMark.timestamp(snapshot.positions[eqId]) ?? 0").isEmpty)
        #expect(Self.lastAsTimestampReads(
            in: "let name = AppStorageKeys.localPosition(id); let x = url.lastPathComponent").isEmpty)
    }
}
#endif

// MARK: - 🔴 gpodder comparison sets read ONE visibility rule

extension ProjectFileIntegrityTests {
    /// Finds hand-rolled "what does gpodder see" filters: a `.filter {` whose
    /// statement mentions `isTokenFeedURL`. The ONE sanctioned answer is
    /// `GPodderVisibleSubscriptions`. The third instance of "rule sits only
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

    /// Proof run: the fence must find the shape that shipped the 🔴. The
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
        // The COMPLETE hand-rolled rule is caught too. Copying both halves
        // is still a copy, and the next change would touch only one of them.
        #expect(Self.handRolledGPodderFilters(
            in: ".filter { !PodcastSubscriptions.isTokenFeedURL($0.feedURL) && $0.origin == nil }").count == 1)
        // Reading the one source is not an offence.
        #expect(Self.handRolledGPodderFilters(
            in: "let visible = GPodderVisibleSubscriptions.current()").isEmpty)
    }
}

// MARK: - 🟡 Kuratierte Picks kommen aus EINER geprobten Quelle

extension ProjectFileIntegrityTests {
    /// Finds preview rows that build their items themselves instead of going
    /// through the probed entry point. The class this fences: "the rule was
    /// built where it was reported, the sibling surface stayed unprotected".
    /// `livePicks` covered only the audiobook picks, so "Discover · Music"
    /// kept showing withdrawn archive.org records (fourth instance).
    ///
    /// The boundary is deliberate: FULL pages and grids (CatalogSourcePage)
    /// stay unprobed (dozens of requests per visit) and heal reactively.
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
            // The wider second cut of an already probed fetch is sanctioned.
            // It is not a preview.
            guard !statement.hasPrefix("rows.tabBooks") else { continue }
            offenders.append(text[..<hit.lowerBound].filter { $0 == "\n" }.count + 1)
        }
        return offenders
    }

    @Test("kuratierte Vorschau-Reihen beziehen ihre Picks ueber den geprobten Eintrittspunkt")
    func previewPicksComeFromTheProbedEntryPoint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        // The preview rows are built in the two loaders; both are read.
        let text = try ["Sources/ViewModels/FreeCatalogLoader.swift", "Sources/ViewModels/CatalogSourceLoader.swift"]
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        #expect(text.contains("rows.classical = await Self.picks("), "der Zeuge liest die Vorschau-Reihen nicht mehr")
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

// MARK: - Das Instrument fragt die Regel, es kopiert sie nicht

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

    /// The start path decides where a book begins. Both witnesses are
    /// judged by the SHARED rules. The same reason as above, and the same
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
        // The statement is unchanged, its expression moved into the stock:
        // the sync notes what it pushed instead of deleting the backup bare.
        #expect(collapsed.contains("ListeningStore.noteFlushed("),
                "der Sync schreibt keinen geflusht-Zeugen mehr")
        #expect(!collapsed.contains("UserDefaults.standard.removeObject(forKey:key)"),
                "der Sync entfernt die Sicherung wieder roh, am Bestand vorbei")
    }

    /// The cached detail is the start source of a
    /// downloaded book. Written only at download time it freezes. The
    /// same class as a stale constant. It must keep a SECOND writer, the
    /// one that carries the
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


// MARK: - One precondition, one scroll helper

extension ProjectFileIntegrityTests {
    /// The journey file as text. The fences here measure its SHAPE, because a
    /// UI test cannot measure itself.
    private static func journeyText() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(
            "MaerUITests/MaerUITests.swift"), encoding: .utf8)
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

    /// Proof run: the fence must catch the shape that shipped. Single-line as
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
    /// the string literal too, so the needle is the spaceless form. That is
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

    /// The start precondition belongs in `launchSeeded`. One place, not
    /// twelve copies, and none that bets on an element below the fold.
    @Test("die Start-Vorbedingung steht genau einmal, im geteilten Start")
    func launchPreconditionLivesInLaunchSeeded() throws {
        let text = try Self.journeyText()
        #expect(Self.blindSeedBookWaits(in: text) == 0,
                "a journey bets on the seed book being in the first viewport again")
        #expect(text.contains(#"app.buttons["open-settings"].firstMatch.waitForExistence"#),
                "the shared launch lost its precondition")
    }

    /// Proof run on the form that shipped. Twelve times, word for word.
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

    /// Exactly ONE place may build the app. The shared `launch`. Everything
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

// MARK: - The size class is not a caller's question

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

    /// Proof run on the three shapes that shipped. The server-only sheet, its
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
    /// allows cleartext for MEDIA only, so such a request can never succeed.
    /// It just makes a living feed look dead. Statement-based, because the
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

    /// Proof run on the three shapes that shipped. The preview, the refresh
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

    // MARK: - Hoerstand-Invariante: kein Pfad entfernt einen Stand ersatzlos

    /// A raw removal of a progress key. The whole weekend's error family came
    /// from exactly one such line: the sync deleted the local witness after
    /// pushing, so a downloaded book had no local truth at all and started at
    /// zero whenever the server was missing, late or empty. Replacing is
    /// allowed, removing is not. Except for the ONE named user intent inside
    /// the stock itself.
    /// Removals are counted by the SAME resolver as every other access. The
    /// literal version missed `removeObject(forKey: oldKey)` for exactly the
    /// reason the read half missed its twelve.
    static func rawProgressRemovals(in text: String) -> Int {
        Self.rawProgressAccesses(in: text, operations: "removeObject")
    }

    /// The other half of ownership: nobody TOUCHES the raw keys. Reading,
    /// writing, asking whether they exist, or removing them.
    ///
    /// **This fence had a hole and it was the same class it guards against.**
    /// The first version searched the LITERAL
    /// `array(forKey:AppStorageKeys.localPosition(`, so every access through a
    /// key variable (`let key = AppStorageKeys.localPosition(id)` … then
    /// `forKey: key`) walked straight past it. And most sites are written
    /// that way. It also did not know `object(forKey:)`, the existence check.
    /// Twelve accesses stood in the tree while it reported green. So it now
    /// RESOLVES the key variables of each file first, like a measurement
    /// would, instead of trusting one spelling.
    static func rawProgressAccesses(in text: String,
                                    operations: String = "array|object|set|removeObject") -> Int {
        // 1. Which local names hold a progress key in THIS file?
        var keyVars: Set<String> = []
        let varPattern = #"\b(?:let|var)\s+(\w+)\s*=\s*AppStorageKeys\.(?:localPosition|flushedPosition)\("#
        if let re = try? NSRegularExpression(pattern: varPattern) {
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                keyVars.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        // 2. Every store operation, direct or through one of those names.
        let ops = "(?:" + operations + ")"
        var patterns = [ops + #"\([^()]*forKey:\s*AppStorageKeys\.(?:localPosition|flushedPosition)\("#]
        if !keyVars.isEmpty {
            let names = keyVars.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            patterns.append(ops + #"\([^()]*forKey:\s*("# + names + #")\b"#)
        }
        var count = 0
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            count += re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        return count
    }

    /// The third indirection, found only because removing the twelve exposed
    /// it: a computed property that HANDS OUT a key
    /// (`var localPositionKey: String? { AppStorageKeys.localPosition(id) }`).
    /// It lived in one file and was used in another, so no per-file resolver
    /// could ever see it. The answer is not a cleverer resolver but a closed
    /// door: outside the stock, nobody builds a progress key at all.
    static func progressKeyBuilders(in text: String) -> Int {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).joined()
        return ["AppStorageKeys.localPosition(", "AppStorageKeys.flushedPosition("]
            .reduce(0) { $0 + collapsed.components(separatedBy: $1).count - 1 }
    }

    @Test("ausserhalb des Bestands baut niemand einen Fortschritts-Schluessel")
    func onlyTheStockBuildsProgressKeys() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles()
        where !["ListeningStore.swift", "AppStorageKeys.swift"].contains(file.lastPathComponent) {
            if Self.progressKeyBuilders(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these files build a progress key outside the stock: \\(offenders)")
    }

    /// Proof run: the shipped key export, and a plain build.
    @Test("der Schluessel-Zaun faengt die ausgelieferte Weitergabe")
    func keyFenceCatchesTheShippedExport() {
        #expect(Self.progressKeyBuilders(in: """
                    var localPositionKey: String? {
                        item.map { AppStorageKeys.localPosition($0.id) }
                    }
        """) == 1)
        #expect(Self.progressKeyBuilders(
            in: "let key = AppStorageKeys.flushedPosition(item.id)") == 1)
        #expect(Self.progressKeyBuilders(in: "ListeningStore.mark(item.id)") == 0)
    }

    @Test("keine Flaeche fasst die Fortschritts-Schluessel selbst an")
    func everySurfaceAsksTheStock() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles()
        where !["ListeningStore.swift", "AppStorageKeys.swift"].contains(file.lastPathComponent) {
            if Self.rawProgressAccesses(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these surfaces touch the progress keys themselves: \\(offenders)")
    }

    /// Proof run on all THREE shipped forms. The one the old fence caught,
    /// and the two it was blind to.
    @Test("der Zugriffs-Zaun faengt alle drei ausgelieferten Formen")
    func accessFenceCatchesAllThreeShapes() {
        // 1. direct. The only shape the first version knew.
        #expect(Self.rawProgressAccesses(in: """
                    let saved = UserDefaults.standard.array(
                        forKey: AppStorageKeys.localPosition(item.id)) as? [Double]
        """) == 1)
        // 2. through a key variable. Twelve sites, all invisible before.
        #expect(Self.rawProgressAccesses(in: """
                    let oldKey = AppStorageKeys.localPosition(old)
                    guard let value = d.array(forKey: oldKey) else { return }
                    d.removeObject(forKey: oldKey)
        """) == 2)
        // 3. the existence check, which it did not know at all.
        #expect(Self.rawProgressAccesses(
            in: "defaults.object(forKey: AppStorageKeys.localPosition(guid)) == nil") == 1)
        // Going through the stock is no violation. It is the point.
        #expect(Self.rawProgressAccesses(in: "ListeningStore.backup(item.id, in: defaults)") == 0)
        #expect(Self.rawProgressAccesses(in: "ListeningStore.hasStand(guid, in: defaults)") == 0)
    }

    /// The invariant's first half: playback writes locally for EVERY class.
    /// The ticker is class-blind by construction. The moment a call-site
    /// condition appears around it, one class loses its local truth again, and
    /// that asymmetry is where the whole null-start family came from.
    @Test("der Sekundenschreiber kennt keine Klassen-Ausnahme")
    func theTickerWritesForEveryClass() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(
            "Sources/ViewModels/PlayerViewModel.swift"), encoding: .utf8)
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).joined()
        #expect(collapsed.contains("ListeningStore.record("),
                "der Ticker schreibt nicht mehr in den Bestand")
        // The class question is answered INSIDE the stock (a live stream keeps
        // no position); a second answer at the call site would drift from it.
        for smell in ["hasPrefix(\"li_\")", "hasPrefix(\"local:\")",
                      "ListeningClasses.keepsPosition"] {
            #expect(!collapsed.contains(smell + "),ListeningStore.record"),
                    "die Klassenfrage wird an der Aufrufstelle zweitbeantwortet")
        }
    }

    @Test("kein Sync-Pfad entfernt einen Hoerstand ersatzlos")
    func noPathRemovesAListeningState() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() where file.lastPathComponent != "ListeningStore.swift" {
            if Self.rawProgressRemovals(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these paths remove a listening state instead of replacing it: \(offenders)")
    }

    /// Proof run on the shipped shapes. The sync deletion that caused the
    /// null start, and the re-keying that overwrote a newer stand.
    @Test("der Invarianten-Zaun faengt die ausgelieferten Formen")
    func invariantFenceCatchesTheShippedShapes() {
        #expect(Self.rawProgressRemovals(
            in: "UserDefaults.standard.removeObject(forKey: AppStorageKeys.localPosition(id))") == 1)
        #expect(Self.rawProgressRemovals(in: """
                    d.removeObject(
                        forKey: AppStorageKeys.flushedPosition(item.id))
        """) == 1)
        // Going through the stock is no violation. It is the point.
        #expect(Self.rawProgressRemovals(in: "ListeningStore.forgetUserDeleted(id)") == 0)
        #expect(Self.rawProgressRemovals(in: "ListeningStore.clearBackup(item.id)") == 0)
    }

    // MARK: - Stempel-Regel: ein festes Format braucht ein festes Gebietsschema

    /// A `DateFormatter` with a fixed `dateFormat` but no fixed locale. Under a
    /// non-Gregorian calendar (selectable in iOS settings) the same instant
    /// formats as a different year. And where the result is STORED or
    /// COMPARED, that is a silent data split, not a cosmetic issue.
    ///
    /// `ISO8601DateFormatter` is deliberately not covered: it takes no locale
    /// and reads the offset from the string, which is exactly what the rule
    /// asks for.
    static func localeLessFixedFormats(in text: String) -> Int {
        var count = 0
        var search = text.startIndex
        while let hit = text.range(of: "DateFormatter()", range: search..<text.endIndex) {
            search = hit.upperBound
            // ISO8601DateFormatter() also ends in "DateFormatter()". Skip it.
            let isoStart = text.index(hit.lowerBound, offsetBy: -7, limitedBy: text.startIndex)
            if let isoStart, text[isoStart..<hit.lowerBound] == "ISO8601" { continue }
            let windowEnd = text.index(hit.upperBound, offsetBy: 400,
                                       limitedBy: text.endIndex) ?? text.endIndex
            let block = String(text[hit.upperBound..<windowEnd])
            guard block.contains("dateFormat") else { continue }
            if !block.contains("en_US_POSIX") { count += 1 }
        }
        return count
    }

    @Test("kein festes Datumsformat ohne festes Gebietsschema")
    func fixedFormatsCarryAFixedLocale() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() {
            if Self.localeLessFixedFormats(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these formatters pin a format but not a calendar: \(offenders)")
    }

    /// Proof run on the two shipped shapes. The listening statistics, whose
    /// day string is a STORED KEY, and the catalogue air-date parse.
    @Test("der Gebietsschema-Zaun faengt die ausgelieferten Formen")
    func localeFenceCatchesTheShippedShapes() {
        #expect(Self.localeLessFixedFormats(in: """
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
        """) == 1)
        #expect(Self.localeLessFixedFormats(in: """
                let iso = DateFormatter()
                iso.dateFormat = "yyyy-MM-dd"
                iso.timeZone = TimeZone(identifier: "UTC")
        """) == 1)
        // Fixed locale present, and the zone-free ISO parser, are both fine.
        #expect(Self.localeLessFixedFormats(in: """
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        """) == 0)
        #expect(Self.localeLessFixedFormats(in: "let f = ISO8601DateFormatter()") == 0)
    }

    // MARK: - Einstellungs-Schluessel stehen an EINER Stelle

    /// A raw string inside `@AppStorage`. The keys live in `AppStorageKeys`;
    /// a literal beside them is the drift a rename breaks silently. Measured
    /// on `podcastAutoSaveOnPlay`, which existed as a constant AND as a
    /// literal in the same feature.
    static func rawStorageKeyLiterals(in text: String) -> Int {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).joined()
        let pattern = #"@AppStorage\(""#
        let re = try? NSRegularExpression(pattern: pattern)
        return re?.numberOfMatches(in: collapsed,
                                   range: NSRange(collapsed.startIndex..., in: collapsed)) ?? 0
    }

    @Test("kein Einstellungs-Schluessel steht als roher String im Baum")
    func storageKeysComeFromTheOnePlace() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() {
            if Self.rawStorageKeyLiterals(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these surfaces spell a settings key themselves: \\(offenders)")
    }

    /// Proof run on the shipped form. The literal that stood next to its own
    /// constant, and the correct spelling beside it.
    @Test("der Schluessel-Zaun faengt die ausgelieferte Form")
    func storageKeyFenceCatchesTheShippedShape() {
        #expect(Self.rawStorageKeyLiterals(
            in: #"@AppStorage("podcastAutoSaveOnPlay") private var autoSaveOnPlay = true"#) == 1)
        #expect(Self.rawStorageKeyLiterals(
            in: "@AppStorage(AppStorageKeys.podcastAutoSaveOnPlay) private var x = true") == 0)
    }

    // MARK: - Ein Feld an einem gespeicherten Typ ist eine stille Migration

    /// A decode whose BYTES come from a local store. File, UserDefaults, the
    /// key-value store, the app group. That is the cut between "persisted" and
    /// "transient", and it is anchored on the DATA SOURCE rather than on a list
    /// of type names: a list in the repo goes stale, a data source does not.
    ///
    /// Network responses are deliberately out. A decode failure there is a
    /// visible network error with a retry; nothing stored is lost.
    static func persistedDecodes(in text: String) -> [(line: Int, type: String)] {
        let lines = text.components(separatedBy: "\n")
        let localSources = ["Data(contentsOf", ".data(forKey", "UserDefaults",
                            "NSUbiquitousKeyValueStore", "containerURL"]
        var out: [(Int, String)] = []
        for (index, line) in lines.enumerated() {
            guard let range = line.range(of: "decode(") else { continue }
            let tail = line[range.upperBound...]
            let name = tail.drop { "[ ".contains($0) }.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            guard !name.isEmpty else { continue }
            let window = lines[max(0, index - 6)...min(lines.count - 1, index + 1)].joined(separator: "\n")
            if localSources.contains(where: window.contains) {
                out.append((index + 1, String(name)))
            }
        }
        return out
    }

    /// A decode that falls back to an EMPTY value and whose holder writes that
    /// value back is how a read error becomes permanent loss. The file is
    /// overwritten with the emptiness. This is the shape worth naming; the
    /// fence only counts it, the report ranks it.
    @Test("gespeicherte Typen sind erhoben, damit ein neues Feld keine Historie kostet")
    func persistedTypesAreKnown() throws {
        var found: Set<String> = []
        for file in Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for hit in Self.persistedDecodes(in: text) { found.insert(hit.type) }
        }
        // A RATCHET at the measured count of distinct TYPES. Not of call
        // sites, which is what it counted first. The fence caught the
        // difference itself: adding a second READ of an already-persisted type
        // is harmless, while a new TYPE is the decision worth noticing, because
        // adding a field to it is a migration that can cost a history without
        // producing a single error.
        // 20: mit dem Ende der Bruecken-Aera fielen Manifest und Summary
        // der Faehre wieder aus dem Bestand; die Ratsche geht auf den
        // Stand davor zurueck.
        #expect(found.count <= 20,
                "ein neuer gespeicherter Typ — er braucht einen handgeschriebenen Dekodierer und einen Testfall auf seine Altform: \(found.sorted())")
    }

    @Test("der Persistenz-Zaun trennt Ablage von Netzantwort")
    func persistedFenceSeparatesStoreFromNetwork() {
        let store = """
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        """
        #expect(Self.persistedDecodes(in: store).map(\.type) == ["Entry"])

        let defaults = """
        guard let data = UserDefaults.standard.data(forKey: opsKey),
              let ops = try? JSONDecoder().decode([Operation].self, from: data) else { return [] }
        """
        #expect(Self.persistedDecodes(in: defaults).map(\.type) == ["Operation"])

        // Eine Netzantwort ist KEINE Ablage. Sonst faengt der Zaun 30 DTOs
        // und wird nach zwei Wochen abgeschaltet.
        let network = """
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        """
        #expect(Self.persistedDecodes(in: network).isEmpty)
    }

    // MARK: - Aufloesen ist kein Hoeren

    /// The body of every `fetchItemDetail`, brace-exact. A character window
    /// would read past the closing brace into the next function. The same
    /// mistake this file already made once with a 300-character window.
    static func detailFetchBodies(in text: String) -> [String] {
        var bodies: [String] = []
        var search = text.startIndex
        while let head = text.range(of: "func fetchItemDetail(", range: search..<text.endIndex) {
            guard let open = text.range(of: "{", range: head.upperBound..<text.endIndex) else { break }
            var depth = 0
            var index = open.lowerBound
            var end: String.Index?
            while index < text.endIndex {
                let character = text[index]
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { end = index; break }
                }
                index = text.index(after: index)
            }
            guard let end else { break }
            bodies.append(String(text[open.upperBound..<end]))
            search = end
        }
        return bodies
    }

    /// Resolving an item is not listening to it. The same resolution serves the
    /// bounded server check, the sync refresh and the restore after an app
    /// start. A statistic booked there counts launches, not plays.
    static func bookingsInsideDetailFetch(in text: String) -> Int {
        detailFetchBodies(in: text).reduce(0) { total, body in
            total + ["recordPlay", "recordRecent", "notePlaybackStarted"]
                .reduce(0) { $0 + body.components(separatedBy: $1).count - 1 }
        }
    }

    @Test("keine Zaehlung in einer Aufloesungs-Funktion")
    func resolvingNeverCounts() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() {
            if Self.bookingsInsideDetailFetch(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these sources book a play while merely resolving an item: \(offenders)")
    }

    /// Proof run on the shipped form. The two calls that really stood in
    /// `RadioProvider.fetchItemDetail`, and the booking beside it that is fine.
    @Test("der Zaehl-Zaun faengt die ausgelieferte Form und endet an der Klammer")
    func bookingFenceCatchesTheShippedShape() {
        let shipped = """
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            guard let station = RadioStore.station(forId: itemId) else { throw URLError(.badURL) }
            RadioStore.recordRecent(station)
            RadioStore.recordPlay(station)
            return LibraryItemDetail(id: station.id)
        }

        func notePlaybackStarted(itemId: String) {
            RadioStore.recordPlay(station)
        }
        """
        #expect(Self.bookingsInsideDetailFetch(in: shipped) == 2,
                "beide Buchungen im Rumpf — und die daneben zaehlt NICHT mit")
        #expect(Self.detailFetchBodies(in: shipped).count == 1)
        let fixed = """
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            guard let station = RadioStore.station(forId: itemId) else { throw URLError(.badURL) }
            return LibraryItemDetail(id: station.id)
        }
        """
        #expect(Self.bookingsInsideDetailFetch(in: fixed) == 0)
    }

    // MARK: - Der Inhaltstyp ist kein Antwortgeber mehr

    /// Every shape in which the old single content type could still be ASKED.
    /// The pair replaced it as the answer; a surface that reads the stored
    /// string again would be a second source of truth for one decision, which
    /// is the class this project keeps closing.
    static func legacyContentTypeReads(in text: String) -> Int {
        ["subsonicIsAudiobooksValue",
         "subsonicContentType",
         "string(forKey: \"subsonicContentType\")"]
            .reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
    }

    @Test("den alten Inhaltstyp befragt nur noch die Ablage selbst")
    func legacyContentTypeIsNotAnAnswer() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() {
            // The stock itself, and the choice-family CATALOG that classifies
            // every stored key by name. Naming a key is not asking it.
            if ["AppStorageKeys.swift", "UserChoiceSync.swift"]
                .contains(file.lastPathComponent) { continue }
            if Self.legacyContentTypeReads(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these surfaces still ask the old content type: \(offenders)")
    }

    /// A fence that only ever reports 0 proves nothing. This one is measured
    /// against the shapes that REALLY stood in the tree before the pair became
    /// the answer, one per read site.
    @Test("der Inhaltstyp-Zaun faengt die drei ausgelieferten Lesestellen")
    func legacyContentTypeFenceCatchesTheShippedShapes() {
        #expect(Self.legacyContentTypeReads(
            in: "let subsonicServesMusic = AppStorageKeys.subsonicActive && !AppStorageKeys.subsonicIsAudiobooksValue") == 1)
        #expect(Self.legacyContentTypeReads(
            in: "var mediaType: MediaType { AppStorageKeys.subsonicIsAudiobooksValue ? .audiobooks : .music }") == 1)
        #expect(Self.legacyContentTypeReads(
            in: "tabEnabled: subsonicIsAudiobooksValue ? audiobooksTabEnabledValue : musicTabEnabledValue,") == 1)
        #expect(Self.legacyContentTypeReads(
            in: "let modes = AppStorageKeys.subsonicModes") == 0)
    }

    /// One source, one type was only ever right while every source had exactly
    /// one library. The single-valued form must not come back through a new
    /// provider that copies an old one.
    /// TWO meanings of one name lived in this tree: the provider's content type
    /// (the enum) and Audiobookshelf's own library field (a String, "book" /
    /// "podcast"). The enum meaning is now always spelled `mediaTypes` or
    /// carried as `for type:`; the bare name belongs to the String layer alone.
    /// A new enum-typed `mediaType` would put the confusion straight back.
    static func ambiguousMediaTypeNames(in text: String) -> Int {
        ["mediaType: MediaType", "mediaType == .", "mediaType ?? ."]
            .reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
    }

    @Test("der Name mediaType gehoert der String-Ebene, nicht dem Aufzaehlungstyp")
    func mediaTypeNameIsNotAmbiguous() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() {
            if Self.ambiguousMediaTypeNames(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "these files spell the enum meaning with the String layer's name: \(offenders)")
    }

    @Test("der Namens-Zaun faengt die ausgelieferten Formen")
    func ambiguityFenceCatchesTheShippedShapes() {
        #expect(Self.ambiguousMediaTypeNames(
            in: "    var mediaType: MediaType { .radio }") == 1)
        #expect(Self.ambiguousMediaTypeNames(
            in: "where provider.mediaType == .audiobooks && provider.isAvailable {") == 1)
        // Die STRING-Ebene bleibt unberuehrt. Sie darf den Namen behalten.
        #expect(Self.ambiguousMediaTypeNames(in: "    var mediaType: String? = nil") == 0)
        #expect(Self.ambiguousMediaTypeNames(
            in: #"return libs.filter { ($0.mediaType ?? "book") == "book" }"#) == 0)
        #expect(Self.ambiguousMediaTypeNames(
            in: "func fetchLibraryItems(for type: MediaType) async throws -> [LibraryItem]") == 0)
    }

    @Test("kein Provider gibt seinen Typ noch als Einzelwert heraus")
    func providersAnswerWithASet() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("var mediaType: MediaType {") { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty,
                "these providers still answer with ONE type: \(offenders)")
    }
}

// MARK: - Der Quelltext spricht ohne uns

extension ProjectFileIntegrityTests {

    /// Walks every shipped Swift file and hands out its text.
    static func sourceTexts(in folders: [String] = ["Sources", "MaerWidgets", "LiveActivityWidget"]) -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        var found: [(String, String)] = []
        for folder in folders {
            let dir = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                found.append((url.lastPathComponent, text))
            }
        }
        return found
    }

    /// The names of the people who build this app appear in exactly one place:
    /// the copyright line. A comment addresses the NEXT reader, and the next
    /// reader does not know us.
    ///
    /// **The search is the one of the README fence, not a second one.** This
    /// fence had its own, word-exact and in one spelling only, so a genitive
    /// and a name in capitals passed here while the other fence caught them.
    /// Two fences that answer the same question must answer it the same way.
    @Test("no person is named in the sources outside the copyright line", .needsTheSources)
    func sourcesNamesNobody() throws {
        let files = Self.sourceTexts()
        #expect(!files.isEmpty, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        var offenders: [String] = []
        for (name, text) in files {
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                for hit in PublicReadmeFenceTests.roleNameHits(in: String(line)) {
                    offenders.append("\(name):\(number + 1) \(hit)")
                }
            }
        }
        #expect(offenders.isEmpty, "a person stands where a measurement belongs: \(offenders)")
    }

    /// Order shorthands carry a decision's history compactly, and only for us.
    /// Wikidata property ids (`P18`, `P154`) share the shape and are external
    /// vocabulary, so they are named as exceptions rather than pattern-matched
    /// around.
    static let wikidataProperties = ["P18", "P31", "P154", "P463"]

    @Test("no order shorthand is left in a comment", .needsTheSources)
    func commentsCarryNoOrderShorthands() throws {
        let files = Self.sourceTexts()
        #expect(!files.isEmpty, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        var offenders: [String] = []
        for (name, text) in files {
            for (number, comment) in Self.comments(in: text) {
                for hit in Self.orderShorthands(in: comment) {
                    offenders.append("\(name):\(number + 1) \(hit)")
                }
            }
        }
        #expect(offenders.isEmpty, "an order shorthand says nothing to a stranger: \(offenders)")
    }

    /// Every comment of a file with its zero-based line index. Lines inside a
    /// multi-line string literal are content, not comments: the literal opens
    /// on a line ending in three quotes and closes on a line starting with them.
    static func comments(in text: String) -> [(index: Int, comment: String)] {
        var out: [(Int, String)] = []
        var insideString = false
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if insideString {
                // The closing line may carry a comment behind the delimiter.
                if trimmed.hasPrefix("\"\"\"") {
                    insideString = false
                    if let comment = commentPart(of: String(trimmed.dropFirst(3))) { out.append((index, comment)) }
                }
                continue
            }
            if trimmed.hasSuffix("\"\"\""), !trimmed.hasPrefix("//") { insideString = true }
            if let comment = commentPart(of: String(line)) { out.append((index, comment)) }
        }
        return out
    }

    /// The comment of a line: everything after the first `//` outside a
    /// string literal, plus the inside of a `/* … */` on the same line. A
    /// comment behind code is read like a comment line; a `//` inside a
    /// string (an address) is not a comment. A raw string (`#"…"#`) ends
    /// only at a quote followed by its own hashes; a lone quote, a backslash
    /// or a `//` inside it is text.
    static func commentPart(of line: String) -> String? {
        var parts: [String] = []
        var inString = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if !inString, character == "#" {
                let hashes = line[index...].prefix { $0 == "#" }
                let afterHashes = hashes.endIndex
                if afterHashes < line.endIndex, line[afterHashes] == "\"" {
                    let close = "\"" + String(hashes)
                    guard let end = line[line.index(after: afterHashes)...].range(of: close) else { return nil }
                    index = end.upperBound
                    continue
                }
            }
            if inString {
                if character == "\\" {
                    index = line.index(after: index)
                    if index < line.endIndex { index = line.index(after: index) }
                    continue
                }
                if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if line[index...].hasPrefix("//") {
                parts.append(String(line[index...]))
                break
            } else if line[index...].hasPrefix("/*") {
                let rest = line[line.index(index, offsetBy: 2)...]
                guard let close = rest.range(of: "*/") else {
                    parts.append(String(rest))
                    break
                }
                parts.append(String(rest[..<close.lowerBound]))
                index = close.upperBound
                continue
            }
            index = line.index(after: index)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The letter shorthands of findings and orders (`E83`, `TF-9`,
    /// `GT-11`, `F5b-4`, `A27-3`). Outside vocabulary shares the shape and is
    /// named here, each entry read in its line, never matched around.
    static let outsideVocabulary: Set<String> = [
        "P18", "P31", "P154", "P463", "ISO8601", "UTF8", "UTF16", "SHA256", "SHA1", "MD5", "H264", "MP3",
        "HTTP2", "HTTP1", "IPV4", "IPV6", "A12", "A13", "AAC", "C0", "X25519", "HLS", "OPML2", "ID3", "S3",
        "M3U8", "GPL-3", "FNV-1a", "AX1", "AX2", "AX3", "AX4", "AX5", "UTF-8", "SHA-256", "ISO-639-3",
        "SWR1", "SWR3", "SWR4", "WDR-2", "SRF-1", "MP4", "RFC822",
    ]

    static func letterShorthands(in comment: String) -> [String] {
        matches(of: #"(?<![A-Za-z0-9_./-])[A-Z]{1,3}-?[0-9]{1,3}[a-z]?(?:-[0-9]+)?(?![A-Za-z0-9_])"#, in: comment)
            .filter { !outsideVocabulary.contains($0) }
    }

    /// Letter shorthands per file. The stock is EMPTY: every one in the app
    /// was rewritten by hand, keeping the reason it stood for, so a letter
    /// shorthand in any file fails the fence. A file named here that no
    /// longer exists would be a ghost and fail it too.
    nonisolated static let letterShorthandStock: [String: Int] = [:]

    @Test("letter shorthands in comments only fall, per file", .needsTheSources)
    func letterShorthandsOnlyFall() throws {
        let files = Self.sourceTexts()
        #expect(!files.isEmpty, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        var perFile: [String: [String]] = [:]
        for (name, text) in files {
            for (number, comment) in Self.comments(in: text) {
                for hit in Self.letterShorthands(in: comment) { perFile[name, default: []].append("\(number + 1) \(hit)") }
            }
        }
        var grown: [String] = []
        for (name, hits) in perFile where hits.count > Self.letterShorthandStock[name, default: 0] {
            grown.append("\(name): \(hits.count) > \(Self.letterShorthandStock[name, default: 0]) \(hits)")
        }
        #expect(grown.isEmpty, "a shorthand says nothing to a stranger; write the reason instead: \(grown)")
        let names = Set(files.map(\.name))
        let ghosts = Self.letterShorthandStock.keys.filter { !names.contains($0) }.sorted()
        #expect(ghosts.isEmpty, "the stock names files that are gone: \(ghosts)")
        let fallen = Self.letterShorthandStock.compactMap { name, stock -> String? in
            let now = perFile[name]?.count ?? 0
            return now < stock ? "\(name) \(stock) -> \(now)" : nil
        }.sorted()
        #expect(fallen.isEmpty, "the stock fell, write it back as measured: \(fallen)")
    }

    /// A comment without its code spans. A test names a fixture (`B1`) or
    /// plants the very shape a fence counts (`E83`), and it does so in
    /// backticks; outside them it follows the app's rule.
    static func withoutCodeSpans(_ comment: String) -> String {
        comment.replacingOccurrences(of: #"`[^`]*`"#, with: "``", options: .regularExpression)
    }

    @Test("letter shorthands in test comments: none outside backticks", .needsTheSources)
    func letterShorthandsStayOutOfTheTests() throws {
        let files = Self.sourceTexts(in: ["MaerTests", "MaerUITests"])
        #expect(files.count > 100, "der Zaun hat die Tests nicht gelesen, also misst er nichts: \(files.count)")
        var found: [String] = []
        for (name, text) in files {
            for (number, comment) in Self.comments(in: text) {
                for hit in Self.letterShorthands(in: Self.withoutCodeSpans(comment)) { found.append("\(name):\(number + 1) \(hit)") }
            }
        }
        #expect(found.isEmpty, "a shorthand says nothing to a stranger; write the reason instead: \(found)")
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }

    /// `R45`, `P10`, `Auftrag K`, `Auflage 1`. Wikidata properties share the
    /// letter-plus-number shape and are named above as exceptions.
    static func orderShorthands(in line: String) -> [String] {
        var hits: [String] = []
        for word in line.split(whereSeparator: { !isWordCharacter($0) }) {
            let token = String(word)
            guard token.count >= 2, let first = token.first,
                  first == "R" || first == "P",
                  token.dropFirst().allSatisfy(\.isNumber)
            else { continue }
            if wikidataProperties.contains(token) { continue }
            hits.append(token)
        }
        if line.contains("Auftrag ") { hits.append("Auftrag") }
        if line.contains("Auflage ") { hits.append("Auflage") }
        // A build number and a finding number (`Build 48`, `47-6`) are the
        // same history in another shape. A range of numbers (`0,99-1,49`)
        // is not: a digit or a comma beside it keeps it out. A letter in
        // front (`A27-3`) is the older form of the letter shorthands, which
        // this line does not count.
        hits += matches(of: #"Build [0-9]+"#, in: line)
        hits += matches(of: #"(?<![0-9A-Za-z,.])[0-9]{2}-[0-9](?![0-9,.])"#, in: line)
        return hits
    }

    /// A step of a plan (`3b`, `4b`): the older comments still carry some,
    /// so this form has a stock that may only fall.
    static func planSteps(in line: String) -> [String] {
        // A hyphen in front is a name (`FNV-1a`), not a step.
        matches(of: #"(?<![0-9A-Za-z_-])[0-9]{1,2}[a-f](?![0-9A-Za-z_])"#, in: line)
    }

    /// The comment lines naming a plan step. The stock is EMPTY: every one
    /// was rewritten by hand, so a new plan step in a comment fails the fence.
    nonisolated static let planStepStock = 0

    @Test("plan steps in comments only fall", .needsTheSources)
    func planStepsOnlyFall() throws {
        let files = Self.sourceTexts()
        #expect(!files.isEmpty, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        var found: [String] = []
        for (name, text) in files {
            for (number, comment) in Self.comments(in: text) {
                for hit in Self.planSteps(in: comment) { found.append("\(name):\(number + 1) \(hit)") }
            }
        }
        #expect(found.count <= Self.planStepStock, "a plan step names history, not the code: \(found)")
    }

    private static func matches(of pattern: String, in line: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            Issue.record("the pattern does not compile: \(pattern)")
            return []
        }
        let range = NSRange(line.startIndex..., in: line)
        return regex.matches(in: line, range: range).compactMap { Range($0.range, in: line).map { String(line[$0]) } }
    }

    /// The instrument itself, in both directions: a planted line goes red, the
    /// copyright line and the external vocabulary stay green.
    @Test("the two fences fire on a planted line and stay quiet on the header")
    func theFencesFireInBothDirections() {
        let names = PublicReadmeFenceTests.roleNameHits
        #expect(!names("/// Laurenz am Geraet: kein Bild", nil).isEmpty)
        #expect(names("// Copyright (C) 2026 Laurenz Schröder", nil).isEmpty)
        #expect(names("/// one Piece of the answer", nil).isEmpty)
        #expect(names("/// see fable-auftraege", nil).contains("fable-auftraege"),
                "a channel branch carries the name, and the history no longer does")
        #expect(names("/// the account momo-bot and pie-berichte", nil) == ["momo-bot", "pie-berichte"])
        #expect(names("// Copyright (C) 2026 Laurenz Schröder, gemessen von Momo", nil) == ["Momo"])
        // The planted line that stood green here while the README fence
        // already knew all three forms.
        #expect(Set(names("// Pies Messung und MOMO und Takts Fund", nil)) == ["Pies", "MOMO", "Takts"])
        #expect(Self.orderShorthands(in: "/// R58: die Faecher fragen") == ["R58"])
        #expect(Self.orderShorthands(in: "/// Auftrag K settled it") == ["Auftrag"])
        #expect(Self.orderShorthands(in: "/// Wikidata P154 first").isEmpty)
        #expect(Self.orderShorthands(in: "/// the row shows twelve tiles").isEmpty)
        #expect(Self.orderShorthands(in: "/// the refused feed (47-6: typed by hand)") == ["47-6"])
        #expect(Self.orderShorthands(in: "/// `maerSync` (Build 48): the address") == ["Build 48"])
        #expect(Self.orderShorthands(in: "/// answers in 0,99-1,49 s, a year 1999-2001").isEmpty)
        #expect(Self.planSteps(in: "/// Welle 3b: the full grid") == ["3b"])
        #expect(Self.planSteps(in: "/// waits 30s, a 64k buffer, an FNV-1a hash").isEmpty,
                "units and names are not steps")
        #expect(Self.orderShorthands(in: "/// mechanics never note (A27-3)").isEmpty,
                "the older letter form is not this line's count")
        // A multi-line string is content: its lines are no comments, a comment
        // behind the closing delimiter and after the literal is one.
        let multiline = "let s = \"\"\"\n    // E83 is string content\n    \"\"\" // T46 behind the close\n// X21 after the string"
        #expect(Self.comments(in: multiline).map(\.index) == [2, 3])
        #expect(Self.comments(in: multiline).flatMap { Self.letterShorthands(in: $0.comment) } == ["T46", "X21"])
        // The comment part: behind code it counts, inside a string it is none.
        let behindCode = Self.commentPart(of: "    RecentSearches.record(query)   // Y30: dedupe") ?? ""
        #expect(Self.letterShorthands(in: behindCode) == ["Y30"], "a shorthand behind code counts")
        #expect(Self.commentPart(of: #"let u = "http://host/E83" // plain"#) == "// plain")
        #expect(Self.commentPart(of: #"let s = "a // E83 inside a string""#) == nil)
        #expect(Self.commentPart(of: #"let q = "\"" // R1 after an escaped quote"#) == "// R1 after an escaped quote")
        // A raw string: a lone quote and `//` inside are text, it ends at its hashes.
        #expect(Self.commentPart(of: ##"let d = Data(#"["https://a.example/E83","x"]"#.utf8)"##) == nil)
        #expect(Self.commentPart(of: ##"let p = #"a\"// E83"# // T46 after"##) == "// T46 after")
        #expect(Self.commentPart(of: ###"let q = ##"x"# // E83 still inside"## // R1"###) == "// R1")
        #expect(Self.letterShorthands(in: Self.commentPart(of: "cancel { _ in /* T46 */ }") ?? "") == ["T46"])
        #expect(Self.letterShorthands(in: "/// TF-9, GT-11, F5b-4, A27-3, E83") == ["TF-9", "GT-11", "F5b-4", "A27-3", "E83"])
        #expect(Self.letterShorthands(in: "// SPDX GPL-3, UTF-8, SWR3, AX3, FNV-1a, `audio/*`").isEmpty,
                "outside vocabulary is named, not matched around")
        #expect(Self.letterShorthands(in: Self.withoutCodeSpans("// `B1` has no stamp, T46 does")) == ["T46"],
                "a code span is exempt, the prose beside it is not")
        #expect(Self.letterShorthands(in: Self.withoutCodeSpans("// a lone ` T46 is prose")) == ["T46"])
        #expect(Self.proseDashes(in: "/// one thought — and a second one"))
        #expect(!Self.proseDashes(in: "/// the deck shows \"Artist — Title\""))
        #expect(!Self.proseDashes(in: "/// one thought. And a second one"))
    }

    /// One thought, one sentence. Where a dash used to hold two statements
    /// together, there are two sentences now. A dash inside a quoted value
    /// stays: there it is the content the code handles, not prose.
    static func proseDashes(in line: String) -> Bool {
        var insideDouble = false
        var insideBacktick = false
        for character in line {
            if character == "\"" { insideDouble.toggle() }
            if character == "`" { insideBacktick.toggle() }
            if character == "\u{2014}", !insideDouble, !insideBacktick { return true }
        }
        return false
    }

    @Test("no comment holds two statements together with a dash", .needsTheSources)
    func commentsCarryNoProseDashes() throws {
        let files = Self.sourceTexts()
        #expect(!files.isEmpty, "der Zaun hat keine Quelldatei gelesen, also misst er nichts")
        var offenders: [String] = []
        for (name, text) in files {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (number, line) in lines.enumerated() where number >= 5 {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("//"), Self.proseDashes(in: String(line)) else { continue }
                offenders.append("\(name):\(number + 1)")
            }
        }
        #expect(offenders.isEmpty, "a dash still carries two statements: \(offenders)")
    }

    /// Der ID-Umzug ist ZU ENDE: mit dem Ende der Bruecken-Aera fielen
    /// auch die drei gepinnten Stellen (KVS-Topf, App-Group,
    /// CloudKit-Container) und der alte Keychain-Service. Der alte Stamm
    /// darf in Sources NIRGENDS mehr stehen, auch nicht der alte
    /// Projektname als Code- oder Pfadname. Die einzige Ausnahme ist der
    /// Ruhestands-Verweis der Keychain-Hygiene, der den alten Service
    /// zum LOESCHEN nennen muss.
    /// Die Mac-Notwehr traegt nur, solange sie die EINZIGE Slider-Stelle
    /// ist: ein zweiter nackter `Slider(` irgendwo umgeht sie lautlos,
    /// und der Absturz waere zurueck, ohne dass jemand etwas merkt.
    /// Ein reiner Domaenentyp darf nicht in einer Datei wohnen, die ein
    /// Framework importiert: die Wohnadresse allein machte PodcastShow
    /// und PodcastEpisode fuer die pure Schicht unerreichbar (die
    /// Quellen-Wache uebersetzt unseren echten Dekodierer auf Linux,
    /// Foundation-only, und verweigerte die Datei). Der Typ ist unschuldig,
    /// die Adresse war es nicht.
    @Test("Codable-Domaenentypen wohnen nicht in Framework-Dateien")
    func codableTypesLiveInPureFiles() throws {
        // Die BESTANDSAUFNAHME (Aufzaehlpflicht des Entscheids): diese
        // vier wohnen heute noch in Framework-Dateien. Sie sind kein
        // Freibrief, sondern die Liste, die abgearbeitet wird, sobald
        // eine von ihnen die pure Schicht wirklich blockiert; die
        // Podcast-Typen sind ausgezogen, weil sie es TATEN.
        let bestand: Set<String> = ["LibraryDiskCache", "ListeningStatsData",
                                    "LyricsLine", "SongLyrics"]
        var offenders: [String] = []
        for file in Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            let frameworks = ["import Combine", "import SwiftUI", "import UIKit"]
            guard frameworks.contains(where: { text.contains($0) }) else { continue }
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                // NUR eigenstaendige Typen: ein GESCHACHTELTER (eingerueckter)
                // Typ gehoert seinem Besitzer und teilt dessen Adresse
                // zu Recht. Die Frage ist die Wohnung des Domaenentyps,
                // nicht die eines inneren Berichts-Records.
                guard !line.hasPrefix(" "), !line.hasPrefix("\t") else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("nonisolated struct ") || trimmed.hasPrefix("struct ") else { continue }
                guard trimmed.contains(": Codable") || trimmed.contains(", Codable") else { continue }
                let name = trimmed.replacingOccurrences(of: "nonisolated ", with: "")
                    .dropFirst("struct ".count)
                    .prefix { $0.isLetter || $0.isNumber }
                if !bestand.contains(String(name)) {
                    offenders.append("\(file.lastPathComponent):\(number + 1) \(name)")
                }
            }
        }
        #expect(offenders.isEmpty,
                "ein Codable-Domaenentyp in einer Framework-Datei: \(offenders)")
        // Rot-Probe: der Zaun saehe genau diese Form.
        #expect("nonisolated struct X: Codable, Sendable {".contains(": Codable"))
    }

    /// Die Kernschicht baut auf einem nackten Linux-Werkzeugkasten (die
    /// Quellen-Wache prueft dort den echten Decoder). Ein einziges
    /// Apple-Rahmenwerk in `Sources/Models` macht sie blind, ohne dass
    /// der Sim es zeigt. Positivliste statt Erinnerung: erlaubt sind
    /// Foundation und OSLog; die zwei Combine-Dateien stehen NAMENTLICH,
    /// weil dort nur `ObservableObject`-Speicher wohnen, keine Kernlogik.
    /// Der Pruefer als pure Funktion ueber EINE Zeile, damit die Rot-Probe
    /// den PRUEFER fuettert und nicht eine Eigenschaft eines Strings.
    /// Bestandsliste nach RELATIVEM Pfad, damit eine gleichnamige Datei in
    /// einem Unterordner die Ausnahme nicht erbt.
    nonisolated static func offendingImport(line: String, relativePath: String) -> String? {
        // `Synchronization` is the standard library's `Mutex`, no framework.
        let allowed: Set<String> = ["Foundation", "OSLog", "Synchronization"]
        let bestand: [String: Set<String>] = ["Sources/Models/ListeningStats.swift": ["Combine"],
                                              "Sources/Models/RadioGenreSources.swift": ["Combine"]]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("import ") else { return nil }
        let module = String(trimmed.dropFirst("import ".count)
            .prefix { $0.isLetter || $0.isNumber })
        if allowed.contains(module) { return nil }
        if bestand[relativePath]?.contains(module) == true { return nil }
        return module
    }

    @Test("Sources/Models importiert nur Foundation und OSLog")
    func coreLayerImportsOnlyFoundation() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() where file.path.contains("/Sources/Models/") {
            let relative = "Sources/Models/" + file.lastPathComponent
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if let module = Self.offendingImport(line: String(line), relativePath: relative) {
                    offenders.append("\(relative):\(number + 1) \(module)")
                }
            }
        }
        #expect(offenders.isEmpty,
                "ein Apple-Rahmenwerk in der Kernschicht: \(offenders)")
        // Rot-Proben am PRUEFER, in beide Richtungen.
        #expect(Self.offendingImport(line: "import CryptoKit",
                                     relativePath: "Sources/Models/FreeCatalog.swift") == "CryptoKit")
        #expect(Self.offendingImport(line: "import Combine",
                                     relativePath: "Sources/Models/ListeningStats.swift") == nil)
        #expect(Self.offendingImport(line: "import Combine",
                                     relativePath: "Sources/Models/Other.swift") == "Combine")
        #expect(Self.offendingImport(line: "import Combine",
                                     relativePath: "Sources/Models/Sub/ListeningStats.swift") == "Combine")
        #expect(Self.offendingImport(line: "import Foundation",
                                     relativePath: "Sources/Models/X.swift") == nil)
    }

    /// Image bytes leave through ONE door that raises cleartext addresses
    /// to https; a call site that reads from the session directly would
    /// be refused by App Transport Security on every feed with `http://`
    /// images and show a placeholder instead.
    @Test("Bildbytes kommen nur durch die eine Tuer, die http auf https hebt")
    func coverBytesPassTheOneDoor() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() where file.lastPathComponent != "URLSession+Maer.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let squeezed = line.split(separator: " ").joined()
                if squeezed.contains("coverImage.data(from:") {
                    offenders.append("\(file.lastPathComponent):\(number + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "these read image bytes past the https door: \(offenders)")
        // Rot-Probe: der Zaun saehe genau diese Zeile, auch mit Leerraum.
        #expect("try await URLSession.coverImage .data(from: url)".split(separator: " ").joined().contains("coverImage.data(from:"))
        #expect(!"try await URLSession.coverImage.coverData(from: url)".contains("coverImage.data(from:"))
    }

    /// The archive.org identifier is cut out of an item id in ONE place,
    /// which knows the song address. A surface that drops the prefix itself
    /// sends `%23<index>` into every link for a song.
    @Test("die archive.org-Kennung wird nur an einer Stelle aus der Id geschnitten")
    func archiveIdentifierIsCutInOnePlace() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() where file.lastPathComponent != "FreeCatalog.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let squeezed = line.split(separator: " ").joined()
                if squeezed.contains("dropFirst(FreeCatalog.archivePrefix.count)") {
                    offenders.append("\(file.lastPathComponent):\(number + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "these cut the archive identifier themselves: \(offenders)")
        #expect("String(id.dropFirst(FreeCatalog.archivePrefix.count))".contains("dropFirst(FreeCatalog.archivePrefix.count)"))
    }

    @Test("Slider steht in Sources nur im PlatformScrubber")
    func sliderLivesOnlyInThePlatformScrubber() throws {
        var offenders: [String] = []
        for file in Self.sourceFiles() where file.lastPathComponent != "PlatformScrubber.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                if trimmed.contains("Slider(") {
                    offenders.append("\(file.lastPathComponent):\(number + 1)")
                }
            }
        }
        #expect(offenders.isEmpty,
                "ein Slider ausserhalb der Notwehr-Weiche: \(offenders)")
        // Rot-Probe: der Zaun saehe genau diese Zeile.
        #expect("        Slider(value: $x, in: 0...1)".contains("Slider("))
    }

    /// Das Zahnrad gehoert den Tab-Wurzeln und keiner geschobenen Seite.
    /// Die Regel war vorher begruendet, aber von aussen unsichtbar: der
    /// Nutzer sieht einer Flaeche nicht an, ob sie Wurzel oder geschoben
    /// ist, und las den Unterschied als Willkuer. Ein Zaun statt eines
    /// Kommentars, weil die naechste Detailseite ihn sonst wieder
    /// mitbringt.
    @Test("das Zahnrad steht an genau EINER Stelle im Quelltext")
    func settingsGearLivesOnlyAtTheTabRoot() throws {
        var fundstellen: [String] = []
        for file in Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                if trimmed.contains("gearshape") {
                    fundstellen.append("\(file.lastPathComponent):\(number + 1)")
                }
            }
        }
        #expect(fundstellen.count == 1,
                "das Zahnrad steht nicht mehr an genau einer Stelle: \(fundstellen)")
        #expect(fundstellen.first?.hasPrefix("LibraryView.swift") == true,
                "die eine Stelle ist nicht die Tab-Wurzel: \(fundstellen)")
        // Rot-Probe: der Zaun saehe eine zweite Stelle sehr wohl.
        #expect("            Image(systemName: \"gearshape\")".contains("gearshape"))
    }

    @Test("der alte Stamm kommt in Sources nicht mehr vor")
    func oldIdentityStemIsGone() throws {
        let stems = ["de.lzs", "com.example.absplayer", "ABSPlayer"]
        let erlaubt: Set<String> = ["KeychainStore.swift"]
        var offenders: [String] = []
        for file in Self.sourceFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard stems.contains(where: { text.contains($0) }) else { continue }
            if !erlaubt.contains(file.lastPathComponent) {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "alter Identitaets-Stamm in Sources: \(offenders.sorted())")
        // Rot-Probe: der Zaun saehe jeden Rueckfall.
        #expect("let x = \"de.lzs.\" + \"anything\"".contains("de.lzs"))
        // Und die Ausnahme traegt wirklich nur den Ruhestands-Verweis.
        let keychainFile = try #require(Self.sourceFiles()
            .first { $0.lastPathComponent == "KeychainStore.swift" })
        let keychain = try String(contentsOf: keychainFile, encoding: .utf8)
        #expect(keychain.contains("retiredService"))
        #expect(!keychain.contains("de.lzs"))
    }

    /// The old stems, as they may still appear in the documents and the
    /// tools: only the App-ID history in `docs/appstore.md` (the id itself,
    /// `de.lzs.ABSPlayer`) and a line that names this fence (the flip's
    /// own inventory row). Everything else is a line that points at a name
    /// the repository no longer has.
    nonisolated static let oldStems = ["de.lzs", "com.example.absplayer", "ABSPlayer"]

    /// Lines of one file that carry an old stem outside the two named
    /// exceptions, one-based.
    nonisolated static func oldStemLines(in text: String, fileName: String) -> [Int] {
        var out: [Int] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard oldStems.contains(where: line.contains) else { continue }
            if line.contains("oldIdentityStemIsGone") { continue }
            if fileName == "appstore.md" {
                // The App-ID history: every stem on the line is the id.
                let stripped = line.replacingOccurrences(of: "de.lzs.ABSPlayer", with: "")
                if !oldStems.contains(where: stripped.contains) { continue }
            }
            out.append(index + 1)
        }
        return out
    }

    @Test("der alte Stamm kommt in docs und tools nicht mehr vor", .needsTheSources)
    func oldIdentityStemIsGoneFromDocsAndTools() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("docs"),
                                                                includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        files += FileManager.default.enumerator(at: root.appendingPathComponent("tools"),
                                                includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
        // The precondition names what the finder must see, not a count: a
        // count was a value without a reason, and it held on a working
        // tree with an untracked file while a clean checkout has exactly
        // the tracked ones (20 at the time, measured by the reviewer).
        let names = Set(files.map(\.lastPathComponent))
        for expected in ["components.md", "appstore.md", "app-keys.md", "messung.sh"] {
            try #require(names.contains(expected), "the finder must still see \(expected): \(names.sorted())")
        }
        var offenders: [String] = []
        for file in files {
            // A file that is not text (an image, a font) carries no prose.
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = Self.oldStemLines(in: text, fileName: file.lastPathComponent)
            if !lines.isEmpty { offenders.append("\(file.lastPathComponent): \(lines)") }
        }
        #expect(offenders.isEmpty, "alter Identitaets-Stamm in docs oder tools: \(offenders.sorted())")
        // Red probes on the checker: a planted name is found with its line,
        // the two exceptions stay quiet, an id beside a planted name does not.
        #expect(Self.oldStemLines(in: "fine\nsee `ABSPlayerApp.init()`\n", fileName: "components.md") == [2])
        #expect(Self.oldStemLines(in: "the fence `oldIdentityStemIsGone` (de.lzs, ABSPlayer)", fileName: "components.md").isEmpty)
        #expect(Self.oldStemLines(in: "id `de.lzs.ABSPlayer` and `group.de.lzs.ABSPlayer`", fileName: "appstore.md").isEmpty)
        #expect(Self.oldStemLines(in: "id `de.lzs.ABSPlayer`, file `ABSPlayer.entitlements`", fileName: "appstore.md") == [1])
        #expect(Self.oldStemLines(in: "id `de.lzs.ABSPlayer`", fileName: "app-keys.md") == [1], "the id history is appstore.md's alone")
    }

    /// Kein Zeuge kehrt still zurueck, und der Bestand faellt nur.
    ///
    /// Die Form `guard <Bedingung> else { return }` am Anfang eines Falls ist
    /// **kein Ueberspringen**: der Fall meldet BESTANDEN und hat nichts
    /// gemessen. Sie stand an fuenfzehn Stellen, die meisten davon in
    /// ZAEUNEN, zwei mit dem Satz „sources unreadable, no verdict" daneben
    /// und einem gruenen Haekchen darunter. Sie hat sich durch Abschreiben
    /// fortgepflanzt, also schafft ein Handgriff sie nicht ab.
    ///
    /// Was an ihre Stelle tritt, trennt die zwei Gruende: **liegt die Quelle
    /// dieser Kopie nicht bei**, entscheidet das eine Bedingung VOR dem Lauf
    /// (`.needsTheSources` und ihre Nachbarn), und der Fall erscheint als
    /// uebersprungen · **ist sie da und der Zaun hat trotzdem nichts
    /// gelesen**, ist das ein Befund und gehoert rot.
    @Test("kein Zeuge kehrt still zurueck", .needsTheTests)
    func noWitnessReturnsSilently() throws {
        // Der Bestand je Datei, mit Grund im Eintrag. Ein Eintrag ohne Grund
        // waere eine Ausnahme, die niemand nachgesehen hat.
        let stock: [String: (count: Int, reason: String)] = [
            "ProjectFileIntegrityTests.swift":
                (1, "ein guard INNERHALB eines Fixture-Textes, den ein anderer Zaun liest"),
        ]
        let directory = SourceTree.root.appendingPathComponent("MaerTests")
        let walker = try #require(FileManager.default.enumerator(at: directory,
                                                                includingPropertiesForKeys: nil))
        var checked = 0
        var found: [String: Int] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            let hits = text.split(separator: "\n", omittingEmptySubsequences: false).filter {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return line.hasPrefix("guard ") && line.hasSuffix("else { return }")
            }.count
            if hits > 0 { found[url.lastPathComponent] = hits }
        }
        // Derselbe Riegel, den dieser Zaun einfordert, an ihm selbst.
        #expect(checked > 0, "der Zaun hat keine Testdatei gelesen, also misst er nichts")
        for (name, hits) in found.sorted(by: { $0.key < $1.key }) {
            let allowed = stock[name]?.count ?? 0
            #expect(hits <= allowed,
                    "\(name) kehrt an \(hits) Stellen still zurueck, erlaubt sind \(allowed)")
        }
        // Rot-Probe im Fall selbst: der Sucher saehe die Form ueberhaupt.
        let sample = "        guard names.isEmpty else { return }"
        #expect(sample.trimmingCharacters(in: .whitespaces).hasPrefix("guard "))
        #expect(sample.trimmingCharacters(in: .whitespaces).hasSuffix("else { return }"))
    }
}
