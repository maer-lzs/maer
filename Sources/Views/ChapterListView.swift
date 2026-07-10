import SwiftUI

struct ChapterListView: View {
    let chapters: [ABSChapter]
    let currentChapter: ABSChapter?
    let onSelect: (ABSChapter) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(chapters) { chapter in
                Button {
                    onSelect(chapter)
                } label: {
                    HStack {
                        Text(chapter.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if chapter.id == currentChapter?.id {
                            Image(systemName: "waveform")
                        }
                    }
                }
            }
            .navigationTitle("Chapters")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
