import AppUIComponents
import JournalVault
import SwiftUI

private let detailScreenPadding: CGFloat = 16

/// Resolves one re-rooted detail tree from the live relationship graph.
///
/// The selected placement becomes the local root. Ancestors and siblings stay
/// represented by the navigation path instead of being repeated in this view.
struct VaultSavedEntryDetailDestination: View {

  let edgeID: UUID
  let treeProjection: SavedEntryTreeProjection<VaultSavedEntry>
  @Binding var navigationPath: [SavedListNavigationRoute]
  @Binding var detailScrollRequest: SavedListDetailScrollRequest?
  let isEditingDisabled: Bool
  let isDeletingDisabled: Bool
  let isTodoCompletionDisabled: Bool
  let transitionNamespace: Namespace.ID
  let onShare: @MainActor (VaultSavedEntry) -> Void
  let onEdit: @MainActor (VaultSavedEntry) -> Void
  let onDelete: @MainActor (VaultSavedEntry) async -> Bool
  let onToggleTodoCompletion: @MainActor (VaultSavedEntry) -> Void

  var body: some View {
    Group {
      if let tree {
        VaultSavedEntryDetailView(
          tree: tree,
          detailScrollRequest: $detailScrollRequest,
          isEditingDisabled: isEditingDisabled,
          isDeletingDisabled: isDeletingDisabled,
          isTodoCompletionDisabled: isTodoCompletionDisabled,
          transitionNamespace: transitionNamespace,
          onShare: onShare,
          onEdit: onEdit,
          onDelete: onDelete,
          onToggleTodoCompletion: onToggleTodoCompletion
        )
        .appZoomNavigationTransition(
          sourceID: transitionSourceID,
          in: transitionNamespace
        )
      } else {
        ContentUnavailableView(
          "Entry Not Found",
          systemImage: "questionmark.square.dashed"
        )
      }
    }
  }

  private var tree: SavedEntryTreeProjection<VaultSavedEntry>.Node? {
    let ancestorEdgeIDs = Set(
      navigationPath
        .prefix(throughEntry: edgeID)
        .compactMap(\.entryEdgeID)
        .filter { $0 != edgeID }
    )
    return treeProjection.tree(
      startingAt: edgeID,
      excluding: ancestorEdgeIDs
    )
  }

  /// Matches the source registered by the tree surface immediately below this
  /// route, rather than another retained surface that renders the same edge.
  private var transitionSourceID: VaultSavedEntryTransitionSourceID {
    let route = SavedListNavigationRoute.entry(edgeID: edgeID)
    let sourceTreeRootEdgeID = navigationPath.firstIndex(of: route)
      .flatMap { index in
        navigationPath[..<index].last?.entryEdgeID
      }
    return VaultSavedEntryTransitionSourceID(
      treeRootEdgeID: sourceTreeRootEdgeID,
      edgeID: edgeID
    )
  }
}

/// Detail surface for a subtree whose first node is the current route.
private struct VaultSavedEntryDetailView: View {

  let tree: SavedEntryTreeProjection<VaultSavedEntry>.Node
  @Binding var detailScrollRequest: SavedListDetailScrollRequest?
  let isEditingDisabled: Bool
  let isDeletingDisabled: Bool
  let isTodoCompletionDisabled: Bool
  let transitionNamespace: Namespace.ID
  let onShare: @MainActor (VaultSavedEntry) -> Void
  let onEdit: @MainActor (VaultSavedEntry) -> Void
  let onDelete: @MainActor (VaultSavedEntry) async -> Bool
  let onToggleTodoCompletion: @MainActor (VaultSavedEntry) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.composerOverlayHeight) private var composerOverlayHeight
  @State private var deleteCandidate: VaultSavedEntry?

  var body: some View {
    TreeScrollView(
      root: tree,
      spacing: VaultSavedEntryTreeMetrics.nodeSpacing,
      scrollTargetID: detailScrollRequest?.targetID(ownedBy: tree.id),
      onScrollTargetResolved: { targetID in
        if detailScrollRequest?.ownerDetailRootEdgeID == tree.id,
          detailScrollRequest?.targetEdgeID == targetID
        {
          detailScrollRequest = nil
        }
      }
    ) { entry, context in
      VaultSavedEntryTreeCell(
        depth: context.indentationDepth,
        entry: entry,
        isNavigationEnabled: entry.edgeID != tree.id,
        isMutationDisabled: isEditingDisabled || isDeletingDisabled
          || isTodoCompletionDisabled,
        transitionSourceTreeRootEdgeID: tree.id,
        transitionNamespace: transitionNamespace,
        onShare: onShare,
        onEdit: onEdit,
        onRequestDelete: { entry in
          deleteCandidate = entry
        },
        onToggleTodoCompletion: onToggleTodoCompletion
      )
    }
    .padding(.horizontal, detailScreenPadding)
    .contentMargins(.bottom, composerOverlayHeight, for: .scrollContent)
    .background(.background)
    .navigationTitle(tree.body.kind.vaultListDisplayTitle)
    .appInlineNavigationTitle()
    .confirmationDialog(
      "Delete Entry",
      isPresented: deleteConfirmationPresentation,
      titleVisibility: .visible,
      presenting: deleteCandidate
    ) { entry in
      Button("Delete Entry", role: .destructive) {
        deleteCandidate = nil
        Task { @MainActor in
          let didDelete = await onDelete(entry)
          if didDelete, entry.edgeID == tree.id {
            dismiss()
          }
        }
      }
      Button("Cancel", role: .cancel) {
        deleteCandidate = nil
      }
    } message: { _ in
      Text(
        "This entry and its connected entries will be removed from this vault. Synced copies are deleted through iCloud."
      )
    }
  }

  private var deleteConfirmationPresentation: Binding<Bool> {
    Binding {
      deleteCandidate != nil
    } set: { isPresented in
      if isPresented == false {
        deleteCandidate = nil
      }
    }
  }

}

extension SavedListNavigationRoute {

  fileprivate var entryEdgeID: UUID? {
    guard case .entry(let edgeID) = self else { return nil }
    return edgeID
  }
}

extension Array where Element == SavedListNavigationRoute {

  /// Returns the route ancestry through the first occurrence of `edgeID`.
  fileprivate func prefix(throughEntry edgeID: UUID) -> ArraySlice<Element> {
    guard let index = firstIndex(of: .entry(edgeID: edgeID)) else {
      return self[...]
    }
    return self[...index]
  }
}
