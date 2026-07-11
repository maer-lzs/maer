import Foundation
import UIKit
import WidgetKit

/// Versorgt das Home-Screen-„Weiterhören"-Widget: Snapshot (JSON) + Cover-
/// Thumbnail in den App-Group-Container schreiben und ein Widget-Reload
/// anstoßen. Gedrosselt — Widget-Reloads haben ein Systembudget.
extension PlayerViewModel {
    private static var lastWidgetWriteAt: TimeInterval = 0
    private static var lastWidgetCoverItemId: String?

    /// - Parameter force: true bei Zustandswechseln (Play/Pause/Laden/Ende);
    ///   false beim periodischen Ticken (greift max. 1×/Minute).
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

        // Cover nur beim Buchwechsel kopieren (Thumbnail-Stufe reicht dem
        // Widget locker).
        if Self.lastWidgetCoverItemId != item.id {
            Self.lastWidgetCoverItemId = item.id
            let coverURL = provider.coverURL(forItemId: item.id)
            Task { @MainActor in
                guard let coverURL,
                      let thumb = await ImageCache.shared.thumbnail(for: coverURL),
                      let data = thumb.pngData(),
                      let target = WidgetSnapshot.coverURL else { return }
                try? data.write(to: target, options: .atomic)
                WidgetCenter.shared.reloadTimelines(ofKind: "ContinueListeningWidget")
            }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueListeningWidget")
    }

    /// Nutzt die bestehenden Katalog-Keys ("%lld hr %lld min left").
    private static func widgetRemainingText(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 { return String(localized: "\(hours) hr \(minutes) min left") }
        return String(localized: "\(minutes) min left")
    }
}
