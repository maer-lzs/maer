// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

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

    /// Cover-image fetches. `ImageCache` already owns cover caching on disk,
    /// so this session keeps NO `URLCache`. Otherwise every cover response is
    /// stored a SECOND time in the (app-unbounded, purgeable) URLCache, which
    /// balloons the "System Data" footprint during heavy scrolling. `nil` cache
    /// + reload policy means we always go to ImageCache/network, never URLCache.
    /// Image bytes (the cover lane of `HTTP`). Feeds still hand out
    /// `http://` image addresses (relay.fm, the BBC) that answer over
    /// https; under App Transport Security a cleartext image request is
    /// refused before its redirect is ever seen, so the door raises the
    /// address, the same rule feed addresses take.
    nonisolated static let coverImage: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Mass routes that compute before they answer (catalogue stock dumps,
    /// gutendex pages): minutes, not the app's usual window.
    nonisolated static let mass: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Session-based servers (gpodder): cookies travel with the requests.
    nonisolated static let cookies: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// The changes socket of the Mär sync service. The request timeout is
    /// the time the session waits for the NEXT bytes, and a socket that
    /// idles for twenty seconds would be cut on it; an announcement can be
    /// an hour away. Not measured on a host yet: a socket cut by this
    /// number is reopened at the next occasion, so the number costs
    /// speed, never correctness.
    nonisolated static let socket: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = 86_400
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}
