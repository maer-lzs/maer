// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import UIKit
import WidgetKit

/// Feeds the home-screen "Continue" widget: writes a snapshot (JSON) + cover
/// thumbnail into the App Group container and triggers a widget reload, on
/// state changes only: widget reloads have a system budget, and while
/// playing the widget runs on by itself from the snapshot's steps.
extension PlayerViewModel {
    private static var lastWidgetCoverItemId: String?

    /// How far ahead the widget runs on by itself while playing.
    static let widgetMinutesAhead = 60

    /// Written on state changes (load, play, pause, jump, rate, end) and,
    /// while playing, once before the steps run out: the snapshot carries a
    /// step per minute for the next hour, and the widget shows them by
    /// itself (`WidgetSnapshot.steps`); the tick renews them after
    /// `widgetMinutesAhead` less the margin of `needsRenewal`.
    func updateWidgetSnapshot() {
        guard let item, duration > 0 else { return }
        let now = Date().timeIntervalSince1970
        widgetWrites += 1
        widgetPlayingSavedAt = isPlaying ? now : nil

        let remaining = max(duration - currentTime, 0)
        WidgetSnapshot(
            itemId: item.id,
            title: item.media.metadata?.title ?? "",
            author: item.media.metadata?.authorName,
            fraction: min(max(currentTime / duration, 0), 1),
            remainingText: Self.widgetRemainingText(remaining),
            isPlaying: isPlaying,
            steps: isPlaying
                ? WidgetSnapshot.steps(position: currentTime, duration: duration, rate: Double(playbackRate),
                                       minutes: Self.widgetMinutesAhead, remaining: Self.widgetRemainingText)
                : nil,
            savedAt: now
        ).save()

        // Copy the cover only on a book change (the thumbnail tier is plenty for
        // the widget).
        if Self.coverNeedsRewrite(previous: Self.lastWidgetCoverItemId, current: item.id) {
            let itemId = item.id
            let coverURL = provider.coverURL(forItemId: item.id)
            Task { @MainActor in
                var data: Data?
                if let coverURL, let thumb = await Artwork.thumbnail(for: coverURL) { data = thumb.pngData() }
                let written = Self.writeSharedCover(data)
                Self.lastWidgetCoverItemId = Self.coverMark(previous: Self.lastWidgetCoverItemId,
                                                            current: itemId, written: written)
                WidgetCenter.shared.reloadTimelines(ofKind: "ContinueListeningWidget")
            }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueListeningWidget")
    }

    /// The shared cover file must be rewritten exactly when the
    /// item changes (incl. the first item). Never for the same item.
    static func coverNeedsRewrite(previous: String?, current: String) -> Bool {
        previous != current
    }

    /// The item whose cover the shared file holds after a write attempt: the
    /// new one only when its picture was written, otherwise the mark stays,
    /// so the next update tries again.
    static func coverMark(previous: String?, current: String, written: Bool) -> String? {
        written ? current : previous
    }

    /// Writes the shared cover file, or removes it when there is no picture,
    /// so the widget never shows the previous title's cover under a new one.
    /// True when written.
    @discardableResult
    static func writeSharedCover(_ data: Data?) -> Bool {
        guard let target = WidgetSnapshot.coverURL else { return false }
        do {
            if let data {
                try data.write(to: target, options: .atomic)
                return true
            }
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
        } catch {
            Logger.library.error("WIDGET cover not written: \(FailureReason.of(error), privacy: .public)")
        }
        return false
    }

    /// Write a small cover PNG (from the reliably-loaded lock-screen
    /// artwork) into the shared app-group file the home widget reads, then
    /// refresh it. Dependable across item changes, unlike the
    /// ImageCache-thumbnail path which is often empty right after a switch.
    func refreshSharedCover(from image: UIImage) {
        let thumb = Self.downscaled(image, maxPixel: 300)
        let written = Self.writeSharedCover(thumb.pngData())
        if let itemId = item?.id {
            Self.lastWidgetCoverItemId = Self.coverMark(previous: Self.lastWidgetCoverItemId,
                                                        current: itemId, written: written)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueListeningWidget")
    }

    /// Aspect-preserving downscale so the shared cover PNG stays small.
    nonisolated static func downscaled(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > maxPixel, maxSide > 0 else { return image }
        let scale = maxPixel / maxSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// The one duration rule, as everywhere else.
    private static func widgetRemainingText(_ seconds: Double) -> String {
        DurationText.remaining(seconds: seconds)
    }
}
