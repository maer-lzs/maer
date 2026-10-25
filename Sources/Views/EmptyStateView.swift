// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// What a surface shows when it has nothing to show, or could not load it:
/// the content-unavailable form with a title, its glyph, an optional
/// sentence and optional actions. Title and sentence wrap onto further
/// lines in a narrow column (one column of the open fold) instead of ending
/// in an ellipsis. The bare system view cuts its title two ways: in a list
/// row on iOS 27 it draws the title in one line's height, whatever the line
/// limit, and on iOS 18 a line limit of the container reaches the title. So
/// the texts carry their own height (`fixedSize`, which answers the first)
/// and their own line limit (which answers the second), inside the system
/// view. Every empty state in the views goes through here.
struct EmptyStateView<Actions: View>: View {
    let title: Text
    let systemImage: String
    var description: Text?
    @ViewBuilder var actions: () -> Actions

    init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.init(title: Text(title), systemImage: systemImage, description: description, actions: actions)
    }

    init(title: Text, systemImage: String, description: Text? = nil,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions
    }

    var body: some View {
        ContentUnavailableView {
            Label { title.wrapsInEmptyState() } icon: { Image(systemName: systemImage) }
        } description: {
            if let description { description.wrapsInEmptyState() }
        } actions: {
            actions()
        }
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String, description: Text? = nil) {
        self.init(title, systemImage: systemImage, description: description) { EmptyView() }
    }

    init(title: Text, systemImage: String, description: Text? = nil) {
        self.init(title: title, systemImage: systemImage, description: description) { EmptyView() }
    }
}

private extension Text {
    /// As many lines as the words need at the width given, centred.
    func wrapsInEmptyState() -> some View {
        lineLimit(nil)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
