// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine
import OSLog

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
                UnifiedDownloadRing(fraction: fraction, lineWidth: 2.5, tint: .white)
                    .frame(width: ringSize, height: ringSize)
                    .padding(5)
                    .glyphDisc()
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
                        .overlay(Image(systemName: MediaFamily.placeholderSymbol(
                            for: item.id, markedForm: ListeningStore.startedForm(item.id)))
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
                        CatalogRightsSection(item: item, licence: catalogFacts.licence(item.id))
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
