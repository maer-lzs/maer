// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// The one way a family follows the account through the shelf
/// (`RestingShelf.handOver`), so what goes around the rule is written once:
/// the account last handed to in this run, the replacements begun here,
/// when a replacement counts as landed, and an unsettled holding that is
/// tried again before anything else.
@MainActor
final class ShelfFollower {
    let family: String
    let shelf: RestingShelf
    /// The log prefix of the family, so a line names its owner.
    private let label: String
    /// The account the family was last handed to in this run.
    private(set) var handedTo: String?
    /// The replacements this run began; their writes may still be landing.
    private var issued: Set<String> = []
    /// A replacement that landed but whose holding did not settle; tried
    /// again at the next question, before anything else.
    private var unsettled: (owner: String, replacement: String)?
    /// A replacement whose rows have not yet landed with its mark.
    private var open: (owner: String, replacement: String, settled: @MainActor (String) -> Void)?

    /// When a family's replacement has landed: at once (its writes are
    /// synchronous), or once a write of its rows landed with the
    /// replacement's mark (`mark`, `OwnerMark`); such a family answers
    /// `landed` from the mark after a restart.
    enum Landing {
        case now
        case marked
    }

    /// The mark the family's next write must carry, and what it calls once
    /// that write landed; nil while no replacement is open. Asked when the
    /// write runs, so a write that takes the memory of the replaced stock
    /// carries it whatever was queued before.
    func mark() -> (statements: [SQLiteConnection.Statement], landed: @MainActor () -> Void)? {
        guard let open else { return nil }
        let name = open.replacement
        return (OwnerMark.statements(family: family, replacement: name), { [weak self] in self?.markLanded(name) })
    }

    /// The rows of the replacement `name` landed with its mark.
    func markLanded(_ name: String) {
        guard let landed = open, landed.replacement == name else { return }
        open = nil
        settle((landed.owner, landed.replacement), settled: landed.settled)
    }

    init(family: String, shelf: RestingShelf, label: String) {
        self.family = family
        self.shelf = shelf
        self.label = label
    }

    /// Whether the family's stock belongs to `scope`, handing it over first.
    /// Nil while it cannot (unread, a rest not laid, the shelf not
    /// writable); the family then holds what would carry one account's
    /// stock to another. `settled` hears the owner once a replacement settled.
    func follow<Value: Codable & Equatable>(
        to scope: String, previous: String? = nil, unread: Bool, landing: Landing,
        landed: (_ replacement: String) throws -> Bool = { _ in false },
        before: (_ holder: String) throws -> Void = { _ in },
        current: () throws -> Value,
        replace: (_ rest: Value?, _ owner: String, _ replacement: String) throws -> Void,
        settled: @escaping @MainActor (_ owner: String) -> Void = { _ in }
    ) -> RestingShelf.HandOver? {
        if !unread, scope == handedTo, unsettled == nil { return .kept }
        do {
            if let waiting = unsettled {
                try shelf.settle(family, owner: waiting.owner, replacement: waiting.replacement)
                unsettled = nil
                settled(waiting.owner)
            }
            var began: (owner: String, replacement: String)?
            let step = try shelf.handOver(
                family, to: scope, previous: previous, unread: unread, issuedHere: issued,
                landed: landed, before: before, current: current,
                replace: { rest, owner, name in
                    issued.insert(name)
                    // Known as open before its rows are asked to write, so a
                    // landing reported at once is heard.
                    if case .marked = landing { open = (owner, name, settled) }
                    do {
                        try replace(rest, owner, name)
                    } catch {
                        issued.remove(name)
                        open = nil
                        throw error
                    }
                    began = (owner, name)
                })
            if let began { land(began, landing, settled: settled) }
            if step != .unread { handedTo = scope }
            return step
        } catch {
            Logger.library.error("\(self.label, privacy: .public) owner held reason=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func land(_ began: (owner: String, replacement: String), _ landing: Landing,
                      settled: @escaping @MainActor (String) -> Void) {
        switch landing {
        case .now: settle(began, settled: settled)
        case .marked: break
        }
    }

    private func settle(_ began: (owner: String, replacement: String), settled: @MainActor (String) -> Void) {
        do {
            try shelf.settle(family, owner: began.owner, replacement: began.replacement)
            settled(began.owner)
        } catch {
            unsettled = began
            Logger.library.error("\(self.label, privacy: .public) owner holding not settled, tried again next time reason=\(String(describing: error), privacy: .public)")
        }
    }
}
