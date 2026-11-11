// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// The headers a guard in front of a server asks for (Cloudflare Access,
/// Authelia, Authentik), entered under the server's credentials in every
/// server sheet: one row per header with its name and its value (always
/// hidden), "Add Header", swipe to delete. The rows are kept for the address
/// in the sheet's field when a row is committed, deleted, or the sheet
/// closes; a changed address takes the headers with it
/// (`ServerHeaders.move`), unless it names a server with headers of its
/// own, whose headers the section then shows. A row the rule refuses says
/// why and is not kept.
struct CustomHeadersSection: View {
    /// The sheet's address field, as typed.
    let address: String
    var idPrefix: String

    struct Row: Identifiable, Equatable {
        let id = UUID()
        var name = ""
        var value = ""
    }

    @State private var rows: [Row] = []
    /// The address the rows were read for or last kept under.
    @State private var keptFor: URL?
    /// The keychain could not be read: nothing is shown and nothing kept.
    @State private var unreadable = false
    /// The last keeping did not land: the rows shown are not saved.
    @State private var notKept = false

    var body: some View {
        Section {
            if unreadable {
                Text("The headers can be read once this device is unlocked.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if notKept {
                Text("The headers could not be saved. They are saved again when you change them or close this page.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(idPrefix)-headers-not-kept")
            }
            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 4) {
                    // Wraps instead of cutting a long name at large text sizes.
                    TextField("Header Name", text: $row.name, axis: .vertical)
                        .lineLimit(1...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { keep() }
                        .accessibilityIdentifier("\(idPrefix)-header-name")
                    SecureField("Value", text: $row.value)
                        .onSubmit { keep() }
                        .accessibilityIdentifier("\(idPrefix)-header-value")
                    if let sentence = Self.sentence(for: row) {
                        Text(sentence)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .onDelete { offsets in
                rows.remove(atOffsets: offsets)
                keep()
            }
            if !unreadable {
                Button {
                    rows.append(Row())
                } label: {
                    Label("Add Header", systemImage: "plus")
                }
                .accessibilityIdentifier("\(idPrefix)-header-add")
            }
        } header: {
            Text("Custom Headers")
        } footer: {
            Text("Headers a guard in front of the server asks for, such as Cloudflare Access. They go only to this server.")
        }
        .onAppear { read() }
        .onChange(of: ServerHeaderRule.base(typed: address)) { _, _ in
            // A typed address that names another server shows its headers;
            // the rows of the one before stay until they are kept or moved.
            if rows.allSatisfy({ $0.name.isEmpty && $0.value.isEmpty }) { read() }
        }
        .onDisappear { keep() }
    }

    /// The sentence under a row the rule refuses; none while the row is
    /// still empty in one of its fields.
    static func sentence(for row: Row) -> String? {
        let header = ServerHeaderRule.cleaned(name: row.name, value: row.value)
        guard !header.name.isEmpty, !header.value.isEmpty else { return nil }
        switch ServerHeaderRule.refusal(of: header) {
        case .reservedName: return String(localized: "The app sets this header itself.")
        case .notAToken: return String(localized: "A header name has only letters, digits and signs such as -, no spaces and no colon.")
        case .unsafeValue: return String(localized: "A header value cannot contain a line break.")
        case nil: return nil
        }
    }

    private func read() {
        guard let base = ServerHeaderRule.base(typed: address) else { return }
        keptFor = base
        // Unreadable is not empty: rows shown empty would be kept as none
        // and remove the server's headers.
        guard let stored = ServerHeaders.stored(for: base) else {
            unreadable = true
            return
        }
        unreadable = false
        rows = stored.map { Row(name: $0.name, value: $0.value) }
    }

    /// Keeps the complete rows the rule takes under the sheet's address,
    /// after moving what was kept under an address typed before. An address
    /// that names a server with headers of its own takes nothing: the rows
    /// become that server's, and its headers stay as they are. A keeping
    /// the keychain does not take says so under the rows and leaves the
    /// address they were kept for, so the next keeping moves them again.
    private func keep() {
        guard !unreadable, let base = ServerHeaderRule.base(typed: address) else { return }
        if let before = keptFor {
            switch ServerHeaders.move(from: before, to: base) {
            case .targetHasOwn:
                read()
                return
            case .notTaken:
                notKept = true
                return
            case .moved, .nothingToMove:
                break
            }
        }
        let headers = rows.map { ServerHeaderRule.cleaned(name: $0.name, value: $0.value) }
            .filter { !$0.name.isEmpty && !$0.value.isEmpty && ServerHeaderRule.refusal(of: $0) == nil }
        guard ServerHeaders.set(headers, for: base) else {
            notKept = true
            keptFor = keptFor ?? base
            return
        }
        notKept = false
        keptFor = base
    }
}
