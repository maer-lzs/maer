// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import os

/// Whether a chapter's name already carries its count, in any form: a
/// number in front ("01 - X", "1. X"), a word mark with a count ("Chapter
/// 3", "Kapitel IV", "Part Two", "Book the First"), an ordinal before a
/// word mark ("Erstes Kapitel"), a Roman numeral in front ("III. X"), a
/// written-out number in front ("One: X"), a counter at the end ("Name
/// 03"). The app sets the place in front only when none of them holds,
/// so "3. III Er tat es" never appears. When unsure, it counts: a number
/// missing reads better than one twice. Measured on the libraries at hand,
/// the forms of the witnesses in `AddChapterTests`.
nonisolated enum ChapterCounting {
    private static let words = "(?:chapter|chap\\.?|kapitel|kap\\.?|part|teil|book|buch|section|abschnitt|track|cd|disc|episode|folge|chapitre|cap[ií]tulo|capitolo|hoofdstuk|letter|brief|act|akt|scene|szene|canto|lesson|lektion|stave|tag|day)"
    private static let roman = "(?=[IVXLCDM])(?:M{0,3}(?:CM|CD|D?C{0,3})(?:XC|XL|L?X{0,3})(?:IX|IV|V?I{0,3})(?<=[IVXLCDMivxlcdm]))"
    private static let enNum = "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred)(?:[- ](?:one|two|three|four|five|six|seven|eight|nine))?"
    private static let deNum = "(?:eins|zwei|drei|vier|f[uü]nf|sechs|sieben|acht|neun|zehn|elf|zw[oö]lf|dreizehn|vierzehn|f[uü]nfzehn|sechzehn|siebzehn|achtzehn|neunzehn|zwanzig|drei[sß]ig|vierzig)"
    private static let enOrd = "(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|eleventh|twelfth|\\w+teenth|twentieth|thirtieth|last|final)"
    private static let deOrd = "(?:erste|zweite|dritte|vierte|f[uü]nfte|sechste|siebte|achte|neunte|zehnte|elfte|zw[oö]lfte|\\w+zehnte|zwanzigste|letzte)[snrm]?"
    private static let months = "(?:januar|februar|maerz|märz|april|mai|juni|juli|august|september|oktober|november|dezember|january|february|march|may|june|july|october|december)"

    /// The forms, each with whether it ignores case. The Roman one keeps
    /// case, so "Mix" and "Civil" are words, and it never takes a lone C,
    /// D, L or M.
    private static let forms: [(regex: NSRegularExpression, roman: Bool)] = {
        // The en and em dash as escapes, so no app text carries the sign.
        let dashes = "\u{2013}\u{2014}"
        let patterns: [(String, Bool, Bool)] = [
            ("^\\s*\\d{1,3}(?:\\s*[-.:)_\(dashes)]\\s*|\\s+(?=\\D))(?!\\d)", true, false),
            ("^\\s*\\d{1,3}\\s*$", true, false),
            ("(?:^|[\\s\\-_.,:(])\\s*\(words)[\\s_]*(?:\\d+|\(roman)\\b|\(enNum)\\b|\(deNum)\\b|the\\s+\(enOrd)\\b)", true, false),
            ("^\\s*(?:\(enOrd)|\(deOrd)|\\d+(?:st|nd|rd|th|\\.))\\s+\(words)\\b", true, false),
            ("^\\s*(\(roman))(?:\\s*[-.:)\(dashes)]\\s*|\\s*$)", false, true),
            ("^(?!.*\\b\(months)\\s+\\d{1,2}\\s*$)\\D.*\\s\\d{1,3}(?:-\\d{1,3})?\\s*$", true, false),
            ("^\\s*(?:\(enNum)|\(deNum))\\s*[-.:\(dashes)]\\s*", true, false),
            // A number word alone counts, as a number alone does: "Three".
            ("^\\s*(?:\(enNum)|\(deNum))\\s*$", true, false),
        ]
        return patterns.compactMap { pattern, ignoresCase, roman in
            do {
                return (try NSRegularExpression(pattern: pattern, options: ignoresCase ? [.caseInsensitive] : []), roman)
            } catch {
                // A form that does not build counts nothing; the line says
                // so instead of a count quietly missing a form.
                Logger.library.error("CHAPTERS counting form not built: \(FailureReason.of(error), privacy: .public)")
                return nil
            }
        }
    }()

    static func counts(_ name: String) -> Bool {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(text.startIndex..., in: text)
        for form in forms {
            guard let match = form.regex.firstMatch(in: text, range: range) else { continue }
            if form.roman {
                let numeral = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
                if ["", "C", "D", "L", "M"].contains(numeral) { continue }
            }
            return true
        }
        return false
    }

    /// Whether a name is a file's name rather than a chapter's: no space,
    /// and underscores or an audio ending. Such a name reads "Part N of M".
    static func isFileName(_ name: String) -> Bool {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return false }
        let endings = ["mp3", "m4a", "m4b", "ogg", "oga", "opus", "flac", "aac", "wav"]
        return text.contains("_") || endings.contains((text as NSString).pathExtension.lowercased())
    }
}
