import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit

/// Lockscreen/Dynamic Island: RemoteCommands, NowPlaying-Info, Artwork.
extension PlayerViewModel {

    // MARK: - Shared now-playing title/subtitle (Regel 2 — one source, three surfaces)

    /// True for a Subsonic music item (`sub:`) — its playing "work" is the song,
    /// not the album.
    var isMusicItem: Bool { item?.id.hasPrefix("sub:") == true }

    /// F2: live radio (`radio:`) — no duration, no seek, elapsed only; the
    /// player switches to its live abstraction and Now Playing flags the
    /// stream as live.
    var isLiveStream: Bool { item?.id.hasPrefix("radio:") == true }

    /// F2: ICY "Artist - Title" parsed from the in-stream metadata (nil while
    /// the stream sent nothing yet).
    var icyNowPlaying: (title: String, artist: String?)? {
        icyStreamTitle.flatMap { ICYMetadata.parse(streamTitle: $0) }
    }

    /// X14: the large title = the work (book/episode title; the SONG title for
    /// music). One derivation for the full player, lock screen and CarPlay —
    /// never empty.
    var nowPlayingTitle: String {
        // F2: live radio — the ICY song title when the stream ships one,
        // otherwise the station name.
        if isLiveStream {
            if let icy = icyNowPlaying { return icy.title }
            return item?.media.metadata?.title ?? String(localized: "Radio")
        }
        return NowPlayingPresentation.title(
            isMusic: isMusicItem,
            songTitle: currentMusicSong?.title,
            workTitle: item?.media.metadata?.title,
            fallback: String(localized: "Audiobook"))
    }

    /// Subtitle for the lock screen / CarPlay: for music the
    /// artist (the song is already the title); otherwise the REAL chapter +
    /// author (a fallback marker is never a chapter name → suppressed). The full
    /// player uses its own richer line (it also surfaces the fallback marker).
    var nowPlayingSubtitle: String? {
        // F2: live radio — artist from ICY; with a song title showing, the
        // station name moves to the subtitle slot.
        if isLiveStream {
            if let icy = icyNowPlaying {
                return icy.artist ?? item?.media.metadata?.title
            }
            return nil
        }
        let author = item?.media.metadata?.authorName
        if isMusicItem { return author }
        return NowPlayingPresentation.subtitle(
            chapterTitle: currentChapter?.title, author: author, isFallback: chaptersAreFallback)
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
        // the main actor — behaviour is unchanged since each body already hops via
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
                self.skipFromLockscreen(by: self.skipInterval)
            }
            return .success
        }
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        commandCenter.skipBackwardCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skipFromLockscreen(by: -self.skipInterval)
            }
            return .success
        }
    }

    func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        // T9c/X14: the TITLE is ALWAYS the work (book/episode; the song for
        // music), the subtitle is the real chapter + author. Shared derivation —
        // identical on the full player, CarPlay (same info centre) and the Live
        // Activity.
        info[MPMediaItemPropertyTitle] = nowPlayingTitle
        info[MPMediaItemPropertyArtist] = nowPlayingSubtitle ?? ""
        if isLiveStream {
            // F2: the system live treatment (no scrubber, "LIVE" pill on the
            // lock screen) — duration/elapsed stay out.
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0
        } else {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0
        }
        if let artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: artworkImage.size,
                requestHandler: Self.artworkRequestHandler(for: artworkImage)
            )
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Artwork request handler for `MPMediaItemArtwork`. MPNowPlayingInfoCenter
    /// invokes it on its PRIVATE accessQueue, NOT the main actor — so it must be
    /// nonisolated, otherwise the Swift 6 runtime isolation check traps
    /// (dispatch_assert_queue) on cold start. The `@Sendable` RETURN TYPE makes
    /// that a compile-time contract: MediaPlayer's `requestHandler` parameter is
    /// not `@Sendable`-typed, so an inline main-actor closure would compile yet
    /// crash — routing through this typed factory prevents that regression.
    /// UIImage is Sendable, so capturing the finished image is safe.
    nonisolated static func artworkRequestHandler(for image: UIImage) -> @Sendable (CGSize) -> UIImage {
        { _ in image }
    }

    func loadArtwork(coverURL: URL?) {
        guard let coverURL else { return }
        Task { [weak self] in
            guard let image = await Self.loadImage(for: coverURL) else { return }
            await MainActor.run {
                self?.artworkImage = image
                self?.updateNowPlayingInfo()
                // X9/V8: write the RELIABLY-loaded cover to the shared app-group
                // file the home widget reads, then refresh it. The old path wrote
                // only from ImageCache.thumbnail, which is typically still empty
                // right after an item change (auto-continue) — so the widget
                // showed the new title next to the stale cover. Loading here
                // already retries, so this is dependable.
                self?.refreshSharedCover(from: image)
            }
        }
    }

    /// Loads the cover for the lock screen / Dynamic Island — uses the same
    /// shared cache as the library and retries once automatically on failure.
    private static func loadImage(for url: URL) async -> UIImage? {
        if let cached = await ImageCache.shared.image(for: url) {
            return cached
        }
        if let (image, data) = await fetchImage(url) {
            ImageCache.shared.set(image, data: data, for: url)
            return image
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        if let (image, data) = await fetchImage(url) {
            ImageCache.shared.set(image, data: data, for: url)
            return image
        }
        return nil
    }

    private static func fetchImage(_ url: URL) async -> (UIImage, Data)? {
        // X9c: use the SAME session the player's cover views use
        // (URLSession.coverImage — no shared urlCache, ignores local cache).
        // `URLSession.shared` failed to fetch some Subsonic music covers, so the
        // app-group artwork file was never written and the widgets showed a
        // gray placeholder for music tracks.
        guard let (data, _) = try? await URLSession.coverImage.data(from: url),
              let image = UIImage(data: data) else { return nil }
        return (image, data)
    }
}
