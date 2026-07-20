import AppUIComponents
import CaptureBauhaus
import JournalVault
import SwiftUI

/// Detail editor for one unpublished entry.
///
/// The creation input bar owns one draft; this screen owns that content type's
/// editing experience. Each capture component stays
/// persistence-agnostic and reports a value, which this app-shell layer converts
/// into the normalized payload stored on `CardEditDraft`.
struct ThreadDraftEntryDetailEditor: View {

  @Environment(\.dismiss) private var dismiss

  @Bindable var draft: ThreadDraftCard
  let isSaving: Bool

  var body: some View {
    EntryDraftEditor(
      draft: draft,
      isSaving: isSaving,
      confirmationTitle: "Done",
      requiresSavableDraft: false,
      showsKindPicker: false,
      onConfirm: {
        dismiss()
      }
    )
  }
}

/// Shared detail editor for a standalone entry draft.
///
/// Creation, saved-entry editing, and previews can all bind to this component
/// because it only knows about `CardEditDraft`, capture values, and callbacks.
/// Persistence remains outside the view.
struct EntryDraftEditor: View {

  @Bindable var draft: CardEditDraft
  let isSaving: Bool
  let confirmationTitle: LocalizedStringResource
  let requiresSavableDraft: Bool
  let showsKindPicker: Bool
  let onConfirm: @MainActor () -> Void

  init(
    draft: CardEditDraft,
    isSaving: Bool,
    confirmationTitle: LocalizedStringResource,
    requiresSavableDraft: Bool = true,
    showsKindPicker: Bool = true,
    onConfirm: @escaping @MainActor () -> Void
  ) {
    self.draft = draft
    self.isSaving = isSaving
    self.confirmationTitle = confirmationTitle
    self.requiresSavableDraft = requiresSavableDraft
    self.showsKindPicker = showsKindPicker
    self.onConfirm = onConfirm
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsKindPicker {
        EntryContentKindPicker(kind: $draft.kind)
          .disabled(isSaving)
          .padding(.horizontal, 16)
          .padding(.vertical, 12)

        Divider()
      }

      EntryContentKindEditor(draft: draft)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(.background)
    .navigationTitle(draft.kind.editorTitle)
    .appInlineNavigationTitle()
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button {
          onConfirm()
        } label: {
          Text(confirmationTitle)
        }
        .disabled(isSaving || (requiresSavableDraft && draft.canSave == false))
      }
    }
  }
}

/// Segmented content-type switcher for a draft entry.
private struct EntryContentKindPicker: View {

  @Binding var kind: Card.Kind

  /// Kinds a person can author. `.unknown` is excluded — it only appears on cards
  /// synced from a newer build and is never user-selectable.
  private var selectableKinds: [Card.Kind] {
    Card.Kind.allCases.filter { kind in
      switch kind {
      case .file, .video, .livePhoto, .suggestion, .unknown:
        return false
      case .text, .link, .photo, .audio, .doodle, .bauhaus:
        return true
      }
    }
  }

  var body: some View {
    Picker("Content Type", selection: $kind) {
      ForEach(selectableKinds, id: \.self) { kind in
        Text(kind.displayTitle)
          .tag(kind)
      }
    }
    .pickerStyle(.segmented)
  }
}

/// Routes the selected persisted kind to its concrete content editor.
private struct EntryContentKindEditor: View {

  @Bindable var draft: CardEditDraft

  var body: some View {
    ZStack {
      switch draft.kind {
      case .text:
        ThreadDraftTextEditorContent(text: $draft.text)
      case .link:
        ThreadDraftLinkEditorContent(urlString: $draft.text)
      case .file:
        ContentUnavailableView(
          "File Editing Unavailable",
          systemImage: "doc",
          description: Text("Files shared to Tinycurve stay attached to their original entry.")
        )
      case .photo:
        ThreadDraftPhotoDetailEditor(card: draft)
      case .video, .livePhoto:
        EntryContentView(content: draft.entryContent, style: .detail)
          .padding(16)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      case .audio:
        ThreadDraftAudioDetailEditor(card: draft)
      case .suggestion:
        EntryContentView(content: draft.entryContent, style: .detail)
          .padding(16)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      case .doodle:
        ThreadDraftDoodleDetailEditor(card: draft)
      case .bauhaus:
        ThreadDraftBauhausDetailEditor(card: draft)
      case .unknown:
        ThreadDraftTextEditorContent(text: $draft.text)
      @unknown default:
        ThreadDraftTextEditorContent(text: $draft.text)
      }
    }
  }
}

/// Camera-backed editor for a photo draft.
private struct ThreadDraftPhotoDetailEditor: View {

  @Bindable var card: CardEditDraft

  var body: some View {
    ThreadDraftPhotoCaptureContent(card: card) { [card] photo in
      card.setPhoto(photo)
    }
  }
}

/// Recorder-backed editor for an ambient audio draft.
private struct ThreadDraftAudioDetailEditor: View {

  @Bindable var card: CardEditDraft

  var body: some View {
    ThreadDraftAudioRecorderContent(card: card) { [card] recording in
      card.setAudio(recording)
    }
  }
}

/// Vector-canvas editor for a doodle draft.
private struct ThreadDraftDoodleDetailEditor: View {

  @Bindable var card: CardEditDraft

  var body: some View {
    ThreadDraftDoodleCanvasContent(card: card) { [card] drawing in
      guard let drawing else {
        card.clearDoodle()
        return
      }

      card.setDoodle(drawing)
    }
  }
}

/// Grid editor for a Bauhaus artwork draft.
private struct ThreadDraftBauhausDetailEditor: View {

  @Bindable var card: CardEditDraft

  var body: some View {
    BauhausGridCaptureView(
      initialDocument: card.bauhaus ?? .empty,
      onChange: { [card] document in
        guard document.artwork.isEmpty == false else {
          card.clearBauhaus()
          return
        }

        card.setBauhaus(document)
      }
    )
  }
}

/// Small confirmation chip shown after a capture writes back to the draft.
private struct DraftCapturedBanner: View {

  let title: LocalizedStringResource
  let systemImage: String

  var body: some View {
    Label {
      Text(title)
    } icon: {
      Image(systemName: systemImage)
    }
    .font(.footnote.weight(.semibold))
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.ultraThinMaterial, in: Capsule())
  }
}

extension Card.Kind {

  /// Navigation title for the selected kind editor.
  fileprivate var editorTitle: LocalizedStringResource {
    switch self {
    case .text:
      return "Text"
    case .link:
      return "Link"
    case .file:
      return "File"
    case .photo:
      return "Photo"
    case .video:
      return "Video"
    case .livePhoto:
      return "Live Photo"
    case .audio:
      return "Audio"
    case .suggestion:
      return "Suggestion"
    case .doodle:
      return "Doodle"
    case .bauhaus:
      return "Bauhaus"
    case .unknown:
      return "Entry"
    @unknown default:
      return "Entry"
    }
  }
}

#Preview("Entry Draft Editor") {
  NavigationStack {
    EntryDraftEditor(
      draft: CardEditDraft(
        kind: .text,
        text: "A shared draft keeps creation, editing, and display on the same content model."
      ),
      isSaving: false,
      confirmationTitle: "Save",
      onConfirm: {}
    )
  }
}
