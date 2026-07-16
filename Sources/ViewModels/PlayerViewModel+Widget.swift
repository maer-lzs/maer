import Foundation
import UIKit
import WidgetKit

/// Feeds the home-screen "Continue" widget: writes a snapshot (JSON) + cover
/// thumbnail into the App Group container and triggers a widget reload.
/// Throttled — widget reloads have a system budget.
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
            Task { @MainActor [weak self] in
                guard let coverURL,
                      let thumb = await ImageCache.shared.thumbnail(for: coverURL),
                      let data = thumb.pngData(),
                      let target = WidgetSnapshot.coverURL else { return }
                try? data.write(to: target, options: .atomic)
                WidgetCenter.shared.reloadTimelines(ofKind: "ContinueListeningWidget")
                // V8: the Live Activity reads the SAME shared cover file. The
                // fetch+write above is async, so on an item change the activity
                // had already re-rendered the NEW title next to the OLD cover.
                // Refresh it now that the new cover is on disk.
                self?.updateLiveActivity()
            }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueListeningWidget")
    }

    /// V8 (testable): the shared cover file must be rewritten exactly when the
    /// item changes (incl. the first item) — never for the same item.
    static func coverNeedsRewrite(previous: String?, current: String) -> Bool {
        previous != current
    }

    /// Uses the existing catalog keys ("%lld hr %lld min left").
    private static func widgetRemainingText(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 { return String(localized: "\(hours) hr \(minutes) min left") }
        return String(localized: "\(minutes) min left")
    }
}
