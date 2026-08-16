// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// P3.2 (iPad round): THE access-form fields. Six forms (Audiobookshelf,
/// Subsonic, Jellyfin, gpodder, Pinchflat, premium feed login) carried the
/// same modifier stacks as copies — four of them complete, Pinchflat and the
/// feed login without any `textContentType` at all, which is exactly why no
/// password manager offered to fill or save there.
///
/// One parameterised set instead of six copies (Regel 2): the QuickType bar
/// and the "save password?" prompt come from the content types, so getting
/// them right in ONE place gets them right everywhere — including Bitwarden
/// and any other manager, which read the same system hints as the keychain.
///
/// Secrets always use `SecureField` + `.password` — TOKENS too: a manager
/// can only offer to store what it recognises as a credential, and a route
/// token is exactly as worth storing as a password.
enum CredentialField {
    /// Server address — URL keyboard, no autocorrect, `.URL` content type.
    ///
    /// d990695: with a `service` it also offers the KNOWN addresses below the
    /// field. Deliberately below and as its own control: the QuickType bar
    /// belongs to the password managers, and the address is the part they do
    /// not carry.
    static func serverURL(_ title: LocalizedStringKey, text: Binding<String>,
                          id: String? = nil,
                          service: KnownServer.Service? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: text)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(id ?? "credential-url")
            if let service {
                KnownServerSuggestions(service: service, text: text)
            }
        }
    }

    static func username(_ title: LocalizedStringKey, text: Binding<String>,
                         id: String? = nil) -> some View {
        TextField(title, text: text)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(id ?? "credential-username")
    }

    /// Password, API key, route token — everything secret takes this one.
    static func secret(_ title: LocalizedStringKey, text: Binding<String>,
                       id: String? = nil) -> some View {
        SecureField(title, text: text)
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(id ?? "credential-secret")
    }
}


/// The suggestion row under a server field — own service type first, the
/// other known addresses below (their value is the domain family). A tap
/// fills the field; removing is a LONG PRESS, never automatic (P5 lesson:
/// an outage is not a reason to delete).
struct KnownServerSuggestions: View {
    let service: KnownServer.Service
    @Binding var text: String
    @State private var entries: [KnownServer] = []

    var body: some View {
        if !entries.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(entries) { entry in
                        Button {
                            text = entry.url
                        } label: {
                            Text(verbatim: entry.url)
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(.quaternary))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                KnownServers.forget(entry)
                                entries = KnownServers.suggestions(for: service)
                            } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }
            }
            .accessibilityIdentifier("known-server-suggestions")
        }
    }

    init(service: KnownServer.Service, text: Binding<String>) {
        self.service = service
        self._text = text
        self._entries = State(initialValue: KnownServers.suggestions(for: service))
    }
}
