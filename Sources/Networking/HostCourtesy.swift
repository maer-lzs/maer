// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The one place every request to a server passes before it is sent and
/// after its answer: at most `HostCourtesyRule.concurrent` requests at once
/// to a foreign host, the MusicBrainz group one per second, and a whole
/// host rests after a 429 or 503 for as long as it asked. The rule itself
/// is pure (`HostCourtesyRule`); this actor only keeps the state per group.
///
/// The person's own servers (the addresses in `KnownServers`) have no cap
/// and no spacing, but a rest they ask for is kept like any other. The
/// device itself (loopback) is no service and passes untouched.
///
/// A slot is handed on by continuation, so waiting for a slot sleeps
/// nowhere; only a rest and the group spacing wait on the clock, in one
/// place. A rest longer than `HostCourtesyRule.longestWait` ends the
/// request without asking (`Resting`).
actor HostCourtesy {
    static let shared = HostCourtesy()

    /// What `enter` hands out and `leave` takes back.
    struct Pass: Sendable {
        let group: String
        let counted: Bool
    }

    /// A request that met a long rest and was not sent.
    struct Resting: Error {
        let host: String
        let remaining: Duration
    }

    private struct State {
        var inFlight = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
        var nextStart: ContinuousClock.Instant?
        var restUntil: ContinuousClock.Instant?
        var restsInARow = 0
        var asked = 0
        var held = 0
        var refused = 0
    }

    private var states: [String: State] = [:]
    private let ownHosts: @Sendable () -> Set<String>
    private var knownOwn: (hosts: Set<String>, readAt: ContinuousClock.Instant)?
    private let clock = ContinuousClock()

    /// `ownHosts` gives a witness its own set; the app reads `KnownServers`.
    init(ownHosts: @escaping @Sendable () -> Set<String> = { HostCourtesy.knownServerHosts() }) {
        self.ownHosts = ownHosts
    }

    nonisolated static func knownServerHosts() -> Set<String> {
        Set(KnownServers.all().compactMap { URL(string: $0.url)?.host()?.lowercased() })
    }

    static let loopback: Set<String> = ["localhost", "127.0.0.1", "::1"]

    // MARK: - The two calls

    func enter(_ url: URL?) async throws -> Pass {
        guard let host = url?.host()?.lowercased(), !Self.loopback.contains(host) else {
            return Pass(group: "", counted: false)
        }
        let group = HostCourtesyRule.group(of: host)
        let allowance = HostCourtesyRule.allowance(group: group, isOwnServer: isOwn(host))
        var heldOnce = false
        while true {
            let now = clock.now
            var until: ContinuousClock.Instant?
            if let rest = states[group]?.restUntil, rest > now {
                let remaining = now.duration(to: rest)
                if remaining > HostCourtesyRule.longestWait {
                    states[group, default: State()].held += 1
                    throw Resting(host: host, remaining: remaining)
                }
                until = rest
            }
            if allowance.spacing != nil, let next = states[group]?.nextStart, next > now {
                until = max(until ?? next, next)
            }
            if let until {
                if !heldOnce { heldOnce = true; states[group, default: State()].held += 1 }
                try await Task.sleep(until: until, clock: .continuous)
                continue
            }
            if let cap = allowance.concurrent, states[group, default: State()].inFlight >= cap {
                if !heldOnce { heldOnce = true; states[group, default: State()].held += 1 }
                await withCheckedContinuation { states[group, default: State()].waiting.append($0) }
                continue
            }
            break
        }
        states[group, default: State()].inFlight += 1
        states[group, default: State()].asked += 1
        if let spacing = allowance.spacing { states[group, default: State()].nextStart = clock.now + spacing }
        return Pass(group: group, counted: true)
    }

    /// `status` nil is a request that ended without an answer.
    func leave(_ pass: Pass, status: Int?, retryAfter: String?) {
        guard pass.counted, var state = states[pass.group] else { return }
        state.inFlight = max(0, state.inFlight - 1)
        if !state.waiting.isEmpty { state.waiting.removeFirst().resume() }
        if let status, HostCourtesyRule.asksToRest(status: status) {
            let rest = HostCourtesyRule.rest(retryAfter: retryAfter, restsInARow: state.restsInARow, now: Date())
            state.restUntil = clock.now + rest
            state.restsInARow += 1
            state.refused += 1
            Logger.library.notice("COURTESY rest group=\(pass.group, privacy: .public) status=\(status) seconds=\(rest.components.seconds)")
        } else if let status, (200..<400).contains(status) {
            state.restsInARow = 0
        }
        states[pass.group] = state
    }

    /// One line per group for the session so far: asked, held, refused.
    /// Written when the app goes to the background, so a device run brings
    /// the numbers.
    func report() {
        for (group, state) in states.sorted(by: { $0.key < $1.key }) where state.asked + state.held > 0 {
            Logger.library.notice("COURTESY group=\(group, privacy: .public) asked=\(state.asked) held=\(state.held) refused=\(state.refused)")
        }
    }

    /// The numbers for a witness.
    func counts(group: String) -> (inFlight: Int, asked: Int, held: Int, refused: Int) {
        let state = states[group] ?? State()
        return (state.inFlight, state.asked, state.held, state.refused)
    }

    private func isOwn(_ host: String) -> Bool {
        let now = clock.now
        if let known = knownOwn, known.readAt.duration(to: now) < .seconds(60) {
            return known.hosts.contains(host)
        }
        let hosts = ownHosts()
        knownOwn = (hosts, now)
        return hosts.contains(host)
    }
}
