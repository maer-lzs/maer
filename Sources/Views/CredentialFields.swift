// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// THE access-form fields. Six forms (Audiobookshelf,
/// Subsonic, Jellyfin, gpodder, Pinchflat, premium feed login) carried the
/// same modifier stacks as copies. Four of them complete, Pinchflat and the
/// feed login without any `textContentType` at all, which is exactly why no
/// password manager offered to fill or save there.
///
/// One parameterised set instead of six copies: the QuickType bar
/// and the "save password?" prompt come from the content types, so getting
/// them right in ONE place gets them right everywhere. Including Bitwarden
/// and any other manager, which read the same system hints as the keychain.
///
/// Secrets always use `SecureField` + `.password`. TOKENS too: a manager
/// can only offer to store what it recognises as a credential, and a route
/// token is exactly as worth storing as a password.
enum CredentialField {
    /// Server address. URL keyboard, no autocorrect, `.URL` content type.
    ///
    /// With a `service` it also offers the KNOWN addresses below the
    /// field. Deliberately below and as its own control: the QuickType bar
    /// belongs to the password managers, and the address is the part they do
    /// not carry.
    static func serverURL(_ title: LocalizedStringKey, text: Binding<String>,
                          id: String? = nil,
                          service: KnownServer.Service? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TitledCredential(title: title) { large in
                Group {
                    if large { TextField(text: text, prompt: Text(verbatim: "")) { Text(title) } }
                    else { TextField(title, text: text) }
                }
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier(id ?? "credential-url")
            }
            if let service {
                KnownServerSuggestions(service: service, text: text)
            }
        }
    }

    static func username(_ title: LocalizedStringKey, text: Binding<String>,
                         id: String? = nil) -> some View {
        TitledCredential(title: title) { large in
            Group {
                if large { TextField(text: text, prompt: Text(verbatim: "")) { Text(title) } }
                else { TextField(title, text: text) }
            }
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(id ?? "credential-username")
        }
    }

    /// Password, API key, route token. Everything secret takes this one.
    /// `new` marks a password being SET: iOS then offers a strong one and
    /// does not fill in the one it keeps for the account.
    static func secret(_ title: LocalizedStringKey, text: Binding<String>,
                       id: String? = nil, new: Bool = false) -> some View {
        TitledCredential(title: title) { large in
            Group {
                if large { SecureField(text: text, prompt: Text(verbatim: "")) { Text(title) } }
                else { SecureField(title, text: text) }
            }
            .textContentType(new ? .newPassword : .password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(id ?? "credential-secret")
        }
    }
}

/// At accessibility sizes a placeholder that does not fit is shrunk to a few
/// points (measured at AX3: „Neues Passwort wiederholen“). There the title
/// stands above the field as its own line and the field stays empty; the
/// field keeps the title as its label, so VoiceOver still names it once.
private struct TitledCredential<Field: View>: View {
    let title: LocalizedStringKey
    /// Builds the field; `true` asks for the empty placeholder.
    let field: (Bool) -> Field
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                field(true)
            }
        } else {
            field(false)
        }
    }
}


/// The suggestion row under a server field. Own service type first, the
/// other known addresses below (their value is the domain family). A tap
/// fills the field; removing is a LONG PRESS, never automatic (
/// an outage is not a reason to delete).
struct KnownServerSuggestions: View {
    let service: KnownServer.Service
    @Binding var text: String
    @State private var entries: [KnownServer] = []

    var body: some View {
        if !entries.isEmpty {
            ScrollView(.horizontal) {
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
