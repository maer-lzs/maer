// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Combine
import OSLog
import SwiftUI

/// The one body of a music page around its content: every state that is not
/// content has one sentence and a way out (`MusicPageState` decides which).
/// The tab's server section and every library page draw it, so no surface
/// keeps its own chain of empty, error and "no server" states.
struct MusicPageBody<Content: View>: View {
    let state: MusicPageState
    let emptyTitle: LocalizedStringKey
    var emptyDetail: LocalizedStringKey?
    var loadingHeight: CGFloat = 200
    let retry: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch state {
        case .missing:
            MusicServerMissingHere(retry: retry)
        case .content:
            content()
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: loadingHeight)
        case .failed(let sentence):
            LoadFailedView(form: .page(title: Text("Music unavailable"), systemImage: "music.note"),
                           sentence: Text(sentence), retry: retry)
            .frame(maxWidth: .infinity)
        case .empty:
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "music.note")
            } description: {
                if let emptyDetail { Text(emptyDetail) }
            } actions: {
                Button("Retry", action: retry)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// The one way a library page asks the device's music server: the server is
/// asked first (no server is never "none"), a failure is logged and becomes
/// the page's sentence, and a cancellation decides nothing. Neither does a
/// run the page has moved past (`isCurrent`, from its `PageRuns`): an
/// answer landing after a reload, a new sort or filter is dropped, value
/// and failure alike.
enum MusicPageLoad {
    enum Outcome<Value> {
        case missing
        case loaded(Value)
        case failed(String)
        case cancelled

        var isCancelled: Bool { if case .cancelled = self { true } else { false } }
        var isMissing: Bool { if case .missing = self { true } else { false } }
        var failure: String? { if case .failed(let sentence) = self { sentence } else { nil } }
        var value: Value? { if case .loaded(let value) = self { value } else { nil } }
    }

    static func run<Value>(_ page: String, reachable: Bool, isCurrent: () -> Bool,
                           fetch: () async throws -> Value) async -> Outcome<Value> {
        guard reachable else {
            Logger.music.notice("MUSIC page=\(page, privacy: .public) no server to ask on this device")
            return .missing
        }
        do {
            let value = try await fetch()
            if superseded(page, isCurrent()) { return .cancelled }
            return .loaded(value)
        } catch {
            if error.isCancellation || superseded(page, isCurrent()) { return .cancelled }
            Logger.music.error("MUSIC page=\(page, privacy: .public) load failed reason=\(FailureReason.of(error), privacy: .public)")
            return .failed(ErrorSentence.of(error))
        }
    }

    /// Whether a landing run is past its page, with the log line. Also asked
    /// by a page whose loader is not this one.
    static func superseded(_ page: String, _ isCurrent: Bool) -> Bool {
        guard !isCurrent else { return false }
        Logger.music.notice("MUSIC page=\(page, privacy: .public) superseded, answer dropped")
        return true
    }
}

extension View {
    /// Runs when the sources change (an address or account added or removed
    /// here). The one place a music surface listens for it.
    func onMusicSourcesChange(_ action: @escaping () -> Void) -> some View {
        onReceive(AppSession.shared.$sourcesVersion.dropFirst()) { _ in action() }
    }

    /// The same for a page that keeps its own state: the reachability is
    /// asked on every change (`MusicPageState.onSourcesChange`), a server
    /// that went away shows the way out, one that came loads the page, and so
    /// does a page that never asked (`asked`, from its runs).
    func reasksOnSourcesChange(serverMissing: Binding<Bool>, asked: @escaping () -> Bool,
                               reachable: @escaping () -> Bool,
                               reload: @escaping () async -> Void) -> some View {
        onMusicSourcesChange {
            switch MusicPageState.onSourcesChange(reachableNow: reachable(), wasMissing: serverMissing.wrappedValue,
                                                  asked: asked()) {
            case .showMissing: serverMissing.wrappedValue = true
            case .reload: Task { await reload() }
            case .keep: break
            }
        }
    }
}
