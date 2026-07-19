import Foundation

/// F1: Radio Browser API — the open, key-free community catalog. Served by
/// volunteer MIRRORS behind round-robin DNS; we try a fixed mirror list in
/// order (the de-dupe against double-serves lives in `RadioMapping`). Every
/// request rides the shared retry policy (Y39).
nonisolated enum RadioBrowserClient {
    /// Known stable mirrors, tried in order. Deliberately NOT the round-robin
    /// `all.api.radio-browser.info` host: its DNS answer varies per lookup,
    /// which makes failures unreproducible.
    static let mirrors = [
        "https://de1.api.radio-browser.info",
        "https://at1.api.radio-browser.info",
        "https://nl1.api.radio-browser.info",
    ]

    static func search(name: String, limit: Int = 50) async throws -> [RadioStation] {
        var lastError: Error = URLError(.cannotConnectToHost)
        for mirror in mirrors {
            var comps = URLComponents(string: "\(mirror)/json/stations/search")!
            comps.queryItems = [
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "hidebroken", value: "true"),
                URLQueryItem(name: "order", value: "votes"),
                URLQueryItem(name: "reverse", value: "true"),
            ]
            var request = URLRequest(url: comps.url!)
            // The API asks clients to identify themselves.
            request.setValue("Maer/1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, http) = try await RequestRetryPolicy.fetch(request)
                guard let status = http?.statusCode, (200...299).contains(status) else {
                    lastError = URLError(.badServerResponse)
                    continue
                }
                let raw = try JSONDecoder().decode([RadioBrowserStation].self, from: data)
                return RadioMapping.stations(from: raw)
            } catch {
                // Next mirror — the policy already retried transients here.
                lastError = error
            }
        }
        throw lastError
    }
}
