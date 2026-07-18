import SwiftUI

/// F9: the persisted sync history (last 50 runs) — a plain list. Guard events
/// (mass-delete veto) are permanently marked entries, not transient warnings.
struct SyncHistoryView: View {
    @ObservedObject private var store = SyncHistoryStore.shared

    var body: some View {
        List {
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
        }
    }

    private func serviceIcon(_ service: SyncHistoryEntry.Service) -> String {
        switch service {
        case .gpodder: return "antenna.radiowaves.left.and.right"
        case .absProgress: return "externaldrive.connected.to.line.below"
        case .iCloud: return "icloud"
        }
    }

    /// "2 subscriptions up, 1,299 positions up" — counters in display order.
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
            }
        }.joined(separator: ", ")
    }
}
