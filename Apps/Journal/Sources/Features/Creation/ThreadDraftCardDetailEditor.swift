import CaptureAudio
import CaptureDoodle
import CapturePhoto
import JournalModel
import MuColor
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
      ToolbarItem(placement: .cancellationAction) {
        Button("Done") {
          dismiss()
        }
      }

      ToolbarItem(placement: .navigationBarTrailing) {
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
      @unknown default:
        ThreadDraftTextDetailEditor(text: $card.text)
      }
    }
  }
}

/// Full-screen text editor for a text draft.
private struct ThreadDraftTextDetailEditor: View {

  @Binding var text: String
  @FocusState private var isFocused: Bool

  var body: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        Text("Write your thoughts...")
          .foregroundStyle(.secondary)
          .padding(.horizontal, 20)
          .padding(.vertical, 24)
          .allowsHitTesting(false)
      }

      TextEditor(text: $text)
        .foregroundStyle(.primary)
        .focused($isFocused)
        .scrollContentBackground(.hidden)
        .padding(16)
    }
    .font(.system(size: 32, weight: .bold))
    .onAppear { isFocused = true }
  }
}

/// Camera-backed editor for a photo draft.
private struct ThreadDraftPhotoDetailEditor: View {

  @Bindable var card: ThreadDraftCard
  @State private var isCapturingReplacement: Bool = false

  var body: some View {
    if isCapturingReplacement || card.photo == nil {
      PhotoCaptureView { [card] photo in
        card.setPhoto(photo)
        isCapturingReplacement = false
      }
      .overlay(alignment: .topTrailing) {
        if card.photo != nil {
          DraftCapturedBanner(title: "Photo captured", systemImage: "checkmark.circle.fill")
            .padding()
        }
      }
      .clipped()
    } else {
      ThreadDraftPhotoExistingContent(
        photo: card.photo,
        onRetake: {
          isCapturingReplacement = true
        }
      )
    }
  }
}

/// Displays the still already attached to a photo draft.
private struct ThreadDraftPhotoExistingContent: View {

  let photo: CapturedPhoto?
  let onRetake: @MainActor @Sendable () -> Void

  private var image: UIImage? {
    photo?.image
  }

  var body: some View {
    ZStack {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        MissingDraftMediaContent(
          systemImage: "photo",
          title: "Photo unavailable"
        )
      }

      VStack {
        Spacer()
        Button(action: onRetake) {
          Label("Retake Photo", systemImage: "camera.rotate")
        }
        .buttonStyle(.borderedProminent)
        .padding(.bottom, 32)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
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

  @Environment(\.appPalette) private var palette
  @Bindable var card: ThreadDraftCard

  var body: some View {
    DoodleCanvasView(
      inkColor: palette.tint,
      initialDrawing: card.doodle,
      onChange: { [card] drawing in
        guard let drawing else {
          card.clearDoodle()
          return
        }

        card.setDoodle(drawing)
      }
    )
    .overlay(alignment: .topTrailing) {
      if card.doodle != nil {
        DraftCapturedBanner(title: "Doodle saved", systemImage: "checkmark.circle.fill")
          .padding()
      }
    }
  }
}

/// Placeholder for a draft whose media reference exists but cannot be decoded.
private struct MissingDraftMediaContent: View {

  let systemImage: String
  let title: LocalizedStringResource

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 54, weight: .light))
      Text(title)
        .font(.headline)
    }
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @unknown default:
      return "Card"
    }
  }
}
