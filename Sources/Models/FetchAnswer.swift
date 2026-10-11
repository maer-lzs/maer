// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation
import OSLog

/// What a fetch a surface waits on hands back: a value, a failure, or a
/// cancellation. A failed fetch is not an empty answer: a surface that
/// read `(try? fetch()) ?? []` showed "no results" or "no playlists" when the
/// server did not answer, and marked the load as done, so nothing asked
/// again. A cancellation (a restarted task, a page that left) is no
/// failure and leaves the surface as it was.
nonisolated enum FetchAnswer<Value: Sendable>: Sendable {
    case value(Value)
    /// `reason` names the failure in the log (`FailureReason`), never as a
    /// sentence on the surface.
    case failed(reason: String)
    case cancelled

    /// Runs `body` and books its end: a thrown error is a failure with its
    /// reason, logged with `what`; a cancellation is not. On the main actor
    /// like the surfaces that wait on it, so `body` may read their state.
    @MainActor static func of(_ what: String, logger: Logger,
                   _ body: () async throws -> Value) async -> FetchAnswer<Value> {
        do {
            return .value(try await body())
        } catch {
            let answer = FetchAnswer<Value>.from(error)
            if case .failed(let reason) = answer {
                logger.error("FETCH failed what=\(what, privacy: .public) reason=\(reason, privacy: .public)")
            }
            return answer
        }
    }

    /// The answer a thrown error stands for.
    static func from(_ error: Error) -> FetchAnswer<Value> {
        error.isCancellation ? .cancelled : .failed(reason: FailureReason.of(error))
    }

    /// The error a failed answer throws on to a caller that books failures
    /// by a throw (the global search counts a source that threw).
    struct Failure: Error, Equatable {
        let reason: String
    }

    /// The value, or the throw a caller of a throwing door expects: a
    /// failure as `Failure`, a cancellation as `CancellationError`.
    func get() throws -> Value {
        switch self {
        case .value(let value): return value
        case .failed(let reason): throw Failure(reason: reason)
        case .cancelled: throw CancellationError()
        }
    }

    /// The value, when there is one.
    var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }

    var failed: Bool {
        if case .failed = self { return true }
        return false
    }

    /// One answer for a list that is several fetches put together (a chart
    /// chip over its genre ids): the values of the fetches that answered,
    /// in order; failed only when none answered and one failed; cancelled
    /// when all were cancelled. A fetch that failed beside one that
    /// answered is logged where it failed and leaves a shorter list.
    static func joined<Element: Sendable>(_ answers: [FetchAnswer<[Element]>]) -> FetchAnswer<[Element]> where Value == [Element] {
        let values = answers.compactMap(\.value)
        if !values.isEmpty { return .value(values.flatMap { $0 }) }
        if let failure = answers.first(where: \.failed) { return failure }
        return answers.isEmpty ? .value([]) : .cancelled
    }
}
