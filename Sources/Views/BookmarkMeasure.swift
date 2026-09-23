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

/// The measuring instrument before E1b (linked folders): does a folder
/// bookmark survive a restart, an update, a device restart, per place; does
/// the access hold a background playback for an hour; what happens when the
/// place is gone. DEBUG ONLY, the whole file: a Release build has none of
/// it, and no product code may name it (`DebugOnlySeedFenceTests`).
///
/// A debug build installed from Xcode updates another way than a TestFlight
/// update does. What A3 measures here is the Xcode way; E1b writes the same
/// resolution line in every build so the first TestFlight update measures
/// the real one.
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
                log(E1MeasureLine.resolution(place: place, resolved: true, stale: false, renewed: false,
                                             access: started, files: Self.audioCount(in: folder), reason: nil))
            } catch {
                log(E1MeasureLine.resolution(place: place, resolved: false, stale: false, renewed: false,
                                             access: started, files: nil, reason: FailureReason.of(error)))
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
                                             access: false, files: nil, reason: FailureReason.of(error)))
                return nil
            }
            let started = access.start(folder)
            defer { if started { access.stop(folder) } }
            var renewed = false
            if stale, let fresh = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(fresh, forKey: Self.bookmarkKey)
                renewed = true
            }
            let files = started ? Self.audioCount(in: folder) : nil
            log(E1MeasureLine.resolution(place: place, resolved: true, stale: stale, renewed: renewed,
                                         access: started, files: files, reason: started ? nil : "kein-zugriff"))
            return folder
        }

        /// The playback probe: holds the access for the whole playback and
        /// writes one line a minute.
        func startPlayback() {
            stopPlayback()
            guard let folder = resolve(), access.start(folder) else { return }
            heldFolder = folder
            guard let file = Self.audioFiles(in: folder).first else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(contentsOf: file)
            player?.numberOfLoops = -1
            player?.play()
            minute = 0
            ticker = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                // Unstructured on purpose: a Timer callback is no async
                // context; the hop only writes one log line on the main actor.
                Task { @MainActor in self?.tick() }
            }
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

        nonisolated static func audioFiles(in folder: URL) -> [URL] {
            let kinds: Set<String> = ["mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "caf"]
            let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return all.filter { kinds.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        nonisolated static func audioCount(in folder: URL) -> Int { audioFiles(in: folder).count }
    }

    /// Every launch resolves the kept bookmark once, so A2 to A4 need no tap.
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
                        if playing { store.stopPlayback() } else { store.startPlayback() }
                        playing.toggle()
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
