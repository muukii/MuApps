import JournalModel
import MuColor
import SwiftData
import SwiftUI

/// SwiftData + iCloud entries list.
///
/// The real journaling interface is still being designed; this exists only to
/// verify the SwiftData + CloudKit stack end-to-end (read via `@Query`, write via
/// `modelContext`). Hosted inside the dev gallery's navigation stack.
///
/// Cards are laid out as a two-column grid of portrait tiles shaped like a sheet
/// of paper (1 : 1.1414).
struct ListView: View {

  @Environment(\.modelContext) private var modelContext
  @Query(sort: \Card.createdAt, order: .reverse) private var cards: [Card]

  private let columns = [
    GridItem(.flexible(), spacing: cardSpacing),
    GridItem(.flexible(), spacing: cardSpacing),
  ]

  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: cardSpacing) {
        ForEach(cards) { card in
          CardTile(
            title: card.title.isEmpty ? "Untitled" : card.title,
            createdAt: card.createdAt,
            tilt: card.tiltAngle
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
      ToolbarItem(placement: .primaryAction) {
        Button("Add", systemImage: "plus") {
          modelContext.insert(Card(title: "New Card"))
        }
      }
    }
  }
}

/// Gutter between cards and around the grid, kept equal so columns and edges
/// share the same rhythm.
private let cardSpacing: CGFloat = 16

/// Width-to-height ratio of a card tile. The card stands taller than it is wide
/// (1 : 1.1414), so the value passed to `aspectRatio` is `width / height`.
private let cardAspectRatio: CGFloat = 1 / 1.1414

/// Maximum absolute tilt for a card, in degrees. Each tile picks a stable angle
/// in `-cardMaxTilt ... +cardMaxTilt` from its id, giving the grid a loosely
/// hand-placed feel rather than a rigid one.
private let cardMaxTilt: Double = 3

// MARK: - Fileprivate Views

/// A single journal card rendered as a portrait tile: title pinned to the top,
/// date to the bottom, tilted slightly off-axis.
private struct CardTile: View {

  let title: String
  let createdAt: Date
  let tilt: Angle

  var body: some View {
    RoundedRectangle(cornerRadius: 16, style: .continuous)
      .fill(.appSecondaryContainer)
      .aspectRatio(cardAspectRatio, contentMode: .fit)
      .overlay {
        VStack(alignment: .leading, spacing: 8) {
          Text(title)
            .font(.headline)
            .lineLimit(4)

          Spacer(minLength: 8)

          Text(createdAt, format: .dateTime)
            .font(.caption)
            .foregroundStyle(.appOnSecondaryContainer.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .foregroundStyle(.appOnSecondaryContainer)
      }
      .rotationEffect(tilt)
  }
}

// MARK: - Formatting Helpers

extension Card {
  /// A small, stable tilt derived from the card's id. Deriving it from the id
  /// (rather than `Double.random` inside `body`) keeps each card at a fixed
  /// angle across launches and stops it from re-rolling every time the body is
  /// re-evaluated.
  fileprivate var tiltAngle: Angle {
    let bytes = id.uuid
    let seed = UInt(bytes.0) &+ (UInt(bytes.7) &* 31) &+ (UInt(bytes.15) &* 131)
    let fraction = Double(seed % 1000) / 999  // 0...1
    return .degrees((fraction * 2 - 1) * cardMaxTilt)  // -max ... +max
  }
}

#Preview {
  PrimaryContainer(theme: .default) {
    NavigationStack {
      ListView()
    }
  }
  .modelContainer(for: Card.self, inMemory: true)
}
