// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// "Next steps": the card after the first success (a server connected, or
/// "start without a server"). Two points in this order: attach more
/// sources (the map, ticks at what is connected, and every server's guide
/// in every state), and bring a
/// listening history from another app (one guide per source, the file
/// picker or the sign-in at its end). ONE component, two hosts: the
/// overlay at the start and the entry in the settings.
struct NextStepsView: View {
    /// Where the Audiobookshelf row leads: the login form before a session
    /// exists, the full source page in the settings.
    let absDestination: () -> AnyView

    var body: some View {
        Form {
            Section {
                Text("Available areas are ticked. Every area can be attached later in the settings; nothing has to be set up before listening.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Add more sources")
            }
            SourceMapCard(facts: { .current }) { area in
                AnyView(SourceAreaPage(area: area, absDestination: absDestination))
            }
            ServerGuidesSection()
            ImportGuidesSection()
        }
        .navigationTitle(Text("Next Steps"))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
    }
}

/// The overlay host: the same card in a sheet with a Done button. It stays
/// at every start until it is dismissed; the dismissal is what gets stored.
struct NextStepsSheet: View {
    @ObservedObject var authViewModel: AuthViewModel
    /// The coordinator the source page needs, handed in by the root: the
    /// sheet must not reach for a singleton the settings host gets passed.
    let coordinator: PlayerCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NextStepsView(absDestination: {
                // The same rule the settings host follows: a signed-in
                // person lands on the source page, never on the empty form.
                switch NextStepsRules.absDestination(isLoggedIn: authViewModel.isLoggedIn) {
                case .loginForm:
                    return AnyView(ABSLoginPage(viewModel: authViewModel))
                case .sourcePage:
                    return AnyView(ABSSourceView(coordinator: coordinator, libraryViewModel: nil,
                                                 onLogout: authViewModel.logout))
                }
            })
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .softTopScrollEdge()
    }
}

/// The list of import guides. One row per source, a tick where an import
/// already brought something from it.
struct ImportGuidesSection: View {
    var body: some View {
        Section {
            ForEach(ImportGuide.allCases) { guide in
                NavigationLink {
                    ImportGuidePage(guide: guide)
                } label: {
                    HStack {
                        Text(verbatim: guide.title)
                        Spacer()
                        if ImportGuidesDone.isDone(guide) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text("Imported"))
                        }
                    }
                }
                .accessibilityIdentifier("import-guide-\(guide.rawValue)")
            }
        } header: {
            Text("Bring your listening history")
        } footer: {
            Text("Each guide says what its source carries and how to get its file; nothing is applied before you see the preview.")
        }
    }
}

/// One guide: what comes along, the steps in the other app's words, and
/// the action at the end. The page owns its picker and preview, through
/// the same entries the podcast source page uses.
struct ImportGuidePage: View {
    let guide: ImportGuide

    @State private var pickerSource: ForeignSource?
    @State private var pending: PendingForeignImport?
    @State private var message: String?
    @State private var isReading = false

    var body: some View {
        Form {
            carriesSection
            if !guide.steps.isEmpty {
                Section {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(verbatim: "\(index + 1).")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(LocalizedStringKey(step))
                        }
                    }
                    if guide == .applePodcasts {
                        Text(verbatim: ImportGuide.appleLibraryPath)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("import-guide-apple-path")
                    }
                } header: {
                    Text("Steps")
                } footer: {
                    if let note = Self.noteText(guide.notes) { note }
                }
            } else if let note = Self.noteText(guide.notes) {
                Section { note.foregroundStyle(.secondary) }
            }
            actionSection
        }
        .navigationTitle(Text(verbatim: guide.title))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        .modifier(ForeignImportEntries(
            pickerSource: $pickerSource,
            pending: $pending,
            message: $message,
            onPick: { result, source in
                isReading = true
                Task {
                    let read = await ForeignImportReading.read(result, source: source)
                    pending = read.pending
                    message = read.message
                    isReading = false
                }
            }))
    }

    private var carriesSection: some View {
        Section {
            carriesRow("Subscriptions", guide.carries.subscriptions)
            carriesRow("Positions", guide.carries.positions)
            carriesRow("Played marks", guide.carries.playedMarks)
            carriesRow("When an episode was heard", guide.carries.moments)
        } header: {
            Text("What comes along")
        }
    }

    private func carriesRow(_ title: LocalizedStringKey, _ yes: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: yes ? "checkmark" : "xmark")
                .foregroundStyle(yes ? Color.accentColor : Color.secondary)
                .accessibilityLabel(yes ? Text("Yes") : Text("No"))
        }
    }

    /// The caveat sentences, each its own catalog key, joined with a space.
    /// One sentence can then be shared with another surface without
    /// becoming a second key there.
    static func noteText(_ notes: [String]) -> Text? {
        guard let first = notes.first else { return nil }
        return notes.dropFirst().reduce(Text(LocalizedStringKey(first))) { joined, sentence in
            joined + Text(verbatim: " ") + Text(LocalizedStringKey(sentence))
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        switch guide.action {
        case .pickFile(let source):
            Section {
                Button {
                    pickerSource = source
                } label: {
                    Label("Pick the file", systemImage: "square.and.arrow.down")
                }
                .disabled(isReading)
                .accessibilityIdentifier("import-guide-pick")
                if isReading {
                    HStack { ProgressView(); Text("Importing…").foregroundStyle(.secondary) }
                }
            }
        case .signIn(let source):
            Section {
                Button {
                    pending = PendingForeignImport(source: source, library: nil)
                } label: {
                    Label("Sign in and read", systemImage: "person.crop.circle.badge.checkmark")
                }
                .accessibilityIdentifier("import-guide-sign-in")
            }
        case .none:
            EmptyView()
        }
    }
}
