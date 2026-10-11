// Mär — an audio player for self-hosted open ecosystems
// Copyright (C) 2026 Laurenz Schröder
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms apply — see LICENSE-ADDITIONAL-TERMS

import SwiftUI

extension View {
    /// The one way an action of the person on a server says that it failed
    /// (rename, delete, remove from a playlist, favorite): the server did not
    /// take it, and nothing on the surface pretends it did. The action runs
    /// through `FetchAnswer`, which writes the reason to the log; this says
    /// the sentence.
    func actionFailedAlert(_ isPresented: Binding<Bool>) -> some View {
        alert(Text("The source did not answer."), isPresented: isPresented) {
            Button("OK", role: .cancel) {}
        }
    }

    /// The one way a surface says a sentence it was handed (a refused mark,
    /// a refused delete, a row that cannot open): the sentence is the title,
    /// OK dismisses it, and dismissing clears it.
    func sentenceAlert(_ sentence: Binding<String?>) -> some View {
        alert(Text(verbatim: sentence.wrappedValue ?? ""), isPresented: Binding(
            get: { sentence.wrappedValue != nil },
            set: { if !$0 { sentence.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) { sentence.wrappedValue = nil }
        }
    }
}
