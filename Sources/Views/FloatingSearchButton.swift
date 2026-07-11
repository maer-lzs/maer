import SwiftUI

/// Schwebender Lupen-Button unten, der sich beim Antippen zu einem Suchfeld
/// aufklappt — angelehnt an den separaten, schwebenden Such-Button, den
/// Apple seit iOS 26 in Music & Co. nutzt (dort über `Tab(..., role: .search)`
/// realisiert). Da diese App nur einen einzigen Hauptbildschirm hat, lohnt
/// sich der Umbau auf eine ganze TabView dafür nicht — stattdessen ein
/// eigenständiger Button im selben Glas-Look wie die Mini-Player-Leiste.
struct FloatingSearchButton: View {
    @Binding var searchText: String
    /// Von außen (LibraryView) beobachtbar/steuerbar — auf dem iPhone blendet
    /// die Bibliothek die Mini-Leiste aus, sobald hier aufgeklappt wird
    /// (nicht genug Platz für beides gleichzeitig).
    @Binding var isExpanded: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isExpanded {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
                TextField("Title, author, series", text: $searchText)
                    .focused($isFocused)
                    .font(.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)

                Button {
                    collapse()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        isExpanded = true
                    }
                    // Kurze Verzögerung, damit die Aufklapp-Animation zuerst
                    // sichtbar startet, bevor die Tastatur reinschiebt.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isFocused = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 56, height: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 56)
        .frame(maxWidth: isExpanded ? .infinity : 56)
        .modifier(AdaptiveGlassBackground(shape: Capsule()))
        .onChange(of: isFocused) { _, focused in
            // Verliert das Feld den Fokus (z. B. Tastatur weggewischt) und
            // ist es leer, klappt es wieder ein.
            if !focused && searchText.isEmpty {
                withAnimation(.snappy(duration: 0.25)) {
                    isExpanded = false
                }
            }
        }
    }

    private func collapse() {
        searchText = ""
        isFocused = false
        withAnimation(.snappy(duration: 0.25)) {
            isExpanded = false
        }
    }
}
