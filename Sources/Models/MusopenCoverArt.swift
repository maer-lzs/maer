// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The drawn cover of a Musopen recording, which has no picture: a field
/// whose colours belong to the composer, with the composer and the work
/// on it (`MusopenCover`), drawn once behind its address (`DrawnCover`).
///
/// The colours follow Goethe's colour circle: every composer has for good
/// one of its three pairs of opposites, purple and green, yellow and
/// violet, orange and blue, and within the pair a lightness and a
/// saturation of his own. The diagonal runs from one to the other round
/// the colour circle in OKLCH, never through grey, and the text takes the
/// colour, white or dark, that stands out from what lies under it.
nonisolated enum MusopenCoverArt {
    /// Goethe's three pairs of opposites as OKLCH hues in degrees: purple
    /// and green, yellow and violet, orange and blue.
    static let goethePairs: [(first: Double, second: Double)] = [(350, 145), (100, 305), (55, 260)]

    static func applies(to itemId: String) -> Bool { itemId.hasPrefix(MusopenCatalog.prefix) }

    /// FNV-1a over the family name in lower case and in its composed form.
    /// The source names one composer as "Mozart", "Wolfgang Amadeus Mozart"
    /// or "Mozart, Wolfgang Amadeus"; the family name is the part before a
    /// comma, else the last word. A hash of its own, because the one of the
    /// standard library changes with every launch, and the colours must
    /// not. No name hashes to 0.
    static func familyHash(_ composer: String?) -> UInt32 {
        let name = familyName(composer).lowercased().precomposedStringWithCanonicalMapping
        guard !name.isEmpty else { return 0 }
        var hash: UInt32 = 0x811c9dc5
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return hash
    }

    static func familyName(_ composer: String?) -> String {
        var name = (composer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = name.firstIndex(of: ",") { name = String(name[..<comma]) }
        return name.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
    }

    /// The composer above the work. The composer is the one the page's
    /// order sorts by (`MusopenOrder.composer`), so a field that is no name
    /// does not stand on the cover nor give it its colours and letter; the
    /// work is the whole title.
    static func lines(title: String, composer: String?) -> (composer: String?, work: String) {
        (MusopenOrder.composer(author: composer, title: title), title)
    }

    /// The colours of one composer's cover: the pair of Goethe's circle,
    /// the two ends as OKLCH (lightness, chroma, hue), and whether the
    /// text is dark.
    struct Art: Equatable {
        let pair: Int
        let start: [Double]
        let end: [Double]
        /// The diagonal as red, green and blue at `stopCount` even stops.
        let stops: [[Double]]
        let darkText: Bool
    }

    static let stopCount = 9

    /// The two lightnesses lie this far apart at least, so the two ends of
    /// a pair stand apart in lightness as well as in hue.
    static let lightnessStep = 0.16

    static func art(composer: String?) -> Art {
        let hash = familyHash(composer)
        let pair = Int(hash % UInt32(goethePairs.count))
        let hues = goethePairs[pair]
        let flip = (hash >> 2) & 1 == 1
        // A dark field (one in three light): the end under the text lies
        // between 0.34 and 0.46 for white text or between 0.76 and 0.86 for
        // dark text, the other end the step toward the middle, so the text
        // over the first half of the diagonal keeps its contrast. The
        // saturation lies between 0.09 and 0.15.
        let lightField = (hash >> 3) % 3 == 0
        let step = Double((hash >> 5) % 7) / 50
        let light = lightField ? 0.76 + step * 0.8 : 0.34 + step
        let other = lightField ? light - lightnessStep : light + lightnessStep
        let chroma = 0.09 + Double((hash >> 8) % 7) / 100
        let first = [light, chroma, flip ? hues.second : hues.first]
        let second = [other, chroma, flip ? hues.first : hues.second]
        let around = (hash >> 10) & 1 == 1
        let stops = (0..<stopCount).map { index in
            rgb(oklch: along(first, second, at: Double(index) / Double(stopCount - 1), clockwise: around))
        }
        return Art(pair: pair, start: first, end: second, stops: stops, darkText: textIsDark(on: stops))
    }

    /// The colour at `t` of the way from `a` to `b` round the colour
    /// circle: lightness and chroma straight, the hue the long or the
    /// short way as `clockwise` says. The chroma never falls, so the way
    /// does not pass through grey.
    static func along(_ a: [Double], _ b: [Double], at t: Double, clockwise: Bool) -> [Double] {
        var delta = (b[2] - a[2]).truncatingRemainder(dividingBy: 360)
        if delta < 0 { delta += 360 }
        if !clockwise { delta -= 360 }
        let hue = (a[2] + delta * t).truncatingRemainder(dividingBy: 360)
        return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, hue < 0 ? hue + 360 : hue]
    }

    /// The text stands top left, over the first half of the diagonal: it is
    /// dark where dark text stands out more there than white.
    static func textIsDark(on stops: [[Double]]) -> Bool {
        let under = Array(stops.prefix(stops.count / 2 + 1))
        let white = under.map { contrast([1, 1, 1], $0) }.min() ?? 0
        let dark = under.map { contrast(darkText, $0) }.min() ?? 0
        return dark > white
    }

    /// The dark text colour.
    static let darkText: [Double] = [0.08, 0.08, 0.10]

    // MARK: OKLCH, OKLab and sRGB

    /// sRGB (0…1 each, gamma encoded) of an OKLCH colour, its chroma
    /// lowered until it fits.
    static func rgb(oklch: [Double]) -> [Double] {
        var chroma = oklch[1]
        while true {
            let h = oklch[2] * .pi / 180
            let linear = linearRGB(oklab: [oklch[0], chroma * cos(h), chroma * sin(h)])
            if linear.allSatisfy({ $0 >= -0.0001 && $0 <= 1.0001 }) || chroma <= 0 {
                return linear.map { encode(min(max($0, 0), 1)) }
            }
            chroma -= 0.005
        }
    }

    static func linearRGB(oklab lab: [Double]) -> [Double] {
        let l_ = lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2]
        let m_ = lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2]
        let s_ = lab[0] - 0.0894841775 * lab[1] - 1.2914855480 * lab[2]
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
    }

    /// OKLab of an sRGB colour (gamma encoded).
    static func oklab(rgb: [Double]) -> [Double] {
        let r = decode(rgb[0]), g = decode(rgb[1]), b = decode(rgb[2])
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return [0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s]
    }

    /// The distance of two sRGB colours in OKLab.
    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        let p = oklab(rgb: a), q = oklab(rgb: b)
        return sqrt(zip(p, q).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
    }

    static func encode(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
    static func decode(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

    /// WCAG contrast of two sRGB colours.
    static func contrast(_ a: [Double], _ b: [Double]) -> Double {
        func luminance(_ c: [Double]) -> Double { 0.2126 * decode(c[0]) + 0.7152 * decode(c[1]) + 0.0722 * decode(c[2]) }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // MARK: The letter

    /// The initial is a darker shade of the field.
    static let letterShade: Double = 0
    static let letterOpacity: Double = 0.22

    static func underLetter(_ rgb: [Double]) -> [Double] {
        rgb.map { $0 * (1 - letterOpacity) + letterShade * letterOpacity }
    }

    /// The first letter of the family name, else of the work.
    static func initial(composer: String?, title: String) -> String {
        let name = familyName(composer)
        let source = name.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : name
        return source.first.map { String($0).uppercased() } ?? ""
    }
}
