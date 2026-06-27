import JournalModel
import SwiftData
import SwiftUI
import UIKit
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
  let content: NoteContent
  let createdAt: Date
}

/// The widget-renderable content extracted from a `Card`.
///
/// Text cards carry their display string. Doodle cards carry only the mirrored
/// thumbnail bytes, not the full vector JSON, so the extension can render them
/// without linking the capture framework or touching media files.
enum NoteContent: Sendable, Hashable {
  case text(String)
  case doodle(thumbnailData: Data?)
  case bauhaus(thumbnailData: Data?)
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
      return NoteSnapshot(
        id: card.id,
        content: card.widgetContent,
        createdAt: card.createdAt
      )
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
      LatestNoteContentCard(
        note: note,
        family: family
      )
    } else {
      LatestNoteEmptyState()
    }
  }
}

private struct LatestNoteContentCard: View {

  let note: NoteSnapshot
  let family: WidgetFamily

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Latest", systemImage: note.content.symbolName)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)

      NoteContentView(
        content: note.content,
        family: family
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      Text(note.createdAt, format: .relative(presentation: .named))
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct NoteContentView: View {

  let content: NoteContent
  let family: WidgetFamily

  var body: some View {
    switch content {
    case .text(let text):
      Text(text)
        .font(bodyFont)
        .fontWeight(.medium)
        .lineLimit(bodyLineLimit)
        .multilineTextAlignment(.leading)
        .minimumScaleFactor(0.85)
    case .doodle(let thumbnailData):
      DoodleThumbnailView(thumbnailData: thumbnailData)
    case .bauhaus(let thumbnailData):
      DoodleThumbnailView(
        thumbnailData: thumbnailData,
        fallbackTitle: "Bauhaus",
        fallbackSymbolName: "square.grid.3x3.square"
      )
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

private struct DoodleThumbnailView: View {

  let thumbnailData: Data?
  let fallbackTitle: LocalizedStringResource
  let fallbackSymbolName: String

  init(
    thumbnailData: Data?,
    fallbackTitle: LocalizedStringResource = "Doodle",
    fallbackSymbolName: String = "scribble.variable"
  ) {
    self.thumbnailData = thumbnailData
    self.fallbackTitle = fallbackTitle
    self.fallbackSymbolName = fallbackSymbolName
  }

  var body: some View {
    if let image = thumbnailData.flatMap(UIImage.init(data:)) {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(
          .secondary.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityLabel(Text(fallbackTitle))
    } else {
      Label {
        Text(fallbackTitle)
      } icon: {
        Image(systemName: fallbackSymbolName)
      }
        .font(.body.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
  }
}

private struct LatestNoteEmptyState: View {

  var body: some View {
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

// MARK: - Formatting Helpers

extension Card {
  /// The widget content for this card. Text cards render their written body;
  /// doodle cards render the mirrored thumbnail, and other media cards keep
  /// their modality label until they get a dedicated widget treatment.
  fileprivate var widgetContent: NoteContent {
    let attachments = (attachments ?? []).sorted { $0.createdAt < $1.createdAt }
    switch kind {
    case .text:
      return .text(displayText)
    case .photo:
      return .text("Photo")
    case .audio:
      return .text("Audio")
    case .doodle:
      return .doodle(
        thumbnailData: attachments.first(matching: .doodle)?.thumbnail
      )
    case .bauhaus:
      return .bauhaus(
        thumbnailData: attachments.first(matching: .bauhaus)?.thumbnail
      )
    @unknown default:
      return .text("Untitled")
    }
  }

  /// The fallback label for non-visual widget content.
  fileprivate var displayText: String {
    let body = self.body.trimmingCharacters(in: .whitespacesAndNewlines)
    if !body.isEmpty { return body }
    let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Untitled" : title
  }
}

extension NoteContent {

  /// SF Symbol used by the latest-note label for this content type.
  fileprivate var symbolName: String {
    switch self {
    case .text:
      return "note.text"
    case .doodle:
      return "scribble.variable"
    case .bauhaus:
      return "square.grid.3x3.square"
    }
  }
}

extension Array where Element == Attachment {

  fileprivate func first(matching kind: Attachment.Kind) -> Attachment? {
    first { $0.kind == kind }
  }
}

// MARK: - Sample Data

extension NoteSnapshot {
  /// Placeholder content for the widget gallery and redacted previews.
  static let sample = NoteSnapshot(
    id: UUID(),
    content: .text(
      "Had a slow morning and a long walk by the river. Felt good to step away from the screen for a while."
    ),
    createdAt: .now.addingTimeInterval(-1_800)
  )

  /// Placeholder content for the doodle rendering path when a real thumbnail
  /// has not been loaded from the shared store.
  static let sampleDoodle = NoteSnapshot(
    id: UUID(),
    content: .doodle(thumbnailData: nil),
    createdAt: .now.addingTimeInterval(-600)
  )

  /// Placeholder content for the Bauhaus rendering path when a real thumbnail
  /// has not been loaded from the shared store.
  static let sampleBauhaus = NoteSnapshot(
    id: UUID(),
    content: .bauhaus(thumbnailData: nil),
    createdAt: .now.addingTimeInterval(-900)
  )
}

// MARK: - Preview

#Preview(as: .systemSmall) {
  LatestNoteWidget()
} timeline: {
  LatestNoteEntry(date: .now, note: .sample)
  LatestNoteEntry(date: .now, note: .sampleDoodle)
  LatestNoteEntry(date: .now, note: .sampleBauhaus)
  LatestNoteEntry(date: .now, note: nil)
}
