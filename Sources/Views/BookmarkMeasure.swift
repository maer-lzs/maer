// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if DEBUG
import SwiftUI
import Combine
import AVFoundation
import OSLog
import UniformTypeIdentifiers

/// The measuring instrument for linked folders: does a folder
/// bookmark survive a restart, an update, a device restart, per place; does
/// the access hold a background playback for an hour; what happens when the
/// place is gone. DEBUG ONLY, the whole file: a Release build has none of
/// it, and no product code may name it (`DebugOnlySeedFenceTests`).
///
/// A debug build installed from Xcode updates another way than a TestFlight
/// update does. The update measured here is the Xcode way; the linked-folder
/// code writes the same resolution line in every build, so the first
/// TestFlight update measures the real one.
enum BookmarkMeasure {
    /// Starting and stopping the security-scoped access, a seam so the
    /// cleanup witness can see that nothing stays held.
    protocol Access {
        func start(_ url: URL) -> Bool
        func stop(_ url: URL)
    }

    struct ScopedAccess: Access {
        func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
        func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
    }

    /// The one bookmark under measurement, its place, and the access the
    /// playback probe holds.
    /// No singleton: the page holds its store, the launch resolves with a
    /// fresh one (the bookmark lives in the defaults). The playback probe
    /// therefore runs while the page is open, screen locked.
    @MainActor
    final class Store: ObservableObject {
        static let bookmarkKey = "e1mess.bookmark"
        static let placeKey = "e1mess.place"

        private let defaults: UserDefaults
        private let access: any Access
        /// The folder whose access the playback probe holds; nil when none.
        private(set) var heldFolder: URL?
        private var player: AVAudioPlayer?
        private var ticker: Timer?
        private var minute = 0
        @Published private(set) var lastLine: String?

        init(defaults: UserDefaults = .standard, access: any Access = ScopedAccess()) {
            self.defaults = defaults
            self.access = access
        }

        var hasBookmark: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }
        var place: E1MeasureLine.Place {
            E1MeasureLine.Place(rawValue: defaults.string(forKey: Self.placeKey) ?? "") ?? .intern
        }

        /// Keeps a bookmark of the chosen folder, for the chosen place.
        func keep(folder: URL, place: E1MeasureLine.Place) {
            let started = access.start(folder)
            defer { if started { access.stop(folder) } }
            do {
                let data = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                defaults.set(data, forKey: Self.bookmarkKey)
                defaults.set(place.rawValue, forKey: Self.placeKey)
                let counted = Self.counted(in: folder)
                log(E1MeasureLine.resolution(place: place, resolved: true, stale: false, renewed: false,
                                             access: started, files: counted.files, notLoaded: counted.notLoaded,
                                             reason: counted.reason))
            } catch {
                log(E1MeasureLine.resolution(place: place, resolved: false, stale: false, renewed: false,
                                             access: started, files: nil, notLoaded: nil, reason: FailureReason.of(error)))
            }
        }

