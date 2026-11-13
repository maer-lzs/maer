// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import Foundation
import UIKit
import os
@testable import Maer

/// At most two covers are brought to size at once; the others wait in the
/// order they asked, and a cell that left gives its place up.
struct SizingGateTests {
    /// Polls `condition` until it holds or five seconds passed.
    private static func until(_ condition: () async -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }

    /// Eight ask, each only after the one before stands in the gate, so the
    /// order of asking is known. Each works until the witness lets it go,
    /// one at a time, so each turn is recorded before the next is given.
    @Test("acht zugleich angefragt, nie mehr als zwei in Arbeit, in der Reihenfolge der Anfrage")
    func eightAskTwoWork() async throws {
        let gate = SizingGate(width: 2)
        let state = OSAllocatedUnfairLock(initialState: (now: 0, most: 0, order: [Int](), released: Set<Int>()))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<8 {
                group.addTask {
                    try await gate.enter()
                    state.withLock { $0.now += 1; $0.most = max($0.most, $0.now); $0.order.append(n) }
                    while !state.withLock({ $0.released.contains(n) }) {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                    state.withLock { $0.now -= 1 }
                    await gate.leave()
                }
                let stands = try await Self.until { await gate.asked == n + 1 }
                try #require(stands, "the precondition: ask \(n) stands in the gate")
            }
            for turn in 0..<8 {
                let given = try await Self.until { state.withLock { $0.order.count } == min(turn + 2, 8) }
                try #require(given, "the precondition: the gate gave turn \(turn + 1): \(state.withLock { $0.order })")
                state.withLock { $0.released.insert($0.order[turn]) }
            }
            try await group.waitForAll()
        }
        let seen = state.withLock { $0 }
        #expect(seen.most == 2, "more than two worked at once, or never two: \(seen.most)")
        #expect(await gate.mostAtOnce == 2)
        #expect(seen.order == Array(0..<8), "the line was not kept: \(seen.order)")
    }

    @Test("ein Wartender, der abgebrochen wird, gibt seinen Platz frei, ohne zu arbeiten; der naechste kommt dran")
    func aCancelledWaiterGivesItsPlaceUp() async throws {
        let gate = SizingGate(width: 1)
        try await gate.enter()
        let worked = OSAllocatedUnfairLock(initialState: [String]())
        let left = Task {
            do {
                try await gate.enter()
                worked.withLock { $0.append("left") }
                await gate.leave()
            } catch {
                worked.withLock { $0.append("gave up") }
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let next = Task {
            try await gate.enter()
            worked.withLock { $0.append("next") }
            await gate.leave()
        }
        try await Task.sleep(for: .milliseconds(20))
        left.cancel()
        try await Task.sleep(for: .milliseconds(20))
        await gate.leave()
        _ = await left.result
        try await next.value
        #expect(worked.withLock { $0 } == ["gave up", "next"], "a cell that left decoded, or the line stopped")
    }

    /// The app's own path: eight large covers brought to display size at
    /// once pass two at a time.
    @Test("die App bringt acht grosse Cover zugleich angefragt zu zweit auf Anzeigegroesse")
    func theAppSizesTwoAtATime() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 3000), format: format).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3000, height: 3000))
        }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask { try await ImageCache.displaySized(data, maxPixelSize: 1500) != nil }
            }
            for try await sized in group { #expect(sized) }
        }
        #expect(await ImageCache.sizing.mostAtOnce == 2, "covers were sized more than two at once, or never two")
    }
}
#endif
