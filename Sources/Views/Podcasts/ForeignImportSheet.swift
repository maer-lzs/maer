// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// A foreign library that has been read but not yet applied. The sheet's
/// item: it exists exactly while the preview is open.
struct PendingForeignImport: Identifiable {
    let id = UUID()
    let source: ForeignSource
    let library: ForeignLibrary
}

/// The one surface for every foreign import: what the file carries,
/// measured, then the result of applying it. Nothing is written before
/// the reader taps Apply, and nothing that fails to match is dropped
/// without a name.
struct ForeignImportSheet: View {
    let pending: PendingForeignImport
    @Environment(\.dismiss) private var dismiss
    @State private var isApplying = false
    @State private var result: PodcastSubscriptions.ImportResult?

    private var preview: ForeignImportPreview {
        let subscribed = Set(PodcastSubscriptions.shared.shows.map { PodcastSubscriptions.feedKey($0.feedURL) })
        return ForeignImportPreview.make(pending.library, subscribedFeedKeys: subscribed,
                                         feedKeyOf: PodcastSubscriptions.feedKey)
    }

    var body: some View {
        NavigationStack {
            List {
                if let result {
                    resultSection(result)
                } else {
                    previewSection
                }
            }
            .accessibilityIdentifier(result == nil ? "foreign-import-preview" : "foreign-import-result")
            .navigationTitle(sourceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }
                        .disabled(isApplying)
                }
                if result == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") { apply() }
                            .disabled(isApplying
                                      || (pending.library.feedURLs.isEmpty && pending.library.states.isEmpty))
                            .accessibilityIdentifier("foreign-import-apply")
                    }
                }
            }
            .interactiveDismissDisabled(isApplying)
        }
    }

    private var sourceName: LocalizedStringKey {
        switch pending.source {
        case .opml: "OPML"
        case .applePodcasts: "Apple Podcasts"
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        let p = preview
        Section {
            LabeledContent("Shows", value: "\(p.shows)")
            if p.alreadySubscribed > 0 {
                LabeledContent("Already subscribed", value: "\(p.alreadySubscribed)")
            }
            if p.unimportablePaid > 0 {
                LabeledContent("Paid, no public feed", value: "\(p.unimportablePaid)")
            }
        } header: {
            Text("Subscriptions")
        }
        Section {
            if p.states == 0 {
                Text("This file carries no listening states.")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Episodes with a state", value: "\(p.states)")
                LabeledContent("Finished", value: "\(p.finished)")
                LabeledContent("In progress", value: "\(p.inProgress)")
                LabeledContent("With the source's own moment", value: "\(p.withMoment)")
            }
        } header: {
            Text("Listening states")
        } footer: {
            Text(sourceNote)
        }
        if isApplying {
            Section {
                HStack { ProgressView(); Text("Importing…").foregroundStyle(.secondary) }
            }
        }
    }

    /// What the format can carry, so the reader knows what not to expect.
    private var sourceNote: LocalizedStringKey {
        switch pending.source {
        case .opml:
            "A plain OPML carries subscriptions only. Overcast's extended OPML also carries positions, played marks and when they were recorded. A state without a moment only fills gaps; a newer one wins; a finished episode stays finished."
        case .applePodcasts:
            "Apple's database carries subscriptions, positions, played marks and when they were recorded. A newer state wins; a finished episode stays finished."
        }
    }

    @ViewBuilder
    private func resultSection(_ r: PodcastSubscriptions.ImportResult) -> some View {
        Section {
            LabeledContent("Subscriptions imported", value: "\(r.subscribed)")
            if r.failed > 0 {
                LabeledContent("Feeds not loadable", value: "\(r.failed)")
            }
            if r.paidSkipped > 0 {
                LabeledContent("Paid, no public feed", value: "\(r.paidSkipped)")
            }
            if r.freeTwinsSkipped > 0 {
                LabeledContent("Free feeds skipped, subscribed as premium", value: "\(r.freeTwinsSkipped)")
            }
        } header: {
            Text("Subscriptions")
        }
        if pending.library.states.isEmpty == false {
            Section {
                LabeledContent("Episodes with progress", value: "\(r.progressApplied)")
                    .accessibilityIdentifier("foreign-import-applied")
                    .accessibilityValue("\(r.progressApplied)")
                if r.keptLocal > 0 {
                    LabeledContent("Kept, this device knew better", value: "\(r.keptLocal)")
                }
            } header: {
                Text("Listening states")
            }
            if !r.unmatched.isEmpty {
                Section {
                    ForEach(Array(r.unmatched.prefix(40).enumerated()), id: \.offset) { _, title in
                        Text(verbatim: title).font(.footnote)
                    }
                    if r.unmatched.count > 40 {
                        Text("and \(r.unmatched.count - 40) more")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Not matched to any episode: \(r.unmatched.count)")
                } footer: {
                    Text("These states name no episode of the subscribed shows. Nothing was written for them.")
                }
            }
        }
    }

    private func apply() {
        isApplying = true
        Task {
            result = await PodcastSubscriptions.shared.importForeignLibrary(pending.library)
            isApplying = false
        }
    }
}
