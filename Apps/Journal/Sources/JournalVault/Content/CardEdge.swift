import Foundation
import SwiftData

/// Placement of one `Card` in a vault's content tree.
///
/// Root and child placements share this one shape — there is no separate
/// "group" model. A root edge has `parentEdgeID == nil`; child edges point at a
/// parent edge in the same vault. `children` arrays are never persisted; the
/// tree is derived from `parentEdgeID`, so ordering, nesting, and layout
/// changes are ordinary row mutations.
///
/// Domain rules (enforced by `VaultContentStore`, not by the schema and not by
/// CloudKit record hierarchy):
/// - every visible card is referenced by exactly one edge
/// - `parentEdgeID` may only point at an edge in the same vault
/// - cycles are forbidden
/// - a linear thread is a root edge plus children ordered by `sortIndex`
@Model
public final class CardEdge {

  @Attribute(.unique)
  public var id: UUID

  public var cardID: UUID

  public var parentEdgeID: UUID?

  /// Order among siblings under the same parent (authored order for threads).
  public var sortIndex: Int

  /// Encoded layout metadata for spatial trees (mind-map positions). Shape is
  /// intentionally undecided; linear threads leave it `nil`.
  public var layout: Data?

  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    cardID: UUID,
    parentEdgeID: UUID? = nil,
    sortIndex: Int = 0,
    layout: Data? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.cardID = cardID
    self.parentEdgeID = parentEdgeID
    self.sortIndex = sortIndex
    self.layout = layout
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
