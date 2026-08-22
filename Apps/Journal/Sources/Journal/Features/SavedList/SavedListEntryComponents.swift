import AppUIComponents
import JournalVault
import MuColor
import SwiftUI

private struct SavedListMutationDisabledKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {

  /// Whether Home row mutations are temporarily disabled by another action.
  var savedListMutationDisabled: Bool {
    get { self[SavedListMutationDisabledKey.self] }
    set { self[SavedListMutationDisabledKey.self] = newValue }
  }
}

/// Shared spacing for trees rendered on Home.
struct VaultSavedEntryTreeMetrics {
  static let descendantMarkerGutter: CGFloat = 16
  static let nodeSpacing: CGFloat = 2
}

/// Recursively renders one live `CardEdge` placement and its active children.
///
/// The view intentionally emits the matching row and child `ForEach` as
/// siblings instead of wrapping each node in a nested `VStack`. A filtered
/// ancestor therefore contributes no card while its descendants retain their
/// semantic depth and participate in the surrounding Home `LazyVStack`.
struct VaultSavedEntryTreeRows: View {

  let edge: JournalVault.CardEdge
  let store: VaultContentStore
  let depth: Int
  let selectedContentKind: JournalVault.Card.Kind?
  let ancestorEdgeIDs: Set<UUID>
  let ownerRootEdgeID: UUID
  let onReply: @MainActor (JournalVault.CardEdge, JournalVault.Card, UUID) -> Void
  let onShare: @MainActor (JournalVault.CardEdge, JournalVault.Card) -> Void
  let onEdit: @MainActor (JournalVault.Card) -> Void
  let onRequestDelete: @MainActor (JournalVault.CardEdge, JournalVault.Card) -> Void
  let onToggleTodoCompletion: @MainActor (JournalVault.Card) -> Void

  @Environment(\.savedListMutationDisabled)
  private var isMutationDisabled

  var body: some View {
    if let card = edge.card,
      edge.deletedAt == nil,
      selectedContentKind == nil || card.kind == selectedContentKind
    {
      row(for: card)
    }

    ForEach(children, id: \.id) { child in
      VaultSavedEntryTreeRows(
        edge: child,
        store: store,
        depth: depth + 1,
        selectedContentKind: selectedContentKind,
        ancestorEdgeIDs: ancestorEdgeIDs.union([edge.id]),
        ownerRootEdgeID: ownerRootEdgeID,
        onReply: onReply,
        onShare: onShare,
        onEdit: onEdit,
        onRequestDelete: onRequestDelete,
        onToggleTodoCompletion: onToggleTodoCompletion
      )
    }
  }

  /// Active, resolved children in authored order with a path-local cycle guard.
  private var children: [JournalVault.CardEdge] {
    VaultSavedListTreeTraversal.orderedActiveChildren(
      of: edge,
      pathEdgeIDs: ancestorEdgeIDs.union([edge.id])
    )
  }

  @ViewBuilder
  private func row(for card: JournalVault.Card) -> some View {
    let cell = VaultSavedEntryTreeCell(
      depth: depth,
      content: EntryContent(card: card, store: store),
      kind: card.kind,
      createdAt: card.createdAt,
      isMutationDisabled: isMutationDisabled,
      onReply: { onReply(edge, card, ownerRootEdgeID) },
      onShare: { onShare(edge, card) },
      onEdit: { onEdit(card) },
      onRequestDelete: { onRequestDelete(edge, card) },
      onToggleTodoCompletion: { onToggleTodoCompletion(card) }
    )

    if depth == 0 {
      cell.preference(
        key: SavedListRenderedEdgeIDsPreferenceKey.self,
        value: [edge.id]
      )
    } else {
      cell
        .id(edge.id)
        .preference(
          key: SavedListRenderedEdgeIDsPreferenceKey.self,
          value: [edge.id]
        )
    }
  }
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

