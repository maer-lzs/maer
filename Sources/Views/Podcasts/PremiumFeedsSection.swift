// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import Combine

/// THE premium-feed management. ALWAYS visible (an empty section
/// with the manual marking path beats a hidden one: a detection hole used to
/// hide the whole management), grouped by PROVIDER host, URLs
/// masked, one truth (`PodcastSubscriptions.isPremiumFeed` = automatic
/// classes + manual markings) shared with the tab grouping, the badges, the
/// replace dialog and the OPML-export guard. Twin repair on top:
/// free+premium of the same show offer a one-tap cleanup. Progress moves,
/// nothing is deleted without a tap. Mounted on the Podcasts settings pill
/// AND the podcast source page (second access point, one truth).
struct PremiumFeedsSection: View {
    @ObservedObject var subs = PodcastSubscriptions.shared
    @State private var editTarget: PodcastShow?
    @State private var removeTarget: PodcastShow?
    @State private var showMarkPicker = false

    private var premiumShows: [PodcastShow] {
        subs.shows.filter { PodcastSubscriptions.isPremiumFeed($0.feedURL) }
    }

    private var freeShows: [PodcastShow] {
        subs.shows.filter { !PodcastSubscriptions.isPremiumFeed($0.feedURL) }
    }

    /// A→Z instead of subscription order. With 30+ feeds the
    /// stock order is a finger hunt. Locale-aware, case/diacritic folded.
    private var sortedFreeShows: [PodcastShow] {
        freeShows.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Provider grouping: comparable host, alphabetical, stable.
    private var providerGroups: [(host: String, shows: [PodcastShow])] {
        let grouped = Dictionary(grouping: premiumShows) {
            PodcastSubscriptions.feedHost($0.feedURL)
        }
        return grouped.keys.sorted().map { (host: $0, shows: grouped[$0] ?? []) }
    }

    private var twinState: PodcastPremiumMatch.TwinState {
        PodcastPremiumMatch.twinState(
            shows: subs.shows.map { (id: $0.id, title: $0.title, feedURL: $0.feedURL) },
            isPremium: { PodcastSubscriptions.isPremiumFeed($0) })
    }

    private var twins: [PodcastPremiumMatch.Pair] {
        if case .pairs(let pairs) = twinState { return pairs }
        return []
    }

    var body: some View {
        Section {
            // The suppressed state says so instead of showing
            // nothing. A pair on the device with no way to it was the
            // finding, not the missing detection.
            if twinState == .waitingForRotationMerge {
                Label("A free and a premium subscription of the same show were found. The cleanup waits until the changed premium links have been merged — that happens by itself on the next refresh.",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("premium-twin-waiting")
            }
            // Twin repair first. The actionable finding on top.
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

            // The manual escape hatch for unknown URL patterns.
            // Feeds the SAME truth as the automatic detection.
            // A bare iOS menu cannot carry an explaining
            // line. And the owner of the app did not recognise WHAT the
            // list was. So: a sheet with heading + purpose sentence and the
            // plain sorted list, without a new concept.
            if !freeShows.isEmpty {
                Button {
                    showMarkPicker = true
                } label: {
                    Label("Mark a feed as premium", systemImage: "lock.badge.plus")
                        .font(.subheadline)
                }
                .accessibilityIdentifier("premium-mark-menu")
                // The sheet hangs on the ROW, not on the Section.
                // A sheet attached to a Section inside a Form did not open
                // (the new journey caught it on the first run). The row is a
                // stable presentation anchor.
                .sheet(isPresented: $showMarkPicker) {
                    PremiumMarkPicker(shows: sortedFreeShows) { show in
                        PodcastSubscriptions.setManualPremium(true, feedURL: show.feedURL)
                        subs.objectWillChange.send()
                        showMarkPicker = false
                    }
                }
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
        // The feed's own block signal. Honestly "Private", not
        // "Premium": a free UNLISTED feed carries the tag too, and the
        // protective behaviour (export/sync exclusion) is right either way.
        if PodcastSubscriptions.isFeedBlocked(feedURL) {
            return String(localized: "Private")
        }
        if PodcastSubscriptions.isManuallyMarkedPremium(feedURL) {
            return String(localized: "Marked")
        }
        return String(localized: "Members")
    }
}


/// The marking surface explains ITSELF. Heading plus one purpose
/// sentence in the idiom of the existing footnotes, then simply the list.
/// (A menu can carry neither, which is why the menu became a sheet;
/// the picker is the smallest form that works, not a new concept.)
struct PremiumMarkPicker: View {
    let shows: [PodcastShow]
    let onPick: (PodcastShow) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(shows) { show in
                        Button(show.title) { onPick(show) }
                            .accessibilityIdentifier("premium-mark-pick")
                    }
                } footer: {
                    // A sentence instead of a feature. After the
                    // probe showed tokens are per SHOW, the honest help is
                    // "fetch the per-show URL at your provider", not a
                    // provider-wide token store that would not work anyway.
                    Text("Your feeds classified as free — pick one whose premium access the automatic detection missed. Paid feeds usually come as a personal podcatcher URL you copy from your provider's account page and add per show.")
                }
            }
            .navigationTitle("Mark a feed as premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
