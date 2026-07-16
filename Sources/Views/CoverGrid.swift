import SwiftUI

/// Shared cover grid (Etappe 4, Regel 2): the album/book/show grids across the
/// tabs all used the same `LazyVGrid(columns:, alignment: .leading, spacing: 20)`
/// with only the column definition differing. One wrapper — the columns are
/// passed through (they are deliberately per-surface, e.g. `.adaptive(min: 108)`
/// vs a fixed count).
struct CoverGrid<Content: View>: View {
    let columns: [GridItem]
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20, content: content)
    }
}
