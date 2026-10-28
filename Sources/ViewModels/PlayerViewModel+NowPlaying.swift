// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import Combine
import AVFoundation
import MediaPlayer
import OSLog
import UIKit

/// Lockscreen/Dynamic Island: RemoteCommands, NowPlaying-Info, Artwork.
extension PlayerViewModel {

    // MARK: - Shared now-playing title/subtitle (one source, three surfaces)

    /// True for a music item: its playing "work" is the song, not the album,
    /// and the line under the title is the artist. Music by form, the ONE
    /// question the player's tools ask (`MediaFamily.isMusicByForm`): the
    /// music family and a catalogue song or album, never a reading. The
    /// form comes from the one place, `playingForm`.
    var isMusicItem: Bool { item.map { MediaFamily.isMusicByForm($0.id, markedForm: playingForm) } == true }

    /// The form of the playing title, the ONE place the player's form
    /// questions read (music or not, skip habit, remote commands): the
    /// mark its start noted, else the form its source gives while the
    /// title is loaded (a catalogue album started by shuffle, before the
    /// mark is written). Never guessed: nil when neither says.
    var playingForm: ProgressMark.StartedForm? { item.flatMap { startedForm(of: $0.id) } }

    func startedForm(of id: String) -> ProgressMark.StartedForm? {
        ListeningStore.startedForm(id) ?? (provider as? FreeCatalogProvider)?.startedForm(itemId: id)
    }

    /// Live radio (`radio:`). No duration, no seek, elapsed only; the
    /// player switches to its live abstraction and Now Playing flags the
    /// stream as live.
    var isLiveStream: Bool { item.map { ItemNamespace.isRadio($0.id) } == true }

    /// ICY "Artist - Title" parsed from the in-stream metadata (nil while
    /// the stream sent nothing yet).
    var icyNowPlaying: (title: String, artist: String?)? {
        icyStreamTitle.flatMap { ICYMetadata.parse(streamTitle: $0) }
    }

    /// The station name (radio items). The in-app player shows it as the big
    /// title, with `icyDisplayLine` underneath (the lock screen stays song-first
    /// per Apple's convention, see `nowPlayingTitle`).
    var stationName: String {
        (item?.media.metadata?.title).map(RadioMapping.displayName) ?? String(localized: "Radio")
    }

    /// The current ICY song as one line ("Artist — Title", or just the title).
    /// Nil when the stream has sent nothing.
    var icyDisplayLine: String? { Self.displayLine(fromStreamTitle: icyStreamTitle) }

    /// The SAME derivation, from the raw stream title. It exists because a
    /// `@Published` sink fires BEFORE the property is set: a mirror that read
    /// back `icyDisplayLine` from inside the sink would publish the previous
    /// song, forever one title behind. The mirror gets the incoming value and
    /// runs it through this one place instead of re-deriving its own.
    nonisolated static func displayLine(fromStreamTitle raw: String?) -> String? {
        guard let icy = raw.flatMap({ ICYMetadata.parse(streamTitle: $0) }) else { return nil }
        if let artist = icy.artist, !artist.isEmpty { return "\(artist) · \(icy.title)" }
        return icy.title
    }

    /// The large title = the work (book/episode title; the SONG title for
    /// music). One derivation for the full player, lock screen and CarPlay.
    /// Never empty.
    var nowPlayingTitle: String {
        // Live radio. The ICY song title when the stream ships one,
        // otherwise the station name.
        if isLiveStream {
            if let icy = icyNowPlaying { return icy.title }
            return stationName   // Trimmed everywhere (one derivation)
        }
        return NowPlayingPresentation.title(
            isMusic: isMusicItem,
            // A catalogue album names its songs in its chapters too; a
            // single track keeps the title of its entry.
            songTitle: currentMusicSong?.title ?? (chapters.count > 1 ? currentChapter?.title : nil),
            workTitle: item?.media.metadata?.title,
            fallback: String(localized: "Audiobook"))
    }

