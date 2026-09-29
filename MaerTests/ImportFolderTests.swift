// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Picking a target library for a LibriVox import once did nothing at all
/// when its folder could not be read: the view fetched it itself, swallowed
/// the failure and returned. The folder is now answered by one pure rule
/// with three outcomes, and the importer turns the two empty ones into its
/// visible failed state.
struct ImportFolderTests {
    struct LookupFailed: Error {}

    @Test("ein gelisteter Ordner gilt, ohne nachzufragen")
    func aListedFolderWinsWithoutAsking() async {
        var asked = false
        let answer = await ImportFolder.resolve(listed: [ABSFolder(id: "fo_1", fullPath: nil)]) {
            asked = true
            return []
        }
        #expect(answer == .folder("fo_1"))
        #expect(!asked, "die Liste trug den Ordner, also wird nicht nachgefragt")
    }

    @Test("ohne gelisteten Ordner wird nachgefragt")
    func withoutAListedFolderItAsks() async {
        #expect(await ImportFolder.resolve(listed: nil) { [ABSFolder(id: "fo_2", fullPath: nil)] } == .folder("fo_2"))
        #expect(await ImportFolder.resolve(listed: []) { [ABSFolder(id: "fo_3", fullPath: nil)] } == .folder("fo_3"))
    }

    @Test("eine Bibliothek ohne Ordner und eine unerreichbare sind zwei Antworten, nicht nichts")
    func noFolderAndUnreachableAreTwoAnswers() async {
        #expect(await ImportFolder.resolve(listed: nil) { [] } == .none)
        #expect(await ImportFolder.resolve(listed: nil) { throw LookupFailed() } == .unreachable)
    }

    /// A view asks no network question of the server client. Reading its
    /// address is a fact; calling a method on it is a fetch.
    @Test("keine Ansicht ruft eine Methode des Server-Clients", .needsTheSources)
    func noViewCallsTheServerClient() throws {
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(files.count > 100, "der Zeuge hat den Ansichtsbaum nicht gelesen")
        var callers: [String] = []
        for file in files where Self.clientCalls(in: try String(contentsOf: file, encoding: .utf8)) > 0 {
            callers.append(file.lastPathComponent)
        }
        #expect(callers.isEmpty, "eine Ansicht ruft den Server-Client: \(callers)")
    }

    /// Calls on `apiClient`, whitespace around the dot closed, comments
    /// dropped, also at the end of a line.
    nonisolated static func clientCalls(in text: String) -> Int {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(IdQuestionDoorFenceTests.withoutComment)
            .joined(separator: "\n")
            .replacing(#/\s*\.\s*/#, with: ".")
        return code.matches(of: #/apiClient\.\w+\s*\(/#).count
    }

    /// The server address is one fact with one name (`serverAddress` on
    /// the sign-in model); no view reads it off the client itself.
    @Test("keine Ansicht liest die Server-Adresse am Client vorbei", .needsTheSources)
    func noViewReadsTheAddressOffTheClient() throws {
        let files = ProjectFileIntegrityTests.sourceFiles().filter { $0.path.contains("/Sources/Views/") }
        try #require(files.count > 100, "der Zeuge hat den Ansichtsbaum nicht gelesen")
        var readers: [String] = []
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(IdQuestionDoorFenceTests.withoutComment)
                .joined(separator: "\n")
                .replacing(#/\s*\.\s*/#, with: ".")
            if code.contains("apiClient.baseURL") { readers.append(file.lastPathComponent) }
        }
        #expect(readers.isEmpty, "eine Ansicht liest die Adresse am Client: \(readers)")
    }

    @Test("der Zaehler sieht den Ruf auch ueber einen Umbruch, nicht die Adresse")
    func theCounterSeesTheCallNotTheAddress() {
        #expect(Self.clientCalls(in: "(try? await AppSession.shared.apiClient\n    .fetchLibraryFolders(libraryId: id))") == 1)
        #expect(Self.clientCalls(in: "Text(AppSession.shared.apiClient.baseURL.absoluteString)") == 0)
        #expect(Self.clientCalls(in: "// apiClient.fetch(x)") == 0)
    }
}
#endif
