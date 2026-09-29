// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The ONE place that sets the query of a URL the app builds.
///
/// `URLComponents` leaves a `+` in a query value raw (RFC 3986 allows it
/// there), and a server that reads the query as a form turns it into a
/// space: Go's `url.ParseQuery`, PHP, .NET, Node, Django. Measured on the
/// test stands (29.09.2026): the sign-in at Koel fails with `u=name+plus@…`
/// and succeeds with `u=name%2Bplus@…`; a search at gonic for `Zett+Plus`
/// also finds "Zett Plus", for `Zett%2BPlus` only the right title. Here
/// every `+` travels as `%2B`; everything else keeps Apple's encoding. No
/// caller encodes on its own, and the fence holds that no caller sets
/// `queryItems` past this place.
extension URLComponents {
    nonisolated mutating func setQuery(_ items: [URLQueryItem]?) {
        queryItems = items
        percentEncodedQuery = percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
}
