// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import UIKit

/// Leaves the covers a widget's snapshot names in its store
/// (`WidgetCoverStore`): the thumbnails written where missing, then the
/// files the snapshot on disk no longer names removed. One writer for every
/// widget with covers.
enum WidgetCoverWriter {
    /// Says whether a thumbnail was written, so the widget reloads once
    /// more. `named` is asked at the end, so an earlier pass never removes
    /// the covers of a later snapshot.
    static func write(_ covered: [(id: String, name: String)], into store: WidgetCoverStore,
                      named: () -> Set<String>) async -> Bool {
        guard let folder = AppGroup.containerURL else { return false }
        var wrote = false
        for entry in covered {
            guard let target = store.url(named: entry.name),
                  !FileManager.default.fileExists(atPath: target.path),
                  let url = ItemRouter.live.coverURL(entry.id),
                  let image = await Artwork.thumbnail(for: url),
                  let data = PlayerViewModel.downscaled(image, maxPixel: store.pixel).pngData()
            else { continue }
            wrote = store.write(data, named: entry.name) || wrote
        }
        // bearable, because an unread folder only leaves old thumbnails for the next pass
        let present = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in store.stale(in: present, keeping: named()) {
            guard let url = store.url(named: name) else { continue }
            // bearable, because a thumbnail left behind is removed on the next pass
            try? FileManager.default.removeItem(at: url)
        }
        return wrote
    }
}
