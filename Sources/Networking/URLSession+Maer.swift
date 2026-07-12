import Foundation

extension URLSession {
    /// Session for user-visible requests (API, feed, PodcastIndex): shorter
    /// timeout than the 60 s default so a hanging server does not block the UI
    /// for long. `waitsForConnectivity = false` → offline the request fails
    /// immediately (the app then shows its offline state) instead of waiting.
    static let maer: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}
