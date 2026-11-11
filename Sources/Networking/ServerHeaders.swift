// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog
import Synchronization

/// The headers a person entered for a server, and the one table the four
/// ways out of the app ask: the HTTP door, the retrying fetch, the
/// background downloads and the stream of a track. No client and no caller
/// names them; `ServerHeaderRule` decides which request carries which.
///
/// Each server's headers are one item in the iCloud keychain, so they reach
/// the person's other devices with the server's address. Names and values
/// are kept together: a header always counts as a secret. Signing out of a
/// server keeps them, they guard the host and not the account; removing the
/// server from the register removes them on every device.
///
/// A keychain that cannot be read (before the first unlock) is not one
/// without headers: a request to a server that has headers then does not go
/// out at all (`Unreadable`), and the table is read again a minute later.
/// Which servers have headers is kept beside it, without the values.
nonisolated enum ServerHeaders {
    /// A request held back because its server's headers cannot be read now.
    struct Unreadable: Error, Equatable {
        let host: String
    }

    static let accountPrefix = "serverHeaders|"
    static let readAgainAfter: TimeInterval = 60

    /// Where the table lives: the keychain and the register of servers with
    /// headers in the app, or a witness's own in its task.
    struct Keys: Sendable {
        var list: @Sendable () -> [String: String]?
        var write: @Sendable (_ account: String, _ value: String?) -> Bool
        var bases: @Sendable () -> [String]
        var setBases: @Sendable ([String]) -> Void
    }

    #if DEBUG
    /// A witness's keys for the task that set them and the tasks it starts.
    @TaskLocal static var witness: Keys?
    #endif

    static let device = Keys(
        list: { KeychainStore.values(withPrefix: accountPrefix) },
        write: { account, value in
            guard let value else {
                KeychainStore.delete(forKey: account)
                return true
            }
            return KeychainStore.save(value, forKey: account, synchronizable: true)
        },
        bases: { AppStorageKeys.stringArray(AppStorageKeys.serverHeaderBases) ?? [] },
        setBases: { AppStorageKeys.set($0.isEmpty ? nil : $0, for: AppStorageKeys.serverHeaderBases) }
    )

    private static var keys: Keys {
        #if DEBUG
        if let witness { return witness }
        #endif
        return device
    }

    /// The device's table, read again after `readAgainAfter`, so headers
    /// another device put into the iCloud keychain arrive, and a table that
    /// could not be read is asked again.
    private static let cache = Mutex<(entries: [ServerHeaderRule.Entry]?, readAt: Date)?>(nil)

    /// The table; nil while the keychain cannot be read.
    static func entries(now: Date = Date()) -> [ServerHeaderRule.Entry]? {
        #if DEBUG
        if let witness { return read(witness) }
        #endif
        if let held = cache.withLock({ $0 }), now.timeIntervalSince(held.readAt) < readAgainAfter {
            return held.entries
        }
        let read = read(device)
        cache.withLock { $0 = (read, now) }
        guard let read else {
            Logger.library.notice("SERVERHEADERS keychain unreadable, asked again in \(Int(readAgainAfter))s")
            return nil
        }
        // Headers another device laid down arrive in the keychain alone;
        // the register of their servers follows the table here.
        let bases = read.map { address($0.base) }.sorted()
        if bases != device.bases().sorted() { device.setBases(bases) }
        return read
    }

    /// Reads the table, after lifting items kept under another spelling of
    /// their server onto the one key (`ServerHeaderRule.key`). Once lifted,
    /// a later read writes nothing; a write the keychain does not take
    /// leaves the items where they are, and the next read tries again.
    private static func read(_ keys: Keys) -> [ServerHeaderRule.Entry]? {
        // One turn with every write of the table: a header laid down while
        // the read lifts is not written over by the lifting.
        keychainTurn.withLock { _ in
            guard let items = keys.list() else { return nil }
            let lift = lifted(items, register: Set(keys.bases()))
            guard !lift.writes.isEmpty else { return table(from: lift.items) }
            for write in lift.writes where !keys.write(write.account, write.value) {
                Logger.library.error("SERVERHEADERS lifting onto the one key not taken, read as kept")
                return table(from: items)
            }
            Logger.library.notice("SERVERHEADERS lifted onto the one key: \(lift.writes.filter { $0.value != nil }.count) kept, \(lift.dropped) left out")
            return table(from: lift.items)
        }
    }

    /// Every write of the keychain items and the lifting of a read take
    /// their turn here.
    private static let keychainTurn = Mutex(())

    /// The items with each one under the one key of its server, and the
    /// writes that bring the keychain there: the new item first, then the
    /// old one removed. Of several spellings of one server, the item
    /// already under the key stays (this build wrote it, it is the newest);
    /// else the spelling the register names, else the first in order. The
    /// others are left out of the table, since a request could never tell
    /// which it gets, and stay in the keychain under their own account
    /// until the server is forgotten.
    static func lifted(_ items: [String: String], register: Set<String> = [])
        -> (items: [String: String], writes: [(account: String, value: String?)], dropped: Int) {
        var spellings: [String: [String]] = [:]
        for account in items.keys.sorted() where account.hasPrefix(accountPrefix) {
            guard let base = URL(string: String(account.dropFirst(accountPrefix.count))),
                  let key = ServerHeaderRule.key(base) else { continue }
            spellings[accountPrefix + key, default: []].append(account)
        }
        var out = items
        var writes: [(account: String, value: String?)] = []
        var dropped = 0
        for (target, accounts) in spellings.sorted(by: { $0.key < $1.key }) where accounts != [target] {
            let named = accounts.filter { register.contains(String($0.dropFirst(accountPrefix.count))) }
            let kept = accounts.contains(target) ? target : (named.first ?? accounts[0])
            if kept != target, let value = items[kept] {
                out[target] = value
                writes.append((target, value))
                out[kept] = nil
                writes.append((kept, nil))
            }
            for account in accounts where account != kept && account != target {
                out[account] = nil
                dropped += 1
            }
        }
        return (out, writes, dropped)
    }

    private static func table(from items: [String: String]?) -> [ServerHeaderRule.Entry]? {
        guard let items else { return nil }
        return items.compactMap { account, value in
            guard account.hasPrefix(accountPrefix),
                  let base = URL(string: String(account.dropFirst(accountPrefix.count))) else { return nil }
            do {
                let headers = try JSONDecoder().decode([ServerHeaderRule.Header].self, from: Data(value.utf8))
                return ServerHeaderRule.Entry(base: base, headers: headers)
            } catch {
                Logger.library.error("SERVERHEADERS an item does not decode, its server gets none: \(FailureReason.of(error), privacy: .public)")
                return nil
            }
        }
    }

    // MARK: The ways out

    /// Sets the headers of the request's server. Each of the four ways out
    /// calls it next to the app's identity.
    static func apply(to request: inout URLRequest) {
        guard let entries = entries() else { return }
        request = ServerHeaderRule.applied(request, entries: entries)
    }

    /// Throws `Unreadable` for a request to a server that has headers while
    /// the keychain cannot be read; such a request would reach the guard in
    /// front of the server without them.
    static func admit(_ request: URLRequest) throws {
        guard entries() == nil, let url = request.url else { return }
        let known = keys.bases().compactMap(URL.init(string:)).map { ServerHeaderRule.Entry(base: $0, headers: []) }
        guard ServerHeaderRule.entry(for: url, in: known) != nil else { return }
        let host = url.host ?? "-"
        Logger.library.notice("SERVERHEADERS held host=\(host, privacy: .public): the headers cannot be read now")
        throw Unreadable(host: host)
    }

    /// The next request of a redirect, with the table read when the request
    /// started (a session's delegate runs outside the request's task).
    static func redirected(_ request: URLRequest, from previous: URL?,
                           entries: [ServerHeaderRule.Entry]?) -> URLRequest {
        guard let entries else { return request }
        return ServerHeaderRule.redirected(request, from: previous, entries: entries)
    }

    // MARK: The stream

    /// Whether any server has headers, or may have while the keychain
    /// cannot be read; without one no stream is asked ahead.
    static func anyServer() -> Bool {
        guard let entries = entries() else { return !keys.bases().isEmpty }
        return !entries.isEmpty
    }

    /// Whether the stream at this address waits for its plan: its server
    /// has headers, or may have while the keychain cannot be read.
    static func needsPlan(_ url: URL) -> Bool {
        guard !url.isFileURL else { return false }
        if let entries = entries() { return ServerHeaderRule.entry(for: url, in: entries) != nil }
        let known = keys.bases().compactMap(URL.init(string:)).map { ServerHeaderRule.Entry(base: $0, headers: []) }
        return ServerHeaderRule.entry(for: url, in: known) != nil
    }

    /// How a track's stream is built.
    enum Stream: Equatable, Sendable {
        /// The server has no headers: the asset asks the track's address
        /// with the source's headers alone.
        case plain
        /// Ask this address, with these headers (the source's sign-in and
        /// the server's headers when the address is still the server's).
        case resolved(URL, headers: [String: String])
        /// The headers cannot be read now; the track is not asked.
        case waiting
        /// The end of a stream with a sign-in could not be asked: it is
        /// not asked with the sign-in at an address whose redirects are
        /// unknown. Playback holds there with a sentence, and the next play
        /// asks again.
        case unanswered
    }

    /// The stream of a track on a server with headers is asked at the end
    /// of its redirects (`end(of:server:)`): a stream asset follows a
    /// redirect itself, and its later requests go straight to the end of
    /// the redirect with every header of the asset, `Authorization` too.
    static func stream(for url: URL, sourceHeaders: [String: String]) async -> Stream {
        guard let entries = entries() else {
            do {
                try admit(URLRequest(url: url))
                return .plain
            } catch {
                return .waiting
            }
        }
        guard let server = ServerHeaderRule.entry(for: url, in: entries) else { return .plain }
        var request = URLRequest(url: url)
        for (name, value) in sourceHeaders { request.setValue(value, forHTTPHeaderField: name) }
        guard let end = await self.end(of: ServerHeaderRule.applied(request, entries: entries), server: server) else {
            return .unanswered
        }
        return .resolved(end.url ?? url, headers: end.allHTTPHeaderFields ?? [:])
    }

    /// The request to the end of a server's redirects, for the two ways
    /// that follow a redirect without asking (a stream asset and the
    /// background session of the downloads, measured). The address is
    /// asked once over the HTTP door with `Range: bytes=0-0`, reading the
    /// head of the answer and no body, where a
    /// redirect passes the rule: an end at the server keeps the request with
    /// its headers; an end anywhere else gets a bare request, without the
    /// server's headers and without the source's sign-in (the request that
    /// follows a redirect drops `Authorization` itself, measured; a stream
    /// asset's later requests to that end carry it, measured, so the end
    /// is asked bare). A later redirect of that end by the server itself
    /// still carries the headers: the way follows it without asking.
    /// Nil when the end cannot be asked: the way is not built, since its
    /// own address could redirect anywhere with the headers.
    static func end(of request: URLRequest, server: ServerHeaderRule.Entry) async -> URLRequest? {
        guard let url = request.url else { return request }
        guard let end = await endAddress(of: request) else {
            Logger.library.notice("SERVERHEADERS not asked host=\(url.host ?? "-", privacy: .public): the end of its redirects is unknown")
            return nil
        }
        guard let entries = entries(), ServerHeaderRule.entry(for: end, in: entries) == server else {
            var bare = URLRequest(url: end)
            bare.timeoutInterval = request.timeoutInterval
            return bare
        }
        var kept = request
        kept.url = end
        return kept
    }

    /// How long the ask for the end of a stream's redirects may stay
    /// without an answer: a start, a jump and a rebuild wait for it, so a
    /// host that accepts and never answers holds them this long and no
    /// longer (the request's own default is 60 s).
    nonisolated static let endAskLimit: TimeInterval = 10

    /// The address at the end of a request's redirects, or nil when it
    /// cannot be asked. Asked once over the HTTP door with
    /// `Range: bytes=0-0`; only the head of the answer is read, because a
    /// server that ignores the range sends the whole file, or a transcoded
    /// stream without end. The door drops `Authorization` at a redirect, so
    /// the question itself carries a sign-in to no other host.
    static func endAddress(of request: URLRequest) async -> URL? {
        guard let url = request.url else { return nil }
        var probe = request
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        probe.timeoutInterval = endAskLimit
        do {
            let (bytes, response) = try await HTTP.bytes(for: probe)
            bytes.task.cancel()
            return response.url ?? url
        } catch {
            Logger.library.notice("SERVERHEADERS end unknown host=\(url.host ?? "-", privacy: .public) reason=\(FailureReason.of(error), privacy: .public)")
            return nil
        }
    }

    // MARK: The table itself

    static func account(for base: URL) -> String {
        accountPrefix + address(base)
    }

    /// The server's address as the table and the register name it: its one
    /// key, the same form the rule matches by.
    static func address(_ base: URL) -> String {
        ServerHeaderRule.key(base) ?? KnownServers.normalized(base.absoluteString)
    }

    /// Lays a server's headers down (empty removes them) and notes the
    /// server in the register; false when the keychain did not take them.
    @discardableResult
    static func set(_ headers: [ServerHeaderRule.Header], for base: URL) -> Bool {
        let account = account(for: base)
        let address = address(base)
        let value: String?
        if headers.isEmpty {
            value = nil
        } else {
            do {
                value = String(decoding: try JSONEncoder().encode(headers), as: UTF8.self)
            } catch {
                Logger.library.error("SERVERHEADERS headers do not encode: \(FailureReason.of(error), privacy: .public)")
                return false
            }
        }
        let taken = keychainTurn.withLock { _ in
            guard keys.write(account, value) else { return false }
            var bases = keys.bases().filter { $0 != address }
            if !headers.isEmpty { bases.append(address) }
            keys.setBases(bases)
            return true
        }
        guard taken else {
            Logger.library.error("SERVERHEADERS headers not kept host=\(base.host ?? "-", privacy: .public): the keychain did not take them")
            return false
        }
        cache.withLock { $0 = nil }
        return true
    }

    /// The headers laid down for exactly this server (any spelling of its
    /// address, not one it lies under); empty when it has none, nil while
    /// the keychain cannot be read.
    static func stored(for base: URL) -> [ServerHeaderRule.Header]? {
        guard let entries = entries() else { return nil }
        let address = address(base)
        return entries.first { Self.address($0.base) == address }?.headers ?? []
    }

    /// What became of the headers when a sheet's address changed.
    enum Move: Equatable, Sendable {
        /// Laid down under the new address, removed under the old.
        case moved
        /// The old address had none, or both name the same server.
        case nothingToMove
        /// The new address is a server with headers of its own: both keep
        /// theirs, and the sheet now shows the new server's.
        case targetHasOwn
        /// The keychain cannot be read, or did not take the write.
        case notTaken
    }

    /// The headers of a server move with its address, so nothing stays
    /// behind for the old one; never onto a server with headers of its own,
    /// which would get another server's secret and lose its own.
    @discardableResult
    static func move(from old: URL, to new: URL) -> Move {
        guard address(old) != address(new) else { return .nothingToMove }
        guard let target = stored(for: new), let headers = stored(for: old) else {
            Logger.library.error("SERVERHEADERS not moved host=\(new.host ?? "-", privacy: .public): the keychain cannot be read")
            return .notTaken
        }
        if !target.isEmpty {
            Logger.library.notice("SERVERHEADERS not moved host=\(new.host ?? "-", privacy: .public): the new address has headers of its own")
            return .targetHasOwn
        }
        guard !headers.isEmpty else { return .nothingToMove }
        guard set(headers, for: new), set([], for: old) else { return .notTaken }
        return .moved
    }

    /// Removes a server from the register by hand, and its headers on every
    /// device with it.
    static func forget(_ entry: KnownServer, defaults: UserDefaults? = nil) {
        KnownServers.forget(entry, defaults: defaults ?? AppStorageKeys.store)
        keychainTurn.withLock { _ in
            guard let items = keys.list() else {
                Logger.library.error("SERVERHEADERS forget: the keychain cannot be read, the headers of the server stay")
                return
            }
            let matching = items.keys.filter {
                KnownServers.sameServer(String($0.dropFirst(accountPrefix.count)), entry.url)
            }
            // Each item by its own account, so one still under an old
            // spelling goes too.
            for account in matching where !keys.write(account, nil) {
                Logger.library.error("SERVERHEADERS forget: an item of the server was not removed")
            }
            keys.setBases(keys.bases().filter { !KnownServers.sameServer($0, entry.url) })
        }
        cache.withLock { $0 = nil }
    }
}
