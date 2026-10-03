// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import Foundation

/// Whether the network can be asked at all, the one question the services'
/// network paths put before a request. In production it is the path
/// monitor's answer. A witness that replaces a service's wire or serves on
/// the loopback must not follow the network of the machine it runs on, so in
/// DEBUG a task-local answer comes first. It reaches only the task that set
/// it and the tasks that task starts, never a neighbouring test.
nonisolated enum Reachability {
    #if DEBUG
    @TaskLocal static var assumed: Bool?
    #endif

    static func isConnected() async -> Bool {
        #if DEBUG
        if let assumed { return assumed }
        #endif
        return await NetworkMonitor.shared.isConnected
    }
}
