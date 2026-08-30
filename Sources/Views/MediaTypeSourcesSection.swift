// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The sources that feed one media type, as links into the ONE page each
/// account already has.
///
/// Deliberately links, never copies: an account exists once and appears
/// wherever it acts. Audiobookshelf under Audiobooks and under Podcasts is the
/// same row with the same name and the same icon, and both lead to the same
/// page. That recognisability IS the feature, not a detail of it.
///
/// The pill and the source register share this component, so a source cannot
/// appear in one place and be forgotten in the other.
struct MediaTypeSourcesSection: View {
    let area: SourceMapArea
    /// The Audiobookshelf page needs a session the caller owns. Injected as a
    /// closure, exactly as the source register already does it, so both places
    /// reach the SAME page instead of building two.
    var absDestination: () -> AnyView

    var body: some View {
        Section {
            ForEach(MediaTypeSources.all(for: area)) { source in
                NavigationLink {
                    destination(for: source.id)
                } label: {
                    Label(source.title, systemImage: source.symbol)
                }
                .accessibilityIdentifier(source.accessibilityId)
            }
        } header: {
            Text("Sources")
        } footer: {
            // Says what the rows ARE, so nobody reads them as per-type copies.
            Text("These are the sources that feed this type. An account exists once — the same entry appears under every type it serves.")
        }
    }

    /// The one page per source. A `@ViewBuilder` switch rather than a value in
    /// the model: the model stays Foundation-only (the shared-core rule), and
    /// the pages live here anyway.
    @ViewBuilder
    private func destination(for sourceId: String) -> some View {
        switch sourceId {
        case "abs":            absDestination()
        case "subsonic":       SubsonicSourceView()
        case "jellyfin":       JellyfinSourceView()
        case "gpodder", "pinchflat", "rss": PodcastSourceView()
        case "local-files":    LocalFilesView()
        case "radio-browser":  RadioSourceView()
        // The free catalogues have no account page of their own. Their
        // services (and their opt-outs) live on the sources page.
        default:               SourcesSettingsView()
        }
    }
}
