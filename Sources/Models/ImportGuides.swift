// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// How to bring a listening history from another app: step by step, with
/// the real menu names of that app, and with what comes along and what
/// does not. What a source does not give is not promised (the IM block's
/// rule, word for word). The texts are English keys the view localizes.
nonisolated enum ImportGuide: String, CaseIterable, Identifiable, Sendable {
    case applePodcasts
    case overcast
    case antennaPod
    case pocketCasts
    case otherOPML
    case spotify

    var id: String { rawValue }

    /// What the guide ends in: a file picker, a sign-in, or nothing.
    enum Action: Equatable, Sendable {
        case pickFile(ForeignSource)
        case signIn(ForeignSource)
        case none
    }

    /// What the source carries. Honest per source.
    struct Carries: Equatable, Sendable {
        let subscriptions: Bool
        let positions: Bool
        let playedMarks: Bool
        /// When an episode was heard.
        let moments: Bool
    }

    /// The Mac path of Apple Podcasts' library, checked on a Mac on
    /// 5 September 2026 (the group container carries Apple's team id).
    static let appleLibraryPath = "~/Library/Group Containers/243LU875E5.groups.com.apple.podcasts/Documents"
    static let appleLibraryFile = "MTLibrary.sqlite"

    var title: String {
        switch self {
        case .applePodcasts: return "Apple Podcasts"
        case .overcast: return "Overcast"
        case .antennaPod: return "AntennaPod"
        case .pocketCasts: return "Pocket Casts"
        case .otherOPML: return "Other apps (OPML)"
        case .spotify: return "Spotify"
        }
    }

    var action: Action {
        switch self {
        case .applePodcasts: return .pickFile(.applePodcasts)
        case .overcast, .otherOPML: return .pickFile(.opml)
        case .antennaPod: return .pickFile(.antennaPod)
        case .pocketCasts: return .signIn(.pocketCasts)
        case .spotify: return .none
        }
    }

    var carries: Carries {
        switch self {
        case .applePodcasts, .overcast, .antennaPod:
            return Carries(subscriptions: true, positions: true, playedMarks: true, moments: true)
        case .pocketCasts:
            return Carries(subscriptions: true, positions: true, playedMarks: true, moments: false)
        case .otherOPML:
            return Carries(subscriptions: true, positions: false, playedMarks: false, moments: false)
        case .spotify:
            return Carries(subscriptions: false, positions: false, playedMarks: false, moments: false)
        }
    }

    /// The steps, one line each, in the words of the other app.
    var steps: [String] {
        switch self {
        case .applePodcasts:
            // Quitting comes first: while Podcasts runs, its newest listening
            // states sit in a side file next to the database (measured on a
            // Mac: the side file 12 minutes newer than the database), and the
            // copied database alone does not carry them.
            return [
                "On your Mac, quit Podcasts first: choose Podcasts, then Quit Podcasts.",
                "On your Mac, open the Finder and choose Go, then Go to Folder.",
                "Paste the path below and press Return.",
                "Copy the file MTLibrary.sqlite to this device, for example with AirDrop or iCloud Drive.",
                "Pick the copied file below."
            ]
        case .overcast:
            return [
                "In a browser, sign in at overcast.fm.",
                "Open Account, then Export Your Data.",
                "Choose All data: the OPML that carries your episode progress.",
                "Save the file to this device and pick it below."
            ]
        case .antennaPod:
            return [
                "In AntennaPod open Settings, then Backup & restore.",
                "Choose Database export.",
                "Share the file to this device and pick it below."
            ]
        case .pocketCasts:
            return [
                "Sign in below with your Pocket Casts email and password.",
                "Mär reads your subscriptions and listening states in one pass and shows them before anything is applied."
            ]
        case .otherOPML:
            return [
                "In the other app, export your subscriptions as OPML.",
                "Save the file to this device and pick it below."
            ]
        case .spotify:
            return []
        }
    }

    /// The one sentence about what happens with the Pocket Casts password.
    /// The guide and the sign-in sheet both show it, so it is one key.
    static let pocketCastsPrivacyLine = "Your email and password go to Pocket Casts only and are not stored; nothing runs in the background."

    /// The caveat sentences under the steps, where there are any. Each
    /// sentence is its own catalog key.
    var notes: [String] {
        switch self {
        case .applePodcasts:
            return ["Only a Mac gives this file away; the iPhone does not."]
        case .pocketCasts:
            return ["The interface is unofficial and may stop working.", Self.pocketCastsPrivacyLine]
        case .otherOPML:
            return ["A plain OPML carries subscriptions, not listening progress."]
        case .spotify:
            return ["Spotify offers no export of subscriptions or listening progress, so nothing can be imported from it."]
        default:
            return []
        }
    }
}

/// Which sources an import already brought something from (at least one
/// subscription or state taken over). Measured at the import, not ticked
/// by hand; on this device.
nonisolated enum ImportGuidesDone {
    private static let key = AppStorageKeys.foreignImportsDone

    static func sources() -> Set<String> {
        Set(AppStorageKeys.stringArray(key) ?? [])
    }

    static func mark(_ source: ForeignSource) {
        var done = sources()
        done.insert(source.rawValue)
        AppStorageKeys.set(Array(done).sorted(), for: key)
    }

    static func isDone(_ guide: ImportGuide) -> Bool {
        switch guide.action {
        case .pickFile(let source), .signIn(let source): return sources().contains(source.rawValue)
        case .none: return false
        }
    }

    #if DEBUG
    static func _resetForTest() { AppStorageKeys.remove(key) }
    #endif
}
