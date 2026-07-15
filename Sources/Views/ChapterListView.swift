import SwiftUI

struct ChapterListView: View {
    let chapters: [ABSChapter]
    let currentChapter: ABSChapter?
    let onSelect: (ABSChapter) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // S12: books/albums can have 150+ chapters/tracks — open straight on
            // the playing one and highlight it, instead of scrolled to the top.
            ScrollViewReader { proxy in
                List(chapters) { chapter in
                    let isActive = chapter.id == currentChapter?.id
                    Button {
                        onSelect(chapter)
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .fontWeight(isActive ? .semibold : .regular)
                                .foregroundStyle(isActive ? AnyShapeStyle(AppTheme.accent) : AnyShapeStyle(.primary))
                            Spacer()
                            if isActive {
                                Image(systemName: "waveform")
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                    }
                    .listRowBackground(isActive ? AppTheme.accent.opacity(0.12) : nil)
                    .id(chapter.id)
                }
                .navigationTitle("Chapters")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .onAppear {
                    guard let id = currentChapter?.id else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}
