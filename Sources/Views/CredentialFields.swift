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
    static func serverURL(_ title: LocalizedStringKey, text: Binding<String>,
                          id: String? = nil) -> some View {
        TextField(title, text: text)
            .textContentType(.URL)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier(id ?? "credential-url")
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
