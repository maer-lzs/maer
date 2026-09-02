// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import ImageIO
import CryptoKit

/// Header-level questions about image bytes. Lives beside the image
/// chain, not in the catalogue core: the core is Foundation-only so it
/// builds on a plain Linux toolchain, and ImageIO and CryptoKit are
/// Apple frameworks.
nonisolated enum ImageProbe {
    /// Pixel size from the header alone, without decoding the bitmap.
    /// nil for anything that is not an image (HTML, JSON, an empty body).
    static func pixels(in data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    /// Colour model from the header, as ImageIO names it.
    static func colorModel(in data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return props[kCGImagePropertyColorModel] as? String
    }
}

/// The archive.org item image service answers SOMETHING for every
/// identifier: an item without artwork gets the archive's own pillar
/// logo, an audio item sometimes a derived waveform strip. Both are
/// answers of the service, not pictures of the work, and a tile showing
/// them claims artwork that does not exist; the app's own placeholder is
/// the honest form. Measured: the pillar is ONE byte-identical PNG
/// (160x110, 2212 bytes) across every artless item, the waveform a
/// single-channel strip several times wider than tall. A changed pillar
/// file upstream fails OPEN (it gets shown), never closed.
nonisolated enum ArchiveServicePlaceholder {
    static func isPlaceholder(data: Data, url: URL) -> Bool {
        guard url.host()?.hasSuffix("archive.org") == true,
              url.path().hasPrefix("/services/img/") else { return false }
        return isPlaceholderBody(data)
    }

    /// The body judgement alone, for the one caller that has no URL any
    /// more: the cache-maintenance sweep over files this service wrote
    /// BEFORE the fetch gate existed (scoped there by file name).
    static func isPlaceholderBody(_ data: Data) -> Bool {
        // Size gate first, so not every arriving cover pays a hash.
        if data.count == pillarBytes,
           SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == pillarSHA256 {
            return true
        }
        guard let pixels = ImageProbe.pixels(in: data), pixels.height > 0 else { return false }
        return ImageProbe.colorModel(in: data) == (kCGImagePropertyColorModelGray as String)
            && pixels.width >= pixels.height * 3
    }

    /// The pillar fallback file, measured at the service.
    private static let pillarBytes = 2212
    private static let pillarSHA256 =
        "b5ef1d4bff2d0f057b6b8239c03c08bfe44206c7f5ae92fe05864f22ad3eb7b9"
}

extension RadioLogoLookup {
    /// The booking probe of the logo chain: a body counts as a logo only
    /// when it decodes as an image AND clears the touch-icon floor, the
    /// same gate the display applies afterwards. A 2xx answer alone proved
    /// nothing; an error page with status 200 became a stored "logo", the
    /// display refused it, the store dropped it, and the chain booked the
    /// same address again, a loop with no exit. Probed once at booking
    /// time, the loop never starts. Here and not in the lookup itself,
    /// because the lookup is core and the probe needs ImageIO.
    nonisolated static func usableLogo(_ data: Data) -> Bool {
        guard let pixels = ImageProbe.pixels(in: data) else { return false }
        return RadioFaviconGate.acceptableTouchIcon(pixelWidth: pixels.width,
                                                    pixelHeight: pixels.height)
    }
}
