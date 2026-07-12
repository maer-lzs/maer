import Foundation

extension URLSession {
    /// Session für nutzer-sichtbare Requests (API, Feed, PodcastIndex): kürzeres
    /// Timeout als der 60-s-Default, damit ein hängender Server die UI nicht
    /// lange blockiert. `waitsForConnectivity = false` → offline schlägt der
    /// Request sofort fehl (die App zeigt dann ihren Offline-Zustand), statt zu
    /// warten.
    static let maer: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}
