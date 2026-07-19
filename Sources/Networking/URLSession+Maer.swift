import Foundation

extension URLSession {
    /// Session for user-visible requests (API, feed, PodcastIndex): shorter
    /// timeout than the 60 s default so a hanging server does not block the UI
    /// for long. `waitsForConnectivity = false` → offline the request fails
    /// immediately (the app then shows its offline state) instead of waiting.
    nonisolated static let maer: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// S24: cover-image fetches. `ImageCache` already owns cover caching on disk,
    /// so this session keeps NO `URLCache` — otherwise every cover response is
    /// stored a SECOND time in the (app-unbounded, purgeable) URLCache, which
    /// balloons the "System Data" footprint during heavy scrolling. `nil` cache
    /// + reload policy means we always go to ImageCache/network, never URLCache.
    nonisolated static let coverImage: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}
