import AppUIComponents
import JournalVault
import MuColor
import SwiftUI

/// Shared spacing for trees rendered on Home.
struct VaultSavedEntryTreeMetrics {
  static let descendantMarkerGutter: CGFloat = 16
  static let nodeSpacing: CGFloat = 2
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
  let isMutationDisabled: Bool
  let onReply: @MainActor (VaultSavedEntry) -> Void
  let onShare: @MainActor (VaultSavedEntry) -> Void
  let onEdit: @MainActor (VaultSavedEntry) -> Void
  let onRequestDelete: @MainActor (VaultSavedEntry) -> Void
  let onToggleTodoCompletion: @MainActor (VaultSavedEntry) -> Void

  init(
    entry: VaultSavedEntry,
    isMutationDisabled: Bool,
    onReply: @escaping @MainActor (VaultSavedEntry) -> Void,
    onShare: @escaping @MainActor (VaultSavedEntry) -> Void,
    onEdit: @escaping @MainActor (VaultSavedEntry) -> Void,
    onRequestDelete: @escaping @MainActor (VaultSavedEntry) -> Void,
    onToggleTodoCompletion: @escaping @MainActor (VaultSavedEntry) -> Void
  ) {
    self.entry = entry
    self.isMutationDisabled = isMutationDisabled
    self.onReply = onReply
    self.onShare = onShare
    self.onEdit = onEdit
    self.onRequestDelete = onRequestDelete
    self.onToggleTodoCompletion = onToggleTodoCompletion
  }

  var body: some View {
    VaultSavedRootGroup(
      entry: entry.entryModel,
      interaction: .interactive(isEnabled: isMutationDisabled == false) { action in
        switch action {
        case .toggleTodoCompletion:
          onToggleTodoCompletion(entry)
        }
      }
    )
    .contentShape(.rect)
    .contextMenu {
      Button {
        onReply(entry)
      } label: {
        Label("Reply", systemImage: "arrowshape.turn.up.left")
      }

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
    .accessibilityAction(
      named: Text(
        "Reply",
        comment: "Accessibility action that selects this entry as a Reply parent."
      )
    ) {
      onReply(entry)
    }
  }

}

/// Existing saved-entry card presentation within its proposed tree width.
///
/// Descendants reserve one marker gutter while the capsule count communicates
/// their semantic depth without progressively narrowing deeply nested cards.
struct VaultSavedEntryTreeCell: View {

  let depth: Int
  let entry: VaultSavedEntry
  let isMutationDisabled: Bool
  let onReply: @MainActor (VaultSavedEntry) -> Void
  let onShare: @MainActor (VaultSavedEntry) -> Void
  let onEdit: @MainActor (VaultSavedEntry) -> Void
  let onRequestDelete: @MainActor (VaultSavedEntry) -> Void
  let onToggleTodoCompletion: @MainActor (VaultSavedEntry) -> Void

  var body: some View {
    SwipeCell {
      VaultSavedEntryRow(
        entry: entry,
        isMutationDisabled: isMutationDisabled,
        onReply: onReply,
        onShare: onShare,
        onEdit: onEdit,
        onRequestDelete: onRequestDelete,
        onToggleTodoCompletion: onToggleTodoCompletion
      )
    } onTrigger: {
      onReply(entry)
    }
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

/// Saved-edge presentation shared by every depth of a Home tree.
///
/// The surface belongs to one placement rather than to the authored card. Tree
/// indentation stays outside this type so the card's current media and content
/// behavior is identical at every depth.
struct VaultSavedRootGroup: View {

  let entry: VaultSavedEntryModel
  let interaction: EntryContentView.Interaction

  var body: some View {
    EntryContentView(
      content: entry.content,
      style: .cell,
      interaction: interaction
    )
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(.appOnSecondaryContainer)
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
