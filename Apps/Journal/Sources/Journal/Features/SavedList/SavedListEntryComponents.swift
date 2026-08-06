import AppUIComponents
import JournalVault
import MuColor
import SwiftUI

private let rootGroupContentPadding: CGFloat = 16
private let rootGroupCornerRadius: CGFloat = 24

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
  let transitionNamespace: Namespace.ID
  let onShare: @MainActor (VaultSavedEntry) -> Void
  let onEdit: @MainActor (VaultSavedEntry) -> Void
  let onRequestDelete: @MainActor (VaultSavedEntry) -> Void

  var body: some View {
    NavigationLink(
      value: SavedListNavigationRoute.entry(edgeID: entry.edgeID)
    ) {
      VaultSavedRootGroup(entry: entry.entryModel)
        .appMatchedTransitionSource(
          id: entry.edgeID,
          in: transitionNamespace
        )
    }
    .buttonStyle(.plain)
    .id(entry.edgeID)
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
}

/// Root-edge presentation used by Home's single-column reading stream.
///
/// The surface belongs to the root placement rather than to the authored card.
/// For now the group contains only its root content; direct children remain in
/// the relationship graph used by the destination instead of adding summary
/// labels or nested card surfaces to Home.
struct VaultSavedRootGroup: View {

  let entry: VaultSavedEntryModel

  var body: some View {
    EntryContentView(content: entry.content, style: .detail)
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(.appOnSecondaryContainer)
      .allowsHitTesting(false)  
      .clipShape(.rect(cornerRadius: 32))    
  }
}

struct VaultSavedDayHeader: View {

  let day: Date

  var body: some View {
    Text(day, format: .dateTime.weekday(.abbreviated).month(.wide).day().year())
      .font(.headline)
      .foregroundStyle(.appOnPrimaryContainer.opacity(0.72))
      .accessibilityAddTraits(.isHeader)
  }
}
