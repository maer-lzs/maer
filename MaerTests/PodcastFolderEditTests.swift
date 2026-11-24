// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Foundation
import Testing
@testable import Maer

/// A folder is edited in the sheet it was made in: its name and its shows,
/// chosen and unchosen among the subscriptions. Saving changes that folder
/// and makes no second one. The sheet's confirming button stands where iOS
/// puts it, so it reads as a button and not as a line of the form; the
/// footer of the folds says what the switch does in plain words.
@MainActor
@Suite(.serialized)
struct PodcastFolderEditTests {
    private static func freshStore() -> MaerPlaylists {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-edit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MaerPlaylists(database: MaerDatabase(path: directory.appendingPathComponent("maer.sqlite").path))
    }

    private static func folders(_ store: MaerPlaylists) -> [MaerPlaylists.Playlist] {
        store.playlists.filter { PodcastFolder.isFolder($0.itemIds) }
    }

    @Test("an edit: the chosen shows join in the order of the subscriptions, an unchosen one leaves, a show that is no subscription stays")
    func theRule() {
        let edit = PodcastFolder.edit(["show:a", "show:b", "show:gone"], candidates: ["a", "b", "c", "d"], chosen: ["a", "d", "c"])
        #expect(edit.join == ["c", "d"])
        #expect(edit.leave == ["b"])
        #expect(PodcastFolder.remaining(["show:a", "show:b", "show:gone"], after: edit) == 4)
        let none = PodcastFolder.edit(["show:a"], candidates: ["a", "b"], chosen: ["a"])
        #expect(none.join.isEmpty && none.leave.isEmpty, "nothing chosen differently changes nothing")
        let all = PodcastFolder.edit(["show:a"], candidates: ["a"], chosen: [])
        #expect(PodcastFolder.remaining(["show:a"], after: all) == 0, "the last show unchosen leaves nothing to save")
    }

    @Test("saving an edit adds and removes shows and renames that folder; no second folder")
    func saveChangesTheFolder() {
        let store = Self.freshStore()
        let folder = store.createFolder(name: "Morgens", show: "a")
        store.file(show: "b", into: folder.id)
        store.editFolder(id: folder.id, name: "  Abends ", join: ["c"], leave: ["a"])
        #expect(Self.folders(store).count == 1, "the edit made a second folder")
        let edited = store.playlist(id: folder.id)
        #expect(edited?.itemIds == ["show:b", "show:c"])
        #expect(edited?.name == "Abends")
    }

    @Test("an edit that leaves the name keeps it and its clock; the folder is never empty on the way")
    func nameStays() {
        let store = Self.freshStore()
        let folder = store.createFolder(name: "Morgens", show: "a")
        let clock = store.playlist(id: folder.id)?.nameUpdatedAt
        store.editFolder(id: folder.id, name: "Morgens", join: ["b"], leave: ["a"])
        #expect(store.playlist(id: folder.id)?.name == "Morgens")
        #expect(store.playlist(id: folder.id)?.nameUpdatedAt == clock, "an unchanged name took a new clock")
        #expect(store.playlist(id: folder.id)?.itemIds == ["show:b"], "the folder went while its only show was swapped")
        #expect(Self.folders(store).count == 1)
    }

    @Test("Fence: the folder page's menu edits the folder in the sheet it was made in; Create and Save stand as the confirming button of the sheet", .needsTheSources)
    func surfaces() throws {
        func source(_ path: String) throws -> String {
            SyncContractFenceTests.stripped(
                try String(contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
        }
        let page = try source("Sources/Views/Podcasts/PodcastFolderViews.swift")
        #expect(page.contains("Label(\"Edit Folder\", systemImage: \"pencil\")"), "the folder's menu has no Edit Folder")
        #expect(page.contains("AddShowToFolderSheet(show: nil, editing: folder)"), "Edit Folder does not open the sheet of the making")
        #expect(!page.contains(".alert(\"Rename\""), "a second way to rename stands beside the edit")
        let sheet = try source("Sources/Views/Podcasts/AddShowToFolderSheet.swift")
        #expect(sheet.contains("ToolbarItem(placement: .confirmationAction)"), "Create is no confirming button of the sheet")
        #expect(sheet.contains("store.editFolder(id: folder.id"), "saving does not change the folder")
        #expect(sheet.contains("PodcastFolder.edit(folder.itemIds"), "the sheet decides by itself what an edit changes")
        let form = sheet.components(separatedBy: "Form {").dropFirst().first?.components(separatedBy: ".toolbar").first ?? ""
        #expect(!form.isEmpty)
        #expect(!form.contains("Button(\"Create\")"), "Create stands in the form like its name field")
    }

    @Test("Fence: the footer of the folds says it in plain words, in English, German and French", .needsTheSources)
    func footer() throws {
        let fold = SyncContractFenceTests.stripped(try String(contentsOf: SourceTree.root
            .appendingPathComponent("Sources/Views/Podcasts/PodcastSubscriptionFoldSection.swift"), encoding: .utf8))
        let premium = "If switched on, premium shows will be displayed with your other subscriptions and count alongside them. Their own row will no longer be shown."
        let pinchflat = "If switched on, Pinchflat shows will be displayed with your other subscriptions and count alongside them. Their own row will no longer be shown."
        #expect(fold.contains(premium))
        #expect(fold.contains(pinchflat))
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let strings = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any])
        for key in [premium, pinchflat] {
            let entry = strings[key] as? [String: Any]
            let languages = entry?["localizations"] as? [String: Any] ?? [:]
            for language in ["de", "fr"] {
                let unit = (languages[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                #expect(unit?["state"] as? String == "translated", "\(language): \(key)")
                #expect(!((unit?["value"] as? String) ?? "").isEmpty, "\(language): \(key)")
            }
        }
    }
}
#endif
