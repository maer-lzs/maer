import SwiftUI

/// Zugang zu einem gpodder-kompatiblen Sync-Server (oPodSync, Nextcloud GPodder,
/// gpodder.net) — gleichwertig neben iCloud und ABS. Server/Nutzer/Passwort
/// eingeben, Verbindung testen, aktivieren; danach gleichen Abos (und History)
/// beim Öffnen des Podcast-Tabs automatisch ab.
struct GPodderSettingsView: View {
    @State private var serverURL = AppStorageKeys.gpodderServerURLValue
    @State private var username = AppStorageKeys.gpodderUsernameValue
    @State private var password = AppStorageKeys.gpodderPasswordValue
    @State private var enabled = AppStorageKeys.gpodderEnabledValue

    @State private var isTesting = false
    @State private var isSyncing = false
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $serverURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } header: {
                Text("gpodder Server")
            } footer: {
                Text("Works with oPodSync, Nextcloud GPodder and gpodder.net. Example: https://sync.example.com")
            }

            Section {
                Toggle("Sync podcasts via gpodder", isOn: $enabled)
                LabeledContent("Device", value: AppStorageKeys.gpodderDeviceIdValue)
            } footer: {
                Text("Subscriptions (and listening history) sync with this server, alongside iCloud and Audiobookshelf.")
            }

            Section {
                Button {
                    save()
                    isTesting = true
                    Task {
                        let err = await GPodderSync.shared.testConnection()
                        setStatus(err ?? String(localized: "Connected."), isError: err != nil)
                        isTesting = false
                    }
                } label: {
                    Label("Test connection", systemImage: "bolt.horizontal")
                }
                .disabled(isTesting || serverURL.isEmpty)

                Button {
                    save()
                    isSyncing = true
                    Task {
                        let r = await GPodderSync.shared.reconcile()
                        setStatus(syncSummary(r), isError: r.error != nil)
                        isSyncing = false
                    }
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing || !enabled || serverURL.isEmpty)

                if isTesting || isSyncing {
                    HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) }
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
            }
        }
        .navigationTitle("gpodder Sync")
        .navigationBarTitleDisplayMode(.inline)
        // Beim Verlassen speichern, damit nichts verloren geht.
        .onDisappear { save() }
    }

    private func save() {
        AppStorageKeys.gpodderServerURLValue = serverURL.trimmingCharacters(in: .whitespaces)
        AppStorageKeys.gpodderUsernameValue = username.trimmingCharacters(in: .whitespaces)
        AppStorageKeys.setGpodderPassword(password)
        AppStorageKeys.gpodderEnabledValue = enabled
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func syncSummary(_ r: GPodderSync.Report) -> String {
        if let error = r.error { return error }
        var parts: [String] = []
        if r.addedLocally > 0 { parts.append(String(localized: "\(r.addedLocally) added from server")) }
        if r.pushedToServer > 0 { parts.append(String(localized: "\(r.pushedToServer) pushed to server")) }
        return parts.isEmpty ? String(localized: "Already in sync.") : parts.joined(separator: " · ")
    }
}
