import Foundation

/// Per-feed HTTP Basic auth for private/premium podcasts (user/password in the
/// keychain, bound to the stable `feedKey`). Provides the `Authorization`
/// header for feed fetch, streaming and download. Nonisolated — usable from the
/// parser (background), the providers and the player.
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

    /// `Authorization: Basic …` for a feed (empty when there are no credentials).
    static func authHeader(feedKey: String) -> [String: String] {
        guard let c = credentials(feedKey: feedKey) else { return [:] }
        let token = Data("\(c.user):\(c.password)".utf8).base64EncodedString()
        return ["Authorization": "Basic \(token)"]
    }

    /// Auth header from an `rss:<feedKey>:<guid>` item id (empty otherwise).
    static func authHeader(forItemId id: String) -> [String: String] {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "rss" else { return [:] }
        return authHeader(feedKey: String(parts[1]))
    }
}
