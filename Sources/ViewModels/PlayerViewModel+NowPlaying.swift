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

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.skipFromLockscreen(by: self.skipInterval)
            }
            return .success
        }
        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
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
        if let chapter = currentChapter {
            info[MPMediaItemPropertyTitle] = chapter.title
            info[MPMediaItemPropertyAlbumTitle] = bookTitle
        } else {
            info[MPMediaItemPropertyTitle] = bookTitle
        }
        info[MPMediaItemPropertyArtist] = item?.media.metadata?.authorName ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(playbackRate) : 0
        if let artworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
        if let cached = ImageCache.shared.image(for: url) {
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
