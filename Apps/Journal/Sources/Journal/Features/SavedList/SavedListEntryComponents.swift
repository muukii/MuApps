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
      interaction: .interactive(isEnabled: isMutationDisabled == false) {
        action in
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
        comment:
          "Accessibility action that selects this entry as a Reply parent."
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
    HStack {

      if depth > 0 {

        Text(depth.description)
          .font(.system(size: 12))
          .fontWeight(.semibold)
          .fontDesign(.rounded)
          .padding(5)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .foregroundStyle(.quinary)
          )
          .foregroundStyle(.tint)
          .frame(width: 26, alignment: .center)
          .padding(.leading, -10)

      }

      SwipeCell {
        VStack {
          //          if depth > 0 {
          //            DepthIndicator(depth: depth)
          //              .frame(
          //                maxWidth: .infinity,
          //                alignment: .init(horizontal: .leading, vertical: .center)
          //              )
          //          }
          VaultSavedEntryRow(
            entry: entry,
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
        VaultSavedEntryCreatedAtInfo(createdAt: entry.createdAt)
      } onTrigger: {
        onReply(entry)
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
