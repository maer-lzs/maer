// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import Combine

/// 92e25d6: THE premium-feed management — ALWAYS visible (an empty section
/// with the manual marking path beats a hidden one: a detection hole used to
/// hide the whole management, 7dba2b1), grouped by PROVIDER host, URLs
/// masked, one truth (`PodcastSubscriptions.isPremiumFeed` = automatic
/// classes + manual markings) shared with the tab grouping, the badges, the
/// replace dialog and the OPML-export guard. Twin repair on top (97b1f7c):
/// free+premium of the same show offer a one-tap cleanup — progress moves,
/// nothing is deleted without a tap. Mounted on the Podcasts settings pill
/// AND the podcast source page (second access point, one truth).
struct PremiumFeedsSection: View {
    @ObservedObject var subs = PodcastSubscriptions.shared
    @State private var editTarget: PodcastShow?
    @State private var removeTarget: PodcastShow?

    private var premiumShows: [PodcastShow] {
        subs.shows.filter { PodcastSubscriptions.isPremiumFeed($0.feedURL) }
    }

    private var freeShows: [PodcastShow] {
        subs.shows.filter { !PodcastSubscriptions.isPremiumFeed($0.feedURL) }
    }

    /// Provider grouping: comparable host, alphabetical, stable.
    private var providerGroups: [(host: String, shows: [PodcastShow])] {
        let grouped = Dictionary(grouping: premiumShows) {
            PodcastSubscriptions.feedHost($0.feedURL)
        }
        return grouped.keys.sorted().map { (host: $0, shows: grouped[$0] ?? []) }
    }

    private var twins: [(freeId: String, premiumId: String, title: String)] {
        PodcastPremiumMatch.twins(
            shows: subs.shows.map { (id: $0.id, title: $0.title, feedURL: $0.feedURL) },
            isPremium: { PodcastSubscriptions.isPremiumFeed($0) })
    }

    var body: some View {
        Section {
            // 97b1f7c: twin repair first — the actionable finding on top.
            ForEach(twins, id: \.freeId) { twin in
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(twin.title) exists as a free AND a premium subscription.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                    Button("Remove free subscription — progress moves over") {
                        subs.replaceFreeWithPremium(PremiumReplacementOffer(
                            freeShowId: twin.freeId, premiumShowId: twin.premiumId,
                            showTitle: twin.title))
                    }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("premium-twin-cleanup")
                }
            }

            if premiumShows.isEmpty {
                Text("No premium feeds yet. Feeds with a login, an access token in the URL or a members host are detected automatically — or mark one manually below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(providerGroups, id: \.host) { group in
                if providerGroups.count > 1 || !group.host.isEmpty {
                    Text(verbatim: group.host)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                ForEach(group.shows) { show in
                    row(show)
                }
            }

            // 7dba2b1: the manual escape hatch for unknown URL patterns —
            // feeds the SAME truth as the automatic detection.
            if !freeShows.isEmpty {
                Menu {
                    ForEach(freeShows) { show in
                        Button(show.title) {
                            PodcastSubscriptions.setManualPremium(true, feedURL: show.feedURL)
                            subs.objectWillChange.send()
                        }
                    }
                } label: {
                    Label("Mark a feed as premium", systemImage: "lock.badge.plus")
                        .font(.subheadline)
                }
                .accessibilityIdentifier("premium-mark-menu")
            }
        } header: {
            Label("Premium Feeds", systemImage: "lock.fill")
        } footer: {
            Text("Token feeds carry their access in the URL — they are never shown unmasked, never synced to a gpodder server and left out of OPML exports by default.")
        }
        .sheet(item: $editTarget) { show in
            PremiumFeedEditor(show: show)
        }
        .confirmationDialog(
            Text("Remove \(removeTarget?.title ?? "")?"),
            isPresented: Binding(get: { removeTarget != nil },
                                 set: { if !$0 { removeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Unsubscribe", role: .destructive) {
                if let show = removeTarget { subs.unsubscribe(id: show.id) }
                removeTarget = nil
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        }
    }

    private func row(_ show: PodcastShow) -> some View {
        Button {
            editTarget = show
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(show.title).lineLimit(1)
                    Spacer()
                    Text(Self.classLabel(show.feedURL))
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Text(PodcastSubscriptions.maskedFeedURL(show.feedURL))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if PodcastSubscriptions.isManuallyMarkedPremium(show.feedURL) {
                Button {
                    PodcastSubscriptions.setManualPremium(false, feedURL: show.feedURL)
                    subs.objectWillChange.send()
                } label: { Label("Remove premium marking", systemImage: "lock.slash") }
            }
            Button(role: .destructive) {
                removeTarget = show
            } label: { Label("Unsubscribe", systemImage: "trash") }
        }
    }

    /// One class label for management rows (moved here from the source page).
    static func classLabel(_ feedURL: String) -> String {
        if PodcastFeedAuth.hasCredentials(feedKey: PodcastSubscriptions.feedKey(feedURL)) {
            return String(localized: "Login")
        }
        if PodcastSubscriptions.isTokenFeedURL(feedURL) {
            return String(localized: "Token URL")
        }
        if PodcastSubscriptions.isManuallyMarkedPremium(feedURL) {
            return String(localized: "Marked")
        }
        return String(localized: "Members")
    }
}
