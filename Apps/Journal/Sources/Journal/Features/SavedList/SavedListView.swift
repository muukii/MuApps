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
  @State private var groupPresentation: SavedListGroupPresentation = .stacked

  @Namespace var namespace

  var body: some View {
    let columns = SavedListGrid.columns(for: horizontalSizeClass)
    // TODO: If Entries grows large enough for full-list grouping to show up in
    // profiling, move this boundary into persistence instead of adding a shallow
    // fetchLimit: store a day section key on `Card`, or fetch by month/year
    // ranges and group only the visible archive window.
    let groups = SavedListCardGroup.groups(for: cards)
    let daySections = SavedListDaySection.sections(
      for: groups,
      presentation: groupPresentation,
      calendar: calendar
    )

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
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            groupPresentation.toggle()
          }
        } label: {
          Image(systemName: groupPresentation.toggleSymbolName)
        }
        .accessibilityLabel(groupPresentation.toggleAccessibilityLabel)
      }
    }
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

/// How relationship groups are represented in the entries grid.
private enum SavedListGroupPresentation {
  /// Relationship groups are collapsed to one stacked tile.
  case stacked

  /// Relationship groups are expanded into their member cards.
  case expanded

  mutating func toggle() {
    switch self {
    case .stacked:
      self = .expanded
    case .expanded:
      self = .stacked
    }
  }

  var toggleSymbolName: String {
    switch self {
    case .stacked:
      return "square.grid.2x2"
    case .expanded:
      return "square.stack.3d.up"
    }
  }

  var toggleAccessibilityLabel: LocalizedStringResource {
    switch self {
    case .stacked:
      return "Show expanded card groups"
    case .expanded:
      return "Show stacked card groups"
    }
  }
}

/// A relationship-connected group of cards in the saved entries list.
///
/// The grouping treats `CardRelationship` as an undirected edge for list
/// presentation. The relationship still keeps its directed meaning in detail
/// views; the list only needs to know which cards should travel together.
private struct SavedListCardGroup: Identifiable {
  let id: UUID
  let cards: [Card]

  var primaryCard: Card {
    cards[0]
  }

  var sectionDate: Date {
    primaryCard.createdAt
  }

  var isStackable: Bool {
    cards.count > 1
  }

  func gridItems(for presentation: SavedListGroupPresentation) -> [SavedListDayGridItem] {
    switch presentation {
    case .stacked where isStackable:
      return [.stack(self)]
    case .stacked, .expanded:
      return cards.enumerated().map { index, card in
        .card(
          SavedListCardGridItem(
            card: card,
            relationshipGroupCards: cards,
            groupPosition: isStackable ? index + 1 : nil,
            groupCount: isStackable ? cards.count : nil
          )
        )
      }
    }
  }

  static func groups(for cards: [Card]) -> [SavedListCardGroup] {
    guard cards.isEmpty == false else { return [] }

    var unionFind = SavedListCardUnionFind(cards: cards)

    for card in cards {
      for relationship in card.outgoingRelationships ?? [] {
        guard let targetID = relationship.target?.id else { continue }
        unionFind.union(card.id, targetID)
      }

      for relationship in card.incomingRelationships ?? [] {
        guard let sourceID = relationship.source?.id else { continue }
        unionFind.union(card.id, sourceID)
      }
    }

    var groupedCards: [UUID: [Card]] = [:]
    for card in cards {
      let groupID = unionFind.root(of: card.id)
      groupedCards[groupID, default: []].append(card)
    }

    return groupedCards.map { groupID, cards in
      SavedListCardGroup(
        id: groupID,
        cards: cards.sortedForSavedListGroup()
      )
    }
    .sortedForSavedList()
  }
}

/// One flattened item that the day grid can render.
private enum SavedListDayGridItem: Identifiable {
  case card(SavedListCardGridItem)
  case stack(SavedListCardGroup)

  var id: String {
    switch self {
    case .card(let item):
      return "card-\(item.card.id.uuidString)"
    case .stack(let group):
      return "stack-\(group.id.uuidString)"
    }
  }
}

/// A single card plus optional relationship-group position metadata.
private struct SavedListCardGridItem {
  let card: Card
  let relationshipGroupCards: [Card]
  let groupPosition: Int?
  let groupCount: Int?
}

/// Stable component builder for relationship-connected list groups.
private struct SavedListCardUnionFind {
  private var parentByID: [UUID: UUID]

  init(cards: [Card]) {
    var parentByID: [UUID: UUID] = [:]
    for card in cards {
      parentByID[card.id] = card.id
    }
    self.parentByID = parentByID
  }

  mutating func root(of id: UUID) -> UUID {
    guard let parent = parentByID[id] else { return id }
    guard parent != id else { return id }

    let rootID = root(of: parent)
    parentByID[id] = rootID
    return rootID
  }

