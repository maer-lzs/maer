import Foundation

/// Pro-Feed HTTP-Basic-Auth für private/Premium-Podcasts (Benutzer/Passwort im
/// Keychain, gebunden an den stabilen `feedKey`). Liefert den
/// `Authorization`-Header für Feed-Abruf, Streaming und Download. Nonisolated —
/// vom Parser (Hintergrund), den Providern und dem Player nutzbar.
nonisolated enum PodcastFeedAuth {
    private static func key(_ feedKey: String) -> String { "feedAuth.\(feedKey)" }

    static func credentials(feedKey: String) -> (user: String, password: String)? {
        guard let raw = KeychainStore.load(forKey: key(feedKey)),
              let sep = raw.firstIndex(of: "\n") else { return nil }
        return (String(raw[..<sep]), String(raw[raw.index(after: sep)...]))
    }

    static func set(feedKey: String, user: String, password: String) {
        if user.isEmpty && password.isEmpty {
            KeychainStore.delete(forKey: key(feedKey))
        } else {
            KeychainStore.save("\(user)\n\(password)", forKey: key(feedKey))
        }
    }

    static func hasCredentials(feedKey: String) -> Bool {
        credentials(feedKey: feedKey) != nil
    }

    /// `Authorization: Basic …` für einen Feed (leer, wenn keine Zugangsdaten).
    static func authHeader(feedKey: String) -> [String: String] {
        guard let c = credentials(feedKey: feedKey) else { return [:] }
        let token = Data("\(c.user):\(c.password)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }

    /// Auth-Header aus einer `rss:<feedKey>:<guid>`-Item-ID (leer sonst).
    static func authHeader(forItemId id: String) -> [String: String] {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "rss" else { return [:] }
        return authHeader(feedKey: String(parts[1]))
    }
}