    /// Subtitle for the lock screen / CarPlay: for music the
    /// artist (the song is already the title); otherwise the REAL chapter +
    /// author (a fallback marker is never a chapter name → suppressed). The full
    /// player uses its own richer line (it also surfaces the fallback marker).
    var nowPlayingSubtitle: String? {
        // Live radio. Artist from ICY; with a song title showing, the
        // station name moves to the subtitle slot.
        if isLiveStream {
            if let icy = icyNowPlaying {
                return icy.artist ?? stationName
            }
            return nil
        }
        if isMusicItem { return musicArtist }
        return NowPlayingPresentation.subtitle(
            chapterTitle: currentChapter?.title, author: item?.media.metadata?.authorName,
            isFallback: chaptersAreFallback)
    }

    // MARK: - Lockscreen / Now Playing

    func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)

        // `@Sendable`: MediaPlayer invokes remote-command handlers on its own
        // (main, but not contractually guaranteed) thread. Making them nonisolated
        // avoids the Swift 6 runtime isolation trap if the system ever calls off
        // the main actor. Behaviour is unchanged since each body already hops via
        // `Task { @MainActor }` and touches `self` only inside it.
        commandCenter.playCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        commandCenter.skipForwardCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.noteRemoteCommand("skipForward")
                self.skipFromLockscreen(by: self.skipInterval)
            }
            return .success
        }
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        commandCenter.skipBackwardCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.noteRemoteCommand("skipBackward")
                self.skipFromLockscreen(by: -self.skipInterval)
            }
            return .success
        }

        // The TITLE buttons (headphone double/triple press sends next/previous
        // track). They were never registered, so the press evaporated. With
        // music there was no way to change songs from the pocket at all. Same
        // isolation contract as above: the system does not guarantee the
        // calling thread, the body hops explicitly.
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        // A press that can do nothing answers commandFailed, not success. A
        // silent success is how the queue gap stayed invisible. The answer
        // needs the main actor SYNCHRONOUSLY: hop when the system calls from
        // elsewhere, assume when it already is main (both legal; the blind
        // assumeIsolated alone would be the known trap).
        commandCenter.nextTrackCommand.addTarget { @Sendable [weak self] _ in
            Self.answeredOnMain { self?.handleTitleButton(forward: true) ?? false }
                ? .success : .commandFailed
        }
        commandCenter.previousTrackCommand.addTarget { @Sendable [weak self] _ in
            Self.answeredOnMain { self?.handleTitleButton(forward: false) ?? false }
                ? .success : .commandFailed
        }
    }

    private nonisolated static func answeredOnMain(_ body: @MainActor @Sendable () -> Bool) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        // queue because the remote command wants its answer synchronously; a blocking hop is the only bridge.
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    /// What a title button MEANS depends on what is playing, decided per
    /// press, so an item switch needs no re-registration:
    ///
    ///  * **Songs** (music, and catalogue songs by form). A real track
    ///    change. That is what the button says.
    ///  * **Books, podcasts, catalogue readings**. The configured skip, like
    ///    Audible: from the pocket a title press must never leap a chapter,
    ///    and the pocket-series detection of the lock-screen skip rides along.
    ///  * **Radio**. Nothing; the commands are disabled for live streams.
    /// Returns whether the press does anything. The command answer.
    func handleTitleButton(forward: Bool) -> Bool {
        noteRemoteCommand(forward ? "nextTrack" : "previousTrack")
        guard let id = item?.id else { return false }
        switch RemoteCommandRule.kind(forItem: id, markedForm: playingForm) {
        case .live:
            return false
        case .songs:
            return jumpToAdjacentTrack(forward: forward)
        case .spoken:
            skipFromLockscreen(by: forward ? skipInterval : -skipInterval)
            return true
        }
    }

    /// Which remote command arrived, for what: the measuring line that tells
    /// on the device which command a headphone press delivers.
    func noteRemoteCommand(_ name: String) {
        let family = item.map { MediaFamily.of($0.id).rawValue } ?? "-"
        Logger.player.notice("REMOTE command=\(name, privacy: .public) family=\(family, privacy: .public)")
    }

    func updateNowPlayingInfo() {
        // Live streams have nothing to skip into. Lock-screen/headset
        // skip gestures are DISABLED for radio (re-enabled on the next
        // regular item; this runs on every item switch). Position/rate
        // commands are never registered, and the live flag below removes the
        // lock-screen scrubber.
        let commandCenter = MPRemoteCommandCenter.shared()
        // Per item, from the one rule: music moves between songs and has no
        // skip-by-seconds, so a headphone double press is the next song and
        // the lock screen shows next and previous, as in the system's music
        // app; a live stream has neither.
        let enabled = RemoteCommandRule.enabled(for: RemoteCommandRule.kind(forItem: item?.id, markedForm: playingForm))
        commandCenter.skipForwardCommand.isEnabled = enabled.skip
        commandCenter.skipBackwardCommand.isEnabled = enabled.skip
        commandCenter.nextTrackCommand.isEnabled = enabled.track
        commandCenter.previousTrackCommand.isEnabled = enabled.track

        var info: [String: Any] = [:]
        // The TITLE is ALWAYS the work (book/episode; the song for
        // music), the subtitle is the real chapter + author. Shared derivation.
        // Identical on the full player, CarPlay (same info centre) and the Live
        // Activity.
        info[MPMediaItemPropertyTitle] = nowPlayingTitle
        info[MPMediaItemPropertyArtist] = nowPlayingSubtitle ?? ""
        if isLiveStream {
            // The system live treatment (no scrubber, "LIVE" pill on the
            // lock screen). Duration/elapsed stay out.
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0
        } else {
            // The span the full player's scrubber shows: the song for
            // music, the whole title otherwise.
            let span = playbackSpan
            info[MPMediaItemPropertyPlaybackDuration] = span.length
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = span.elapsed(absolute: currentTime)
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0
        }
        // The artwork is built once per image: the info is written again
        // on every event, the image changes only with the item or a cover.
        var builtArtwork = false
        if let artworkImage {
            let image = ObjectIdentifier(artworkImage)
            if nowPlayingArtwork?.image != image {
                artworkBuilds += 1
                builtArtwork = true
                nowPlayingArtwork = (image, MPMediaItemArtwork(
                    boundsSize: artworkImage.size,
                    requestHandler: Self.artworkRequestHandler(for: artworkImage)
                ))
            }
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork?.artwork
        }
        nowPlayingWrites += 1
        lastNowPlaying = NowPlayingRefresh.Written(fields: nowPlayingFields,
                                                   elapsed: playbackSpan.elapsed(absolute: currentTime),
                                                   at: Date().timeIntervalSince1970)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        PerfSignpost.nowPlaying(newArtwork: builtArtwork)
    }

    /// What the lock screen shows apart from the running time.
    var nowPlayingFields: NowPlayingRefresh.Fields {
        NowPlayingRefresh.Fields(title: nowPlayingTitle, subtitle: nowPlayingSubtitle ?? "",
                                 duration: playbackSpan.length,
                                 rate: isPlaying ? Double(isLiveStream ? 1 : playbackRate) : 0,
                                 isLive: isLiveStream, artwork: artworkImage.map(ObjectIdentifier.init))
    }

    /// From the tick: the lock screen is written only when something but the
    /// running time changed, or the time the system runs on drifted from the
    /// real one (`NowPlayingRefresh`).
    func refreshNowPlayingIfDue() {
        // A song inside a playlist brings its own cover.
        if !isLiveStream, artworkKey != loadedArtworkKey { loadNowPlayingArtwork() }
        guard NowPlayingRefresh.isDue(last: lastNowPlaying, fields: nowPlayingFields,
                                      elapsed: playbackSpan.elapsed(absolute: currentTime),
                                      at: Date().timeIntervalSince1970) else { return }
        updateNowPlayingInfo()
    }

    /// The lock screen's cover for what plays: the playing song's where it
    /// has its own (`songCoverURL`), else the entry's large cover
    /// (`AudioProvider.largeCoverURL`). A LibriVox book then shows the cover
    /// its page shows, the feed's (`LibriVoxCoverLoader.hiresCover`), once
    /// it is known; the session keeps it, so it is asked once per book.
    func loadNowPlayingArtwork() {
        loadedArtworkKey = artworkKey
        loadArtwork(coverURL: songCoverURL ?? item.flatMap { provider.largeCoverURL(forItemId: $0.id) })
        guard songCoverURL == nil, let id = item?.id, id.hasPrefix(FreeCatalog.librivoxPrefix) else { return }
        Task { [weak self] in
            guard let feed = await LibriVoxCoverLoader.hiresCover(forItemId: id),
                  let self, self.item?.id == id else { return }
            self.loadArtwork(coverURL: feed)
        }
    }

    /// Artwork request handler for `MPMediaItemArtwork`. MPNowPlayingInfoCenter
    /// invokes it on its PRIVATE accessQueue, NOT the main actor. So it must be
    /// nonisolated, otherwise the Swift 6 runtime isolation check traps
    /// (dispatch_assert_queue) on cold start. The `@Sendable` RETURN TYPE makes
    /// that a compile-time contract: MediaPlayer's `requestHandler` parameter is
    /// not `@Sendable`-typed, so an inline main-actor closure would compile yet
    /// crash. Routing through this typed factory prevents that regression.
    /// UIImage is Sendable, so capturing the finished image is safe.
    nonisolated static func artworkRequestHandler(for image: UIImage) -> @Sendable (CGSize) -> UIImage {
        { _ in image }
    }

    func loadArtwork(coverURL: URL?) {
        // Radio favicons pass the same quality gate as the
        // in-app tiles; missing/broken/tiny → the SAME deterministic
        // gradient+initials placeholder. One design through to the lock
        // screen and CarPlay.
        if isLiveStream {
            let stationID = item?.id ?? ""
            let name = item?.media.metadata?.title ?? ""
            Task { [weak self] in
                let favicon = await RadioArtwork.gatedImage(for: coverURL, stationID: stationID)
                let image = favicon ?? RadioArtwork.placeholderImage(stationID: stationID, name: name)
                await MainActor.run {
                    guard let self, self.isLiveStream else { return }
                    self.artworkImage = image
                    self.stationArtwork = image
                    self.updateNowPlayingInfo()
                }
            }
            return
        }
        guard let coverURL else { return }
        let key = loadedArtworkKey
        Task { [weak self] in
            guard let image = await Self.loadImage(for: coverURL) else { return }
            await MainActor.run {
                // A cover that arrives after the next song asked for its own
                // stays off the lock screen.
                guard self?.loadedArtworkKey == key else { return }
                self?.artworkImage = image
                self?.updateNowPlayingInfo()
                // Write the RELIABLY-loaded cover to the shared app-group
                // file the home widget reads, then refresh it. The old path wrote
                // only from ImageCache.thumbnail, which is typically still empty
                // right after an item change (auto-continue). So the widget
                // showed the new title next to the stale cover. Loading here
                // already retries, so this is dependable.
                self?.refreshSharedCover(from: image)
            }
        }
    }

    /// Teil 2: best-effort now-playing cover for live radio. On an ICY song with
    /// both artist and title, look the cover up (MusicBrainz → Cover Art Archive)
    /// and, if found and still current, show it on the lock screen / in-app
    /// player. Reverts to the station logo first, so a previous song's cover
    /// never lingers, and on a miss the station logo simply stays.
    func refreshICYArtwork() {
        guard isLiveStream else { return }
        let icy = icyNowPlaying
        guard let artist = icy?.artist, let title = icy?.title,
              RadioArtworkLookup.shouldLookup(artist: artist, title: title) else {
            revertToStationLogo()
            return
        }
        // Revert to the station logo while the async lookup runs, so a previous
        // song's cover never lingers on a new song.
        revertToStationLogo()
        let itemID = item?.id
        let songToken = icyStreamTitle
        Task { [weak self] in
            let image = await RadioArtworkService.shared.artwork(artist: artist, title: title)
            await MainActor.run {
                guard let self, let image,
                      self.item?.id == itemID, self.icyStreamTitle == songToken else { return }
                self.icySongArtwork = image           // in-app player cover
                self.artworkImage = image             // lock screen cover
                self.updateNowPlayingInfo()
                self.refreshSharedCover(from: image)
            }
        }
    }

    /// Teil 2: drop any resolved song cover and show the station logo again.
    private func revertToStationLogo() {
        icySongArtwork = nil
        if let logo = stationArtwork, artworkImage !== logo {
            artworkImage = logo
            updateNowPlayingInfo()
        }
    }

    /// Loads the cover for the lock screen / Dynamic Island. Uses the same
    /// shared cache as the library and retries once automatically on failure.
    private static func loadImage(for url: URL) async -> UIImage? {
        // The one door: the same cache and cover lane the player's cover
        // views use, with the door's own second attempt after a pause.
        await Artwork.image(for: url)?.image
    }
}
