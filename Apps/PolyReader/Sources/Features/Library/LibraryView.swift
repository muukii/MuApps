import MuDesignSystem
import SwiftData
import SwiftUI

struct LibraryView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \ReadingText.updatedAt, order: .reverse) private var readingTexts: [ReadingText]

  @State private var isShowingEditor = false

  var body: some View {
    NavigationStack {
      Group {
        if readingTexts.isEmpty {
          emptyState
        } else {
          readingList
        }
      }
      .navigationTitle("PolyReader")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            isShowingEditor = true
          } label: {
            Label("Add Text", systemImage: "plus")
          }
        }
      }
      .sheet(isPresented: $isShowingEditor) {
        TextEditorSheet()
      }
    }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Texts", systemImage: "text.page")
    } description: {
      Text("Paste text to read it one sentence at a time.")
    } actions: {
      Button {
        isShowingEditor = true
      } label: {
        Label("Add Text", systemImage: "plus")
      }
      .buttonStyle(.borderedProminent)
    }
  }

  private var readingList: some View {
    List {
      ForEach(readingTexts) { readingText in
        NavigationLink {
          ReaderView(readingText: readingText)
        } label: {
          ReadingTextRow(readingText: readingText)
        }
        .swipeActions(edge: .trailing) {
          Button(role: .destructive) {
            delete(readingText)
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
      }
      .onDelete(perform: delete)
    }
    .listStyle(.inset)
  }

  private func delete(_ readingText: ReadingText) {
    modelContext.delete(readingText)
    try? modelContext.save()
  }

  private func delete(at offsets: IndexSet) {
    for index in offsets {
      delete(readingTexts[index])
    }
  }
}

private struct ReadingTextRow: View {
  let readingText: ReadingText

  private var sentences: [String] {
    SentenceSegmenter.segment(readingText.body)
  }

  private var progressValue: Double {
    guard !sentences.isEmpty else { return 0 }
    let index = min(max(readingText.currentSentenceIndex, 0), sentences.count - 1)
    return Double(index + 1) / Double(sentences.count)
  }

  private var progressText: String {
    guard !sentences.isEmpty else { return "No sentences" }
    let index = min(max(readingText.currentSentenceIndex, 0), sentences.count - 1)
    return "\(index + 1) of \(sentences.count)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Text(readingText.title)
          .font(.headline)

        Spacer(minLength: 12)

        Text(progressText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(readingText.body)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      ProgressView(value: progressValue)
    }
    .padding(.vertical, 4)
  }
}
