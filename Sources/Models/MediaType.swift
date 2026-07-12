import Foundation

/// Content type of a source/item — decides which bottom tab it lives in.
/// Tabs group by type, not source: several sources of the same type
/// (e.g. Audiobookshelf + local files) share one tab.
enum MediaType: String, CaseIterable, Identifiable {
    case audiobooks
    case podcasts
    case music
    case radio

    var id: String { rawValue }

    var label: String {
        switch self {
        case .audiobooks: return String(localized: "Audiobooks")
        case .podcasts: return String(localized: "Podcasts")
        case .music: return String(localized: "Music")
        case .radio: return String(localized: "Radio")
        }
    }

    var systemImage: String {
        switch self {
        case .audiobooks: return "book.closed"
        case .podcasts: return "mic"
        case .music: return "music.note"
        case .radio: return "dot.radiowaves.left.and.right"
        }
    }
}
