import Foundation
import SwiftData

/// Placement of one `Card` in a vault's content tree.
///
/// Root and child placements share this one shape — there is no separate
/// "group" model. A root edge has `parent == nil`; child edges point at a
/// parent edge in the same vault. Relationship repair ids are kept internally
/// so CloudKit can import edges out of order without leaking transport ordering
/// to UI code.
///
/// Domain rules (enforced by `VaultContentStore`, not by the schema and not by
/// CloudKit record hierarchy):
/// - every visible card is referenced by exactly one edge
/// - `parent` may only point at an edge in the same vault
/// - cycles are forbidden
/// - a linear thread is a root edge plus children ordered by `sortIndex`
@Model
public final class CardEdge {

  @Attribute(.unique)
  public var id: UUID

  /// Card placed by this edge once the local graph has been repaired.
  public var card: Card?

  /// Parent edge for child cards in a thread or future spatial tree.
  public var parent: CardEdge?

  /// Child placements under this edge.
  @Relationship(deleteRule: .cascade, inverse: \CardEdge.parent)
  public var children: [CardEdge] = []

  /// CloudKit import/export and out-of-order repair key for `card`.
  var cardReferenceID: UUID

  /// CloudKit import/export and out-of-order repair key for `parent`.
  var parentEdgeReferenceID: UUID?

  /// Order among siblings under the same parent (authored order for threads).
  public var sortIndex: Int

  /// Encoded layout metadata for spatial trees (mind-map positions). Shape is
  /// intentionally undecided; linear threads leave it `nil`.
  public var layout: Data?

  public var createdAt: Date
  public var updatedAt: Date

  /// Local timestamp at which this placement left the active journal.
  ///
  /// Deleted placements stay attached to their SwiftData context so existing
  /// SwiftUI observers can finish rendering safely and a future trash flow can
  /// restore the subtree. This state is intentionally not exported to
  /// CloudKit; remote record existence remains the synchronization signal.
  public var deletedAt: Date?

  public init(
    id: UUID = UUID(),
    cardID: UUID,
    parentEdgeID: UUID? = nil,
    sortIndex: Int = 0,
    layout: Data? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    deletedAt: Date? = nil
  ) {
    self.id = id
    self.cardReferenceID = cardID
    self.parentEdgeReferenceID = parentEdgeID
    self.sortIndex = sortIndex
    self.layout = layout
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }
}

// MARK: - Relationships

extension CardEdge {

  /// Stable id of the placed card.
  ///
  /// Reads from the repaired relationship when available and falls back to the
  /// sync reference while imports are still out of order.
  public var cardID: UUID {
    card?.id ?? cardReferenceID
  }

  /// Stable id of the parent edge, if this edge is currently a child.
  public var parentEdgeID: UUID? {
    parent?.id ?? parentEdgeReferenceID
  }

  func setCardReferenceID(_ id: UUID) {
    cardReferenceID = id
    if card?.id != id {
      card = nil
    }
  }

  func connect(to card: Card) {
    cardReferenceID = card.id
    self.card = card
  }

  func setParentEdgeReferenceID(_ id: UUID?) {
    parentEdgeReferenceID = id
    if parent?.id != id {
      parent = nil
    }
  }

  func connect(parent: CardEdge?) {
    parentEdgeReferenceID = parent?.id
    self.parent = parent
  }
}
