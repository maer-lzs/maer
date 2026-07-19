#if canImport(Testing)
import Testing
import Combine
import Foundation
@testable import ABSPlayer

/// Y35/Y36: the music sync core — a successful run records exactly one
/// `.music` history entry (correct counters) and fires the `librarySynced`
/// signal (the live Music tab reloads on it); a failed run records an error
/// entry and stays silent.
@MainActor
struct SubsonicSyncTests {
    private final class MockHistoryStore: SyncHistoryStoring {
        var entries: [SyncHistoryEntry] = []
        var lastChecked: [String: Date] = [:]
        func append(_ entry: SyncHistoryEntry) { entries.append(entry) }
        func noteChecked(_ service: SyncHistoryEntry.Service, at date: Date) {
            lastChecked[service.rawValue] = date
        }
    }

    private func album(id: String, songs: Int) -> SubsonicAlbum {
        SubsonicAlbum(id: id, name: "Album \(id)", artist: "Artist", artistId: nil,
                      coverArt: nil, songCount: songs, duration: nil, year: nil,
                      genre: nil, created: nil, musicBrainzId: nil, song: nil)
    }

    @Test("success: one .music entry with album/song counters, signal fired")
    func successRecordsAndSignals() async {
        let provider = SubsonicProvider.shared
        let mock = MockHistoryStore()
        provider.historyStore = mock
        defer { provider.historyStore = SyncHistoryStore.shared }
        var signals = 0
        let sub = provider.librarySynced.sink { signals += 1 }
        defer { sub.cancel() }

        let result = await provider.runLibrarySync {
            [self.album(id: "a1", songs: 10), self.album(id: "a2", songs: 5)]
        }

        #expect(result == nil)
        #expect(signals == 1)
        #expect(mock.entries.count == 1)
        let entry = mock.entries.first
        #expect(entry?.service == .music)
        #expect(entry?.error == nil)
        #expect(entry?.counters.first { $0.key == .albumsUpdated }?.value == 2)
        #expect(entry?.counters.first { $0.key == .songsUpdated }?.value == 15)
    }

    @Test("Y37 trap: isAvailable dispatches through `any AudioProvider`")
    func availabilityDispatchesDynamically() {
        let stored = AppStorageKeys.subsonicEnabledValue
        defer { AppStorageKeys.subsonicEnabledValue = stored }
        // With the source switched OFF the concrete implementation says false.
        // Before isAvailable was a protocol REQUIREMENT, the existential bound
        // statically to the extension default (true) — this test pinned it.
        AppStorageKeys.subsonicEnabledValue = false
        let provider: any AudioProvider = SubsonicProvider.shared
        #expect(provider.isAvailable == false)
    }

    @Test("failure: error entry recorded, no signal")
    func failureRecordsErrorSilently() async {
        let provider = SubsonicProvider.shared
        let mock = MockHistoryStore()
        provider.historyStore = mock
        defer { provider.historyStore = SyncHistoryStore.shared }
        var signals = 0
        let sub = provider.librarySynced.sink { signals += 1 }
        defer { sub.cancel() }

        let result = await provider.runLibrarySync {
            throw URLError(.notConnectedToInternet)
        }

        #expect(result != nil)
        #expect(signals == 0)
        #expect(mock.entries.count == 1)
        #expect(mock.entries.first?.service == .music)
        #expect(mock.entries.first?.error != nil)
        #expect(mock.entries.first?.counters.isEmpty == true)
    }
}
#endif
