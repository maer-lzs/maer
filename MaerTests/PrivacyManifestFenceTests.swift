// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation

/// App Store Connect takes an upload only when a target's privacy manifest
/// names a reason for every category of required reason API its code calls.
/// This fence holds each target's manifest to that target's sources in both
/// directions: every category the code calls is declared, and no category
/// is declared without a call. The lists below are Apple's, from the
/// documentation of `NSPrivacyAccessedAPIType` (Bundle Resources, "Describing
/// use of required reason API"), written the way Swift code spells them.
struct PrivacyManifestFenceTests {

    /// One category of required reason API. `names` count wherever the word
    /// stands on its own (a key, a property, a type); a URL resource key's
    /// value property is listed beside the key because reading it names the
    /// key too. `functions` count only as a call: the word, then `(`, and
    /// no `.` before it, so a method of the same name on a value does not.
    struct Category {
        let name: String
        let names: Set<String>
        let functions: Set<String>
    }

    nonisolated static let categories: [Category] = [
        Category(name: "NSPrivacyAccessedAPICategoryFileTimestamp",
                 names: ["creationDate", "creationDateKey", "modificationDate", "fileModificationDate",
                         "contentModificationDate", "contentModificationDateKey"],
                 functions: ["getattrlist", "getattrlistbulk", "fgetattrlist", "getattrlistat",
                             "stat", "fstat", "fstatat", "lstat"]),
        Category(name: "NSPrivacyAccessedAPICategorySystemBootTime",
                 names: ["systemUptime"],
                 functions: ["mach_absolute_time"]),
        Category(name: "NSPrivacyAccessedAPICategoryDiskSpace",
                 names: ["volumeAvailableCapacityKey", "volumeAvailableCapacity",
                         "volumeAvailableCapacityForImportantUsageKey", "volumeAvailableCapacityForImportantUsage",
                         "volumeAvailableCapacityForOpportunisticUsageKey", "volumeAvailableCapacityForOpportunisticUsage",
                         "volumeTotalCapacityKey", "volumeTotalCapacity", "systemFreeSize", "systemSize"],
                 functions: ["statfs", "statvfs", "fstatfs", "fstatvfs", "getattrlist", "fgetattrlist", "getattrlistat"]),
        Category(name: "NSPrivacyAccessedAPICategoryActiveKeyboards",
                 names: ["activeInputModes"],
                 functions: []),
        Category(name: "NSPrivacyAccessedAPICategoryUserDefaults",
                 names: ["UserDefaults"],
                 functions: []),
    ]

