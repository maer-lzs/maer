// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

#if canImport(Testing)
import Testing
import UIKit
@testable import Maer

/// Cold-start crash regression: the MPMediaItemArtwork request handler is
/// invoked by MPNowPlayingInfoCenter on its PRIVATE accessQueue, not the main
/// actor. Under the project's default MainActor isolation an inline closure
/// inherited main-actor isolation, and the Swift 6 runtime isolation check then
/// trapped (EXC_BREAKPOINT / dispatch_assert_queue) on the first cold start with
/// playback. The handler now comes from a factory whose `@Sendable` return type
/// makes the nonisolated contract compile-enforced.
struct NowPlayingArtworkTests {

    @Test("Artwork request handler is nonisolated — invokable off the main actor")
    func artworkRequestHandlerRunsOffMain() async {
        let image = UIImage(systemName: "book.fill") ?? UIImage()
        let handler = PlayerViewModel.artworkRequestHandler(for: image)
        // A main-actor-isolated closure would trip the runtime isolation check
        // when invoked here on a detached task; the @Sendable factory must not.
        let result = await Task.detached { handler(image.size) }.value
        #expect(result === image)
    }
}
#endif
