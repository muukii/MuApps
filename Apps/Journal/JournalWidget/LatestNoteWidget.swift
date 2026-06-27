import JournalModel
import SwiftData
import SwiftUI
import WidgetKit

// MARK: - Widget

/// Shows the most recently created note on the Home Screen.
///
/// The timeline provider opens the *same* SwiftData store as the app (the shared
/// App Group container built by `JournalStore`) and reads the single newest
/// `Card`. After a write the app nudges WidgetKit with
/// `WidgetCenter.shared.reloadAllTimelines()` so the widget reflects the new note.
struct LatestNoteWidget: Widget {

  private let kind = "LatestNoteWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: LatestNoteProvider()) { entry in
      LatestNoteView(entry: entry)
        .containerBackground(.background, for: .widget)
    }
    .configurationDisplayName("Latest Note")
    .description("Shows the note you wrote most recently.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

// MARK: - Timeline

struct LatestNoteEntry: TimelineEntry {
  let date: Date
  let note: NoteSnapshot?
}

/// A `Sendable`, value-type view of the latest `Card`. The widget renders this
/// rather than holding a SwiftData model reference, keeping the timeline entry
/// `Sendable` and the views free of the persistence layer.
struct NoteSnapshot: Sendable, Hashable {
  let id: UUID
  let text: String
  let createdAt: Date
}

struct LatestNoteProvider: TimelineProvider {

  func placeholder(in context: Context) -> LatestNoteEntry {
    LatestNoteEntry(date: .now, note: .sample)
  }

  func getSnapshot(in context: Context, completion: @escaping (LatestNoteEntry) -> Void) {
    // The widget gallery (`context.isPreview`) has no real data, so show a
    // representative sample; otherwise read the store.
    let note = context.isPreview ? NoteSnapshot.sample : loadLatestNote()
    completion(LatestNoteEntry(date: .now, note: note))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<LatestNoteEntry>) -> Void) {
    let entry = LatestNoteEntry(date: .now, note: loadLatestNote())
    // Content changes only when the user writes a note, and the app reloads the
    // timeline then; a periodic refresh keeps the relative date ("2h ago") fresh.
    let next = Date.now.addingTimeInterval(60 * 60)
    completion(Timeline(entries: [entry], policy: .after(next)))
  }

  /// Reads the single most recent note from the shared store. Returns `nil` when
  /// there are no notes, or when the store can't be opened — the view shows an
  /// empty state in both cases.
  private func loadLatestNote() -> NoteSnapshot? {
    do {
      let container = try JournalStore.makeModelContainer()
      let context = ModelContext(container)
      var descriptor = FetchDescriptor<Card>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      descriptor.fetchLimit = 1
      guard let card = try context.fetch(descriptor).first else { return nil }
      return NoteSnapshot(id: card.id, text: card.displayText, createdAt: card.createdAt)
    } catch {
      return nil
    }
  }
}

// MARK: - View

private struct LatestNoteView: View {

  @Environment(\.widgetFamily) private var family
  let entry: LatestNoteEntry

  var body: some View {
    if let note = entry.note {
      VStack(alignment: .leading, spacing: 8) {
        Label("Latest", systemImage: "note.text")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)

        Text(note.text)
          .font(bodyFont)
          .fontWeight(.medium)
          .lineLimit(bodyLineLimit)
          .multilineTextAlignment(.leading)
          .minimumScaleFactor(0.85)

        Spacer(minLength: 0)

        Text(note.createdAt, format: .relative(presentation: .named))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    } else {
      VStack(spacing: 6) {
        Image(systemName: "note.text")
          .font(.title2)
          .foregroundStyle(.secondary)
        Text("No notes yet")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var bodyFont: Font {
    switch family {
    case .systemSmall: .subheadline
    case .systemLarge: .title3
    default: .body
    }
  }

  private var bodyLineLimit: Int {
    switch family {
    case .systemSmall: 4
    case .systemLarge: 14
    default: 4
    }
  }
}

// MARK: - Formatting Helpers

extension Card {
  /// The widget label for this card. Text cards render their written body; media
  /// cards render a modality label because `body` is not their content.
  fileprivate var displayText: String {
    switch kind {
    case .text:
      let body = self.body.trimmingCharacters(in: .whitespacesAndNewlines)
      if !body.isEmpty { return body }
      let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
      return title.isEmpty ? "Untitled" : title
    case .photo:
      return "Photo"
    case .audio:
      return "Audio"
    case .doodle:
      return "Doodle"
    @unknown default:
      return "Untitled"
    }
  }
}

// MARK: - Sample Data

extension NoteSnapshot {
  /// Placeholder content for the widget gallery and redacted previews.
  static let sample = NoteSnapshot(
    id: UUID(),
    text: "Had a slow morning and a long walk by the river. Felt good to step away from the screen for a while.",
    createdAt: .now.addingTimeInterval(-1_800)
  )
}

// MARK: - Preview

#Preview(as: .systemSmall) {
  LatestNoteWidget()
} timeline: {
  LatestNoteEntry(date: .now, note: .sample)
  LatestNoteEntry(date: .now, note: nil)
}
