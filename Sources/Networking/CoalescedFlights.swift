// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The limits of a flight's session store; `none` keeps nothing.
nonisolated struct FlightCapacity: Sendable {
    let entries: Int
    let bytes: Int
    static let none = FlightCapacity(entries: 0, bytes: 0)
}

/// One flight per key: every caller asking the same question while it is
/// being answered waits for the same work, and a caller that goes away only
/// stops ITS wait. The work runs to its end regardless.
///
/// Measured on two devices (20.09.2026): the free-catalogue lookups were
/// cancelled more often than they finished, 49 against 30, and asked 29
/// times for 12 ids. The work hung on the lifetime of the cell that asked:
/// scrolling cancelled it, and the next appearance asked again. Here the
/// work belongs to the flight, not to the caller.
///
/// Optionally it keeps successful answers for the session, in memory only
/// and capped, so an answer that landed after its caller left is not lost.
/// A failure is never kept; with `holdsBack`, a failure only makes the next
/// question wait (`FetchHoldback`).
actor CoalescedFlights<Value: Sendable> {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Value, Error>
    }

    private let capacity: FlightCapacity
    /// Told once per caller that left before its answer came.
    private let onLeft: @Sendable (String) -> Void
    /// Told once per question refused during its holdback.
    private let onHeldBack: @Sendable (String) -> Void
    private let holdsBack: Bool
    private let now: @Sendable () -> Date
    private var failedAt: [String: Date] = [:]
    private var waiters: [String: [Waiter]] = [:]
    private var running: Set<String> = []
    private var stored: [String: (value: Value, bytes: Int)] = [:]
    /// Oldest first, for eviction.
    private var storedOrder: [String] = []
    private var storedBytes = 0

    init(capacity: FlightCapacity, holdsBack: Bool = false,
         now: @escaping @Sendable () -> Date = { Date() },
         onLeft: @escaping @Sendable (String) -> Void = { _ in },
         onHeldBack: @escaping @Sendable (String) -> Void = { _ in }) {
        self.capacity = capacity
        self.holdsBack = holdsBack
        self.now = now
        self.onLeft = onLeft
        self.onHeldBack = onHeldBack
    }

    /// The answer for `key`: from the session store, from the flight already
    /// on its way, or from a new flight running `work`. `work` answers the
    /// value and its size in bytes (for the store's cap).
    func value(for key: String,
               work: @escaping @Sendable () async throws -> (Value, Int)) async throws -> Value {
        if let kept = stored[key] { return kept.value }
        // A flight on its way is joined; only a NEW question waits out the
        // holdback of the last failure.
        if holdsBack, !running.contains(key), !FetchHoldback.mayAsk(failedAt: failedAt[key], now: now()) {
            onHeldBack(key)
            throw FetchHeldBack()
        }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    onLeft(key)
                    return
                }
                waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
                if !running.contains(key) {
                    running.insert(key)
                    Task { await self.fly(key: key, work: work) }
                }
            }
        } onCancel: {
            Task { await self.leave(key: key, id: id) }
        }
    }

    private func fly(key: String, work: @Sendable () async throws -> (Value, Int)) async {
        let result: Result<(Value, Int), Error>
        do { result = .success(try await work()) } catch { result = .failure(error) }
        running.remove(key)
        switch result {
        case .success(let (value, bytes)):
            // Not observable, only tidy: a success comes after the holdback
            // ran out, and then the rule lets the next question through anyway.
            failedAt[key] = nil
            keep(value, bytes: bytes, for: key)
        case .failure(let error):
            if holdsBack, FetchHoldback.starts(after: error) { failedAt[key] = now() }
        }
        let landed = result.map(\.0)
        for waiter in waiters.removeValue(forKey: key) ?? [] {
            waiter.continuation.resume(with: landed)
        }
    }

    private func leave(key: String, id: UUID) {
        guard var list = waiters[key], let index = list.firstIndex(where: { $0.id == id }) else { return }
        let waiter = list.remove(at: index)
        waiters[key] = list.isEmpty ? nil : list
        waiter.continuation.resume(throwing: CancellationError())
        onLeft(key)
    }

    private func keep(_ value: Value, bytes: Int, for key: String) {
        guard capacity.entries > 0, bytes <= capacity.bytes else { return }
        if stored.removeValue(forKey: key) != nil {
            storedOrder.removeAll { $0 == key }
        }
        stored[key] = (value, bytes)
        storedOrder.append(key)
        storedBytes = stored.values.reduce(0) { $0 + $1.bytes }
        while stored.count > capacity.entries || storedBytes > capacity.bytes, let oldest = storedOrder.first {
            storedOrder.removeFirst()
            storedBytes -= stored.removeValue(forKey: oldest)?.bytes ?? 0
        }
    }

    /// Drops the kept answer for `key`, so the next question asks the network
    /// and learns afresh. A kept answer can outlive what it describes: a
    /// release withdrawn during the session still answers from the store.
    func forget(_ key: String) {
        guard stored.removeValue(forKey: key) != nil else { return }
        storedOrder.removeAll { $0 == key }
        storedBytes = stored.values.reduce(0) { $0 + $1.bytes }
    }

    /// For the witnesses: how many answers the store holds.
    var storedCount: Int { stored.count }
}
