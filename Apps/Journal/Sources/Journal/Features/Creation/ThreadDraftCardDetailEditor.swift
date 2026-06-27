import CaptureBauhaus
import JournalModel
import SwiftUI

/// Detail editor for one draft card.
///
/// The creation surface owns the card stack; this screen owns the kind-specific
/// editing experience for the selected card. Each capture component stays
/// persistence-agnostic and reports a value, which this app-shell layer converts
/// into the normalized payload stored on `ThreadDraftCard`.
struct ThreadDraftCardDetailEditor: View {

  @Environment(\.dismiss) private var dismiss

  @Bindable var card: ThreadDraftCard
  let isSaving: Bool
  let onToggleLocation: @MainActor @Sendable () -> Void

  var body: some View {
    VStack(spacing: 0) {
      ThreadDraftKindPicker(kind: $card.kind)
        .disabled(isSaving)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

      Divider()

      ThreadDraftKindEditor(card: card)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(.background)
    .navigationTitle(card.kind.editorTitle)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") {
          dismiss()
        }
      }

      ToolbarItem(placement: .navigationBarLeading) {
        Button(action: onToggleLocation) {
          Image(systemName: card.location != nil ? "location.fill" : "location")
        }
        .disabled(isSaving)
        .accessibilityLabel(card.location != nil ? "Location attached" : "Attach location")
      }
    }
  }
}

/// Segmented kind switcher for a draft card.
private struct ThreadDraftKindPicker: View {

  @Binding var kind: Card.Kind

  var body: some View {
    Picker("Card Kind", selection: $kind) {
      ForEach(Card.Kind.allCases, id: \.self) { kind in
        Text(kind.displayTitle)
          .tag(kind)
      }
    }
    .pickerStyle(.segmented)
  }
}

/// Routes the selected card kind to its concrete editor.
private struct ThreadDraftKindEditor: View {

  @Bindable var card: ThreadDraftCard

  var body: some View {
    ZStack {
      switch card.kind {
      case .text:
        ThreadDraftTextDetailEditor(text: $card.text)
      case .photo:
        ThreadDraftPhotoDetailEditor(card: card)
      case .audio:
        ThreadDraftAudioDetailEditor(card: card)
      case .doodle:
        ThreadDraftDoodleDetailEditor(card: card)
      case .bauhaus:
        ThreadDraftBauhausDetailEditor(card: card)
      @unknown default:
        ThreadDraftTextDetailEditor(text: $card.text)
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

  @Bindable var card: ThreadDraftCard

  var body: some View {
    ThreadDraftPhotoCaptureContent(card: card) { [card] photo in
      card.setPhoto(photo)
    }
  }
}

/// Recorder-backed editor for an ambient audio draft.
private struct ThreadDraftAudioDetailEditor: View {

  @Bindable var card: ThreadDraftCard

  var body: some View {
    ThreadDraftAudioRecorderContent(card: card) { [card] recording in
      card.setAudio(recording)
    }
  }
}

/// Vector-canvas editor for a doodle draft.
private struct ThreadDraftDoodleDetailEditor: View {

  @Bindable var card: ThreadDraftCard

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

  @Bindable var card: ThreadDraftCard

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
