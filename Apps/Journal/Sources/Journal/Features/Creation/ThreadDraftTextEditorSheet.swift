import CaptureText
import SwiftUI

/// Native sheet shell for editing a text card from the composer.
///
/// New text capture owns local input until **Save**, while existing text cards
/// continue to edit their draft binding directly.
struct ThreadDraftTextEditorSheet: View {

  /// Draft whose body text and location metadata are edited by the sheet.
  /// `nil` means quick text capture should create/reuse a draft only on Save.
  let card: ThreadDraftCard?

  /// Whether the composer is currently saving and should block metadata edits.
  let isSaving: Bool

  /// Called when a new quick text capture commits non-empty text.
  let onCapture: @MainActor @Sendable (CapturedText) -> Void

  /// Toggles the card's attached coordinate through the Creation-level location
  /// permission bridge.
  let onToggleLocation: @MainActor @Sendable () -> Void

  var body: some View {
    if let card {
      ThreadDraftExistingTextEditorSheet(
        card: card,
        isSaving: isSaving,
        onToggleLocation: onToggleLocation
      )
    } else {
      ThreadDraftNewTextCaptureSheet(onCapture: onCapture)
    }
  }
}

/// Native sheet shell for editing an existing text draft.
private struct ThreadDraftExistingTextEditorSheet: View {

  @Environment(\.dismiss) private var dismiss

  /// Draft whose body text and location metadata are edited by the sheet.
  @Bindable var card: ThreadDraftCard

  /// Whether the composer is currently saving and should block metadata edits.
  let isSaving: Bool

  /// Toggles the card's attached coordinate through the Creation-level location
  /// permission bridge.
  let onToggleLocation: @MainActor @Sendable () -> Void

  var body: some View {
    NavigationStack {
      ThreadDraftTextEditorContent(text: $card.text)
        .navigationTitle("Text")
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
}

/// Native sheet shell for creating a new text draft from the quick action.
private struct ThreadDraftNewTextCaptureSheet: View {

  @Environment(\.dismiss) private var dismiss

  /// Called when `TextCaptureView` emits non-empty text.
  let onCapture: @MainActor @Sendable (CapturedText) -> Void

  var body: some View {
    NavigationStack {
      TextCaptureView(placeholder: "Write your thoughts...") { captured in
        onCapture(captured)
        dismiss()
      }
      .navigationTitle("Text")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
    }
  }
}

/// Large-form text input shared by the text sheet and draft detail editor.
struct ThreadDraftTextEditorContent: View {

  /// Body text for the draft card.
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
