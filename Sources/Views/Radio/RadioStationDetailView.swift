// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// Teil 1: the station detail page. Reached from a station's context menu
/// ("Station Details") — the tap itself still plays directly (F3), this is the
/// opt-in surface for the info and the codec/bitrate variant picker. The choice
/// persists per station (RadioStore) and the next play (and the live-player
/// quality menu) honor it.
struct RadioStationDetailView: View {
    let station: RadioStation
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    /// The currently selected variant stream (persisted); defaults to the best.
    @State private var selectedURL: String = ""
    @State private var isFavorite = false
    /// Similar stations (byTag of the first tag, else the station's
    /// country) — net-gated, empty hides the row.
    @State private var similar: [RadioStation] = []

    private var variants: [RadioStation] { station.variantList }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                RadioArtwork(stationID: station.id,
                             faviconURL: station.faviconURL.flatMap { URL(string: $0) },
                             name: station.name, homepage: station.homepage,
                             isHero: true)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .padding(.horizontal)

                VStack(spacing: 6) {
                    Text(station.name).font(.title2).bold().multilineTextAlignment(.center)
                    if let sub = subtitle {
                        Text(sub).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                HStack(spacing: 14) {
                    Button {
                        RadioPlay.play(station, playerCoordinator: playerCoordinator)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!networkMonitor.isConnected)

                    Button {
                        RadioStore.toggleFavorite(station)
                        isFavorite.toggle()
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.headline).frame(width: 48, height: 48)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(isFavorite ? Text("Remove Favorite") : Text("Add Favorite"))
                }
                .padding(.horizontal)

                if variants.count > 1 { variantPicker }

                if let homepage = station.homepage.flatMap({ URL(string: $0) }) {
                    Link(destination: homepage) {
                        Label("Website", systemImage: "safari")
                    }
                    .font(.subheadline)
                }

                factsSection

                // Similar stations — the SAME shared card row as
                // everywhere else; empty/offline hides it.
                if !similar.isEmpty {
                    RadioCardRow(title: String(localized: "Similar Stations"), stations: similar,
                                 playerCoordinator: playerCoordinator)
                }
            }
            .padding(.vertical)
            .bottomBarClearance()
        }
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedURL = RadioStore.selectedVariantURL(for: station) ?? station.streamURL
            isFavorite = RadioStore.isFavorite(station.id)
        }
        .task {
            guard networkMonitor.isConnected, similar.isEmpty, !station.isManual else { return }
            // "similar" used to be the FIRST community tag, worldwide — a
            // German station carrying "chanson" got a Russian top list.
            // Similar means: from the SAME country, sharing tags.
            // The country pool comes first and is ranked by tag overlap; the
            // worldwide tag list only fills when the country yields nothing.
            let stationTags = Set(station.tags.map { $0.lowercased() }.filter { !$0.isEmpty })
            var pool: [RadioStation] = []
            if let cc = station.countryCode, !cc.isEmpty {
                let national = (try? await RadioBrowserClient.byRegion(countryCode: cc, limit: 80)) ?? []
                pool = national
                    .filter { !Set($0.tags.map { $0.lowercased() }).isDisjoint(with: stationTags) }
                if pool.isEmpty { pool = national }
            }
            if pool.isEmpty, let tag = station.tags.first, !tag.isEmpty {
                pool = (try? await RadioBrowserClient.byTag(tag: tag, limit: 20)) ?? []
            }
            // Rank by tag overlap so the closest neighbours lead.
            let ranked = pool
                .filter { $0.id != station.id }
                .sorted {
                    Set($0.tags.map { $0.lowercased() }).intersection(stationTags).count
                        > Set($1.tags.map { $0.lowercased() }).intersection(stationTags).count
                }
            let cleaned = Array(ranked.prefix(10))
            RadioProvider.shared.remember(cleaned)
            similar = cleaned
        }
    }

    /// The station's facts — bitrate/codec of the BEST variant, the
    /// localized country, all tags. Rows appear only with real data.
    @ViewBuilder
    private var factsSection: some View {
        let codec = station.codec ?? variants.first?.codec
        let bitrate = station.bitrate ?? variants.first?.bitrate
        let country = station.countryCode.flatMap {
            Locale.current.localizedString(forRegionCode: $0)
        }
        let tagLine = station.tags.filter { !$0.isEmpty }.joined(separator: ", ")
        if codec != nil || bitrate != nil || country != nil || !tagLine.isEmpty {
            VStack(spacing: 0) {
                if let codec {
                    factRow(String(localized: "Codec"), codec.uppercased())
                }
                if let bitrate, bitrate > 0 {
                    factRow(String(localized: "Bitrate"), "\(bitrate) kbps")
                }
                if let country {
                    factRow(String(localized: "Country"), country)
                }
                if !tagLine.isEmpty {
                    factRow(String(localized: "Tags"), tagLine)
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .padding(.horizontal)
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.horizontal).padding(.vertical, 10)
    }

    /// Codec/bitrate chooser — the default (best) is marked, the choice persists.
    private var variantPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quality").font(.headline).padding(.horizontal)
            VStack(spacing: 0) {
                ForEach(Array(variants.enumerated()), id: \.element.id) { index, variant in
                    Button {
                        selectedURL = variant.streamURL
                        RadioStore.setSelectedVariant(variant.streamURL, for: station)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(variant.qualityLabel).foregroundStyle(.primary)
                                if index == 0 {
                                    Text("Best").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if variant.streamURL == selectedURL {
                                Image(systemName: "checkmark").foregroundStyle(AppTheme.accent)
                            }
                        }
                        .padding(.horizontal).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < variants.count - 1 { Divider().padding(.leading) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .padding(.horizontal)
            Text("Applies the next time you play this station.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let cc = station.countryCode, !cc.isEmpty { parts.append(cc.uppercased()) }
        if let tag = station.tags.first { parts.append(tag) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