        /// Resolves the kept bookmark, renews it when stale, counts the
        /// audio files, and writes the line. Returns the folder when reached.
        @discardableResult
        func resolve() -> URL? {
            guard let data = defaults.data(forKey: Self.bookmarkKey) else { return nil }
            var stale = false
            let folder: URL
            do {
                folder = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                log(E1MeasureLine.resolution(place: place, resolved: false, stale: false, renewed: false,
                                             access: false, files: nil, notLoaded: nil, reason: FailureReason.of(error)))
                return nil
            }
            let started = access.start(folder)
            defer { if started { access.stop(folder) } }
            var renewed = false
            // A failed renewal shows in the line as stale without renewed.
            if stale, let fresh = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: Self.bookmarkKey)
                renewed = true
            }
            var counted: (files: Int?, notLoaded: Int?, reason: String?) = (nil, nil, "kein-zugriff")
            if started { counted = Self.counted(in: folder) }
            log(E1MeasureLine.resolution(place: place, resolved: true, stale: stale, renewed: renewed,
                                         access: started, files: counted.files, notLoaded: counted.notLoaded,
                                         reason: counted.reason))
            return folder
        }

        /// The playback probe: holds the access for the whole playback and
        /// writes one line a minute. Returns whether it holds the access,
        /// so the page shows the state that is, not the one asked for.
        @discardableResult
        func startPlayback() -> Bool {
            stopPlayback()
            guard let folder = resolve() else { return false }
            guard access.start(folder) else {
                log(E1MeasureLine.playback(minute: 0, playing: false, access: false, reason: "kein-zugriff"))
                return false
            }
            heldFolder = folder
            minute = 0
            // An unreadable folder already has its reason in the resolution
            // line `resolve()` just wrote. The first file is tried even when
            // it is not on the device: what the player does then is part of
            // the measurement.
            guard let first = (try? Self.audio(in: folder))?.first else {
                log(E1MeasureLine.playback(minute: 0, playing: false, access: true, reason: "keine-audiodatei"))
                return true
            }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                let started = try AVAudioPlayer(contentsOf: folder.appendingPathComponent(first.name))
                started.numberOfLoops = -1
                started.play()
                player = started
                log(E1MeasureLine.playback(minute: 0, playing: started.isPlaying, access: true))
            } catch {
                log(E1MeasureLine.playback(minute: 0, playing: false, access: true, reason: FailureReason.of(error)))
            }
            ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                // Unstructured on purpose: a Timer callback is no async
                // context; the hop only writes one log line on the main actor.
                Task { @MainActor in self?.tick() }
            }
            return true
        }

        private func tick() {
            minute += 1
            log(E1MeasureLine.playback(minute: minute, playing: player?.isPlaying == true, access: heldFolder != nil))
        }

        func stopPlayback() {
            ticker?.invalidate()
            ticker = nil
            player?.stop()
            player = nil
            if let heldFolder { access.stop(heldFolder) }
            heldFolder = nil
        }

        /// Cleanup is part of the measurement: no bookmark and no held
        /// access may stay behind.
        func clear() {
            stopPlayback()
            defaults.removeObject(forKey: Self.bookmarkKey)
            defaults.removeObject(forKey: Self.placeKey)
            log("E1MESS geloescht")
        }

        private func log(_ line: String) {
            lastLine = line
            Logger.library.notice("\(line, privacy: .public)")
        }

        /// The folder's audio with its download state. Hidden entries are
        /// read on purpose: an evicted iCloud file can be a hidden placeholder.
        nonisolated static func audio(in folder: URL) throws -> [E1MeasureLine.Audio] {
            let key = URLResourceKey.ubiquitousItemDownloadingStatusKey
            let all = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [key])
            return E1MeasureLine.audio(among: all.map { url in
                // A status that cannot be read is no iCloud file; the
                // placeholder name still marks an evicted one.
                let status = try? url.resourceValues(forKeys: [key]).ubiquitousItemDownloadingStatus
                return (name: url.lastPathComponent, notDownloaded: status == .notDownloaded)
            })
        }

        /// The count for the line and how much of it is not on the device,
        /// or the reason the folder could not be read: an unreadable or an
        /// evicted folder must not look like an empty one.
        nonisolated static func counted(in folder: URL) -> (files: Int?, notLoaded: Int?, reason: String?) {
            do {
                let audio = try audio(in: folder)
                return (audio.count, audio.filter { !$0.loaded }.count, nil)
            } catch {
                return (nil, nil, FailureReason.of(error))
            }
        }
    }

    /// Every launch resolves the kept bookmark once, so the restart, update
    /// and device-restart checks need no tap.
    @MainActor static func resolveOnLaunch() {
        let store = Store()
        guard store.hasBookmark else { return }
        store.resolve()
    }

    /// The page, reached from Diagnostics in debug builds only.
    struct Page: View {
        @StateObject private var store = Store()
        @State private var place: E1MeasureLine.Place = .intern
        @State private var choosing = false
        @State private var playing = false

        var body: some View {
            Form {
                Section {
                    Picker(selection: $place) {
                        ForEach(E1MeasureLine.Place.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                    } label: { Text(verbatim: "Ort") }
                    Button { choosing = true } label: { Text(verbatim: "Ordner waehlen") }
                    Button { store.resolve() } label: { Text(verbatim: "Aufloesen") }
                        .disabled(!store.hasBookmark)
                } footer: {
                    Text(verbatim: "Der Ort ist deine Angabe; die Logzeile traegt nie einen Pfad.")
                }
                Section {
                    Button {
                        if playing {
                            store.stopPlayback()
                            playing = false
                        } else {
                            playing = store.startPlayback()
                        }
                    } label: { Text(verbatim: playing ? "Wiedergabe-Probe beenden" : "Wiedergabe-Probe") }
                        .disabled(!store.hasBookmark)
                    Button(role: .destructive) {
                        store.clear()
                        playing = false
                    } label: { Text(verbatim: "Messung loeschen") }
                }
                if let line = store.lastLine {
                    Section { Text(verbatim: line).font(.caption.monospaced()) }
                }
            }
            .navigationTitle(Text(verbatim: "E1-Messung"))
            .onAppear { place = store.place }
            // Leaving the page ends the probe and lets go of the access.
            .onDisappear { store.stopPlayback(); playing = false }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                if case .success(let folder) = result { store.keep(folder: folder, place: place) }
            }
        }
    }
}
#endif
