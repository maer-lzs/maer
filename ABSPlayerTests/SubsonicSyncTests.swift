#if canImport(Testing)
import Testing
import Foundation
@testable import ABSPlayer

/// Y37: availability must dispatch dynamically through the provider list.
@MainActor
struct SubsonicSyncTests {
    @Test("Y37 trap: isAvailable dispatches through `any AudioProvider`")
    func availabilityDispatchesDynamically() {
        let stored = AppStorageKeys.subsonicEnabledValue
        defer { AppStorageKeys.subsonicEnabledValue = stored }
        // With the source switched OFF the concrete implementation says false.
        // Before isAvailable was a protocol REQUIREMENT, the existential bound
        // statically to the extension default (true) — this test pinned it.
        AppStorageKeys.subsonicEnabledValue = false
        let provider: any AudioProvider = SubsonicProvider.shared
        #expect(provider.isAvailable == false)
    }
}
#endif