  mutating func union(_ lhs: UUID, _ rhs: UUID) {
    guard parentByID[lhs] != nil, parentByID[rhs] != nil else { return }

    let lhsRoot = root(of: lhs)
    let rhsRoot = root(of: rhs)

    guard lhsRoot != rhsRoot else { return }

    let orderedRoots = [lhsRoot, rhsRoot].sortedByUUIDString()
    parentByID[orderedRoots[1]] = orderedRoots[0]
  }
}

/// One local-calendar date bucket in the saved entries list.
///
/// Identity is the start-of-day `Date` in the active SwiftUI calendar
/// environment, so the section stays stable while cards are inserted, deleted,
/// or edited within the same day.
private struct SavedListDaySection: Identifiable {
  let id: Date
  let day: Date
  var items: [SavedListDayGridItem]

  init(day: Date, items: [SavedListDayGridItem]) {
    self.id = day
    self.day = day
    self.items = items
  }

  static func sections(
    for groups: [SavedListCardGroup],
    presentation: SavedListGroupPresentation,
    calendar: Calendar
  ) -> [SavedListDaySection] {
    var sectionIndexesByDay: [Date: Int] = [:]
    var sections: [SavedListDaySection] = []

    for group in groups {
      let day = calendar.startOfDay(for: group.sectionDate)
      let items = group.gridItems(for: presentation)

      if let sectionIndex = sectionIndexesByDay[day] {
        sections[sectionIndex].items.append(contentsOf: items)
      } else {
        sectionIndexesByDay[day] = sections.count
        sections.append(SavedListDaySection(day: day, items: items))
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
        ForEach(section.items) { item in
          switch item {
          case .card(let item):
            SavedListCardNavigationTile(
              item: item,
              onShare: onShare,
              namespace: namespace
            )
          case .stack(let group):
            SavedListStackedCardGroupNavigationTile(
              group: group,
              onShare: onShare,
              namespace: namespace
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

/// A normal saved-entry card tile, with optional group-position chrome.
private struct SavedListCardNavigationTile: View {

  let item: SavedListCardGridItem
  let onShare: @MainActor (Card) -> Void
  let namespace: Namespace.ID

  var body: some View {
    NavigationLink {
      SavedEntryDetailView(
        card: item.card,
        relationshipGroupCards: item.relationshipGroupCards,
        onShare: onShare
      )
      .navigationTransition(.zoom(sourceID: item.card, in: namespace))
    } label: {
      ZStack(alignment: .topTrailing) {
        SavedListMatchedSummaryCard(
          card: item.card,
          namespace: namespace,
          isNavigationSource: true
        )

        if let groupPosition = item.groupPosition, let groupCount = item.groupCount {
          SavedListCardGroupPositionBadge(
            position: groupPosition,
            count: groupCount
          )
          .padding(8)
        }
      }
    }
    .buttonStyle(.plain)
    .contextMenu {
      SavedEntrySummaryCardContextMenu(
        card: item.card,
        onShare: onShare
      )
    }
  }
}

/// A collapsed relationship group represented as a stack of cards.
private struct SavedListStackedCardGroupNavigationTile: View {

  let group: SavedListCardGroup
  let onShare: @MainActor (Card) -> Void
  let namespace: Namespace.ID

  var body: some View {
    NavigationLink {
      SavedEntryDetailView(
        card: group.primaryCard,
        relationshipGroupCards: group.cards,
        onShare: onShare
      )
      .navigationTransition(.zoom(sourceID: group.primaryCard, in: namespace))
    } label: {
      SavedListStackedCardGroupTile(
        group: group,
        namespace: namespace
      )
    }
    .buttonStyle(.plain)
    .contextMenu {
      SavedEntrySummaryCardContextMenu(
        card: group.primaryCard,
        onShare: onShare
      )
    }
  }
}

/// Visual treatment for a collapsed relationship group.
private struct SavedListStackedCardGroupTile: View {

  let group: SavedListCardGroup
  let namespace: Namespace.ID

  var body: some View {
    ZStack(alignment: .topTrailing) {
      ZStack(alignment: .topLeading) {
        Color.clear
          .aspectRatio(CardMetrics.aspectRatio, contentMode: .fit)

        ForEach(SavedListStackCardLayer.layers(for: group.cards)) { layer in
          SavedListStackCardLayerView(
            layer: layer,
            namespace: namespace
          )
        }
      }

      SavedListCardStackCountBadge(count: group.cards.count)
        .padding(8)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(group.cards.count) related cards")
  }
}

/// One visible or hidden card layer inside a collapsed stack.
private struct SavedListStackCardLayerView: View {

  let layer: SavedListStackCardLayer
  let namespace: Namespace.ID

  var body: some View {
    if layer.isVisible {
      SavedListMatchedSummaryCard(
        card: layer.card,
        namespace: namespace,
        isNavigationSource: layer.isPrimary
      )
      .scaleEffect(layer.scale, anchor: .topLeading)
      .offset(x: layer.offset.width, y: layer.offset.height)
      .opacity(layer.opacity)
      .zIndex(layer.zIndex)
      .allowsHitTesting(layer.isPrimary)
    } else {
      SavedListHiddenMatchedCardAnchor(
        card: layer.card,
        namespace: namespace
      )
      .scaleEffect(layer.scale, anchor: .topLeading)
      .offset(x: layer.offset.width, y: layer.offset.height)
      .zIndex(layer.zIndex)
    }
  }
}

/// Summary card with identities shared by stacked and expanded list modes.
private struct SavedListMatchedSummaryCard: View {

  let card: Card
  let namespace: Namespace.ID
  let isNavigationSource: Bool

  var body: some View {
    let cardView = SavedEntrySummaryCardHost(card: card)
      .matchedGeometryEffect(
        id: SavedListCardGeometryID(cardID: card.id),
        in: namespace,
        properties: .frame,
        anchor: .topLeading
      )

    if isNavigationSource {
      cardView
        .matchedTransitionSource(id: card, in: namespace)
    } else {
      cardView
    }
  }
}

/// Invisible collapsed-state source for cards hidden behind the visual stack cap.
///
/// The card content is intentionally not loaded here; the view only contributes
/// a matched frame so every expanded card has a collapsed counterpart.
private struct SavedListHiddenMatchedCardAnchor: View {

  let card: Card
  let namespace: Namespace.ID

  var body: some View {
    Color.clear
      .aspectRatio(CardMetrics.aspectRatio, contentMode: .fit)
      .matchedGeometryEffect(
        id: SavedListCardGeometryID(cardID: card.id),
        in: namespace,
        properties: .frame,
        anchor: .topLeading
      )
      .opacity(0)
      .accessibilityHidden(true)
      .allowsHitTesting(false)
  }
}

/// Stable namespace id for card-to-card list expansion geometry.
private struct SavedListCardGeometryID: Hashable {
  let cardID: UUID
}

/// Backing layer geometry for one visible card in the collapsed stack tile.
private struct SavedListStackCardLayer: Identifiable {
  let id: UUID
  let card: Card
  let isPrimary: Bool
  let isVisible: Bool
  let offset: CGSize
  let scale: CGFloat
  let opacity: Double
  let zIndex: Double

  static func layers(for cards: [Card]) -> [SavedListStackCardLayer] {
    cards
      .enumerated()
      .reversed()
      .map { index, card in
        let visibleIndex = min(index, visibleStackCardLimit - 1)
        let isVisible = index < visibleStackCardLimit

        return SavedListStackCardLayer(
          id: card.id,
          card: card,
          isPrimary: index == 0,
          isVisible: isVisible,
          offset: CGSize(width: CGFloat(visibleIndex) * 7, height: CGFloat(visibleIndex) * 7),
          scale: 1 - CGFloat(visibleIndex) * 0.035,
          opacity: index == 0 ? 1 : 0.72,
          zIndex: isVisible ? Double(visibleStackCardLimit - index) : -Double(index)
        )
      }
  }

  /// More than three visible cards reads as noise; hidden anchors keep animation complete.
  private static let visibleStackCardLimit = 3
}

/// Count badge shown on collapsed relationship stacks.
private struct SavedListCardStackCountBadge: View {

  let count: Int

  var body: some View {
    Label {
      Text(count, format: .number)
    } icon: {
      Image(systemName: "square.stack.3d.up")
    }
    .font(.caption2.weight(.bold))
    .foregroundStyle(.appOnSecondaryContainer)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(.appSecondaryContainer.opacity(0.92), in: Capsule())
    .overlay {
      Capsule()
        .strokeBorder(.appOnSecondaryContainer.opacity(0.10), lineWidth: 1)
    }
    .accessibilityLabel("\(count) related cards")
  }
}

/// Position badge shown while a relationship group is expanded.
private struct SavedListCardGroupPositionBadge: View {

  let position: Int
  let count: Int

  var body: some View {
    Text("\(position)/\(count)")
      .font(.caption2.weight(.bold))
      .foregroundStyle(.appOnSecondaryContainer)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .background(.appSecondaryContainer.opacity(0.92), in: Capsule())
      .overlay {
        Capsule()
          .strokeBorder(.appOnSecondaryContainer.opacity(0.10), lineWidth: 1)
      }
      .accessibilityLabel("Card \(position) of \(count) in group")
  }
}

extension Array where Element == Card {

  /// Newest-first card order used inside one relationship group.
  fileprivate func sortedForSavedListGroup() -> [Card] {
    sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt > rhs.createdAt
      }

      return lhs.id.uuidString < rhs.id.uuidString
    }
  }
}

extension Array where Element == SavedListCardGroup {

  /// Newest-active group first, matching the old card-level list ordering.
  fileprivate func sortedForSavedList() -> [SavedListCardGroup] {
    sorted { lhs, rhs in
      if lhs.sectionDate != rhs.sectionDate {
        return lhs.sectionDate > rhs.sectionDate
      }

      return lhs.id.uuidString < rhs.id.uuidString
    }
  }
}

extension Array where Element == UUID {

  fileprivate func sortedByUUIDString() -> [UUID] {
    sorted { lhs, rhs in
      lhs.uuidString < rhs.uuidString
    }
  }
}
