import AppUIComponents
import JournalVault
import SwiftUI

private let detailScreenPadding: CGFloat = 16
private let detailMaximumContentWidth: CGFloat = 720

/// Resolves one fractal detail level from the live relationship graph.
///
/// A destination shows the selected placement and only its direct children.
/// Opening any child pushes this same destination type again. Ancestor ids are
/// filtered defensively while sync repair is resolving a malformed cycle.
struct VaultSavedEntryDetailDestination: View {

  let edgeID: UUID
  let entries: [VaultSavedEntry]
  let childEntriesByParentID: [UUID: [VaultSavedEntry]]
  @Binding var navigationPath: [SavedListNavigationRoute]
  @Binding var detailScrollTargetID: UUID?
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
      if let currentEntry {
        VaultSavedEntryDetailView(
          currentEntry: currentEntry,
          childEntries: directChildren,
          detailScrollTargetID: $detailScrollTargetID,
          isEditingDisabled: isEditingDisabled,
          isDeletingDisabled: isDeletingDisabled,
          isTodoCompletionDisabled: isTodoCompletionDisabled,
          transitionNamespace: transitionNamespace,
          onOpen: openEntry,
          onShare: onShare,
          onEdit: onEdit,
          onDelete: onDelete,
          onToggleTodoCompletion: onToggleTodoCompletion
        )
        .appZoomNavigationTransition(
          sourceID: currentEntry.edgeID,
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

  private var currentEntry: VaultSavedEntry? {
    entries.first { $0.edgeID == edgeID }
  }

  private var directChildren: [VaultSavedEntry] {
    let ancestorEdgeIDs = Set(
      navigationPath
        .prefix(throughEntry: edgeID)
        .compactMap(\.entryEdgeID)
    )
    return (childEntriesByParentID[edgeID] ?? [])
      .filter { ancestorEdgeIDs.contains($0.edgeID) == false }
  }

  private func openEntry(_ entry: VaultSavedEntry) {
    guard navigationPath.contains(.entry(edgeID: entry.edgeID)) == false else {
      return
    }
    navigationPath.append(.entry(edgeID: entry.edgeID))
  }
}

private struct VaultSavedEntryDetailView: View {

  let currentEntry: VaultSavedEntry
  let childEntries: [VaultSavedEntry]
  @Binding var detailScrollTargetID: UUID?
  let isEditingDisabled: Bool
  let isDeletingDisabled: Bool
  let isTodoCompletionDisabled: Bool
  let transitionNamespace: Namespace.ID
  let onOpen: @MainActor (VaultSavedEntry) -> Void
  let onShare: @MainActor (VaultSavedEntry) -> Void
  let onEdit: @MainActor (VaultSavedEntry) -> Void
  let onDelete: @MainActor (VaultSavedEntry) async -> Bool
  let onToggleTodoCompletion: @MainActor (VaultSavedEntry) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.composerOverlayHeight) private var composerOverlayHeight
  @State private var deleteCandidate: VaultSavedEntry?

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .center, spacing: 40) {
          detailRow(currentEntry)

          ForEach(childEntries) { entry in
            detailRow(
              entry,
              onOpen: {
                onOpen(entry)
              }
            )
            .appMatchedTransitionSource(
              id: entry.edgeID,
              in: transitionNamespace
            )
          }
        }
        .frame(maxWidth: .infinity)
        .padding(detailScreenPadding)
      }
      .contentMargins(.bottom, composerOverlayHeight, for: .scrollContent)
      .onChange(of: detailScrollTargetID, initial: true) { _, _ in
        scrollToPendingChild(using: proxy)
      }
      .onChange(of: childEntries.map(\.edgeID)) { _, _ in
        scrollToPendingChild(using: proxy)
      }
    }
    .background(.background)
    .navigationTitle(currentEntry.kind.vaultListDisplayTitle)
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
          if didDelete, entry.edgeID == currentEntry.edgeID {
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

  @ViewBuilder
  private func detailRow(
    _ entry: VaultSavedEntry,
    onOpen: (@MainActor () -> Void)? = nil
  ) -> some View {
    VaultSavedEntryDetailRow(
      entry: entry.entryModel,
      isEditingDisabled: isEditingDisabled || entry.kind == .file,
      isDeletingDisabled: isDeletingDisabled,
      isTodoCompletionDisabled: isTodoCompletionDisabled,
      onEdit: {
        self.onEdit(entry)
      },
      onDelete: {
        deleteCandidate = entry
      },
      onOpen: onOpen,
      onToggleTodoCompletion: {
        onToggleTodoCompletion(entry)
      }
    )
    .contextMenu {
      Button {
        onShare(entry)
      } label: {
        Label("Share", systemImage: "square.and.arrow.up")
      }

      Button {
        self.onEdit(entry)
      } label: {
        Label("Edit", systemImage: "square.and.pencil")
      }
      .disabled(isEditingDisabled || entry.kind == .file)

      Button(role: .destructive) {
        deleteCandidate = entry
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .disabled(isDeletingDisabled)
    }
    .id(entry.edgeID)
    .frame(maxWidth: detailMaximumContentWidth)
  }

  /// Waits for the appended child to enter the live query before scrolling.
  private func scrollToPendingChild(using proxy: ScrollViewProxy) {
    guard let targetID = detailScrollTargetID,
      childEntries.contains(where: { $0.edgeID == targetID })
    else {
      return
    }

    withAnimation(.snappy) {
      proxy.scrollTo(targetID, anchor: .center)
    }
    detailScrollTargetID = nil
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
