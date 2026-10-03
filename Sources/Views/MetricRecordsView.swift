// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// MetricKit's records of this device, newest first, each with its one log
/// line, and the whole list shareable as text. Reached only where the gate
/// let the receiver subscribe (`MetricReceiver.isOn`).
struct MetricRecordsView: View {
    /// Where the records come from; the kept ones of this device unless a
    /// drawing hands in its own.
    var load: @MainActor () async -> MetricLog.Reading = { await MetricReceiver.records() }
    @State private var records: [MetricRecord] = []
    @State private var loaded = false
    @State private var unreadable = false

    var body: some View {
        List {
            if loaded && unreadable {
                Text("The kept measurements could not be read and were set aside. New ones come about once a day.")
                    .foregroundStyle(.secondary)
            } else if loaded && records.isEmpty {
                Text("No measurements yet. MetricKit delivers them about once a day.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(records.sorted { $0.end > $1.end }.enumerated()), id: \.offset) { _, record in
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.end, format: .dateTime.day().month().hour().minute())
                    Text(verbatim: record.logLine)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(Text("Measurements"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !records.isEmpty {
                ShareLink(item: MetricRecord.shareText(records))
                    .accessibilityIdentifier("metric-records-share")
            }
        }
        .task {
            switch await load() {
            case .records(let kept): records = kept
            case .unreadable: unreadable = true
            }
            loaded = true
        }
    }
}