    /// The reason each declared category must carry, as Apple words it:
    /// `CA92.1` user defaults only this app reads and writes; `E174.1`
    /// checking whether there is space to write files or to delete files
    /// when space is low; `C617.1` timestamps and other metadata of files
    /// inside the app's own container.
    nonisolated static let reasons: [String: String] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": "CA92.1",
        "NSPrivacyAccessedAPICategoryDiskSpace": "E174.1",
        "NSPrivacyAccessedAPICategoryFileTimestamp": "C617.1",
    ]

    /// The categories one source text calls, comment lines left out.
    nonisolated static func categoriesCalled(in text: String) -> Set<String> {
        let code = SyncContractFenceTests.stripped(text)
        var found = Set<String>()
        for match in code.matches(of: #/[A-Za-z_][A-Za-z0-9_]*/#) {
            let word = String(match.output)
            let before: Character = match.range.lowerBound > code.startIndex
                ? code[code.index(before: match.range.lowerBound)] : " "
            let after: Character = match.range.upperBound < code.endIndex ? code[match.range.upperBound] : " "
            for category in categories {
                if category.names.contains(word)
                    || (category.functions.contains(word) && after == "(" && before != ".") {
                    found.insert(category.name)
                }
            }
        }
        return found
    }

    /// The categories a manifest declares, each with its reasons.
    nonisolated static func declared(in manifest: Data) throws -> [String: [String]] {
        let read = try PropertyListSerialization.propertyList(from: manifest, format: nil)
        let top = try #require(read as? [String: Any], "the manifest is no dictionary")
        let types = try #require(top["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
                                 "the manifest has no NSPrivacyAccessedAPITypes array")
        var out: [String: [String]] = [:]
        for entry in types {
            let name = try #require(entry["NSPrivacyAccessedAPIType"] as? String, "an entry without its type: \(entry)")
            out[name] = entry["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? []
        }
        return out
    }

    /// The categories the given Swift files call, with the files per category.
    nonisolated static func called(by files: [URL]) throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for file in files where file.pathExtension == "swift" {
            for category in categoriesCalled(in: try String(contentsOf: file, encoding: .utf8)) {
                out[category, default: []].append(file.lastPathComponent)
            }
        }
        return out
    }

    /// The Sources files the widget target takes in beside its own folder,
    /// as the project file names them.
    nonisolated static func widgetMembersFromSources(project: String) throws -> [String] {
        let head = "/* Exceptions for \"Sources\" folder in \"MaerWidgetsExtension\" target */ = {"
        let start = try #require(project.range(of: head), "the project names no Sources exceptions for the widget")
        let list = try #require(project.range(of: "membershipExceptions = (", range: start.upperBound..<project.endIndex))
        let end = try #require(project.range(of: ");", range: list.upperBound..<project.endIndex))
        return project[list.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ",\"")) }
            .filter { $0.hasSuffix(".swift") }
    }

    private func expectMatch(declared: [String: [String]], called: [String: [String]], target: String) {
        let undeclared = Set(called.keys).subtracting(declared.keys).sorted()
        #expect(undeclared.isEmpty, "\(target) calls \(undeclared.map { "\($0) in \(called[$0] ?? [])" }) without a reason in its manifest")
        let unused = Set(declared.keys).subtracting(called.keys).sorted()
        #expect(unused.isEmpty, "\(target)'s manifest declares \(unused) without a call in its sources")
        for (category, given) in declared {
            let reason = Self.reasons[category]
            #expect(reason != nil && given.contains(reason ?? ""),
                    "\(target) declares \(category) with \(given), the reason for this app is \(reason ?? "not set")")
        }
    }

    @Test("das Manifest der App nennt genau die Kategorien, die ihr Code ruft, je mit ihrem Grund", .needsTheSources)
    func theAppManifestMatchesItsSources() throws {
        let sources = SourceTree.root.appendingPathComponent("Sources")
        let called = try Self.called(by: SourceTree.files(under: sources))
        try #require(called["NSPrivacyAccessedAPICategoryUserDefaults"] != nil,
                     "the reader saw no UserDefaults in Sources, so it read nothing")
        let manifest = try Data(contentsOf: sources.appendingPathComponent("PrivacyInfo.xcprivacy"))
        expectMatch(declared: try Self.declared(in: manifest), called: called, target: "the app")
    }

    @Test("das Widget ruft keine Kategorie ohne eigenes Manifest", .needsTheSources, .needsTheProjectFile)
    func theWidgetManifestMatchesItsSources() throws {
        let project = try String(contentsOf: SourceTree.root.appendingPathComponent("Maer.xcodeproj/project.pbxproj"),
                                 encoding: .utf8)
        let shared = try Self.widgetMembersFromSources(project: project)
        try #require(shared.contains("Models/WidgetShared.swift"), "the widget's shared file was not found: \(shared)")
        let folder = SourceTree.root.appendingPathComponent("LiveActivityWidget")
        let files = SourceTree.files(under: folder)
            + shared.map { SourceTree.root.appendingPathComponent("Sources").appendingPathComponent($0) }
        try #require(files.contains { $0.lastPathComponent == "MaerWidgetBundle.swift" }, "the widget folder was not read")
        let called = try Self.called(by: files)
        let manifests = files.filter { $0.lastPathComponent == "PrivacyInfo.xcprivacy" }
            + SourceTree.files(under: SourceTree.root.appendingPathComponent("MaerWidgets"))
                .filter { $0.lastPathComponent == "PrivacyInfo.xcprivacy" }
        try #require(manifests.count <= 1, "the widget has more than one manifest: \(manifests)")
        let declared = try manifests.first.map { try Self.declared(in: Data(contentsOf: $0)) } ?? [:]
        expectMatch(declared: declared, called: called, target: "the widget")
    }

    @Test("der Leser trennt Aufruf, Methode gleichen Namens und Kommentar")
    func theReaderSeesTheCallNotItsNeighbours() throws {
        #expect(Self.categoriesCalled(in: "let v = try url.resourceValues(forKeys: [.contentModificationDateKey])")
                == ["NSPrivacyAccessedAPICategoryFileTimestamp"])
        #expect(Self.categoriesCalled(in: "try fm.setAttributes([.modificationDate: date], ofItemAtPath: p)")
                == ["NSPrivacyAccessedAPICategoryFileTimestamp"])
        #expect(Self.categoriesCalled(in: "let up = ProcessInfo.processInfo.systemUptime")
                == ["NSPrivacyAccessedAPICategorySystemBootTime"])
        #expect(Self.categoriesCalled(in: "let free = values?.volumeAvailableCapacityForImportantUsage ?? 0")
                == ["NSPrivacyAccessedAPICategoryDiskSpace"])
        #expect(Self.categoriesCalled(in: "guard statfs(path, &buffer) == 0 else { return }")
                == ["NSPrivacyAccessedAPICategoryDiskSpace"])
        #expect(Self.categoriesCalled(in: "let defaults = UserDefaults.standard")
                == ["NSPrivacyAccessedAPICategoryUserDefaults"])
        #expect(Self.categoriesCalled(in: "let s = status(of: x); let t = item.stat(x); let restat = 1").isEmpty,
                "a longer word and a method of the same name are no call")
        #expect(Self.categoriesCalled(in: "    // volumeAvailableCapacityKey and UserDefaults in a comment").isEmpty)

        let sample = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>NSPrivacyAccessedAPITypes</key><array>
        <dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryDiskSpace</string>
        <key>NSPrivacyAccessedAPITypeReasons</key><array><string>E174.1</string></array></dict>
        </array></dict></plist>
        """.utf8)
        let declaredSample = try Self.declared(in: sample)
        #expect(declaredSample == ["NSPrivacyAccessedAPICategoryDiskSpace": ["E174.1"]])
        let project = """
        /* Exceptions for "Sources" folder in "MaerWidgetsExtension" target */ = {
            membershipExceptions = (
                Localizable.xcstrings,
                Models/WidgetShared.swift,
            );
        """
        let members = try Self.widgetMembersFromSources(project: project)
        #expect(members == ["Models/WidgetShared.swift"])
    }
}
#endif
