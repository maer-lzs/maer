// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

/// "A name for home and away": one address that reaches a server at home
/// and on the road. Mär knows a server by its address; a second address
/// for home would make it a second server. This page shows the three usual
/// ways to one name; it changes no setting.
struct HomeAndAwayGuidePage: View {
    var body: some View {
        Form {
            Section {
                Text("Mär knows each server by its address. A second address for home would make it a second server, with its own sign-in, downloads and listening positions. One name that reaches the server everywhere avoids that.")
            } header: {
                Text("Why one name")
            }
            Section {
                Text("**Split DNS.** Your router answers the server's public name with its address at home; everywhere else the name leads to the public address. Mär uses the same name in both places.")
                Text("**A VPN such as Tailscale or WireGuard.** The phone reaches your home network from anywhere, and you enter the server's address in that network.")
                Text("**A reverse proxy.** One public name with https in front of the server, reachable from outside; many routers also lead that name back home from inside.")
            } header: {
                Text("Three ways")
            }
            Section {
                Text("The one name, preferably with https, so passwords and tokens never travel in plain text.")
            } header: {
                Text("What you enter in Mär")
            }
        }
        .navigationTitle(Text("A name for home and away"))
        .navigationBarTitleDisplayMode(.inline)
        .bottomBarClearance()
    }
}
