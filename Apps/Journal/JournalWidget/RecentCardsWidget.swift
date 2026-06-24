import JournalModel
import SwiftData
import SwiftUI
import WidgetKit

// MARK: - Widget

/// Shows the most recent journal cards on the Home Screen.
///
/// Proves the widget-ready structure end to end: the timeline provider opens the
/// *same* SwiftData store as the app (the shared App Group container built by
/// `JournalStore`) and reads `Card`s from it. The app shell can ask WidgetKit to
/// refresh after a write with `WidgetCenter.shared.reloadAllTimelines()`.
struct RecentCardsWidget: Widget {

  private let kind = "RecentCardsWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: RecentCardsProvider()) { entry in
      RecentCardsView(entry: entry)
        .containerBackground(.fill.tertiary, for: .widget)
    }
    .configurationDisplayName("Recent Cards")
    .description("Your most recent journal cards.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

// MARK: - Timeline

struct RecentCardsEntry: TimelineEntry {
  let date: Date
  let cards: [CardSnapshot]
}

/// A `Sendable`, value-type view of a `Card`. The widget renders snapshots
/// rather than holding SwiftData model references, keeping the timeline entry
/// `Sendable` and the views free of the persistence layer.
struct CardSnapshot: Sendable, Hashable {
  let id: UUID
  let title: String
  let createdAt: Date
}

struct RecentCardsProvider: TimelineProvider {

  func placeholder(in context: Context) -> RecentCardsEntry {
    RecentCardsEntry(date: .now, cards: CardSnapshot.samples)
  }

  func getSnapshot(in context: Context, completion: @escaping (RecentCardsEntry) -> Void) {
    // The gallery preview (`context.isPreview`) has no real data to show, so use
    // representative samples; otherwise read the store.
    let cards = context.isPreview ? CardSnapshot.samples : (loadRecentCards() ?? CardSnapshot.samples)
    completion(RecentCardsEntry(date: .now, cards: cards))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<RecentCardsEntry>) -> Void) {
    let entry = RecentCardsEntry(date: .now, cards: loadRecentCards() ?? [])
    // Content changes only when the user captures something, and the app nudges
    // WidgetKit then; a periodic refresh keeps relative dates ("2h ago") current.
    let next = Date.now.addingTimeInterval(60 * 60)
    completion(Timeline(entries: [entry], policy: .after(next)))
  }

  /// Reads the latest cards from the shared store. Returns `nil` on failure
  /// (e.g. the container can't open) so callers can fall back to placeholders.
  private func loadRecentCards() -> [CardSnapshot]? {
    do {
      let container = try JournalStore.makeModelContainer()
      let context = ModelContext(container)
      var descriptor = FetchDescriptor<Card>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      descriptor.fetchLimit = 3
      return try context.fetch(descriptor).map {
        CardSnapshot(id: $0.id, title: $0.title, createdAt: $0.createdAt)
      }
    } catch {
      return nil
    }
  }
}

// MARK: - View

private struct RecentCardsView: View {

  let entry: RecentCardsEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Recent")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      if entry.cards.isEmpty {
        Text("No cards yet")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      } else {
        ForEach(entry.cards, id: \.self) { card in
          VStack(alignment: .leading, spacing: 2) {
            Text(card.title.isEmpty ? "Untitled" : card.title)
              .font(.subheadline.weight(.medium))
              .lineLimit(1)
            Text(card.createdAt, format: .relative(presentation: .named))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

// MARK: - Sample Data

extension CardSnapshot {
  /// Placeholder content for the widget gallery and redacted previews.
  static let samples: [CardSnapshot] = [
    .init(id: UUID(), title: "Morning walk", createdAt: .now),
    .init(id: UUID(), title: "Idea for the project", createdAt: .now.addingTimeInterval(-3_600)),
    .init(id: UUID(), title: "Coffee with a friend", createdAt: .now.addingTimeInterval(-7_200)),
  ]
}

// MARK: - Preview

#Preview(as: .systemSmall) {
  RecentCardsWidget()
} timeline: {
  RecentCardsEntry(date: .now, cards: CardSnapshot.samples)
  RecentCardsEntry(date: .now, cards: [])
}
