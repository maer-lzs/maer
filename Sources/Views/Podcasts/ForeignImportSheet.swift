// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UniformTypeIdentifiers

/// The ONE file picker of every file-based source, the preview sheet and
/// the read-failure alert, as one modifier on the page that hosts the
/// import buttons. A view carries a single file picker presentation:
/// with three `.fileImporter` modifiers on one view only the last one
/// ever opened, so the buttons set the source and this decides the
/// accepted types from it.
struct ForeignImportEntries: ViewModifier {
    /// The source whose picker is open; nil while none is.
    @Binding var pickerSource: ForeignSource?
    @Binding var pending: PendingForeignImport?
    @Binding var message: String?
    let onPick: (Result<[URL], Error>, ForeignSource) -> Void
    /// The source the open picker was built for. The completion may run
    /// after the presentation flag has already dropped the source, so it
    /// reads this copy, never the binding.
    @State private var openedFor: ForeignSource = .opml

    static func allowedTypes(for source: ForeignSource) -> [UTType] {
        switch source {
        case .opml: [UTType(filenameExtension: "opml") ?? .xml, .xml]
        case .applePodcasts: [UTType(filenameExtension: "sqlite") ?? .database, .database, .data]
        case .antennaPod: [UTType(filenameExtension: "db") ?? .database, .database, .data]
        }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: pickerSource) { _, source in
                if let source { openedFor = source }
            }
            .fileImporter(
                isPresented: Binding(get: { pickerSource != nil },
                                     set: { if !$0 { pickerSource = nil } }),
                allowedContentTypes: Self.allowedTypes(for: pickerSource ?? openedFor),
                allowsMultipleSelection: false
            ) { onPick($0, openedFor) }
            .sheet(item: $pending) { pending in
                ForeignImportSheet(pending: pending)
            }
            .task {
                // The harness hands a read library in directly; the file
                // picker cannot be driven from a journey.
                if pending == nil, let seeded = UITestSeed.foreignImportLibrary {
                    pending = PendingForeignImport(source: .opml, library: seeded)
                }
            }
            .alert("Import", isPresented: Binding(
                get: { message != nil },
                set: { if !$0 { message = nil } }
            )) {
                Button("OK", role: .cancel) { message = nil }
            } message: {
                if let message { Text(message) }
            }
    }
}

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
        case .antennaPod: "AntennaPod"
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
        case .antennaPod:
            "AntennaPod's database carries subscriptions, positions, played marks and when an episode last played. An episode marked played by hand carries no moment and only fills gaps. A newer state wins; a finished episode stays finished."
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
