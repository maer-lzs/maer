// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
@testable import Maer

/// Flaws found in 3.8: the offline search names each kind of a music
/// server, the gain gives way where the bands already lift the sound, and
/// an open with a jump lands where it was asked.
@MainActor
struct FlawsFromThreeEightTests {
    // MARK: The offline search of the music servers

    @Test("offline every kind of a music server is named as it is: song, playlist, album, artist, book; an unknown kind falls out")
    func theOfflineSearchNamesEachKind() {
        let table: [(String, SearchResult.Kind?)] = [
            ("sub:song:1", .song), ("sub:playlist:2", .playlist), ("sub:album:3", .album), ("sub:artist:4", .artist),
            ("jf:song:5", .song), ("jf:playlist:6", .playlist), ("jf:album:7", .album), ("jf:artist:8", .artist),
            ("jf:book:9", .book), ("sub:genre:10", nil), ("jf:books:11", nil), ("sub:", nil), ("lva:x", nil),
        ]
        for (id, kind) in table {
            #expect(SearchResult.offlineKind(of: id) == kind, "\(id)")
        }
    }

    @Test("Fence: both offline searches ask the one rule and drop what it does not name", .needsTheSources)
    func bothSearchesAskTheRule() throws {
        for path in ["Sources/Providers/SubsonicProvider.swift", "Sources/Providers/JellyfinProvider.swift"] {
            let code = SyncContractFenceTests.stripped(try String(
                contentsOf: SourceTree.root.appendingPathComponent(path), encoding: .utf8))
            let search = try #require(code.range(of: "private func offlineSearch(_ query: String) -> [SearchResult] {"))
            let body = code[search.upperBound...].prefix(700)
            #expect(body.contains("guard let kind = SearchResult.offlineKind(of: item.id) else { return nil }"), "\(path)")
            #expect(!body.contains(": .album"), "\(path) still calls every other kind an album")
        }
    }

    // MARK: The gain and the bands

    @Test("the lift of the bands and the gain stay under the ceiling together, for every preset, strength and gain")
    func theLiftHasACeiling() {
        for preset in SoundPresets.all {
            for strength in SoundSetting.strengths {
                for gain in [1.0, 1.5, 2.0] {
                    let setting = SoundSetting(presetID: preset.id, gain: gain, strength: strength)
                    let bands = max(0, setting.shapedPreset.bandGainsDB.max() ?? 0)
                    let lift = bands + 20 * log10(setting.playedGain)
                    #expect(lift <= SoundSetting.boostCeilingDB + 0.001, "\(preset.id) \(strength) \(gain): \(lift) dB")
                    #expect(setting.playedGain >= 1 && setting.playedGain <= setting.clampedGain)
                }
            }
        }
        // The measured case: spoken word at 4 with 200 % lifted the voice by about 16 dB.
        let spoken = SoundSetting(presetID: "speech", gain: 2, strength: 4)
        #expect(abs(spoken.playedGain - 1) < 0.001, "spoken word at 4 leaves no room for gain")
        // Without bands the gain stays whole.
        #expect(SoundSetting(presetID: "off", gain: 2).playedGain == 2)
    }

    @Test("Fence: the filter and the curve use the gain that is played", .needsTheSources)
    func theFilterUsesThePlayedGain() throws {
        let tap = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/SoundTap.swift"), encoding: .utf8))
        #expect(tap.contains("gain = Float(setting.playedGain)"))
        let curve = SyncContractFenceTests.stripped(try String(
            contentsOf: SourceTree.root.appendingPathComponent("Sources/Models/SoundCurve.swift"), encoding: .utf8))
        #expect(curve.contains("20 * log10(setting.playedGain)"))
    }

    // MARK: An open with a jump lands

    /// A source with one silent local track of 60 s.
    @MainActor
    final class OneTrackProvider: AudioProvider {
        let file: URL
        init(file: URL) { self.file = file }
        var providerId: String { "one-track" }
        var keepsMarksOnDevice: Bool { true }
        var capabilities: ProviderCapabilities { [] }
        var streamAuthHeaders: [String: String] { [:] }
        var isAvailable: Bool { true }
        var accessUnknown: Bool { false }
        func fetchLibraries() async throws -> [ABSLibrary] { [] }
        func fetchLibraryItems(libraryId: String) async throws -> [LibraryItem] { [] }
        func fetchItemDetail(itemId: String) async throws -> LibraryItemDetail {
            let track = ABSAudioTrack(index: 0, startOffset: 0, duration: 60, contentUrl: "one.wav", metadata: nil)
            let media = LibraryItemMedia(metadata: LibraryItemMetadata(title: "One", authorName: nil, narratorName: nil,
                                                                       seriesName: nil, genres: nil, publishedYear: nil,
                                                                       description: nil),
                                         duration: 60, chapters: nil, tracks: [track])
            return LibraryItemDetail(id: itemId, media: media, userMediaProgress: nil)
        }
        func coverURL(forItemId itemId: String) -> URL? { nil }
        func streamURL(forContentPath contentPath: String) -> URL? { file }
        func fetchAllProgress() async throws -> [String: BookProgress] { [:] }
        func updateProgress(itemId: String, currentTime: Double, duration: Double, isFinished: Bool) async throws {}
        func fetchBookmarks(itemId: String) async throws -> [ABSBookmark] { [] }
        func createBookmark(itemId: String, time: Double, title: String) async throws {}
        func deleteBookmark(itemId: String, time: Double) async throws {}
    }

    @Test("an open with a jump stands and the jump lands: a chapter of a title that does not run starts where it was asked")
    func theOpenStandsAndTheJumpLands() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("one-track-\(UUID().uuidString).wav")
        try SilentAudio.wav(seconds: 60).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let coordinator = PlayerCoordinator(provider: OneTrackProvider(file: file))
        let id = "open-lands-\(UUID().uuidString)"
        let title = LibraryItem(id: id, media: LibraryItemMedia(metadata: nil, duration: 60, chapters: nil, tracks: nil), addedAt: nil)
        await Reachability.$assumed.withValue(true) {
            await coordinator.open(item: title, thenSeekTo: 42)
        }
        defer { coordinator.viewModel?.stop() }
        #expect(coordinator.activeItem?.id == id, "the open does not stand")
        #expect(coordinator.viewModel?.item?.id == id)
        #expect(abs((coordinator.viewModel?.currentTime ?? -1) - 42) < 0.5,
                "the jump did not land: \(coordinator.viewModel?.currentTime ?? -1)")
    }
}
#endif
