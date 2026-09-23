// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// The network questions of the free catalogues, one seam per client, shared
/// by every loader that asks that client. Each `live` seam calls the static
/// client function with exactly the arguments the loaders passed before,
/// defaults spelled out; a witness hands in its own and runs a loader
/// without the network.
nonisolated struct ArchiveSeam: Sendable {
    var popularLibriVoxByLanguage: @Sendable (_ rowsPerLanguage: Int, _ languageCodes: [String],
                                              _ limit: Int, _ page: Int) async throws -> [ArchivePopularDoc]
    var audiobooksOutsideLibriVox: @Sendable (_ rows: Int, _ languageCodes: [String], _ page: Int,
                                              _ unfiltered: Bool) async throws -> (docs: [ArchivePopularDoc], unfiltered: Bool)
    var popularOldTimeRadio: @Sendable (_ rows: Int, _ page: Int) async throws -> [ArchivePopularDoc]
    var popularMusic: @Sendable (_ area: ArchiveMusicArea, _ rows: Int, _ page: Int) async throws -> [ArchivePopularDoc]
    var popularArchiveMusic: @Sendable (_ query: String, _ rows: Int, _ page: Int) async throws -> [ArchivePopularDoc]
    var metadataOnly: @Sendable (_ identifier: String) async throws -> ArchiveOrgClient.MetadataResponse.Meta?
    var liveness: @Sendable (_ identifier: String) async -> DeadCatalogItems.Liveness

    static let live = ArchiveSeam(
        popularLibriVoxByLanguage: {
            try await ArchiveOrgClient.popularLibriVoxByLanguage(rowsPerLanguage: $0, languageCodes: $1,
                                                                 limit: $2, page: $3)
        },
        audiobooksOutsideLibriVox: {
            try await ArchiveOrgClient.audiobooksOutsideLibriVox(rows: $0, languageCodes: $1,
                                                                 page: $2, unfiltered: $3)
        },
        popularOldTimeRadio: { try await ArchiveOrgClient.popularOldTimeRadio(rows: $0, page: $1) },
        popularMusic: { try await ArchiveOrgClient.popularMusic(area: $0, rows: $1, page: $2) },
        popularArchiveMusic: { try await ArchiveOrgClient.popularArchiveMusic(query: $0, rows: $1, page: $2) },
        metadataOnly: { try await ArchiveOrgClient.metadataOnly(identifier: $0) },
        liveness: { await ArchiveOrgClient.liveness(identifier: $0) })
}

nonisolated struct JamendoSeam: Sendable {
    var popularTracks: @Sendable (_ limit: Int, _ tags: [String], _ offset: Int,
                                  _ filter: JamendoFilter) async throws -> [JamendoTrack]
    /// Whether this build carries a Jamendo key. No network, but it decides
    /// whether the row asks at all, so a witness sets it too.
    var clientId: @MainActor @Sendable () -> String?

    static let live = JamendoSeam(
        popularTracks: { try await JamendoClient.popularTracks(limit: $0, tags: $1, offset: $2, filter: $3) },
        clientId: { JamendoClient.clientId() })
}

nonisolated struct GutenbergSeam: Sendable {
    var audiobooks: @Sendable (_ languages: [String], _ page: Int) async throws -> [GutenbergClient.Book]

    static let live = GutenbergSeam(
        audiobooks: { try await GutenbergClient.audiobooks(languages: $0, page: $1) })
}

nonisolated struct LibriVoxSeam: Sendable {
    var newBooks: @Sendable (_ sinceDays: Int, _ limit: Int) async throws -> [LibriVoxBook]

    static let live = LibriVoxSeam(
        newBooks: { try await LibriVoxClient.newBooks(sinceDays: $0, limit: $1) })
}

/// All four seams, as one argument for every catalogue loader.
nonisolated struct CatalogClients: Sendable {
    var archive: ArchiveSeam
    var jamendo: JamendoSeam
    var gutenberg: GutenbergSeam
    var librivox: LibriVoxSeam

    static let live = CatalogClients(archive: .live, jamendo: .live, gutenberg: .live, librivox: .live)
}

/// What the loaders read from the settings before they ask: which sources
/// are on, and in which languages. Read at the moment a load starts; a
/// witness hands in fixed values instead of depending on the test host's
/// settings.
nonisolated struct CatalogGates: Sendable {
    var librivox: Bool
    var archiveBooks: Bool
    var gutenberg: Bool
    var jamendo: Bool
    var freeAudiobooksArea: Bool
    var freeClassical: Bool
    var netlabels: Bool
    var languages: [String]

    @MainActor static var live: CatalogGates {
        CatalogGates(librivox: AppStorageKeys.librivoxActive,
                     archiveBooks: AppStorageKeys.archiveBooksActive,
                     gutenberg: AppStorageKeys.gutenbergSourceActive,
                     jamendo: AppStorageKeys.jamendoActive,
                     freeAudiobooksArea: AppStorageKeys.freeAudiobooksAreaActive,
                     freeClassical: AppStorageKeys.freeClassicalActive,
                     netlabels: AppStorageKeys.netlabelsActive,
                     languages: SuggestionLanguages.current())
    }
}
