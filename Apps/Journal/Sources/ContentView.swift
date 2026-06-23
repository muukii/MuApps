import SwiftData
import SwiftUI

/// SwiftData + iCloud entries list.
///
/// The real journaling interface is still being designed; this exists only to
/// verify the SwiftData + CloudKit stack end-to-end (read via `@Query`, write via
/// `modelContext`). Hosted inside the dev gallery's navigation stack.
struct ContentView: View {

  @Environment(\.modelContext) private var modelContext
  @Query(sort: \JournalEntry.createdAt, order: .reverse) private var entries: [JournalEntry]

  var body: some View {
    List(entries) { entry in
      VStack(alignment: .leading, spacing: 4) {
        Text(entry.title.isEmpty ? "Untitled" : entry.title)
          .font(.headline)
        Text(entry.createdAt, format: .dateTime)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .overlay {
      if entries.isEmpty {
        ContentUnavailableView("No Entries", systemImage: "book.closed")
      }
    }
    .navigationTitle("Entries")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Add", systemImage: "plus") {
          modelContext.insert(JournalEntry(title: "New Entry"))
        }
      }
    }
  }
}

#Preview {
  ContentView()
    .modelContainer(for: JournalEntry.self, inMemory: true)
}

#Preview {
  
  Form {
    Text("Hello, World!")
      .foregroundStyle(.foreground)
    Text("Hello, World!")
      .foregroundStyle(.primary)
    Rectangle()
      .foregroundStyle(.tint)
    Rectangle()
      .foregroundStyle(.foreground)
    Rectangle()
      .fill(.foreground)
    Rectangle()
      .foregroundStyle(.primary)
    Rectangle()
      .foregroundStyle(.secondary)
    Rectangle()
      .foregroundStyle(.primary.secondary)
    Rectangle()
      .foregroundStyle(.background)
  }
  .backgroundStyle(.red)
  .foregroundStyle(.orange)
  .tint(.green)

}
