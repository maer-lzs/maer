import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit

/// Lockscreen/Dynamic Island: RemoteCommands, NowPlaying-Info, Artwork.
extension PlayerViewModel {

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
        let bookTitle = item?.media.metadata?.title ?? String(localized: "Audiobook")
        // Chapter as title, book as album — so the lock screen shows both.
        // T9b: a FALLBACK marker ("Track N" / "Rest from X") is not a real
        // chapter title — show the book/episode title as the title instead and
        // demote the marker to the album line.
        if let chapter = currentChapter, !chaptersAreFallback {
            info[MPMediaItemPropertyTitle] = chapter.title
            info[MPMediaItemPropertyAlbumTitle] = bookTitle
        } else if let chapter = currentChapter {
            info[MPMediaItemPropertyTitle] = bookTitle
            info[MPMediaItemPropertyAlbumTitle] = chapter.title
        } else {
            info[MPMediaItemPropertyTitle] = bookTitle
        }
        info[MPMediaItemPropertyArtist] = item?.media.metadata?.authorName ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0
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
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return nil }
        return (image, data)
    }
}
