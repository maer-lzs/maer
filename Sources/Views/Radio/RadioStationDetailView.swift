// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The station detail page. Reached from a station's context menu
/// ("Station Details"). The tap itself still plays directly, this is the
/// opt-in surface for the info and the codec/bitrate variant picker. The choice
/// persists per station (RadioStore) and the next play (and the live-player
/// quality menu) honor it.
struct RadioStationDetailView: View {
    let station: RadioStation
    @ObservedObject var playerCoordinator: PlayerCoordinator
    @Environment(\.isOnline) private var isOnline

    /// The currently selected variant stream (persisted); defaults to the best.
    @State private var selectedURL: String = ""
    @State private var isFavorite = false
    /// Similar stations (byTag of the first tag, else the station's
    /// country). Net-gated, empty hides the row.
    @State private var similar: [RadioStation] = []
    /// The link on maer.fm for this station; nil when it is not shared.
    @State private var shareOffer: SharedLinkOffer?

    /// The station's streams, at least its own.
    private var variants: [RadioStation] { station.streamVariants }

    var body: some View {
        // In a wide window the head stands beside the station's facts,
        // divided at the fold (`DetailScrollColumns`).
        DetailScrollColumns(spacing: 20) {
            // In one column the station's picture is a wide banner across
            // the page; in the leading column a square as large as the room
            // allows.
            DetailHeader(title: station.name, textInset: 16) { side in
                RadioArtwork(stationID: station.id,
                             faviconURL: station.faviconURL.flatMap { URL(string: $0) },
                             name: station.name, homepage: station.homepage,
                             isHero: true)
                    .frame(maxWidth: side ?? .infinity)
                    .frame(height: side ?? 220)
                    .coverCard()
                    .padding(.horizontal, side == nil ? 16 : 0)
            } lines: {
                if let sub = subtitle {
                    Text(sub).font(.subheadline).foregroundStyle(.secondary)
                }
            } actions: {
                stationControls
            }
        } content: {
            VStack(spacing: 20) {
                streamsSection

                if let homepage = station.homepage.flatMap({ URL(string: $0) }) {
                    DetailLinkRow {
                        Link(destination: homepage) {
                            Label("Website", systemImage: "safari")
                        }
                    }
                }

                factsSection

                // Similar stations. The SAME shared card row as
                // everywhere else; empty/offline hides it.
                if !similar.isEmpty {
                    RadioCardRow(title: String(localized: "Similar Stations"), stations: similar,
                                 playerCoordinator: playerCoordinator)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .untitledDetailPage()
        .pageActions("station-actions", shown: shareOffer != nil) {
            if let shareOffer { SharedLinkButton(offer: shareOffer, title: station.name) }
        }
        .sharedLink(SharedLink.content(station: station), cover: station.faviconURL.flatMap { URL(string: $0) },
                    to: $shareOffer)
        .onAppear {
            selectedURL = RadioStore.selectedVariantURL(for: station) ?? station.streamURL
            isFavorite = RadioStore.isFavorite(station.id)
        }
        .task {
            guard isOnline, similar.isEmpty, !station.isManual else { return }
            // "similar" used to be the FIRST community tag, worldwide. A
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

    /// Play and the favourite star, under the station's name.
    private var stationControls: some View {
        HStack(spacing: 14) {
            DetailMainButton(title: String(localized: "Play"), systemImage: "play.fill") {
                RadioPlay.play(station, playerCoordinator: playerCoordinator)
            }
            .disabled(!isOnline)

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
    }

    /// The station's facts beside its streams: the localized country, the
    /// languages, all tags. Rows appear only with real data.
    @ViewBuilder
    private var factsSection: some View {
        let country = station.countryCode.flatMap {
            Locale.current.localizedString(forRegionCode: $0)
        }
        let languages = (station.languageCodes ?? [])
            .map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            .joined(separator: ", ")
        let tagLine = station.tags.filter { !$0.isEmpty }.joined(separator: ", ")
        if country != nil || !languages.isEmpty || !tagLine.isEmpty {
            VStack(spacing: 0) {
                if let country {
                    factRow(String(localized: "Country"), country)
                }
                if !languages.isEmpty {
                    factRow(String(localized: "Language"), languages)
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

    /// The station's streams, always at least one, each with format,
    /// bitrate and serving host as far as known. With alternatives the rows
    /// choose the stream the next play takes, the best is marked and the
    /// choice persists; a single stream is listed, not chosen.
    private var streamsSection: some View {
        let choosable = variants.count > 1
        return VStack(alignment: .leading, spacing: 8) {
            Text("Streams").font(.headline).padding(.horizontal)
            VStack(spacing: 0) {
                // Keyed by address, like the folding and the choice: two
                // answers can give one id two addresses.
                ForEach(Array(variants.enumerated()), id: \.element.streamURL) { index, variant in
                    if choosable {
                        Button {
                            selectedURL = variant.streamURL
                            RadioStore.setSelectedVariant(variant.streamURL, for: station)
                        } label: {
                            streamRow(variant, isBest: index == 0,
                                      isSelected: variant.streamURL == selectedURL)
                        }
                        .buttonStyle(.plain)
                    } else {
                        streamRow(variant, isBest: false, isSelected: false)
                    }
                    if index < variants.count - 1 { Divider().padding(.leading) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06)))
            .padding(.horizontal)
            if choosable {
                Text("Applies the next time you play this station.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
        }
    }

    private func streamRow(_ stream: RadioStation, isBest: Bool, isSelected: Bool) -> some View {
        let detail = [isBest ? String(localized: "Best") : nil, stream.streamHost]
            .compactMap { $0 }
            .joined(separator: " · ")
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(stream.qualityLabel).foregroundStyle(.primary)
                if !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(AppTheme.accent)
            }
        }
        .padding(.horizontal).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let cc = station.countryCode, !cc.isEmpty { parts.append(cc.uppercased()) }
        if let tag = station.tags.first { parts.append(tag) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
