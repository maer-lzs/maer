import SwiftUI

/// Configure a Subsonic-compatible music server (Navidrome, Gonic, Airsonic).
/// Enter server/user/password, test the connection, switch it on — the Music tab
/// then appears in the library. Source-specific management, like the podcast and
/// gpodder source views.
struct SubsonicSourceView: View {
    @State private var serverURL = AppStorageKeys.subsonicServerURLValue
    @State private var username = AppStorageKeys.subsonicUsernameValue
    @State private var password = AppStorageKeys.subsonicPasswordValue
    @State private var enabled = AppStorageKeys.subsonicEnabledValue
    @AppStorage(AppStorageKeys.musicLyricsOnlineLookup) private var lyricsOnline = true
    @AppStorage(AppStorageKeys.musicHighResCovers) private var highResCovers = true

    @State private var isTesting = false
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
                Text("Subsonic Server")
            } footer: {
                Text("Works with Navidrome, Gonic and Airsonic. Example: https://music.example.com")
            }

            Section {
                Toggle("Show Music tab", isOn: $enabled)
            } footer: {
                Text("When on, your albums, artists and playlists appear in a Music tab in the library.")
            }

            Section {
                Toggle("Look up lyrics online", isOn: $lyricsOnline)
                Toggle("High-res covers (Cover Art Archive)", isOn: $highResCovers)
            } header: {
                Text("Metadata")
            } footer: {
                Text("Lyrics come from your server first; LRCLIB is used as an open fallback. High-res covers load from the Cover Art Archive for albums with a MusicBrainz ID. Both are open services without accounts.")
            }

            Section {
                Button {
                    save()
                    isTesting = true
                    Task {
                        let err = await SubsonicProvider.shared.testConnection()
                        setStatus(err ?? String(localized: "Connected."), isError: err != nil)
                        isTesting = false
                    }
                } label: {
                    Label("Test connection", systemImage: "bolt.horizontal")
                }
                .disabled(isTesting || serverURL.isEmpty || username.isEmpty)

                if isTesting {
                    HStack { ProgressView(); Text("Working…").foregroundStyle(.secondary) }
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? .red : .secondary)
                }
            }
        }
        .navigationTitle("Music Server")
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
        // Save on leaving so nothing is lost.
        .onDisappear { save() }
    }

    private func save() {
        AppStorageKeys.subsonicServerURLValue = serverURL.trimmingCharacters(in: .whitespaces)
        AppStorageKeys.subsonicUsernameValue = username.trimmingCharacters(in: .whitespaces)
        AppStorageKeys.setSubsonicPassword(password)
        AppStorageKeys.subsonicEnabledValue = enabled
        // Rebuild the client so the next request uses the new credentials.
        SubsonicProvider.shared.reloadConfig()
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
