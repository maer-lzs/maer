// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI
import UIKit

/// The ONE place for developer diagnostics, reachable only in builds from
/// Xcode (the settings link stands in `#if DEBUG`); no release build shows
/// a diagnostics surface. Diagnostics bound to a surface's own session (the
/// radio logo report reads what THIS session showed) stay at their place,
/// and this page is the index that says where. The book progress diagnosis
/// stands here, for the book playing and the last ones heard. The lever
/// for the derived stores is no diagnostic: it stands in the settings'
/// storage section (`ReloadCatalogDataRow`).
struct DiagnosticsView: View {
    var libraryViewModel: LibraryViewModel?
    var playingID: String?
    @State private var copiedID: String?

    var body: some View {
        Form {
            // The book progress diagnosis: where a book's position could
            // come from and which one the start would take. Diagnostic UI
            // stays verbatim (project convention).
            if let libraryViewModel {
                let books = BookProgressReport.books(libraryViewModel.entries, playingID: playingID)
                if !books.isEmpty {
                    Section {
                        ForEach(books) { entry in
                            Button {
                                UIPasteboard.general.string = BookProgressReport.text(for: entry)
                                copiedID = entry.id
                            } label: {
                                LabeledContent {
                                    Image(systemName: copiedID == entry.id ? "checkmark" : "doc.on.clipboard")
                                } label: {
                                    Text(verbatim: entry.item.title)
                                    if entry.id == playingID { Text(verbatim: "läuft gerade") }
                                }
                            }
                            .accessibilityIdentifier("book-progress-diagnosis-\(entry.id)")
                        }
                    } header: {
                        Text("Book progress diagnosis")
                    } footer: {
                        Text(verbatim: "Antippen legt den Bericht des Buchs in die Zwischenablage.")
                    }
                }
            }

            // MetricKit's numbers of this device: only where the gate let the
            // receiver subscribe (Xcode, TestFlight), never in the App Store.
            if MetricReceiver.isOn {
                Section {
                    NavigationLink { MetricRecordsView() } label: {
                        Label("Measurements", systemImage: "chart.bar.xaxis")
                    }
                    .accessibilityIdentifier("diagnostics-measurements")
                } footer: {
                    Text("MetricKit's daily numbers of this device, kept here for two weeks. Nothing leaves the device unless you share it.")
                }
            }

            #if DEBUG
            // The bookmark measurement for linked folders; debug builds only.
            Section {
                NavigationLink { BookmarkMeasure.Page() } label: { Text(verbatim: "E1-Messung (Lesezeichen)") }
            }
            #endif

            // The index of the diagnostics that live at their surface: they
            // measure what THAT place shows in THIS session, so moving them
            // here would change what they measure.
            Section {
                LabeledContent {
                    Text("Radio tab, below the catalog rows")
                } label: {
                    Text("Station logo & listening report")
                }
                LabeledContent {
                    Text("Settings › Sync History")
                } label: {
                    Text("Sync runs & counters")
                }
            } header: {
                Text("Diagnostics at their place")
            } footer: {
                Text("These read what their surface currently shows; a copy here would measure something else.")
            }
        }
        .navigationTitle(Text("Diagnostics"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