  let content: EntryContent
  let kind: JournalVault.Card.Kind
  let isMutationDisabled: Bool
  let onReply: @MainActor () -> Void
  let onShare: @MainActor () -> Void
  let onEdit: @MainActor () -> Void
  let onRequestDelete: @MainActor () -> Void
  let onToggleTodoCompletion: @MainActor () -> Void

  var body: some View {
    EntryContentView(
      content: content,
      style: .cell,
      interaction: .interactive(isEnabled: isMutationDisabled == false) {
        action in
        switch action {
        case .toggleTodoCompletion:
          onToggleTodoCompletion()
        }
      }
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(.appOnSecondaryContainer)
    .contentShape(.rect)
    .contextMenu {
      Button {
        onReply()
      } label: {
        Label("Reply", systemImage: "arrowshape.turn.up.left")
      }

      Button {
        onShare()
      } label: {
        Label("Share", systemImage: "square.and.arrow.up")
      }

      Button {
        onEdit()
      } label: {
        Label("Edit", systemImage: "square.and.pencil")
      }
      .disabled(isMutationDisabled || kind == .file)

      Button(role: .destructive) {
        onRequestDelete()
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .disabled(isMutationDisabled)
    }
    .accessibilityAction(
      named: Text(
        "Reply",
        comment:
          "Accessibility action that selects this entry as a Reply parent."
      )
    ) {
      onReply()
    }
  }

}

/// Existing saved-entry card presentation within its proposed tree width.
///
/// Descendants reserve one marker gutter while the capsule count communicates
/// their semantic depth without progressively narrowing deeply nested cards.
struct VaultSavedEntryTreeCell: View {

  let depth: Int
  let content: EntryContent
  let kind: JournalVault.Card.Kind
  let createdAt: Date
  let isMutationDisabled: Bool
  let onReply: @MainActor () -> Void
  let onShare: @MainActor () -> Void
  let onEdit: @MainActor () -> Void
  let onRequestDelete: @MainActor () -> Void
  let onToggleTodoCompletion: @MainActor () -> Void

  var body: some View {
    HStack {

      SwipeCell {
        VStack {
          if depth > 0 {
            DepthIndicator(depth: depth)
              .frame(
                maxWidth: .infinity,
                alignment: .init(horizontal: .leading, vertical: .center)
              )
          }
          VaultSavedEntryRow(
            content: content,
            kind: kind,
            isMutationDisabled: isMutationDisabled,
            onReply: onReply,
            onShare: onShare,
            onEdit: onEdit,
            onRequestDelete: onRequestDelete,
            onToggleTodoCompletion: onToggleTodoCompletion
          )
        }
        .background(.appSecondaryContainer)
        .clipShape(.rect(cornerRadius: 24))
      } info: {
        VaultSavedEntryCreatedAtInfo(createdAt: createdAt)
      } onTrigger: {
        onReply()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
  }
}

/// Capture time disclosed behind a saved-entry card while it is swiped aside.
///
/// The day header already carries the calendar day for a root placement, but a
/// reply can be authored on a later day than the tree it hangs under, so the
/// date stays beside the time instead of being inferred from the section.
private struct VaultSavedEntryCreatedAtInfo: View {

  let createdAt: Date

  var body: some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(createdAt, format: .dateTime.hour().minute())
        .font(.system(size: 13))
        .fontWeight(.semibold)

      Text(createdAt, format: .dateTime.month(.abbreviated).day())
        .font(.system(size: 11))
    }
    .fontDesign(.rounded)
    .monospacedDigit()
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
  }
}

struct VaultSavedDayHeader: View {

  let isSticked: Bool
  let day: Date

  var body: some View {
    Text(day, format: .dateTime.weekday(.abbreviated).month(.wide).day().year())
      .font(.headline)
      .foregroundStyle(.appOnPrimaryContainer.opacity(0.72))
      .accessibilityAddTraits(.isHeader)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .animation(.smooth) {
        $0.glassEffect(isSticked ? .regular : .identity)
      }
      .padding(.horizontal, 16)
  }
}
