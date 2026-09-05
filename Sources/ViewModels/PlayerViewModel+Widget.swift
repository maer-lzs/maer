// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import UIKit
import WidgetKit

/// Feeds the home-screen "Continue" widget: writes a snapshot (JSON) + cover
/// thumbnail into the App Group container and triggers a widget reload.
/// Throttled. Widget reloads have a system budget.
extension PlayerViewModel {
    private static var lastWidgetWriteAt: TimeInterval = 0
    private static var lastWidgetCoverItemId: String?

    /// - Parameter force: true on state changes (play/pause/load/end); false on
    ///   the periodic tick (applies at most 1×/minute).
    func updateWidgetSnapshot(force: Bool = false) {
        guard let item, duration > 0 else { return }
        let now = Date().timeIntervalSince1970
        guard force || now - Self.lastWidgetWriteAt >= 60 else { return }
        Self.lastWidgetWriteAt = now

        let remaining = max(duration - currentTime, 0)
        WidgetSnapshot(
            itemId: item.id,
            title: item.media.metadata?.title ?? "",
            author: item.media.metadata?.authorName,
            fraction: min(max(currentTime / duration, 0), 1),
            remainingText: Self.widgetRemainingText(remaining),
            isPlaying: isPlaying
        ).save()

        // Copy the cover only on a book change (the thumbnail tier is plenty for
        // the widget).
        if Self.coverNeedsRewrite(previous: Self.lastWidgetCoverItemId, current: item.id) {
            Self.lastWidgetCoverItemId = item.id
            let coverURL = provider.coverURL(forItemId: item.id)
            Task { @MainActor in
                guard let coverURL,
                      let thumb = await Artwork.thumbnail(for: coverURL),
                      let data = thumb.pngData(),
                      let target = WidgetSnapshot.coverURL else { return }
                try? data.write(to: target, options: .atomic)
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

    /// Write a small cover PNG (from the reliably-loaded lock-screen
    /// artwork) into the shared app-group file the home widget reads, then
    /// refresh it. Dependable across item changes, unlike the
    /// ImageCache-thumbnail path which is often empty right after a switch.
    func refreshSharedCover(from image: UIImage) {
        guard let target = WidgetSnapshot.coverURL else { return }
        Self.lastWidgetCoverItemId = item?.id
        let thumb = Self.downscaled(image, maxPixel: 300)
        guard let data = thumb.pngData() else { return }
        try? data.write(to: target, options: .atomic)
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

    /// Uses the existing catalog keys ("%lld hr %lld min left").
    private static func widgetRemainingText(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 { return String(localized: "\(hours) hr \(minutes) min left") }
        return String(localized: "\(minutes) min left")
    }
}
