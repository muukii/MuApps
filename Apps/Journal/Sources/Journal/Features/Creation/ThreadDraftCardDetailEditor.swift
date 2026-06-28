import CaptureBauhaus
import JournalModel
import SwiftUI

/// Detail editor for one creation draft card.
///
/// The creation surface owns the card stack; this screen owns the kind-specific
/// editing experience for the selected card. Each capture component stays
/// persistence-agnostic and reports a value, which this app-shell layer converts
/// into the normalized payload stored on `CardEditDraft`.
struct ThreadDraftCardDetailEditor: View {

  @Environment(\.dismiss) private var dismiss

  @Bindable var card: ThreadDraftCard
  let isSaving: Bool
  let onToggleLocation: @MainActor @Sendable () -> Void

  var body: some View {
    CardEditDraftEditor(
      draft: card,
      isSaving: isSaving,
      confirmationTitle: "Done",
      requiresSavableDraft: false,
      onConfirm: {
        dismiss()
      },
      onToggleLocation: onToggleLocation
    )
  }
}

/// Shared detail editor for a standalone card draft.
///
/// Creation, saved-entry editing, and previews can all bind to this component
/// because it only knows about `CardEditDraft`, capture values, and callbacks.
/// Persistence remains outside the view.
struct CardEditDraftEditor: View {

  @Bindable var draft: CardEditDraft
  let isSaving: Bool
  let confirmationTitle: String
  let requiresSavableDraft: Bool
  let showsKindPicker: Bool
  let onConfirm: @MainActor () -> Void
  let onToggleLocation: (@MainActor () -> Void)?

  init(
    draft: CardEditDraft,
    isSaving: Bool,
    confirmationTitle: String,
    requiresSavableDraft: Bool = true,
    showsKindPicker: Bool = true,
    onConfirm: @escaping @MainActor () -> Void,
    onToggleLocation: (@MainActor () -> Void)? = nil
  ) {
    self.draft = draft
    self.isSaving = isSaving
    self.confirmationTitle = confirmationTitle
    self.requiresSavableDraft = requiresSavableDraft
    self.showsKindPicker = showsKindPicker
    self.onConfirm = onConfirm
    self.onToggleLocation = onToggleLocation
  }

  var body: some View {
    VStack(spacing: 0) {
      if showsKindPicker {
        CardEditDraftKindPicker(kind: $draft.kind)
          .disabled(isSaving)
          .padding(.horizontal, 16)
          .padding(.vertical, 12)

        Divider()
      }

      CardEditDraftKindEditor(draft: draft)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(.background)
    .navigationTitle(draft.kind.editorTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(confirmationTitle) {
          onConfirm()
        }
        .disabled(isSaving || (requiresSavableDraft && draft.canSave == false))
      }

      if let onToggleLocation {
        ToolbarItem(placement: .navigationBarLeading) {
          Button(action: onToggleLocation) {
            Image(systemName: draft.location != nil ? "location.fill" : "location")
          }
          .disabled(isSaving)
          .accessibilityLabel(draft.location != nil ? "Location attached" : "Attach location")
        }
      }
    }
  }
}

/// Segmented kind switcher for a draft card.
private struct CardEditDraftKindPicker: View {

  @Binding var kind: Card.Kind

  /// Kinds a person can author. `.unknown` is excluded — it only appears on cards
  /// synced from a newer build and is never user-selectable.
  private var selectableKinds: [Card.Kind] {
    Card.Kind.allCases.filter { $0 != .unknown }
  }

  var body: some View {
    Picker("Card Kind", selection: $kind) {
      ForEach(selectableKinds, id: \.self) { kind in
        Text(kind.displayTitle)
          .tag(kind)
      }
    }
    .pickerStyle(.segmented)
  }
}

/// Routes the selected card kind to its concrete editor.
private struct CardEditDraftKindEditor: View {

  @Bindable var draft: CardEditDraft

  var body: some View {
    ZStack {
      switch draft.kind {
      case .text:
        ThreadDraftTextDetailEditor(text: $draft.text)
      case .photo:
        ThreadDraftPhotoDetailEditor(card: draft)
      case .audio:
        ThreadDraftAudioDetailEditor(card: draft)
      case .doodle:
        ThreadDraftDoodleDetailEditor(card: draft)
      case .bauhaus:
        ThreadDraftBauhausDetailEditor(card: draft)
      @unknown default:
        ThreadDraftTextDetailEditor(text: $draft.text)
      }
    }
  }
}

/// Full-screen text editor for a text draft.
private struct ThreadDraftTextDetailEditor: View {

  @Binding var text: String

  var body: some View {
    ThreadDraftTextEditorContent(text: $text)
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
      initialArtwork: card.bauhaus ?? .empty,
      onChange: { [card] artwork in
        guard artwork.isEmpty == false else {
          card.clearBauhaus()
          return
        }

        card.setBauhaus(artwork)
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
      return "Text Card"
    case .photo:
      return "Photo Card"
    case .audio:
      return "Audio Card"
    case .doodle:
      return "Doodle Card"
    case .bauhaus:
      return "Bauhaus Card"
    @unknown default:
      return "Card"
    }
  }
}

#Preview("Card Edit Draft Editor") {
  NavigationStack {
    CardEditDraftEditor(
      draft: CardEditDraft(
        kind: .text,
        text: "A shared draft makes creation, editing, and previews speak the same card language."
      ),
      isSaving: false,
      confirmationTitle: "Save",
      onConfirm: {}
    )
  }
}
