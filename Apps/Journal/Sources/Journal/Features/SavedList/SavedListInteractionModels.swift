import Foundation
import JournalVault

/// A detached placement selected as the parent of one Reply.
///
/// Reply selection is explicit UI state. It never retains a live SwiftData
/// model and is never inferred from navigation or from whichever tree node is
/// currently visible.
nonisolated struct SavedListReplyTarget: Equatable, Sendable {

  /// Vault that owned the selected placement when the user chose Reply.
  let vaultID: VaultID

  /// Stable placement identity passed to `appendCard(_:to:)` as the parent.
  let parentEdgeID: UUID

  /// Home root whose rendered subtree contains the selected parent.
  let ownerRootEdgeID: UUID

  /// Detached, already-localized text shown above the composer.
  let displaySummary: String
}

/// One post-success reveal owned by Home's vertical scroll surface.
nonisolated struct SavedListScrollRequest: Equatable, Sendable {

  /// Root row that Home must materialize before a descendant can be revealed.
  let ownerRootEdgeID: UUID

  /// Newly created root or Reply child that should become visible.
  let targetEdgeID: UUID

  /// Resolves the next deterministic step from query, live-tree reachability,
  /// and layout availability without performing a SwiftUI side effect itself.
  func resolution(
    allEdgeIDs: Set<UUID>,
    visibleRootEdgeIDs: Set<UUID>,
    targetIsVisibleInOwnerRoot: Bool,
    renderedEdgeIDs: Set<UUID>
  ) -> SavedListScrollResolution {
    guard allEdgeIDs.contains(targetEdgeID) else {
      return .waitForQuery
    }
    guard visibleRootEdgeIDs.contains(ownerRootEdgeID) else {
      return .consumeWithoutScrolling
    }
    guard targetIsVisibleInOwnerRoot else {
      return .consumeWithoutScrolling
    }
    guard renderedEdgeIDs.contains(targetEdgeID) else {
      return .materializeOwnerRoot(ownerRootEdgeID)
    }

    if ownerRootEdgeID == targetEdgeID {
      return .revealRoot(targetEdgeID)
    }
    return .revealReply(targetEdgeID)
  }
}

/// A pure scroll decision consumed by the Home `ScrollViewReader` coordinator.
nonisolated enum SavedListScrollResolution: Equatable, Sendable {
  case waitForQuery
  case materializeOwnerRoot(UUID)
  case revealRoot(UUID)
  case revealReply(UUID)
  case consumeWithoutScrolling
}
