// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import OSLog

/// The free-catalog Discover rows on Home. "New free audiobooks"
/// (LibriVox, keyless) · "Popular free audiobooks" (archive.org downloads
/// sort, keyless) · "Free music" (Jamendo, only with a client key). Tiles
/// play DIRECTLY (tap-to-play like radio); the context menu opens the
/// license/details sheet (public-domain badge resp. the Jamendo ToS
/// attribution with artist + backlink). Each row has its own opt-out on the
/// network-services page; rows are net-gated and hide silently when empty.
struct FreeCatalogRows: View {
    @ObservedObject var playerCoordinator: PlayerCoordinator
    /// The rows are DUMB now. A lazily-mounted, initially EMPTY
    /// view below the fold never ran its .task reliably (the third suspect);
    /// loading lives in HomeView's compute() pass (always runs, calm-gated)
    /// via `FreeCatalogLoader`.
    /// ONE mixed "Entdecken · Musik" row replaced the two source
    /// rows (classical + Jamendo). Interleaved, not two blocks (the archive-
    /// row mix decision), through the ONE merge (`HomeSections.interleave`).
    /// The source gates keep acting through the LOADER (a gated-off source
    /// loads nothing, so its share is simply absent); both empty → no row.
    /// The entry chevron opens the small music-catalog page (I2 earlier).
    let freeMusic: [LibraryItem]
    let classical: [LibraryItem]
    /// The visible reason when the enabled Jamendo half stayed empty.
    var freeMusicProblem: String? = nil
    @State private var detailItem: LibraryItem?

    var body: some View {
        Group {
            if !classical.isEmpty || !freeMusic.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    RowHeading.entry("Discover · Music",
                                     destination: MusicRoute.freeCatalogArea)
                        .accessibilityIdentifier("home-discover-music")
                    // The start surface and the music tab draw from the
                    // same pot. The start surface orders it with ITS OWN
                    // seed, so the two rows do not show the same titles in
                    // the same order. Stability within a session stays, the
                    // twin forming goes.
                    tileRow(items: HomeSections.interleave(
                        [CatalogMix.ordered(classical, for: .musicHome),
                         CatalogMix.ordered(freeMusic, for: .musicHome)],
                        limit: RowPreview.limit))
                    if freeMusic.isEmpty, let problem = freeMusicProblem {
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                }
            } else if let problem = freeMusicProblem {
                // The enabled row appears or says visibly why not.
                // Never a silent absence.
                VStack(alignment: .leading, spacing: 6) {
                    RowHeading.entry("Discover · Music",
                                     destination: MusicRoute.freeCatalogArea)
                        .accessibilityIdentifier("home-discover-music")
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
        }
        .sheet(item: $detailItem) { item in
            FreeCatalogDetailSheet(item: item, playerCoordinator: playerCoordinator)
                .followsAppearanceChoice()
        }
    }

    private func tileRow(items: [LibraryItem]) -> some View {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        // Tap convention: the tap answers "what is that?", the
                        // sheet's prominent Play answers "hear it" one tap
                        // later. Long-press keeps Play as the shortcut.
                        FreeCatalogBookTile(
                            item: item,
                            placeholderSystemImage: item.id.hasPrefix(FreeCatalog.jamendoPrefix)
                                ? "music.note" : "book.closed",
                            onTap: { detailItem = item }
                        )
                        .cardRowSlot(spacing: 14)
                        .contextMenu {
                            Button {
                                Task { await playerCoordinator.open(item: item) }
                            } label: { Label("Play", systemImage: "play.fill") }
                            Button {
                                detailItem = item
                            } label: { Label("Details", systemImage: "info.circle") }
                        }
                    }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
    }
}

/// The LibriVox import shows its progress where every other
/// download does. In the tile's corner slot, through the SHARED
/// `UnifiedDownloadRing`. Self-observing like `CardDownloadBadge`, so only
/// this small view re-renders per progress tick; nothing at all is drawn
/// while no import runs for THIS item (the corner slot collapses).
struct FreeCatalogImportBadge: View {
    let itemId: String
    @ObservedObject private var importer = LibriVoxImporter.shared
    @ScaledMetric(relativeTo: .subheadline) private var ringSize: CGFloat = 17

    var body: some View {
        if importer.activeBookId == itemId,
           let fraction = LibriVoxImporter.ringFraction(importer.phase) {
            Button { importer.cancel() } label: {
                ZStack {
                    Circle().fill(.black.opacity(0.45))
                        .frame(width: ringSize + 10, height: ringSize + 10)
                    UnifiedDownloadRing(fraction: fraction, lineWidth: 2.5, tint: .white)
                        .frame(width: ringSize, height: ringSize)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Cancel Download"))
        }
    }
}

/// License/details sheet: public-domain badge for LibriVox/archive items;
/// Jamendo carries the ToS-mandated artist credit, "via Jamendo" and the
/// DIRECT backlink to the track page.
struct FreeCatalogDetailSheet: View {
    @Environment(\.catalogFacts) private var catalogFacts
    @Environment(\.itemRouter) private var router
    let item: LibraryItem
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss
    /// The metadata API's item description (archive items resolve it
    /// lazily from the SAME metadata endpoint the detail path uses. No new
    /// API); collapsed after a few lines like the book descriptions.
    @State private var itemDescription: String?
    @State private var descriptionExpanded = false

    private var isJamendo: Bool { item.id.hasPrefix(FreeCatalog.jamendoPrefix) }
    private var jamendoTrack: JamendoTrack? {
        catalogFacts.jamendoTrack(item.id)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Thumb first, hi-res swapped in once resolved
                // (soft crossfade; ImageCache persists both).
                CachedAsyncImage(url: router.coverURL(item.id)) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                        .overlay(Image(systemName: isJamendo ? "music.note" : "book.closed")
                            .font(.largeTitle).foregroundStyle(.secondary))
                }
                .frame(maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(spacing: 4) {
                    Text(item.title).font(.headline).multilineTextAlignment(.center)
                    if let author = item.author {
                        Text(author).font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                if isJamendo {
                    // ToS: artist credit + provider credit + direct backlink.
                    VStack(spacing: 6) {
                        Label("Creative Commons, via Jamendo", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.secondary)
                        if let share = jamendoTrack?.shareurl.flatMap({ URL(string: $0) }) {
                            Link(destination: share) {
                                Label("View on Jamendo", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        // Rights capsule + backlink: the ONE shared component
                        // (the book detail page carries the same one).
                        CatalogRightsSection(item: item)
                        // The item description, below the rights capsule.
                        // HTML remnants cleaned by the ONE existing text
                        // preparation (podcastPlainText); collapsed
                        // after four lines, tap expands.
                        if let itemDescription, !itemDescription.isEmpty {
                            Text(podcastPlainText(itemDescription))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(descriptionExpanded ? nil : 4)
                                .fixedSize(horizontal: false, vertical: true)
                                .onTapGesture { descriptionExpanded.toggle() }
                        }
                    }
                }

                Button {
                    dismiss()
                    Task { await playerCoordinator.open(item: item) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Spacer(minLength: 0)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            // The description reaches the sheet. Known metadata first
            // (LibriVox/Gutenberg rows carry it); archive items ask the ONE
            // metadata endpoint (same call class as runtime/hi-res).
            itemDescription = item.media?.metadata?.description
            // The sub-path instead of the full fetch: the sheet wants the
            // description, not the file list.
            if itemDescription == nil,
               case .found(let meta) = await ArchiveMetadataLoader.quickMetadata(forItemId: item.id) {
                itemDescription = meta.description?.joined
            }
        }
    }

}
