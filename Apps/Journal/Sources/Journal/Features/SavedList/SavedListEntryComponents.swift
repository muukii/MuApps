import AppUIComponents
import JournalVault
import MuColor
import SwiftUI

private let rootGroupContentPadding: CGFloat = 16
private let rootGroupCornerRadius: CGFloat = 24

/// Shared spacing for Home trees and re-rooted detail trees.
struct VaultSavedEntryTreeMetrics {
  static let descendantMarkerGutter: CGFloat = 16
  static let nodeSpacing: CGFloat = 2
}

/// Identifies one zoom source inside the tree surface that currently owns it.
///
/// The same edge can remain rendered in Home and multiple retained detail
/// routes. Including the local tree root prevents those hidden surfaces from
/// registering an ambiguous source for the next navigation transition.
struct VaultSavedEntryTransitionSourceID: Hashable {
  let treeRootEdgeID: UUID?
  let edgeID: UUID
}

/// Modal editor for an existing vault card.
///
/// The sheet owns cancellation chrome while `EntryDraftEditor` owns the
/// card-specific editing controls. Saving is lifted to `SavedListView` so the
/// selected vault, reload, and outbox refresh all happen at the screen boundary.
struct VaultSavedEntryEditSheet: View {

  @Bindable var draft: CardEditDraft
  let isSaving: Bool
  let onSave: @MainActor () -> Void
  let onCancel: @MainActor () -> Void

  var body: some View {
    NavigationStack {
      EntryDraftEditor(
        draft: draft,
        isSaving: isSaving,
        confirmationTitle: "Save",
        showsKindPicker: false,
        onConfirm: onSave
      )
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            onCancel()
          }
          .disabled(isSaving)
        }
      }
    }
  }
}

struct VaultSavedEntryRow: View {

  let entry: VaultSavedEntry
  let isNavigationEnabled: Bool
  let isMutationDisabled: Bool
  let transitionSourceTreeRootEdgeID: UUID?
  let transitionNamespace: Namespace.ID
  let onShare: @MainActor (VaultSavedEntry) -> Void
  let onEdit: @MainActor (VaultSavedEntry) -> Void
  let onRequestDelete: @MainActor (VaultSavedEntry) -> Void
  let onToggleTodoCompletion: @MainActor (VaultSavedEntry) -> Void

  init(
    entry: VaultSavedEntry,
    isNavigationEnabled: Bool = true,
    isMutationDisabled: Bool,
    transitionSourceTreeRootEdgeID: UUID?,
    transitionNamespace: Namespace.ID,
    onShare: @escaping @MainActor (VaultSavedEntry) -> Void,
    onEdit: @escaping @MainActor (VaultSavedEntry) -> Void,
    onRequestDelete: @escaping @MainActor (VaultSavedEntry) -> Void,
    onToggleTodoCompletion: @escaping @MainActor (VaultSavedEntry) -> Void
  ) {
    self.entry = entry
    self.isNavigationEnabled = isNavigationEnabled
    self.isMutationDisabled = isMutationDisabled
    self.transitionSourceTreeRootEdgeID = transitionSourceTreeRootEdgeID
    self.transitionNamespace = transitionNamespace
    self.onShare = onShare
    self.onEdit = onEdit
    self.onRequestDelete = onRequestDelete
    self.onToggleTodoCompletion = onToggleTodoCompletion
  }

