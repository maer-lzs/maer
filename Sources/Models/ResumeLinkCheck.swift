// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// What a link of the app's scheme asks, read strictly. Any app or page can
/// open a `maer:` link, so only the form the widget builds is taken: the
/// host `resume`, no user, password, port, query or fragment, and a title
/// of a known form (`ItemNamespace.isKnown`), not longer than `longestId`
/// and without a control character. Anything else asks nothing, and does
/// not continue the last title either. A taken link still starts without a
/// question, as the widget's tap does.
nonisolated enum ResumeLinkCheck {
    enum Ask: Equatable, Sendable {
        /// Continue what was heard last.
        case resume
        /// Continue exactly this title.
        case title(String)
    }

    /// The longest title a link may name.
    static let longestId = 2048

    static func ask(in url: URL) -> Ask? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == ResumeLink.scheme, parts.host == ResumeLink.host,
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil else { return nil }
        guard let id = ResumeLink.itemId(in: url) else {
            // Only the bare link and its empty title mean "the last one".
            return parts.path.isEmpty || parts.path == "/" ? .resume : nil
        }
        guard id.count <= longestId,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              ItemNamespace.isKnown(id) else { return nil }
        return .title(id)
    }
}
