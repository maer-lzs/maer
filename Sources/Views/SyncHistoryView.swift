// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The persisted sync history (last 50 runs). A plain list. Guard events
/// (mass-delete veto) are permanently marked entries, not transient warnings.
struct SyncHistoryView: View {
    @ObservedObject private var store = SyncHistoryStore.shared

    /// Fixed display order for the "last checked" header.
    private static let checkedOrder: [SyncHistoryEntry.Service] =
        [.absProgress, .music, .gpodder, .iCloud]

    private var checkedRows: [(service: SyncHistoryEntry.Service, date: Date)] {
        Self.checkedOrder.compactMap { service in
            store.lastChecked[service.rawValue].map { (service, $0) }
        }
    }

    var body: some View {
        List {
            // Per-service "last checked". A check that changed nothing
            // (clean ABS flush, live music refresh, no-op gpodder/iCloud) leaves
            // no ring entry but still updates its stamp here.
            if !checkedRows.isEmpty {
                Section {
                    ForEach(checkedRows, id: \.service) { row in
                        HStack {
                            Label(serviceLabel(row.service), systemImage: serviceIcon(row.service))
                                .font(.subheadline)
                            Spacer()
                            Text(row.date.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Last checked")
                }
            }

            Section {
                if store.entries.isEmpty {
                    ContentUnavailableView(
                        "No sync runs yet",
                        systemImage: "arrow.triangle.2.circlepath",
                        description: Text("Sync runs appear here as they happen.")
                    )
                } else {
                    ForEach(store.entries) { entry in
                        row(entry)
                    }
                }
            } header: {
                if !store.entries.isEmpty { Text("Recent changes") }
            }
        }
        .navigationTitle("Sync History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ entry: SyncHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(serviceLabel(entry.service), systemImage: serviceIcon(entry.service))
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(entry.startedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !entry.counters.isEmpty {
                Text(summary(entry.counters))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if entry.duration >= 0.5 {
                Text(Duration.seconds(entry.duration)
                    .formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let guardNote = entry.guardNote {
                Label(guardNote, systemImage: "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            // Possible data loss: name exactly which feeds a sync removed, so a
            // suspected subscription loss is inspectable after the fact.
            if let removed = entry.removedFeeds, !removed.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(removed, id: \.self) { feed in
                        // Y52 defense-in-depth: entries persisted BEFORE the
                        // masking-at-source may still carry raw token URLs.
                        Label(PodcastSubscriptions.maskedFeedURL(feed), systemImage: "minus.circle")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            if let error = entry.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func serviceLabel(_ service: SyncHistoryEntry.Service) -> String {
        switch service {
        case .gpodder: return "gpodder"
        case .absProgress: return "Audiobookshelf"
        case .iCloud: return "iCloud"
        case .music: return String(localized: "Music")
        }
    }

    private func serviceIcon(_ service: SyncHistoryEntry.Service) -> String {
        switch service {
        case .gpodder: return "antenna.radiowaves.left.and.right"
        case .absProgress: return "externaldrive.connected.to.line.below"
        case .iCloud: return "icloud"
        case .music: return "music.note"
        }
    }

    /// "2 subscriptions up, 1,299 positions up". Counters in display order.
    private func summary(_ counters: [SyncHistoryEntry.Counter]) -> String {
        counters.map { counter in
            switch counter.key {
            case .subscriptionsUp:
                return String(localized: "\(counter.value) subscriptions up")
            case .subscriptionsDown:
                return String(localized: "\(counter.value) subscriptions down")
            case .positionsUp:
                return String(localized: "\(counter.value) positions up")
            case .positionsDown:
                return String(localized: "\(counter.value) positions down")
            case .albumsUpdated:
                return String(localized: "\(counter.value) albums updated")
            case .songsUpdated:
                return String(localized: "\(counter.value) songs updated")
            case .subscriptionsRemovedLocally:
                return String(localized: "\(counter.value) subscriptions removed locally")
            case .subscriptionsRemovedFromServer:
                return String(localized: "\(counter.value) subscriptions removed on server")
            case .subscriptionsNeedingSignIn:
                return String(localized: "\(counter.value) feeds need a sign-in")
            case .subscriptionsNotFollowed:
                return String(localized: "\(counter.value) feeds could not be followed")
            }
        }.joined(separator: ", ")
    }
}