  var body: some View {
    Group {
      if entry.kind == .todo {
        HStack(alignment: .center, spacing: 0) {
          TodoCompletionButton(isCompleted: entry.isCompleted) {
            onToggleTodoCompletion(entry)
          }
          .padding(.leading, 8)
          .disabled(isMutationDisabled)

          entryPresentation(showsTodoCompletionIndicator: false)
        }
        .background(.appSecondaryContainer)
        .clipShape(.rect(cornerRadius: rootGroupCornerRadius))
      } else {
        entryPresentation(showsTodoCompletionIndicator: true)
      }
    }
    .contextMenu {
      Button {
        onShare(entry)
      } label: {
        Label("Share", systemImage: "square.and.arrow.up")
      }

      Button {
        onEdit(entry)
      } label: {
        Label("Edit", systemImage: "square.and.pencil")
      }
      .disabled(isMutationDisabled || entry.kind == .file)

      Button(role: .destructive) {
        onRequestDelete(entry)
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .disabled(isMutationDisabled)
    }
  }

  @ViewBuilder
  private func entryPresentation(
    showsTodoCompletionIndicator: Bool
  ) -> some View {
    if isNavigationEnabled {
      entryNavigationLink(
        showsTodoCompletionIndicator: showsTodoCompletionIndicator
      )
    } else {
      entryContent(
        showsTodoCompletionIndicator: showsTodoCompletionIndicator
      )
    }
  }

  private func entryNavigationLink(
    showsTodoCompletionIndicator: Bool
  ) -> some View {
    NavigationLink(
      value: SavedListNavigationRoute.entry(edgeID: entry.edgeID)
    ) {
      entryContent(
        showsTodoCompletionIndicator: showsTodoCompletionIndicator
      )
      .appMatchedTransitionSource(
        id: VaultSavedEntryTransitionSourceID(
          treeRootEdgeID: transitionSourceTreeRootEdgeID,
          edgeID: entry.edgeID
        ),
        in: transitionNamespace
      )
    }
    .buttonStyle(.plain)
  }

  private func entryContent(
    showsTodoCompletionIndicator: Bool
  ) -> some View {
    VaultSavedRootGroup(
      entry: entry.entryModel,
      showsTodoCompletionIndicator: showsTodoCompletionIndicator
    )
  }
}

/// Existing saved-entry card presentation within its proposed tree width.
///
/// Descendants reserve one marker gutter while the capsule count communicates
/// their semantic depth without progressively narrowing deeply nested cards.
struct VaultSavedEntryTreeCell: View {

  let depth: Int
  let entry: VaultSavedEntry
  let isNavigationEnabled: Bool
  let isMutationDisabled: Bool
  let transitionSourceTreeRootEdgeID: UUID?
  let transitionNamespace: Namespace.ID
  let onShare: @MainActor (VaultSavedEntry) -> Void
  let onEdit: @MainActor (VaultSavedEntry) -> Void
  let onRequestDelete: @MainActor (VaultSavedEntry) -> Void
  let onToggleTodoCompletion: @MainActor (VaultSavedEntry) -> Void

  var body: some View {
    VaultSavedEntryRow(
      entry: entry,
      isNavigationEnabled: isNavigationEnabled,
      isMutationDisabled: isMutationDisabled,
      transitionSourceTreeRootEdgeID: transitionSourceTreeRootEdgeID,
      transitionNamespace: transitionNamespace,
      onShare: onShare,
      onEdit: onEdit,
      onRequestDelete: onRequestDelete,
      onToggleTodoCompletion: onToggleTodoCompletion
    )
    .padding(
      .leading,
      depth > 0 ? VaultSavedEntryTreeMetrics.descendantMarkerGutter : 0
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .topLeading) {
      HStack(spacing: 1) {
        ForEach(0..<depth, id: \.self) { _ in
          Capsule()
            .frame(width: 6, height: 4)
        }
      }
    }
  }
}

/// Saved-edge presentation shared by Home and re-rooted detail trees.
///
/// The surface belongs to one placement rather than to the authored card. Tree
/// indentation and navigation stay outside this type so the card's current
/// media and content behavior is identical at every depth.
struct VaultSavedRootGroup: View {

  let entry: VaultSavedEntryModel
  let showsTodoCompletionIndicator: Bool

  init(
    entry: VaultSavedEntryModel,
    showsTodoCompletionIndicator: Bool = true
  ) {
    self.entry = entry
    self.showsTodoCompletionIndicator = showsTodoCompletionIndicator
  }

  var body: some View {
    EntryContentView(
      content: entry.content,
      style: .detail,
      showsTodoCompletionIndicator: showsTodoCompletionIndicator
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(.appOnSecondaryContainer)
    .allowsHitTesting(false)
    .contentShape(.rect)
  }
}

struct VaultSavedDayHeader: View {

  let day: Date

  var body: some View {
    Text(day, format: .dateTime.weekday(.abbreviated).month(.wide).day().year())
      .font(.headline)
      .foregroundStyle(.appOnPrimaryContainer.opacity(0.72))
      .accessibilityAddTraits(.isHeader)
      .frame(maxWidth: .infinity, alignment: .center)
  }
}
