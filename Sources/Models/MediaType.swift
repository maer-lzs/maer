import Foundation

/// Inhaltstyp einer Quelle/eines Items — bestimmt, in welchem unteren Tab
/// der Inhalt lebt. Tabs gehen nach TYP, nicht nach Quelle: mehrere Quellen
/// desselben Typs (z. B. Audiobookshelf + lokale Dateien) landen im selben
/// Tab. Podcast/Musik/Radio kommen additiv mit ihren Providern.
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
