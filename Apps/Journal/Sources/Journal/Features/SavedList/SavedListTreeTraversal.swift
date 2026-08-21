import Foundation
import JournalVault

/// Structural traversal rules shared by the live Home tree and its focused
/// scroll/location queries.
///
/// This type deliberately returns live `CardEdge` references instead of a
/// detached content tree. The caller invokes these functions from a SwiftUI
/// observation boundary, so reads of `card`, `children`, and relationship state
/// remain tied to the current SwiftData graph.
enum VaultSavedListTreeTraversal {

  /// Returns active, resolved root placements in Home's newest-first order.
  ///
  /// An edge with an unresolved parent reference is not a root even when its
  /// `parent` relationship is temporarily nil during an out-of-order import.
  static func activeResolvedRoots(
    from edges: [JournalVault.CardEdge]
  ) -> [JournalVault.CardEdge] {
    edges
      .filter { edge in
        edge.deletedAt == nil
          && edge.parentEdgeID == nil
          && edge.card != nil
      }
      .sorted(by: isOrderedBeforeRoot)
  }

  /// Returns the active resolved placement ids used by Reply availability and
  /// the first stage of post-success scroll resolution.
  static func activeResolvedEdgeIDs(
    from edges: [JournalVault.CardEdge]
  ) -> Set<UUID> {
    Set(
      edges.compactMap { edge in
        guard edge.deletedAt == nil, edge.card != nil else { return nil }
        return edge.id
      }
    )
  }

  /// Returns roots whose subtree contains at least one matching placement.
  ///
  /// With no selected kind every valid root is visible. A root itself may be
  /// filtered out while a matching descendant remains reachable beneath it.
  static func visibleRoots(
    from roots: [JournalVault.CardEdge],
    selectedContentKind: JournalVault.Card.Kind?
  ) -> [JournalVault.CardEdge] {
    roots.filter { root in
      containsVisiblePlacement(
        in: root,
        selectedContentKind: selectedContentKind
      )
    }
  }

  /// Returns active children in authored sibling order.
  ///
  /// A child without a resolved card is omitted together with its descendants;
  /// such a placement cannot be rendered or safely used as a tree boundary.
  static func orderedActiveChildren(
    of edge: JournalVault.CardEdge,
    pathEdgeIDs: Set<UUID>
  ) -> [JournalVault.CardEdge] {
    edge.children
      .filter { child in
        child.deletedAt == nil
          && child.card != nil
          && pathEdgeIDs.contains(child.id) == false
      }
      .sorted(by: isOrderedBeforeSibling)
  }

  /// Whether a visible placement matching the selected kind is reachable from
  /// the supplied edge.
  static func containsVisiblePlacement(
    in edge: JournalVault.CardEdge,
    selectedContentKind: JournalVault.Card.Kind?,
    pathEdgeIDs: Set<UUID> = []
  ) -> Bool {
    guard edge.deletedAt == nil, edge.card != nil else { return false }

    var pathEdgeIDs = pathEdgeIDs
    guard pathEdgeIDs.insert(edge.id).inserted else { return false }

    if selectedContentKind == nil || edge.card?.kind == selectedContentKind {
      return true
    }

    return orderedActiveChildren(of: edge, pathEdgeIDs: pathEdgeIDs).contains {
      containsVisiblePlacement(
        in: $0,
        selectedContentKind: selectedContentKind,
        pathEdgeIDs: pathEdgeIDs
      )
    }
  }

  /// Whether a particular visible placement is reachable from a root.
  ///
  /// Scroll resolution uses this focused search instead of materializing every
  /// node in the root subtree merely to find one newly created edge.
  static func containsVisiblePlacement(
    edgeID targetEdgeID: UUID,
    in edge: JournalVault.CardEdge,
    selectedContentKind: JournalVault.Card.Kind?,
    pathEdgeIDs: Set<UUID> = []
  ) -> Bool {
    guard edge.deletedAt == nil, let card = edge.card else { return false }

    var pathEdgeIDs = pathEdgeIDs
    guard pathEdgeIDs.insert(edge.id).inserted else { return false }

    if edge.id == targetEdgeID,
      selectedContentKind == nil || card.kind == selectedContentKind
    {
      return true
    }

    return orderedActiveChildren(of: edge, pathEdgeIDs: pathEdgeIDs).contains {
      containsVisiblePlacement(
        edgeID: targetEdgeID,
        in: $0,
        selectedContentKind: selectedContentKind,
        pathEdgeIDs: pathEdgeIDs
      )
    }
  }

  /// Returns every visible placement in root order for map annotations.
  ///
  /// The result contains live placement references only for the duration of
  /// the caller's derivation. It is not retained as a display projection.
  static func visiblePlacements(
    in roots: [JournalVault.CardEdge],
    selectedContentKind: JournalVault.Card.Kind?
  ) -> [JournalVault.CardEdge] {
    roots.flatMap { root in
      visiblePlacements(
        in: root,
        selectedContentKind: selectedContentKind
      )
    }
  }

  private static func visiblePlacements(
    in edge: JournalVault.CardEdge,
    selectedContentKind: JournalVault.Card.Kind?,
    pathEdgeIDs: Set<UUID> = []
  ) -> [JournalVault.CardEdge] {
    guard edge.deletedAt == nil, let card = edge.card else { return [] }

    var pathEdgeIDs = pathEdgeIDs
    guard pathEdgeIDs.insert(edge.id).inserted else { return [] }

    var result: [JournalVault.CardEdge] = []
    if selectedContentKind == nil || card.kind == selectedContentKind {
      result.append(edge)
    }

    for child in orderedActiveChildren(of: edge, pathEdgeIDs: pathEdgeIDs) {
      result.append(
        contentsOf: visiblePlacements(
          in: child,
          selectedContentKind: selectedContentKind,
          pathEdgeIDs: pathEdgeIDs
        )
      )
    }
    return result
  }

  private static func isOrderedBeforeRoot(
    _ lhs: JournalVault.CardEdge,
    _ rhs: JournalVault.CardEdge
  ) -> Bool {
    guard let lhsCard = lhs.card, let rhsCard = rhs.card else {
      return lhs.id.uuidString < rhs.id.uuidString
    }
    if lhsCard.createdAt != rhsCard.createdAt {
      return lhsCard.createdAt > rhsCard.createdAt
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }

  private static func isOrderedBeforeSibling(
    _ lhs: JournalVault.CardEdge,
    _ rhs: JournalVault.CardEdge
  ) -> Bool {
    if lhs.sortIndex != rhs.sortIndex {
      return lhs.sortIndex < rhs.sortIndex
    }

    guard let lhsCard = lhs.card, let rhsCard = rhs.card else {
      return lhs.id.uuidString < rhs.id.uuidString
    }
    if lhsCard.createdAt != rhsCard.createdAt {
      return lhsCard.createdAt < rhsCard.createdAt
    }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
