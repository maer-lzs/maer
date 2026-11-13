// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The address a feed or a cover request actually goes to. One rule, one
/// place.
///
/// Podcast directories still hand out `http://` addresses for feeds and
/// covers that answer identically over https, so they are raised. A server
/// the person entered (`KnownServers`) keeps the scheme it was entered
/// with: a server reached only over http (a mesh address, a home network
/// without a certificate) answers nothing over https. App Transport Security
/// lets cleartext through (`NSAllowsArbitraryLoads` alone).
///
/// There is deliberately NO fallback to http when https fails for a foreign
/// host: it would trade a clear failure for a confusing one.
nonisolated enum PodcastFeedAddress {

    /// The URL to request for a stored or directory-supplied feed address.
    /// Scheme-less input is assumed to be https (the same assumption the
    /// subscribe path always made); `http://` is raised to https unless the
    /// host is one of the person's own servers (`ownHosts`).
    static func requestURL(_ raw: String, ownHosts: Set<String> = KnownServers.ownHosts()) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(),
           scheme != "http", scheme != "https" {
            // Something that is not web transport at all (file:, itpc:, …).
            // Handing it to URLSession is not this rule's business.
            return URL(string: trimmed)
        }
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "http",
           let host = url.host()?.lowercased(), ownHosts.contains(host) {
            return url
        }
        return URL(string: upgradedString(trimmed))
    }

    /// The same rule for an address that is already a `URL`. The funnel every
    /// feed and cover fetch passes through, so a call site that builds its URL
    /// itself cannot sneak cleartext past the rule.
    static func upgraded(_ url: URL, ownHosts: Set<String> = KnownServers.ownHosts()) -> URL {
        guard url.scheme?.lowercased() == "http" else { return url }
        // The device itself is no service: no certificate names it, and a
        // witness's stand on the loopback is reached over the same door as
        // the open net. A server the person entered keeps its scheme. Every
        // other host is raised.
        if let host = url.host()?.lowercased(), loopback.contains(host) || ownHosts.contains(host) { return url }
        return URL(string: upgradedString(url.absoluteString)) ?? url
    }

    /// The device's own addresses, the one place the rule leaves cleartext.
    static let loopback: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// Query parameters whose VALUES are access secrets. A feed carrying
    /// one is the token-URL premium class: access baked into the URL, no
    /// login. ONE set feeds detection, masking and the OPML export guard.
    /// "freebie" is the ZEIT premium class.
    static let secretQueryParams: Set<String> =
        ["token", "auth", "key", "secret", "freebie"]

    /// Words of a query name that say its value is access, wider than
    /// `secretQueryParams`, which decides premium: an address carrying one
    /// stays home, and is not called premium for it (`api_key`,
    /// `access_token`, `password`, `sig`, `session_id` and the like). A word
    /// counts whole, never inside another (`author`, `keyword`, `design`,
    /// `passage` are no access).
    static let accessNameParts: Set<String> = ["token", "auth", "key", "secret", "pass", "password", "passwd",
                                               "sig", "signature", "session", "sid", "freebie", "apikey"]

    /// Whether a query name names access: the name or one of its words
    /// (split at `_`, `-`, `.` and where a small letter meets a capital) is
    /// one of `accessNameParts`.
    static func namesAccess(_ name: String) -> Bool {
        var words: [String] = []
        var word = ""
        var previous: Character?
        for character in name {
            if !character.isLetter && !character.isNumber {
                words.append(word); word = ""
            } else {
                if character.isUppercase, let previous, previous.isLowercase { words.append(word); word = "" }
                word.append(character)
            }
            previous = character
        }
        words.append(word)
        if ([name] + words).contains(where: { accessNameParts.contains($0.lowercased()) }) { return true }
        // A name written as one word (`authtoken`, `accesskey`, `sessionid`):
        // it begins or ends with a hard word, or ends with `key` right after
        // a word that makes it access. Soft words (`auth`, `key`, `pass`,
        // `sig`) count only whole, so `author`, `keyword`, `passage`,
        // `monkey` and `sigma` stay names.
        let joined = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if accessHardWords.contains(where: { joined.hasPrefix($0) || joined.hasSuffix($0) }) { return true }
        if accessKeyLeads.contains(where: { joined.hasSuffix($0 + "key") }) { return true }
        return joined.hasPrefix("session") || joined.hasSuffix("pass") || joined.hasSuffix("auth")
    }

    /// Words that say access at the beginning or the end of a name written
    /// as one, and as a whole name.
    static let accessHardWords = ["token", "secret", "password", "passwd", "passcode", "passphrase", "apikey", "signature",
                                  "pwd", "hmac"]

    /// Words that make a following `key` an access key.
    static let accessKeyLeads = ["api", "access", "auth", "secret", "private", "session", "client", "signing"]

    /// Whether an address carries access at all: a secret in its query, by
    /// the premium names or a name with an access part, or a user or
    /// password before its host (also written without a scheme). Such an
    /// address stays home. The page on maer.fm (`site/l/l.js`) asks the same
    /// question with the same three lists.
    static func carriesAccess(_ raw: String) -> Bool {
        if isTokenFeedURL(raw) { return true }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let q = text.firstIndex(of: "?"),
           text[text.index(after: q)...].split(separator: "&").contains(where: { pair in
               let parts = pair.split(separator: "=", maxSplits: 1)
               let name = parts.first.map(String.init) ?? ""
               return parts.count == 2 && !parts[1].isEmpty && namesAccess(name)
           }) {
            return true
        }
        guard let url = URL(string: text.contains("://") ? text : "https://" + text) else { return false }
        return url.user != nil || url.password != nil
    }

    /// Token-URL premium class: a known secret parameter with a non-empty
    /// value. Conservative string parse, works for raw and normalized URLs.
    /// Lives here rather than with the subscriptions so the export builder
    /// and the source watch reach it without the store.
    static func isTokenFeedURL(_ raw: String) -> Bool {
        guard let q = raw.firstIndex(of: "?") else { return false }
        return raw[raw.index(after: q)...].split(separator: "&").contains { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            return parts.count == 2 && !parts[1].isEmpty
                && secretQueryParams.contains(parts[0].lowercased())
        }
    }

    private static func upgradedString(_ address: String) -> String {
        let lowered = address.lowercased()
        if lowered.hasPrefix("http://") {
            return "https://" + address.dropFirst("http://".count)
        }
        if lowered.hasPrefix("https://") { return address }
        return "https://" + address
    }
}
