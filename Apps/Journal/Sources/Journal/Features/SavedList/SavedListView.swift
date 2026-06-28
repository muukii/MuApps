import JournalModel
import MuColor
import SwiftData
import SwiftUI

/// SwiftData + iCloud entries list.
///
/// Cards are grouped into local-calendar day sections, then laid out as a
/// responsive grid of portrait tiles shaped like a sheet of paper (1 : 1.4144,
/// via `CardSurface`). Compact widths keep the original two-column rhythm;
/// regular widths add columns as space allows. Each tile renders one captured
/// modality — text, audio, image, or doodle — because a captured thing becomes
/// its own Card rather than media-with-caption.
struct SavedListView: View {

  @Environment(\.calendar) private var calendar
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.appPalette) private var palette
  @Query(sort: \Card.createdAt, order: .reverse) private var cards: [Card]

  @State private var sharePreviewPresentation: CardSharePreviewPresentation?

  @Namespace var namespace

  var body: some View {
    let columns = SavedListGrid.columns(for: horizontalSizeClass)
    // TODO: If Entries grows large enough for full-list grouping to show up in
    // profiling, move this boundary into persistence instead of adding a shallow
    // fetchLimit: store a day section key on `Card`, or fetch by month/year
    // ranges and group only the visible archive window.
    let daySections = SavedListDaySection.sections(for: cards, calendar: calendar)

    ScrollView {
      LazyVStack(alignment: .leading, spacing: daySectionSpacing) {
        ForEach(daySections) { section in
          SavedListDaySectionView(
            section: section,
            columns: columns,
            onShare: presentSharePreview,
            namespace: namespace
          )
        }
      }
      .padding(cardSpacing)
    }
    .overlay {
      if cards.isEmpty {
        ContentUnavailableView("No Cards", systemImage: "book.closed")
      }
    }
    .scrollContentBackground(.hidden)
    .background(.background)
    .navigationTitle("Entries")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $sharePreviewPresentation) { presentation in
      CardSharePreviewScreen(
        snapshot: presentation.snapshot,
        palette: presentation.palette
      )
    }
  }

  private func presentSharePreview(for card: Card) {
    sharePreviewPresentation = CardSharePreviewPresentation(
      snapshot: CardShareSnapshot(card: card),
      palette: palette
    )
  }
}

/// Presentation payload for the pre-share preview screen.
private struct CardSharePreviewPresentation: Identifiable {
  let id = UUID()
  let snapshot: CardShareSnapshot
  let palette: Palette
}

/// One local-calendar date bucket in the saved entries list.
///
/// Identity is the start-of-day `Date` in the active SwiftUI calendar
/// environment, so the section stays stable while cards are inserted, deleted,
/// or edited within the same day.
private struct SavedListDaySection: Identifiable {
  let id: Date
  let day: Date
  var cards: [Card]

  init(day: Date, cards: [Card]) {
    self.id = day
    self.day = day
    self.cards = cards
  }

  static func sections(for cards: [Card], calendar: Calendar) -> [SavedListDaySection] {
    var sectionIndexesByDay: [Date: Int] = [:]
    var sections: [SavedListDaySection] = []

    for card in cards {
      let day = calendar.startOfDay(for: card.createdAt)

      if let sectionIndex = sectionIndexesByDay[day] {
        sections[sectionIndex].cards.append(card)
      } else {
        sectionIndexesByDay[day] = sections.count
        sections.append(SavedListDaySection(day: day, cards: [card]))
      }
    }

    return sections
  }
}

/// Column strategy for the entries grid.
///
/// Compact widths intentionally preserve the original two-column composition.
/// Regular widths use an adaptive item so iPad gains more visible entries
/// without letting the paper tile become oversized.
private enum SavedListGrid {
  static func columns(for horizontalSizeClass: UserInterfaceSizeClass?) -> [GridItem] {
    if horizontalSizeClass == .compact {
      return compactColumns
    }

    return [
      GridItem(
        .adaptive(minimum: regularMinimumCardWidth, maximum: regularMaximumCardWidth),
        spacing: cardSpacing
      )
    ]
  }

  private static let compactColumns = [
    GridItem(.flexible(), spacing: cardSpacing),
    GridItem(.flexible(), spacing: cardSpacing),
  ]
}

/// Gutter between cards and around the grid, kept equal so columns and edges
/// share the same rhythm.
private let cardSpacing: CGFloat = 16

/// Vertical gap between date sections.
private let daySectionSpacing: CGFloat = 28

/// Gap between a date header and the cards for that day.
private let dayHeaderSpacing: CGFloat = 12

/// Smallest card width used by the iPad/regular-width grid.
private let regularMinimumCardWidth: CGFloat = 168

/// Largest card width used by the iPad/regular-width grid before adding another
/// column.
private let regularMaximumCardWidth: CGFloat = 220

// MARK: - Fileprivate Views

/// A single date section in the entries list.
private struct SavedListDaySectionView: View {

  let section: SavedListDaySection
  let columns: [GridItem]
  let onShare: @MainActor (Card) -> Void
  let namespace: Namespace.ID

  var body: some View {
    VStack(alignment: .leading, spacing: dayHeaderSpacing) {
      SavedListDayHeader(day: section.day)

      LazyVGrid(columns: columns, spacing: cardSpacing) {
        ForEach(section.cards) { card in
          NavigationLink {
            SavedEntryDetailView(
              card: card,
              onShare: onShare
            )
            .navigationTransition(.zoom(sourceID: card, in: namespace))
          } label: {
            SavedEntrySummaryCardHost(card: card)
              .matchedTransitionSource(id: card, in: namespace)
          }
          .buttonStyle(.plain)
          .contextMenu {
            SavedEntrySummaryCardContextMenu(
              card: card,
              onShare: onShare
            )
          }
        }
      }
    }
  }
}

/// Localized date label for a saved-entry section.
private struct SavedListDayHeader: View {

  let day: Date

  var body: some View {
    Text(day, format: .dateTime.weekday(.abbreviated).month(.wide).day().year())
      .font(.headline)
      .foregroundStyle(.appOnPrimaryContainer.opacity(0.72))
      .accessibilityAddTraits(.isHeader)
  }
}
